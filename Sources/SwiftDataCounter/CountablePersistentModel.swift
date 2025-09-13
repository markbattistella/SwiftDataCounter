//
// Project: SwiftDataCounter
// Author: Mark Battistella
// Website: https://markbattistella.com
//

import Foundation
import SwiftData

/// A `PersistentModel` that supports counting instances in a given `ModelContext`.
///
/// Conforming types must implement a static method that returns the total number of persisted
/// entities of that type in the specified context.
public protocol CountablePersistentModel: PersistentModel {

    /// Returns the total number of persisted instances of the model in the given context.
    ///
    /// - Parameter context: The `ModelContext` to query.
    /// - Throws: An error if the fetch fails.
    /// - Returns: The total count of persisted entities.
    static func fetchCount(in context: ModelContext) throws -> Int
}
