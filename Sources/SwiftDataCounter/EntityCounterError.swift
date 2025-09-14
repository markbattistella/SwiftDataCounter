//
// Project: SwiftDataCounter
// Author: Mark Battistella
// Website: https://markbattistella.com
//

import Foundation

/// Errors thrown by ``EntityCounter`` during count operations.
internal enum EntityCounterError: Error, LocalizedError {

    /// The supplied model type does not conform to ``CountablePersistentModel`` and cannot be
    /// counted.
    ///
    /// - Parameter typeName: The name of the unsupported type.
    case unsupportedModelType(String)

    // MARK: - LocalizedError

    /// A localized description of the error.
    internal var errorDescription: String? {
        switch self {
            case .unsupportedModelType(let typeName):
                return "Unsupported model type: \(typeName)"
        }
    }

    /// A localized explanation of the reason for the failure.
    internal var failureReason: String? {
        switch self {
            case .unsupportedModelType:
                return "The model does not conform to CountablePersistentModel."
        }
    }

    /// A localized suggestion describing how to recover from the error.
    internal var recoverySuggestion: String? {
        switch self {
            case .unsupportedModelType:
                return "Ensure that the model type conforms to CountablePersistentModel and implements fetchCount(in:)."
        }
    }

    /// A localized string describing additional help.
    internal var helpAnchor: String? {
        switch self {
            case .unsupportedModelType:
                return "See EntityCounter and CountablePersistentModel documentation for implementation details."
        }
    }
}
