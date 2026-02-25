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
///
/// Tracking starts automatically on initialisation. Call ``stopTracking()`` to cancel observation
/// when the counter is no longer needed.
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

    /// The namespaced `UserDefaults` key used to cache the last known counts.
    private let cacheKey: String

    /// The background task that observes `ModelContext` saves.
    private var observationTask: Task<Void, Never>?

    /// A Boolean value indicating whether the entity counts have completed their initial live load.
    public private(set) var isLoaded = false

    // MARK: - Init

    /// Creates a counter for the given models with no default limit.
    ///
    /// Tracking starts automatically. Remove the need to call `startTracking()`.
    ///
    /// - Parameters:
    ///   - context: The context used for fetching and observing.
    ///   - models: Model/limit pairs to track.
    public convenience init(context: ModelContext?, for models: PersistentModelLimit...) {
        self.init(context: context, for: models, default: nil)
    }

    /// Creates a counter for the given models with a shared default limit.
    ///
    /// Tracking starts automatically.
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

        // Build a stable, namespaced cache key from sorted model type names so that multiple
        // EntityCounter instances tracking different model sets never share cached data.
        let modelNames = models.map { String(describing: $0.type) }.sorted().joined(separator: "_")
        self.cacheKey = "EntityCounter_\(modelNames)_Counts"

        // Load cached counts for instant display before the first live fetch completes.
        // Limits are NOT cached — they always come from config or updateLimit().
        let cachedCounts = UserDefaults.standard.dictionary(forKey: cacheKey) as? [String: Int] ?? [:]

        for (modelType, modelLimit) in models {
            let name = String(describing: modelType)
            let cachedCount = cachedCounts[name] ?? 0
            totals[ObjectIdentifier(modelType)] = Count(count: cachedCount, freeLimit: modelLimit)
            logger.debug("Loaded cached \(name) count=\(cachedCount), limit=\(modelLimit ?? -1)")
        }

        logger.info("EntityCounter initialised. Tracking \(models.count) models.")

        // Auto-start observation. The Task is stored so it can be cancelled via stopTracking().
        observationTask = Task { @MainActor [weak self] in
            await self?.beginTracking()
        }
    }
}

// MARK: - Lifecycle

extension EntityCounter {

    /// Stops observing context saves and cancels the background tracking task.
    ///
    /// Call this when the counter is no longer needed — for example during teardown of the
    /// object that owns it — to prevent continued observation after the context is gone.
    public func stopTracking() {
        observationTask?.cancel()
        observationTask = nil
        logger.info("EntityCounter tracking stopped.")
    }

    /// Performs the initial live fetch and then enters the save-observation loop.
    private func beginTracking() async {
        guard let context else {
            logger.error("beginTracking() called with nil context — counts will remain cached")
            return
        }

        logger.info("EntityCounter starting tracking for \(self.models.count) models")

        // Populate live counts before entering the infinite observation loop.
        refresh()
        isLoaded = true
        logger.info("EntityCounter initial refresh complete. isLoaded = true")

        // Observe subsequent saves indefinitely until the task is cancelled.
        for await note in NotificationCenter.default.notifications(named: ModelContext.didSave) {
            if Task.isCancelled { break }
            guard let obj = note.object as? ModelContext, obj === context else { continue }
            logger.debug("ModelContext.didSave detected — refreshing entity counts")
            refresh()
        }
    }
}

// MARK: - Per-model queries

extension EntityCounter {

    /// Holds the current count and optional limit for a tracked model.
    public struct Count {

        /// The current number of entities.
        public var count: Int

        /// The optional maximum allowed count. `nil` means unlimited.
        public var freeLimit: Int?
    }

    /// Defines how combined limits and remaining values are calculated.
    public enum LimitScope {

        /// Include all models, even unlimited ones.
        case all

        /// Exclude unlimited models from combined limit calculations.
        case excludingUnlimited
    }

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
    /// - Returns: The number of additional entities allowed, or `nil` if the model is unlimited.
    public func remaining<T: PersistentModel>(for modelType: T.Type) -> Int? {
        let mc = totals[ObjectIdentifier(modelType)] ?? defaultModelCount()
        guard let freeLimit = mc.freeLimit else { return nil }
        return max(freeLimit - mc.count, 0)
    }

    /// Returns whether the model type currently exceeds its limit.
    ///
    /// Always returns `false` for unlimited models.
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
    /// - Returns: The defined limit, or `nil` if the model is unlimited.
    public func limit<T: PersistentModel>(for modelType: T.Type) -> Int? {
        let mc = totals[ObjectIdentifier(modelType)] ?? defaultModelCount()
        return mc.freeLimit
    }

    /// Updates the entity limit for a specific persistent model type.
    ///
    /// Use this to dynamically adjust the allowed entity count — for example when user
    /// entitlements change after an IAP. The updated limit survives subsequent context saves.
    ///
    /// - Parameters:
    ///   - newLimit: The new maximum. Pass `nil` to remove the limit (unlimited).
    ///   - modelType: The persistent model type whose limit should be updated.
    ///
    /// - Note: If the model type is not currently tracked, this call has no effect.
    public func updateLimit<T: PersistentModel>(_ newLimit: Int?, for modelType: T.Type) {
        let key = ObjectIdentifier(modelType)
        guard var current = totals[key] else { return }
        guard current.freeLimit != newLimit else { return }
        current.freeLimit = newLimit
        totals[key] = current
        logger.info("\(modelType, privacy: .public) limit updated to \(newLimit?.description ?? "unlimited")")
        refresh()
    }
}

// MARK: - Aggregate queries

extension EntityCounter {

    /// Returns the total entity count across all tracked models.
    public var grandCount: Int {
        totals.values.reduce(0) { $0 + $1.count }
    }

    /// Returns the sum of entity counts for models that have a defined limit.
    private func countForLimitedModels() -> Int {
        totals.values.reduce(0) { $0 + ($1.freeLimit != nil ? $1.count : 0) }
    }

    /// Returns the combined limit across tracked models.
    ///
    /// - Parameter scope: Whether to include unlimited models.
    /// - Returns: The combined limit, or `nil` if any model is unlimited and scope is `.all`.
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
    /// When scope is `.excludingUnlimited`, only counts entities from limited models are used
    /// in the calculation — unlimited model counts are excluded.
    ///
    /// - Parameter scope: Whether to include unlimited models.
    /// - Returns: Remaining capacity, or `nil` if the effective limit is unlimited.
    public func combinedRemaining(scope: LimitScope = .all) -> Int? {
        guard let limit = combinedLimit(scope: scope) else { return nil }
        let relevantCount = scope == .excludingUnlimited ? countForLimitedModels() : grandCount
        return max(limit - relevantCount, 0)
    }

    /// Returns `true` if any tracked model exceeds its limit.
    public var isOverAnyLimit: Bool {
        totals.values.contains {
            guard let limit = $0.freeLimit else { return false }
            return $0.count > limit
        }
    }
}

// MARK: - Internal helpers

extension EntityCounter {

    /// Returns the default count object using the global default limit.
    private func defaultModelCount() -> Count {
        Count(count: 0, freeLimit: defaultLimit)
    }

    /// Refreshes entity counts for all tracked models.
    ///
    /// Dynamic limits set via `updateLimit(_:for:)` are preserved — the original config limit
    /// is only used as a fallback for models not yet in `totals`.
    private func refresh() {
        guard let context else {
            logger.error("refresh() called before context was set")
            return
        }

        var countSnapshot: [String: Int] = [:]

        logger.debug("Refreshing entity counts for \(self.models.count) models")

        for (modelType, configLimit) in models {
            do {
                let newCount = try fetchCount(for: modelType, in: context)
                let key = ObjectIdentifier(modelType)
                let oldEntry = totals[key]

                // Preserve any limit change from updateLimit(); fall back to config on first run.
                let effectiveLimit = oldEntry?.freeLimit ?? configLimit

                logChanges(for: modelType, oldCount: oldEntry?.count, newCount: newCount, freeLimit: effectiveLimit)
                totals[key] = Count(count: newCount, freeLimit: effectiveLimit)

                countSnapshot[String(describing: modelType)] = newCount
            } catch {
                logger.error("Failed to fetch \(String(describing: modelType)) count: \(error.localizedDescription, privacy: .public)")
            }
        }

        UserDefaults.standard.set(countSnapshot, forKey: cacheKey)
        logger.debug("Cached counts: \(countSnapshot)")
    }

    /// Logs changes in count and limit status for a given model type.
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

    /// Fetches the current count for a given model type from the context.
    private func fetchCount(
        for modelType: (some FetchablePersistentModel).Type,
        in context: ModelContext
    ) throws -> Int {
        try context.fetchCount(modelType.fetchDescriptor)
    }
}
