//
// Project: SwiftDataCounter
// Author: Mark Battistella
// Website: https://markbattistella.com
//

import Foundation
import SwiftData
import SimpleLogger

/// A tuple representing a persistent model type and its optional item limit.
public typealias PersistentModelLimit = (type: any PersistentModel.Type, limit: Int?)

/// A utility class that tracks entity counts for multiple `PersistentModel` types.
///
/// Supports optional per-model limits and provides convenience functions for querying counts,
/// limits, and remaining capacity.
@MainActor
@Observable
public final class EntityCounter {

    /// Logger categorised as SwiftData.
    private let logger = SimpleLogger(category: .swiftData)

    /// Dictionary mapping model type identifiers to their tracked count data.
    private(set) var totals: [ObjectIdentifier: Count] = [:]

    /// Models being tracked with their associated limits.
    private let models: [PersistentModelLimit]

    /// Default limit to apply when a model does not define its own limit.
    private let defaultLimit: Int?

    /// The model context used to fetch entity counts and observe saves.
    private var context: ModelContext?

    // MARK: - Init

    /// Creates an `EntityCounter` with the given models and no default limit.
    ///
    /// - Parameters:
    ///   - context: The `ModelContext` used for fetching and observing.
    ///   - models: A variadic list of model/limit pairs to track.
    public convenience init(context: ModelContext?, for models: PersistentModelLimit...) {
        self.init(context: context, for: models, default: nil)
    }

    /// Creates an `EntityCounter` with the given models, applying a shared default limit.
    ///
    /// - Parameters:
    ///   - context: The `ModelContext` used for fetching and observing.
    ///   - models: A variadic list of model types to track.
    ///   - defaultLimit: The default maximum count allowed for each model.
    public convenience init(context: ModelContext?, for models: any PersistentModel.Type..., defaultLimit: Int) {
        let mapped = models.map { (type: $0, limit: defaultLimit) }
        self.init(context: context, for: mapped, default: defaultLimit)
    }

    /// Creates an `EntityCounter` with custom model/limit pairs.
    ///
    /// - Parameters:
    ///   - context: The `ModelContext` used for fetching and observing.
    ///   - models: A list of model/limit pairs to track.
    ///   - limit: A default limit applied when no per-model limit is set.
    private init(context: ModelContext?, for models: [PersistentModelLimit], default limit: Int?) {
        self.context = context
        self.models = models
        self.defaultLimit = limit

        if let limit {
            logger.info("EntityCounter initialised. Tracking \(models.count, privacy: .public) models, defaultLimit = \(limit, privacy: .public)")
        } else {
            logger.info("EntityCounter initialised. Tracking \(models.count, privacy: .public) models")
        }

        for (modelType, limit) in models {
            if let limit {
                logger.info("Tracking \(String(describing: modelType)) with limit \(limit, privacy: .public)")
            } else {
                logger.info("Tracking \(String(describing: modelType)) with no limit")
            }
            totals[ObjectIdentifier(modelType)] = Count(count: 0, freeLimit: limit)
        }

        Task { [weak self] in
            await self?.observeContextSaves()
        }
        refresh()
    }
}

extension EntityCounter {

    /// Represents the count and optional free limit for a tracked model.
    public struct Count {

        /// The current number of entities.
        public var count: Int

        /// The optional limit for this model.
        public var freeLimit: Int?
    }

    /// Defines how combined limits are calculated.
    public enum LimitScope {

        /// Include all models, even those without limits.
        case all

        /// Exclude unlimited models when calculating combined limits.
        case excludingUnlimited
    }
}

extension EntityCounter {

    /// Returns the current count of a given model type.
    ///
    /// - Parameter modelType: The model type to query.
    /// - Returns: The current entity count, or 0 if not tracked.
    public func count<T: PersistentModel>(for modelType: T.Type) -> Int {
        totals[ObjectIdentifier(modelType)]?.count ?? 0
    }

    /// Returns the number of remaining available entities before hitting the limit.
    ///
    /// - Parameter modelType: The model type to query.
    /// - Returns: The remaining capacity.
    /// - Precondition: The model type must have a defined limit.
    public func remaining<T: PersistentModel>(for modelType: T.Type) -> Int {
        let mc = totals[ObjectIdentifier(modelType)] ?? defaultModelCount()
        guard let freeLimit = mc.freeLimit else {
            logger.error("Asked for remaining on unlimited model: \(modelType, privacy: .public)")
            preconditionFailure("Asked for remaining on unlimited model: \(modelType)")
        }
        return max(freeLimit - mc.count, 0)
    }

    /// Returns whether the given model type is currently over its limit.
    ///
    /// - Parameter modelType: The model type to query.
    /// - Returns: `true` if the count exceeds the limit, else `false`.
    public func isOverLimit<T: PersistentModel>(for modelType: T.Type) -> Bool {
        let mc = totals[ObjectIdentifier(modelType)] ?? defaultModelCount()
        guard let freeLimit = mc.freeLimit else { return false }
        return mc.count > freeLimit
    }

    /// Returns the limit for a given model type.
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
}

extension EntityCounter {

    /// A default `Count` structure using the global default limit.
    private func defaultModelCount() -> Count {
        Count(count: 0, freeLimit: defaultLimit)
    }

    /// Returns the total count across all tracked models.
    public var grandCount: Int {
        totals.values.reduce(0) { $0 + $1.count }
    }

    /// Returns the combined limit of all tracked models.
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

    /// Returns the remaining capacity across all tracked models.
    ///
    /// - Parameter scope: Whether to include unlimited models.
    /// - Returns: The remaining combined capacity, or `nil` if unlimited.
    public func combinedRemaining(scope: LimitScope = .all) -> Int? {
        guard let limit = combinedLimit(scope: scope) else { return nil }
        return max(limit - grandCount, 0)
    }

    /// Returns whether any tracked model has exceeded its limit.
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
        guard let context else { return }

        for (modelType, limit) in models {
            do {
                let newCount = try fetchCount(for: modelType, in: context)
                let key = ObjectIdentifier(modelType)
                let oldCount = totals[key]?.count

                logChanges(for: modelType, oldCount: oldCount, newCount: newCount, freeLimit: limit)

                totals[key] = Count(count: newCount, freeLimit: limit)

            } catch {
                logger.error("Failed to fetch \(String(describing: modelType)) count: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Fetches the count of entities for a specific model type.
    ///
    /// - Parameters:
    ///   - modelType: The persistent model type to count.
    ///   - context: The model context used to query.
    /// - Throws: `EntityCounterError.unsupportedModelType` if the model does not support counting.
    /// - Returns: The entity count.
    private func logChanges(
        for modelType: any PersistentModel.Type,
        oldCount: Int?,
        newCount: Int,
        freeLimit: Int?
    ) {
        if oldCount != newCount {
            if let oldCount {
                logger.info("\(String(describing: modelType)) count changed from \(oldCount, privacy: .public) to \(newCount, privacy: .public)")
            } else {
                logger.info("\(String(describing: modelType)) count initialised at \(newCount, privacy: .public)")
            }
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

    /// Fetches the count of entities for a specific model type.
    ///
    /// - Parameters:
    ///   - modelType: The persistent model type to count.
    ///   - context: The model context used to query.
    /// - Throws: `EntityCounterError.unsupportedModelType` if the model does not support counting.
    /// - Returns: The entity count.
    private func fetchCount(
        for modelType: any PersistentModel.Type,
        in context: ModelContext
    ) throws -> Int {
        guard let countableType = modelType as? any CountablePersistentModel.Type else {
            let modelTypeDescription = String(describing: modelType)
            logger.error("Unsupported model type: \(modelTypeDescription, privacy: .public)")
            logger.error("\(EntityCounterError.unsupportedModelType(modelTypeDescription).localizedDescription, privacy: .public)")
            throw EntityCounterError.unsupportedModelType(modelTypeDescription)
        }
        return try countableType.fetchCount(in: context)
    }

    /// Observes save notifications on the model context and refreshes counts when changes occur.
    private func observeContextSaves() async {
        guard let context else { return }
        for await note in NotificationCenter.default.notifications(named: ModelContext.didSave) {
            guard let obj = note.object as? ModelContext, obj === context else { continue }
            self.refresh()
        }
    }
}
