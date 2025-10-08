//
// Project: SwiftDataCounter
// Author: Mark Battistella
// Website: https://markbattistella.com
//

import Foundation
import Observation
import SwiftData
import SimpleLogger

/// A tuple pairing a persistent model type with an optional item limit.
public typealias PersistentModelLimit = (type: any FetchablePersistentModel.Type, limit: Int?)

/// A utility for tracking entity counts across multiple persistent model types.
///
/// `EntityCounter` maintains per-model counts, applies optional limits, and provides queries for
/// remaining capacity and limit checks. Counts are refreshed automatically when the associated
/// `ModelContext` saves.
@MainActor
@Observable
public final class EntityCounter {

    /// Logger configured for SwiftData operations.
    private let logger = SimpleLogger(category: .swiftData)

    /// Map of tracked model identifiers to their current count and limit data.
    private(set) var totals: [ObjectIdentifier: Count] = [:]

    /// The list of tracked models and their optional per-model limits.
    private let models: [PersistentModelLimit]

    /// The default limit applied when a model does not specify one.
    private let defaultLimit: Int?

    /// The `ModelContext` used for fetching counts and observing changes.
    private var context: ModelContext?

    /// A Boolean value indicating whether the entity counts have completed their initial load.
    public private(set) var isLoaded = false

    // MARK: - Init

    /// Creates a counter for the given models with no default limit.
    ///
    /// - Parameters:
    ///   - context: The context used for fetching and observing.
    ///   - models: Model/limit pairs to track.
    public convenience init(context: ModelContext?, for models: PersistentModelLimit...) {
        self.init(context: context, for: models, default: nil)
    }

    /// Creates a counter for the given models with a shared default limit.
    ///
    /// - Parameters:
    ///   - context: The context used for fetching and observing.
    ///   - models: Model types to track.
    ///   - defaultLimit: The default maximum count applied to each model.
    public convenience init(
        context: ModelContext?,
        for models: any FetchablePersistentModel.Type...,
        defaultLimit: Int
    ) {
        let mapped = models.map { (type: $0, limit: defaultLimit) }
        self.init(context: context, for: mapped, default: defaultLimit)
    }

    /// Creates a counter with explicit model/limit pairs.
    ///
    /// - Parameters:
    ///   - context: The context used for fetching and observing.
    ///   - models: Model/limit pairs to track.
    ///   - limit: A default limit for models without a specific limit.
    private init(context: ModelContext?, for models: [PersistentModelLimit], default limit: Int?) {
        self.context = context
        self.models = models
        self.defaultLimit = limit

        let cachedCounts = UserDefaults.standard.dictionary(forKey: "EntityCounter_LastCounts") as? [String: Int] ?? [:]
        let cachedLimits = UserDefaults.standard.dictionary(forKey: "EntityCounter_LastLimits") as? [String: Int] ?? [:]

        for (modelType, limit) in models {
            let name = String(describing: modelType)
            let cachedCount = cachedCounts[name] ?? 0
            let cachedLimit = cachedLimits[name] ?? limit
            totals[ObjectIdentifier(modelType)] = Count(count: cachedCount, freeLimit: cachedLimit)
            logger.debug("Loaded cached \(name) count=\(cachedCount), limit=\(cachedLimit ?? -1)")
        }

        logger.info("EntityCounter initialised. Cached counts loaded.")
    }

    /// Begins observing the associated `ModelContext` for save notifications and performs the
    /// initial count refresh.
    ///
    /// Call this method once after creating the `EntityCounter` instance. It runs an initial
    /// `refresh()` to populate counts, sets the `isLoaded` flag to `true`, and then continues
    /// monitoring the context for changes.
    ///
    /// This method suspends indefinitely while listening for `ModelContext.didSave` notifications,
    /// refreshing counts each time the context is saved.
    public func startTracking() async {
        guard !isLoaded else {
            logger.debug("EntityCounter already tracking — skipping new observer registration")
            return
        }

        logger.info("EntityCounter starting tracking for \(self.models.count, privacy: .public) models")

        await observeContextSaves()
        refresh()

        isLoaded = true
        logger.info("EntityCounter initial refresh complete. isLoaded = true")
    }
}

extension EntityCounter {

    /// Holds the current count and optional limit for a tracked model.
    public struct Count {

        /// The current number of entities.
        public var count: Int

        /// The optional maximum allowed count.
        public var freeLimit: Int?
    }

    /// Defines how combined limits are calculated.
    public enum LimitScope {

        /// Include all models, even unlimited ones.
        case all

        /// Exclude unlimited models from combined limit calculations.
        case excludingUnlimited
    }
}

extension EntityCounter {

    /// Returns the current count for a given model type.
    ///
    /// - Parameter modelType: The model type to query.
    /// - Returns: The current entity count, or `0` if not tracked.
    public func count<T: PersistentModel>(for modelType: T.Type) -> Int {
        totals[ObjectIdentifier(modelType)]?.count ?? 0
    }

    /// Returns the remaining capacity before reaching the model's limit.
    ///
    /// - Parameter modelType: The model type to query.
    /// - Returns: The number of additional entities allowed.
    /// - Precondition: The model type must have a defined limit.
    public func remaining<T: PersistentModel>(for modelType: T.Type) -> Int {
        let mc = totals[ObjectIdentifier(modelType)] ?? defaultModelCount()
        guard let freeLimit = mc.freeLimit else {
            logger.error("Asked for remaining on unlimited model: \(modelType, privacy: .public)")
            preconditionFailure("Asked for remaining on unlimited model: \(modelType)")
        }
        return max(freeLimit - mc.count, 0)
    }

    /// Returns whether the model type currently exceeds its limit.
    ///
    /// - Parameter modelType: The model type to query.
    /// - Returns: `true` if the entity count exceeds the limit, otherwise `false`.
    public func isOverLimit<T: PersistentModel>(for modelType: T.Type) -> Bool {
        let mc = totals[ObjectIdentifier(modelType)] ?? defaultModelCount()
        guard let freeLimit = mc.freeLimit else { return false }
        return mc.count > freeLimit
    }

    /// Returns the limit for the given model type.
    ///
    /// - Parameter modelType: The model type to query.
    /// - Returns: The defined limit.
    /// - Precondition: The model type must have a defined limit.
    public func limit<T: PersistentModel>(for modelType: T.Type) -> Int {
        let mc = totals[ObjectIdentifier(modelType)] ?? defaultModelCount()
        guard let freeLimit = mc.freeLimit else {
            logger.error("Asked for limit on unlimited model: \(modelType, privacy: .public)")
            preconditionFailure("Asked for limit on unlimited model: \(modelType)")
        }
        return freeLimit
    }

    /// Updates the entity limit for a specific persistent model type.
    ///
    /// Use this method to dynamically adjust the allowed entity count for a tracked model, such
    /// as when user entitlements or app configuration changes. The method updates the internal
    /// limit, logs the change, and triggers a refresh of all tracked counts.
    ///
    /// - Parameters:
    ///   - newLimit: The new maximum number of entities permitted for the specified model type.
    ///     Pass `nil` to remove the limit and treat the model as unlimited.
    ///   - modelType: The persistent model type whose limit should be updated.
    ///
    /// - Note: If the model type is not currently being tracked, this call has no effect.
    public func updateLimit<T: PersistentModel>(_ newLimit: Int?, for modelType: T.Type) {
        let key = ObjectIdentifier(modelType)
        guard var current = totals[key] else { return }
        current.freeLimit = newLimit
        totals[key] = current
        logger.info("\(modelType, privacy: .public) limit updated to \(newLimit?.description ?? "unlimited")")
        refresh()
    }
}

extension EntityCounter {

    /// Returns the default count object using the global default limit.
    private func defaultModelCount() -> Count {
        Count(count: 0, freeLimit: defaultLimit)
    }

    /// Returns the total entity count across all tracked models.
    public var grandCount: Int {
        totals.values.reduce(0) { $0 + $1.count }
    }

    /// Returns the combined limit across tracked models.
    ///
    /// - Parameter scope: Whether to include unlimited models.
    /// - Returns: The combined limit, or `nil` if unlimited and scope is `.all`.
    public func combinedLimit(scope: LimitScope = .all) -> Int? {
        switch scope {
            case .all:
                if totals.values.contains(where: { $0.freeLimit == nil }) {
                    return nil
                }
                return totals.values.compactMap { $0.freeLimit }.reduce(0, +)

            case .excludingUnlimited:
                return totals.values.compactMap { $0.freeLimit }.reduce(0, +)
        }
    }

    /// Returns the combined remaining capacity across tracked models.
    ///
    /// - Parameter scope: Whether to include unlimited models.
    /// - Returns: Remaining capacity, or `nil` if unlimited.
    public func combinedRemaining(scope: LimitScope = .all) -> Int? {
        guard let limit = combinedLimit(scope: scope) else { return nil }
        return max(limit - grandCount, 0)
    }

    /// Returns `true` if any tracked model exceeds its limit.
    public var isOverAnyLimit: Bool {
        totals.values.contains {
            guard let limit = $0.freeLimit else { return false }
            return $0.count > limit
        }
    }
}

extension EntityCounter {

    /// Refreshes entity counts for all tracked models.
    private func refresh() {
        guard let context else {
            logger.error("Refresh called before context was set")
            return
        }

        var countSnapshot: [String: Int] = [:]
        var limitSnapshot: [String: Int] = [:]

        logger.debug("Refreshing entity counts for \(self.models.count, privacy: .public) models")

        for (modelType, limit) in models {
            do {
                let newCount = try fetchCount(for: modelType, in: context)
                let key = ObjectIdentifier(modelType)
                let oldCount = totals[key]?.count

                logChanges(for: modelType, oldCount: oldCount, newCount: newCount, freeLimit: limit)
                totals[key] = Count(count: newCount, freeLimit: limit)

                countSnapshot[String(describing: modelType)] = newCount
                if let limit { limitSnapshot[String(describing: modelType)] = limit }
            } catch {
                logger.error("Failed to fetch \(String(describing: modelType)) count: \(error.localizedDescription, privacy: .public)")
            }
        }

        UserDefaults.standard.set(countSnapshot, forKey: "EntityCounter_LastCounts")
        UserDefaults.standard.set(limitSnapshot, forKey: "EntityCounter_LastLimits")
        logger.debug("Cached counts: \(countSnapshot), limits: \(limitSnapshot)")

        if !isLoaded {
            logger.notice("EntityCounter switching from cached to live data.")
        }
        isLoaded = true
    }

    /// Logs changes in count and limit status for a given model type.
    ///
    /// - Parameters:
    ///   - modelType: The model type being updated.
    ///   - oldCount: The previous entity count.
    ///   - newCount: The new entity count.
    ///   - freeLimit: The optional maximum allowed count.
    private func logChanges(
        for modelType: any FetchablePersistentModel.Type,
        oldCount: Int?,
        newCount: Int,
        freeLimit: Int?
    ) {
        if oldCount != newCount {
            let delta = (oldCount == nil) ? newCount : newCount - (oldCount ?? 0)
            logger.info(
                "\(String(describing: modelType)) count updated from \(oldCount ?? 0, privacy: .public) → \(newCount, privacy: .public) (Δ \(delta, privacy: .public))"
            )
        }

        if let freeLimit {
            let oldOver = (oldCount ?? 0) > freeLimit
            let newOver = newCount > freeLimit

            if !oldOver, newOver {
                logger.warning("\(String(describing: modelType)) exceeded limit \(freeLimit, privacy: .public). Current count: \(newCount, privacy: .public)")
            } else if oldOver, !newOver {
                logger.info("\(String(describing: modelType)) is back under limit \(freeLimit, privacy: .public). Current count: \(newCount, privacy: .public)")
            }
        }
    }

    /// Fetches the current count for a given model type.
    ///
    /// - Parameters:
    ///   - modelType: The persistent model type to count.
    ///   - context: The model context used to query.
    /// - Throws: `EntityCounterError.unsupportedModelType` if the type does not support counting.
    /// - Returns: The number of entities.
    private func fetchCount(
        for modelType: (some FetchablePersistentModel).Type,
        in context: ModelContext
    ) throws -> Int {
        do {
            return try context.fetchCount(modelType.fetchDescriptor)
        } catch let error as EntityCounterError {

            let modelTypeDescription = String(describing: modelType)

            if let description = error.errorDescription {
                logger.error("EntityCounterError: \(description, privacy: .public)")
            }
            if let reason = error.failureReason {
                logger.error("Failure reason: \(reason, privacy: .public)")
            }
            if let suggestion = error.recoverySuggestion {
                logger.log("Recovery suggestion: \(suggestion, privacy: .public)")
            }

            throw EntityCounterError.unsupportedModelType(modelTypeDescription)
        } catch {
            logger.error("Unexpected error: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    /// Observes save notifications on the model context and refreshes counts when changes occur.
    private func observeContextSaves() async {
        guard let context else {
            logger.error("observeContextSaves() called with nil context")
            return
        }

        logger.debug("Observing ModelContext.didSave notifications for \(String(describing: context))")

        for await note in NotificationCenter.default.notifications(named: ModelContext.didSave) {
            guard let obj = note.object as? ModelContext, obj === context else { continue }
            logger.debug("ModelContext.didSave detected — refreshing entity counts")
            self.refresh()
        }
    }
}
