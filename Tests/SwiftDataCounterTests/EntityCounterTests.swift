//
// Project: SwiftDataCounter
// Author: Mark Battistella
// Website: https://markbattistella.com
//

import Foundation
import SwiftData
import Testing

@testable import SwiftDataCounter

// MARK: - Test models

@Model
final class Item: FetchablePersistentModel {
  var name: String

  init(name: String) {
    self.name = name
  }
}

@Model
final class Tag: FetchablePersistentModel {
  var label: String

  init(label: String) {
    self.label = label
  }
}

// MARK: - Tests

@Suite("EntityCounter", .serialized)
@MainActor
struct EntityCounterTests {

  // MARK: - Helpers

  func makeContainer(_ types: any PersistentModel.Type...) throws -> ModelContainer {
    try ModelContainer(
      for: Schema(types),
      configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
  }

  func waitForLoaded(_ counter: EntityCounter) async -> Bool {
    await wait {
      counter.isLoaded
    }
  }

  func waitForCount<T: PersistentModel>(
    _ counter: EntityCounter,
    for modelType: T.Type,
    equals expectedCount: Int
  ) async -> Bool {
    await wait {
      counter.count(for: modelType) == expectedCount
    }
  }

  func wait(until condition: () -> Bool) async -> Bool {
    let deadline = Date.now.addingTimeInterval(2)

    while Date.now < deadline {
      if condition() {
        return true
      }

      try? await Task.sleep(for: .milliseconds(10))
    }

    return condition()
  }

  // MARK: - Tests

  @Test("Initial count loads")
  func initialCountLoads() async throws {
    let container = try makeContainer(Item.self)
    let context = container.mainContext

    context.insert(Item(name: "First"))
    try context.save()

    let counter = EntityCounter(
      context: context,
      for: (type: Item.self, limit: 10)
    )
    defer { counter.stopTracking() }

    #expect(await waitForLoaded(counter), "Counter should complete its initial refresh")
    #expect(counter.count(for: Item.self) == 1)
  }

  @Test("Count updates on save")
  func countUpdatesOnSave() async throws {
    let container = try makeContainer(Item.self)
    let context = container.mainContext

    let counter = EntityCounter(
      context: context,
      for: (type: Item.self, limit: 10)
    )
    defer { counter.stopTracking() }

    #expect(await waitForLoaded(counter), "Counter should complete its initial refresh")
    #expect(counter.count(for: Item.self) == 0)

    context.insert(Item(name: "Alpha"))
    context.insert(Item(name: "Beta"))
    try context.save()

    #expect(await waitForCount(counter, for: Item.self, equals: 2))
  }

  @Test("updateLimit survives subsequent saves")
  func updateLimitSurvivesRefresh() async throws {
    let container = try makeContainer(Item.self)
    let context = container.mainContext

    let counter = EntityCounter(
      context: context,
      for: (type: Item.self, limit: 5)
    )
    defer { counter.stopTracking() }

    #expect(await waitForLoaded(counter), "Counter should complete its initial refresh")

    counter.updateLimit(20, for: Item.self)
    #expect(counter.limit(for: Item.self) == 20)

    context.insert(Item(name: "Trigger"))
    try context.save()

    #expect(await waitForCount(counter, for: Item.self, equals: 1))
    #expect(counter.limit(for: Item.self) == 20)
  }

  @Test("updateLimit nil remains unlimited after refresh")
  func updateLimitNilRemainsUnlimitedAfterRefresh() async throws {
    let container = try makeContainer(Item.self)
    let context = container.mainContext

    let counter = EntityCounter(
      context: context,
      for: (type: Item.self, limit: 5)
    )
    defer { counter.stopTracking() }

    #expect(await waitForLoaded(counter), "Counter should complete its initial refresh")

    counter.updateLimit(nil, for: Item.self)
    #expect(counter.limit(for: Item.self) == nil)
    #expect(counter.remaining(for: Item.self) == nil)

    context.insert(Item(name: "Trigger"))
    try context.save()

    #expect(await waitForCount(counter, for: Item.self, equals: 1))
    #expect(counter.limit(for: Item.self) == nil)
    #expect(counter.remaining(for: Item.self) == nil)
    #expect(!counter.isOverLimit(for: Item.self))
  }

  @Test("Unlimited model returns nil limit and remaining values")
  func unlimitedModelReturnsNil() async throws {
    let container = try makeContainer(Item.self)
    let context = container.mainContext

    let counter = EntityCounter(
      context: context,
      for: (type: Item.self, limit: nil)
    )
    defer { counter.stopTracking() }

    #expect(await waitForLoaded(counter), "Counter should complete its initial refresh")
    #expect(counter.limit(for: Item.self) == nil)
    #expect(counter.remaining(for: Item.self) == nil)
    #expect(!counter.isOverLimit(for: Item.self))
  }

  @Test("Limited model remaining value is calculated from count and limit")
  func limitedModelRemaining() async throws {
    let container = try makeContainer(Item.self)
    let context = container.mainContext

    for index in 0..<3 {
      context.insert(Item(name: "I\(index)"))
    }
    try context.save()

    let counter = EntityCounter(
      context: context,
      for: (type: Item.self, limit: 10)
    )
    defer { counter.stopTracking() }

    #expect(await waitForLoaded(counter), "Counter should complete its initial refresh")
    #expect(counter.remaining(for: Item.self) == 7)
  }

  @Test("Over-limit state is reported")
  func isOverLimit() async throws {
    let container = try makeContainer(Item.self)
    let context = container.mainContext

    for index in 0..<11 {
      context.insert(Item(name: "I\(index)"))
    }
    try context.save()

    let counter = EntityCounter(
      context: context,
      for: (type: Item.self, limit: 10)
    )
    defer { counter.stopTracking() }

    #expect(await waitForLoaded(counter), "Counter should complete its initial refresh")
    #expect(counter.isOverLimit(for: Item.self))
    #expect(counter.isOverAnyLimit)
  }

  @Test("Cache key isolation between model sets")
  func cacheKeyIsolation() async throws {
    let containerA = try makeContainer(Item.self)
    let containerB = try makeContainer(Tag.self)

    let counterA = EntityCounter(
      context: containerA.mainContext,
      for: (type: Item.self, limit: 5)
    )
    let counterB = EntityCounter(
      context: containerB.mainContext,
      for: (type: Tag.self, limit: 10)
    )
    defer {
      counterA.stopTracking()
      counterB.stopTracking()
    }

    #expect(await waitForLoaded(counterA), "Item counter should complete its initial refresh")
    #expect(await waitForLoaded(counterB), "Tag counter should complete its initial refresh")

    #expect(counterA.limit(for: Item.self) == 5)
    #expect(counterB.limit(for: Tag.self) == 10)

    counterA.updateLimit(99, for: Item.self)

    #expect(counterB.limit(for: Tag.self) == 10)
  }

  @Test("Combined remaining excluding unlimited models uses only limited model counts")
  func combinedRemainingExcludingUnlimited() async throws {
    let container = try makeContainer(Item.self, Tag.self)
    let context = container.mainContext

    let counter = EntityCounter(
      context: context,
      for: (type: Item.self, limit: 10), (type: Tag.self, limit: nil)
    )
    defer { counter.stopTracking() }

    #expect(await waitForLoaded(counter), "Counter should complete its initial refresh")

    for index in 0..<3 {
      context.insert(Item(name: "I\(index)"))
    }
    for index in 0..<5 {
      context.insert(Tag(label: "T\(index)"))
    }
    try context.save()

    #expect(await waitForCount(counter, for: Item.self, equals: 3))
    #expect(counter.grandCount == 8)
    #expect(counter.combinedLimit(scope: .excludingUnlimited) == 10)
    #expect(counter.combinedRemaining(scope: .excludingUnlimited) == 7)
  }

  @Test("Nil context completes loading with cached counts")
  func nilContextCompletesLoadingWithCachedCounts() async {
    let counter = EntityCounter(
      context: nil,
      for: (type: Item.self, limit: 10)
    )
    defer { counter.stopTracking() }

    #expect(
      await waitForLoaded(counter), "Nil context should not leave loading state pending forever")
  }

  @Test("stopTracking prevents further refresh")
  func stopTrackingPreventsRefresh() async throws {
    let container = try makeContainer(Item.self)
    let context = container.mainContext

    let counter = EntityCounter(
      context: context,
      for: (type: Item.self, limit: 10)
    )

    #expect(await waitForLoaded(counter), "Counter should complete its initial refresh")
    #expect(counter.count(for: Item.self) == 0)

    counter.stopTracking()

    context.insert(Item(name: "After stop"))
    try context.save()

    try? await Task.sleep(for: .milliseconds(50))

    #expect(counter.count(for: Item.self) == 0)
  }
}
