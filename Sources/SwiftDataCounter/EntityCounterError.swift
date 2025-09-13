//
// Project: SwiftDataCounter
// Author: Mark Battistella
// Website: https://markbattistella.com
//

import Foundation

/// Errors thrown by `EntityCounter`.
public enum EntityCounterError: Error {

    /// The model type does not conform to `CountablePersistentModel` and cannot be used for
    /// counting.
    ///
    /// - Parameter typeName: A textual representation of the unsupported type.
    case unsupportedModelType(String)
}

extension EntityCounterError: LocalizedError {

    /// A human-readable description of the error.
    public var errorDescription: String? {
        switch self {
            case .unsupportedModelType(let typeName):
                return "Unsupported model type: \(typeName)"
        }
    }
}
