import SwiftData

import XCTest
@testable import LFData

extension SwiftDataServiceTests.TestDataType {
    struct RenameRequest: DataUpdateRequest {
        let uuids: [UUID]
        let name: String

        var predicate: Predicate<SwiftDataServiceTests.TestDataType>? {
            let uuids = uuids
            return #Predicate { uuids.contains($0.uuid) }
        }

        func update(_ model: SwiftDataServiceTests.TestDataType) {
            model.name = name
        }
    }
}

final class SwiftDataServiceUpdateTests: XCTestCase {
    typealias TestDataType = SwiftDataServiceTests.TestDataType

    private func makeService() throws -> SwiftDataService {
        let schema = Schema([TestDataType.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return SwiftDataService(modelContainer: try ModelContainer(for: schema, configurations: config))
    }

    func testUpdateChangesOnlyMatchingRows() async throws {
        let dataService = try makeService()
        let alice = TestDataType.Row(uuid: UUID(), name: "Alice")
        let bob = TestDataType.Row(uuid: UUID(), name: "Bob")
        try await dataService.upsert(TestDataType.UpsertRequest(rows: [alice, bob]))

        try await dataService.update(TestDataType.RenameRequest(uuids: [alice.uuid], name: "Alicia"))

        let rows = try await dataService.fetch(TestDataType.RowFetchRequest())
        XCTAssertEqual(rows, [.init(uuid: alice.uuid, name: "Alicia"), bob])
    }

    func testUpdateNeverInserts() async throws {
        let dataService = try makeService()

        try await dataService.update(TestDataType.RenameRequest(uuids: [UUID()], name: "Nobody"))

        let rows = try await dataService.fetch(TestDataType.RowFetchRequest())
        XCTAssertEqual(rows, [])
    }

    func testUpdateNotifiesObservers() async throws {
        let dataService = try makeService()
        let alice = TestDataType.Row(uuid: UUID(), name: "Alice")
        try await dataService.upsert(TestDataType.UpsertRequest(rows: [alice]))
        var changes = dataService.changes(to: [TestDataType.self]).makeAsyncIterator()

        try await dataService.update(TestDataType.RenameRequest(uuids: [alice.uuid], name: "Alicia"))

        let change: Void? = await changes.next()
        XCTAssertNotNil(change)
    }
}
