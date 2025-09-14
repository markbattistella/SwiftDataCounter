<!-- markdownlint-disable MD033 MD041 -->
<div align="center">

# SwiftDataCounter

[![Swift Version][Shield1]](https://swiftpackageindex.com/markbattistella/SwiftDataCounter)

[![OS Platforms][Shield2]](https://swiftpackageindex.com/markbattistella/SwiftDataCounter)

[![Licence][Shield3]](https://github.com/markbattistella/SwiftDataCounter/blob/main/LICENSE)

</div>

`SwiftDataCounter` is a Swift package that provides live tracking of SwiftData model counts with optional per-model or default limits. It listens for `ModelContext` save notifications and automatically refreshes counts, while also logging changes and limit crossings using `OSLog`.

## Why Use This Package?

`SwiftDataCounter` is designed for apps that need to track usage of SwiftData models and enforce limits. Common use cases:

- **Free vs Paid Limits**: Enforce "up to 10 users on the free plan."
- **Feature Gating**: Track counts of posts, projects, or files to unlock or disable features.
- **Analytics**: Log model usage over time without writing boilerplate counting logic.
- **Debugging**: Automatically observe when models exceed their limits.

By centralising count tracking and limit checks, you can keep app logic clean and consistent.

> [!NOTE]
> Tracked models must conform to `FetchablePersistentModel` and define a `fetchDescriptor` so that `EntityCounter` can query their counts.

## Features

- **Live Counts**: Automatically refreshes when the `ModelContext` saves.
- **Per-Model Limits**: Specify limits individually or apply a default to all.
- **Aggregate Queries**: Get combined totals and remaining capacity across all tracked models.

## Installation

### Swift Package Manager

To add `SwiftDataCounter` to your project, use the Swift Package Manager:

1. Open your project in Xcode.
1. Go to `File > Add Packages`.
1. Enter the repository URL:

    ```url
    https://github.com/markbattistella/SwiftDataCounter
    ```

1. Click **Add Package**.

## Usage

### Setup

Tracked models must conform to `FetchablePersistentModel` and implement a static `fetchDescriptor`:

```swift
// Extend your existing model
extension User: FetchablePersistentModel {
    static var fetchDescriptor: FetchDescriptor<User> {
        FetchDescriptor<User>()
    }
}
```

Track models with a **shared default limit**:

```swift
import SwiftDataCounter

let counter = EntityCounter(
    context: modelContext,
    for: User.self, Post.self,
    defaultLimit: 100
)
```

Or with **per-model limits**:

```swift
let counter = EntityCounter(
    context: modelContext,
    for: (User.self, 10), (Post.self, nil) // nil = unlimited
)
```

### Per-Model Queries

```swift
let users = counter.count(for: User.self)
// eg. 6

let remainingUsers = counter.remaining(for: User.self)
// eg. 4 (10 limit - 6 used)

let userLimit = counter.limit(for: Post.self)
// preconditionFailure since Post is set to unlimited (nil)

if counter.isOverLimit(for: User.self) {
    print("User count is over the limit!")
}
```

### Aggregate Queries

```swift
let total = counter.grandCount

// Combined limit including unlimited models - can return nil
let combined = counter.combinedLimit(scope: .all)

// Combined limit excluding unlimited models
let finite = counter.combinedLimit(scope: .excludingUnlimited)

// Remaining total capacity
let remaining = counter.combinedRemaining(scope: .all)

if counter.isOverAnyLimit {
    print("At least one model is over its limit.")
}
```

### Convenience Extensions

For cleaner code, extend `EntityCounter` with typed accessors:

```swift
extension EntityCounter {
    var userCount: Int { count(for: User.self) }
    var userRemaining: Int { remaining(for: User.self) }
    var userLimit: Int { limit(for: User.self) }
    var isUserOverLimit: Bool { isOverLimit(for: User.self) }
}
```

Then use:

```swift
if isUserOverLimit {
    print("Too many users. Remaining: \(userRemaining)")
}
```

## Logging

`SwiftDataCounter` uses `OSLog` via `SimpleLogger`.

It automatically logs:

- Model initialisation counts.
- Count changes (old → new).
- Limit crossings (exceeded / back under).

Example log in Console.app:

```log
EntityCounter initialised. Tracking 2 models, defaultLimit = 10
Tracking User with limit 10
Tracking Post with no limit
User count changed from 3 to 5
User exceeded limit 10. Current count: 11
```

## Warnings

> [!WARNING]  
> The API is **strict**:
>
> - Calling `remaining(for:)` or `limit(for:)` on a model configured with `nil` (unlimited) will cause a **runtime crash** via `preconditionFailure`.  
> - This is intentional to surface incorrect usage early - if a model is unlimited, you should not be asking for its remaining capacity or limit.  
> - Always design your code so that only limited models are passed to these methods.  

## Licence

`SwiftDataCounter` is released under the MIT licence. See LICENCE for details.

[Shield1]: https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fmarkbattistella%2FSwiftDataCounter%2Fbadge%3Ftype%3Dswift-versions

[Shield2]: https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fmarkbattistella%2FSwiftDataCounter%2Fbadge%3Ftype%3Dplatforms

[Shield3]: https://img.shields.io/badge/Licence-MIT-white?labelColor=blue&style=flat
