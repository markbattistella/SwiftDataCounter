//
// Project: SwiftDataCounter
// Author: Mark Battistella
// Website: https://markbattistella.com
//

import SwiftData

/// A protocol for persistent models that support count-based queries.
///
/// Conforming types must define a static fetch descriptor that can be used to describe how
/// instances of the model should be fetched from persistence.
///
/// Use this protocol when you want a model type to provide a standardised query descriptor,
/// typically for counting records or performing filtered fetches.
///
public protocol FetchablePersistentModel: PersistentModel {

    /// A fetch descriptor that specifies how to retrieve instances of this model.
    ///
    /// This descriptor defines the criteria used when fetching from the underlying persistence
    /// layer, such as sorting or filtering rules.
    static var fetchDescriptor: FetchDescriptor<Self> { get }
}
