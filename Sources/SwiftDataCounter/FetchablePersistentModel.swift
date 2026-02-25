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
    ///
    /// A default implementation is provided that fetches all records with no filter or sort.
    /// Override this only when you need custom filtering or sorting behaviour.
    static var fetchDescriptor: FetchDescriptor<Self> { get }
}

public extension FetchablePersistentModel {

    /// Returns a `FetchDescriptor` that fetches all records of this model with no filter or sort.
    static var fetchDescriptor: FetchDescriptor<Self> { FetchDescriptor() }
}
