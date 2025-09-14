//
// Project: SwiftDataCounter
// Author: Mark Battistella
// Website: https://markbattistella.com
//

import SwiftData

/// A protocol that marks a `PersistentModel` type as countable by `EntityCounter`.
///
/// Conforming types must provide a static implementation of ``fetchCount(in:)`` to return the
/// current number of stored instances in the given `ModelContext`.
///
/// You typically conform your model types to this protocol by implementing a simple `fetchCount`
/// query using SwiftData.
public protocol CountablePersistentModel: PersistentModel {

    /// Returns the number of instances of the model type in the given context.
    ///
    /// - Parameter context: The `ModelContext` to query.
    /// - Returns: The number of stored model instances in `context`.
    /// - Throws: Any error thrown while fetching the count from the context.
    static func fetchCount(in context: ModelContext) throws -> Int
}
