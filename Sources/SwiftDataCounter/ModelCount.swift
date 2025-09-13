//
// Project: SwiftDataCounter
// Author: Mark Battistella
// Website: https://markbattistella.com
//

import Foundation

/// Represents the count of persisted entities for a specific model type, along with an optional
/// free limit that constrains the maximum allowed.
public struct ModelCount {

    /// The current number of persisted entities.
    public var count: Int

    /// The optional free limit for the model type.
    ///
    /// - `nil` means unlimited.
    public var freeLimit: Int?
}
