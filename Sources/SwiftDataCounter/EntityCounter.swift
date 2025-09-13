//
// Project: SwiftDataCounter
// Author: Mark Battistella
// Website: https://markbattistella.com
//

import SwiftData
import Foundation
import SimpleLogger

@MainActor
@Observable
/// Tracks the number of persisted entities for given `PersistentModel` types.
///
/// Supports per-model or uniform limits, and observes `ModelContext` saves to refresh counts
/// automatically.
public final class EntityCounter {
    
    private let logger = SimpleLogger(category: .swiftData)
    
    /// Dictionary of tracked totals keyed by model type identifier.
    private(set) var totals: [ObjectIdentifier: ModelCount] = [:]
    
    /// Models being tracked with optional per-type limits.
    private let trackedModels: [(type: any PersistentModel.Type, limit: Int?)]
    
    /// Uniform default limit applied when no per-type limit is specified.
    private let defaultLimit: Int?
    
    /// The `ModelContext` from which entity counts are fetched.
    private var context: ModelContext?
    
    // MARK: - Initialisers
    
    /// Creates an `EntityCounter` with explicit per-type limits.
    ///
    /// - Parameters:
    ///   - context: The model context to observe and query.
    ///   - trackedModels: Array of `(type, limit)` pairs for each model type.
    public init(
        context: ModelContext?,
        trackedModels: [(type: any PersistentModel.Type, limit: Int)]
    ) {
        self.context = context
        self.trackedModels = trackedModels.map { ($0.type, Optional($0.limit)) }
        self.defaultLimit = nil
        self.setup()
    }
    
    /// Creates an `EntityCounter` with a uniform default limit applied to all types.
    ///
    /// - Parameters:
    ///   - context: The model context to observe and query.
    ///   - trackedModels: Variadic list of model types to track.
    ///   - defaultLimit: The limit applied uniformly to all tracked models.
    public init(
        context: ModelContext?,
        trackedModels: any PersistentModel.Type...,
        defaultLimit: Int
    ) {
        self.context = context
        self.trackedModels = trackedModels.map { ($0, Optional(defaultLimit)) }
        self.defaultLimit = defaultLimit
        self.setup()
    }
    
    /// Sets up totals for each tracked type, starts observation of saves, and refreshes counts.
    private func setup() {
        for (modelType, limit) in trackedModels {
            totals[ObjectIdentifier(modelType)] = ModelCount(count: 0, freeLimit: limit)
        }
        Task { [weak self] in await self?.observeContextSaves() }
        refresh()
    }
}

// MARK: - Per-Type Queries
extension EntityCounter {
    
    /// Returns the current count of entities for a given model type.
    ///
    /// - Parameter modelType: The model type to query.
    /// - Returns: Number of entities counted.
    public func count<T: PersistentModel>(for modelType: T.Type) -> Int {
        totals[ObjectIdentifier(modelType)]?.count ?? 0
    }
    
    /// Returns the number of remaining free slots before hitting the limit for a model type.
    ///
    /// - Parameter modelType: The model type to query.
    /// - Returns: Remaining slots, or `nil` if unlimited.
    public func remaining<T: PersistentModel>(for modelType: T.Type) -> Int? {
        let mc = totals[ObjectIdentifier(modelType)] ?? defaultModelCount()
        guard let freeLimit = mc.freeLimit else { return nil } // unlimited
        return max(freeLimit - mc.count, 0)
    }
    
    /// Returns the number of remaining slots, or `Int.max` if unlimited.
    ///
    /// - Parameter modelType: The model type to query.
    /// - Returns: Remaining slots or `.max` if unlimited.
    public func remainingOrMax<T: PersistentModel>(for modelType: T.Type) -> Int {
        remaining(for: modelType) ?? .max
    }
    
    /// Returns whether the entity count for the given model type exceeds its limit.
    ///
    /// - Parameter modelType: The model type to query.
    /// - Returns: `true` if over the limit, else `false`.
    public func isOverLimit<T: PersistentModel>(for modelType: T.Type) -> Bool {
        let mc = totals[ObjectIdentifier(modelType)] ?? defaultModelCount()
        guard let freeLimit = mc.freeLimit else { return false }
        return mc.count > freeLimit
    }
}

// MARK: - Internal Refresh Logic
extension EntityCounter {
    
    /// Provides a default `ModelCount` using `defaultLimit` when no data exists.
    private func defaultModelCount() -> ModelCount {
        ModelCount(count: 0, freeLimit: defaultLimit)
    }
    
    /// Refreshes counts for all tracked models from the context.
    private func refresh() {
        guard let context else { return }
        
        for (modelType, limit) in trackedModels {
            do {
                let count = try fetchCount(for: modelType, in: context)
                totals[ObjectIdentifier(modelType)] = ModelCount(count: count, freeLimit: limit)
            } catch {
                logger.error("Failed to fetch \(String(describing: modelType)) count: \(error.localizedDescription)")
            }
        }
    }
    
    /// Fetches the count for a single model type.
    ///
    /// - Parameters:
    ///   - modelType: The model type to count.
    ///   - context: The model context used for fetching.
    /// - Throws: `EntityCounterError.unsupportedModelType` if type does not conform.
    /// - Returns: The number of entities found.
    private func fetchCount(
        for modelType: any PersistentModel.Type,
        in context: ModelContext
    ) throws -> Int {
        guard let countableType = modelType as? any CountablePersistentModel.Type else {
            throw EntityCounterError.unsupportedModelType(String(describing: modelType))
        }
        return try countableType.fetchCount(in: context)
    }
    
    /// Observes save notifications for the model context and triggers refresh.
    private func observeContextSaves() async {
        guard let context else { return }
        for await note in NotificationCenter.default.notifications(named: ModelContext.didSave) {
            guard let obj = note.object as? ModelContext, obj === context else { continue }
            self.refresh()
        }
    }
}

// MARK: - Aggregate Queries

extension EntityCounter {
    
    /// Total count of all tracked entities.
    public var grandTotal: Int {
        totals.values.reduce(0) { $0 + $1.count }
    }
    
    /// Sum of all free limits, or `nil` if any model has unlimited.
    public var grandFreeLimit: Int? {
        var sum = 0
        for mc in totals.values {
            guard let limit = mc.freeLimit else { return nil }
            sum += limit
        }
        return sum
    }
    
    /// Sum of all free limits, or `.max` if any are unlimited.
    public var grandFreeLimitOrMax: Int {
        grandFreeLimit ?? .max
    }
    
    /// Remaining free slots across all tracked models, or `nil` if unlimited.
    public var remainingAll: Int? {
        guard let freeLimit = grandFreeLimit else { return nil }
        return max(freeLimit - grandTotal, 0)
    }
    
    /// Remaining free slots across all models, or `.max` if unlimited.
    public var remainingAllOrMax: Int {
        remainingAll ?? .max
    }
    
    /// Returns `true` if any tracked model is over its free limit.
    public var isOverAnyLimit: Bool {
        totals.values.contains {
            guard let limit = $0.freeLimit else { return false }
            return $0.count > limit
        }
    }
}
