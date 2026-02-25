//
// Project: SwiftDataCounter
// Author: Mark Battistella
// Website: https://markbattistella.com
//

import XCTest
import SwiftData
@testable import SwiftDataCounter

// MARK: - Test models

@Model
final class Item: FetchablePersistentModel {
    var name: String
    init(name: String) { self.name = name }
}

@Model
final class Tag: FetchablePersistentModel {
    var label: String
    init(label: String) { self.label = label }
}

// MARK: - Tests

@MainActor
final class EntityCounterTests: XCTestCase {

    // MARK: - Helpers

    func makeContainer(_ types: any PersistentModel.Type...) throws -> ModelContainer {
        try ModelContainer(
            for: Schema(types),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    /// Polls until `counter.isLoaded` is true or a 2-second timeout is reached.
    func waitForLoaded(_ counter: EntityCounter) async {
        let deadline = Date.now.addingTimeInterval(2)
        while !counter.isLoaded, Date.now < deadline {
            await Task.yield()
        }
    }

    /// Gives the save-notification handler a chance to run its refresh cycle.
    func yieldForRefresh() async {
        // Two yields: one to allow the notification to deliver, one for the refresh Task step.
        await Task.yield()
        await Task.yield()
    }

    // MARK: - Test 1: Initial count loads

    func testInitialCountLoads() async throws {
        let container = try makeContainer(Item.self)
        let context = container.mainContext

        context.insert(Item(name: "First"))
        try context.save()

        let counter = EntityCounter(
            context: context,
            for: (type: Item.self, limit: 10)
        )

        await waitForLoaded(counter)

        XCTAssertTrue(counter.isLoaded, "Counter should report isLoaded = true after initial refresh")
        XCTAssertEqual(counter.count(for: Item.self), 1)
    }

    // MARK: - Test 2: Count updates on save

    func testCountUpdatesOnSave() async throws {
        let container = try makeContainer(Item.self)
        let context = container.mainContext

        let counter = EntityCounter(
            context: context,
            for: (type: Item.self, limit: 10)
        )

        await waitForLoaded(counter)
        XCTAssertEqual(counter.count(for: Item.self), 0)

        context.insert(Item(name: "Alpha"))
        context.insert(Item(name: "Beta"))
        try context.save()

        await yieldForRefresh()

        XCTAssertEqual(counter.count(for: Item.self), 2)
    }

    // MARK: - Test 3: updateLimit survives subsequent saves

    func testUpdateLimitSurvivesRefresh() async throws {
        let container = try makeContainer(Item.self)
        let context = container.mainContext

        let counter = EntityCounter(
            context: context,
            for: (type: Item.self, limit: 5)
        )

        await waitForLoaded(counter)

        counter.updateLimit(20, for: Item.self)
        XCTAssertEqual(counter.limit(for: Item.self), 20)

        // Trigger a save-based refresh
        context.insert(Item(name: "Trigger"))
        try context.save()

        await yieldForRefresh()

        // The limit must still be 20, not 5 (the original config value)
        XCTAssertEqual(
            counter.limit(for: Item.self),
            20,
            "updateLimit() override must survive a save-triggered refresh"
        )
    }

    // MARK: - Test 4: Unlimited model returns nil

    func testUnlimitedModelReturnsNil() async throws {
        let container = try makeContainer(Item.self)
        let context = container.mainContext

        let counter = EntityCounter(
            context: context,
            for: (type: Item.self, limit: nil)
        )

        await waitForLoaded(counter)

        XCTAssertNil(counter.limit(for: Item.self))
        XCTAssertNil(counter.remaining(for: Item.self))
        XCTAssertFalse(counter.isOverLimit(for: Item.self))
    }

    // MARK: - Test 5: remaining calculation for a limited model

    func testLimitedModelRemaining() async throws {
        let container = try makeContainer(Item.self)
        let context = container.mainContext

        for i in 0..<3 { context.insert(Item(name: "I\(i)")) }
        try context.save()

        let counter = EntityCounter(
            context: context,
            for: (type: Item.self, limit: 10)
        )

        await waitForLoaded(counter)

        XCTAssertEqual(counter.remaining(for: Item.self), 7)
    }

    // MARK: - Test 6: isOverLimit

    func testIsOverLimit() async throws {
        let container = try makeContainer(Item.self)
        let context = container.mainContext

        for i in 0..<11 { context.insert(Item(name: "I\(i)")) }
        try context.save()

        let counter = EntityCounter(
            context: context,
            for: (type: Item.self, limit: 10)
        )

        await waitForLoaded(counter)

        XCTAssertTrue(counter.isOverLimit(for: Item.self))
        XCTAssertTrue(counter.isOverAnyLimit)
    }

    // MARK: - Test 7: Cache key isolation between instances

    func testCacheKeyIsolation() async throws {
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

        await waitForLoaded(counterA)
        await waitForLoaded(counterB)

        XCTAssertEqual(counterA.limit(for: Item.self), 5)
        XCTAssertEqual(counterB.limit(for: Tag.self), 10)

        counterA.updateLimit(99, for: Item.self)

        // counterB's limit must be unaffected
        XCTAssertEqual(counterB.limit(for: Tag.self), 10)
    }

    // MARK: - Test 8: combinedRemaining excludingUnlimited uses only limited-model counts

    func testCombinedRemainingExcludingUnlimited() async throws {
        let container = try makeContainer(Item.self, Tag.self)
        let context = container.mainContext

        let counter = EntityCounter(
            context: context,
            for: (type: Item.self, limit: 10), (type: Tag.self, limit: nil)
        )

        await waitForLoaded(counter)

        for i in 0..<3 { context.insert(Item(name: "I\(i)")) }
        for i in 0..<5 { context.insert(Tag(label: "T\(i)")) }
        try context.save()

        await yieldForRefresh()

        // grandCount = 8 (3 Items + 5 Tags)
        XCTAssertEqual(counter.grandCount, 8)

        // combinedLimit excludingUnlimited = 10 (Item only; Tag is nil)
        XCTAssertEqual(counter.combinedLimit(scope: .excludingUnlimited), 10)

        // combinedRemaining excludingUnlimited = 10 - 3 (Items only) = 7
        // Must NOT subtract grandCount (8), which would give the wrong answer (2).
        XCTAssertEqual(counter.combinedRemaining(scope: .excludingUnlimited), 7)
    }

    // MARK: - Test 9: stopTracking prevents further refresh

    func testStopTrackingPreventsRefresh() async throws {
        let container = try makeContainer(Item.self)
        let context = container.mainContext

        let counter = EntityCounter(
            context: context,
            for: (type: Item.self, limit: 10)
        )

        await waitForLoaded(counter)
        XCTAssertEqual(counter.count(for: Item.self), 0)

        counter.stopTracking()

        context.insert(Item(name: "After stop"))
        try context.save()

        await yieldForRefresh()

        // Count must still be 0 — tracking was stopped before the save
        XCTAssertEqual(
            counter.count(for: Item.self),
            0,
            "stopTracking() must prevent count updates from subsequent saves"
        )
    }
}
