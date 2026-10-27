import SwiftData

import XCTest
@testable import LFData

final class SwiftDataServiceObserveTests: XCTestCase {
    private typealias TestDataType = SwiftDataServiceTests.TestDataType

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([TestDataType.self])
        return try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
    }

    private func names() -> TestDataType.FetchRequest {
        TestDataType.FetchRequest(sortDescriptors: [SortDescriptor(\.name)])
    }

    func testObserveStartsWithTheCurrentRows() async throws {
        let service = SwiftDataService(modelContainer: try makeContainer())
        try await service.insert(TestDataType.InsertRequest(rows: ["Ada"]))

        var updates = service.observe(names()).makeAsyncIterator()
        let first = try await updates.next()

        XCTAssertEqual(first, ["Ada"])
    }

    func testEveryKindOfWriteDeliversTheNewRows() async throws {
        let service = SwiftDataService(modelContainer: try makeContainer())
        var updates = service.observe(names()).makeAsyncIterator()
        _ = try await updates.next()

        try await service.insert(TestDataType.InsertRequest(rows: ["Ada", "Grace"]))
        let afterInsert = try await updates.next()
        try await service.delete(TestDataType.DeleteRequest(predicate: #Predicate { $0.name == "Ada" }))
        let afterDelete = try await updates.next()

        XCTAssertEqual(afterInsert, ["Ada", "Grace"])
        XCTAssertEqual(afterDelete, ["Grace"])
    }

    func testDeletingARowDeliversTheNewRows() async throws {
        let container = try makeContainer()
        let service = SwiftDataService(modelContainer: container)
        try await service.insert(TestDataType.InsertRequest(rows: ["Ada", "Grace"]))
        let ada = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<TestDataType>(predicate: #Predicate { $0.name == "Ada" })).first)
        var updates = service.observe(names()).makeAsyncIterator()
        _ = try await updates.next()

        try await service.delete(TestDataType.DeleteRowRequest(id: ada.persistentModelID))
        let next = try await updates.next()

        XCTAssertEqual(next, ["Grace"])
    }

    func testSavesFromAnotherContextOnTheSameContainerAreDelivered() async throws {
        let container = try makeContainer()
        let service = SwiftDataService(modelContainer: container)
        var updates = service.observe(names()).makeAsyncIterator()
        _ = try await updates.next()

        let context = ModelContext(container)
        context.insert(TestDataType(name: "Katherine"))
        try context.save()
        let next = try await updates.next()

        XCTAssertEqual(next, ["Katherine"])
    }

    func testUnchangedResultsAreNotDeliveredAgain() async throws {
        let service = SwiftDataService(modelContainer: try makeContainer())
        let onlyAda = service.observe(TestDataType.FetchRequest(predicate: #Predicate { $0.name == "Ada" }))
        let received = Task {
            var count = 0
            for try await _ in onlyAda {
                count += 1
            }
            return count
        }
        try await Task.sleep(for: .milliseconds(100))

        try await service.insert(TestDataType.InsertRequest(rows: ["Grace"]))
        try await Task.sleep(for: .milliseconds(200))
        received.cancel()

        let count = try await received.value
        XCTAssertEqual(count, 1)
    }

    func testSavesToAnotherContainerAreNotDelivered() async throws {
        let service = SwiftDataService(modelContainer: try makeContainer())
        let changes = service.changes(to: [TestDataType.self])
        let received = Task {
            var count = 0
            for await _ in changes {
                count += 1
            }
            return count
        }
        try await Task.sleep(for: .milliseconds(100))

        let otherContext = ModelContext(try makeContainer())
        otherContext.insert(TestDataType(name: "Ada"))
        try otherContext.save()
        try await Task.sleep(for: .milliseconds(200))
        received.cancel()

        let count = await received.value
        XCTAssertEqual(count, 0)
    }

    func testStoppingObservationRemovesTheObserver() async throws {
        let service = SwiftDataService(modelContainer: try makeContainer())
        let updates = service.observe(names())
        let observing = Task {
            for try await _ in updates {}
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(service.observers.count, 1)

        observing.cancel()
        _ = await observing.result
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(service.observers.count, 0)
    }
}
