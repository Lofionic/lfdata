import SwiftData

import XCTest
@testable import LFData

extension SwiftDataServiceTests.TestDataType {
    struct Row: Sendable, Equatable {
        let uuid: UUID
        let name: String
    }

    struct UpsertRequest: DataUpsertRequest {
        let rows: [Row]

        static func predicate(for dto: Row) -> Predicate<SwiftDataServiceTests.TestDataType> {
            let uuid = dto.uuid
            return #Predicate { $0.uuid == uuid }
        }

        static func map(_ dto: Row) -> SwiftDataServiceTests.TestDataType {
            SwiftDataServiceTests.TestDataType(uuid: dto.uuid, name: dto.name)
        }

        static func update(_ model: SwiftDataServiceTests.TestDataType, with dto: Row) {
            model.name = dto.name
        }
    }

    struct RowFetchRequest: DataFetchRequest {
        var predicate: Predicate<SwiftDataServiceTests.TestDataType>? { nil }
        var sortDescriptors: [SortDescriptor<SwiftDataServiceTests.TestDataType>] { [SortDescriptor(\.name)] }
        var limit: Int? { nil }

        static func map(_ model: SwiftDataServiceTests.TestDataType) -> Row {
            Row(uuid: model.uuid, name: model.name)
        }
    }
}

final class SwiftDataServiceUpsertTests: XCTestCase {
    typealias TestDataType = SwiftDataServiceTests.TestDataType

    private func makeService() throws -> (SwiftDataService, ModelContainer) {
        let schema = Schema([TestDataType.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let modelContainer = try ModelContainer(for: schema, configurations: config)
        return (SwiftDataService(modelContainer: modelContainer), modelContainer)
    }

    func testUpsertInsertsWhenNoMatch() async throws {
        let (dataService, _) = try makeService()
        let alice = TestDataType.Row(uuid: UUID(), name: "Alice")

        try await dataService.upsert(TestDataType.UpsertRequest(rows: [alice]))

        let rows = try await dataService.fetch(TestDataType.RowFetchRequest())
        XCTAssertEqual(rows, [alice])
    }

    func testUpsertUpdatesExistingRowInPlace() async throws {
        let (dataService, modelContainer) = try makeService()
        let uuid = UUID()
        try await dataService.upsert(TestDataType.UpsertRequest(rows: [.init(uuid: uuid, name: "Alice")]))

        let callerContext = ModelContext(modelContainer)
        let originalID = try XCTUnwrap(callerContext.fetch(FetchDescriptor<TestDataType>()).first?.persistentModelID)

        try await dataService.upsert(TestDataType.UpsertRequest(rows: [.init(uuid: uuid, name: "Alicia")]))

        let models = try ModelContext(modelContainer).fetch(FetchDescriptor<TestDataType>())
        XCTAssertEqual(models.count, 1)
        XCTAssertEqual(models.first?.name, "Alicia")
        XCTAssertEqual(models.first?.persistentModelID, originalID)
    }

    func testUpsertMixesInsertsAndUpdates() async throws {
        let (dataService, _) = try makeService()
        let aliceID = UUID()
        try await dataService.upsert(TestDataType.UpsertRequest(rows: [.init(uuid: aliceID, name: "Alice")]))

        let bob = TestDataType.Row(uuid: UUID(), name: "Bob")
        try await dataService.upsert(TestDataType.UpsertRequest(rows: [
            .init(uuid: aliceID, name: "Alicia"),
            bob,
        ]))

        let rows = try await dataService.fetch(TestDataType.RowFetchRequest())
        XCTAssertEqual(rows, [.init(uuid: aliceID, name: "Alicia"), bob])
    }

    func testUpsertRepeatedDTOInOneRequestHitsSameRow() async throws {
        let (dataService, _) = try makeService()
        let uuid = UUID()

        try await dataService.upsert(TestDataType.UpsertRequest(rows: [
            .init(uuid: uuid, name: "First"),
            .init(uuid: uuid, name: "Second"),
        ]))

        let rows = try await dataService.fetch(TestDataType.RowFetchRequest())
        XCTAssertEqual(rows, [.init(uuid: uuid, name: "Second")])
    }

    func testUpsertWithZeroRows() async throws {
        let (dataService, _) = try makeService()

        try await dataService.upsert(TestDataType.UpsertRequest(rows: []))

        let rows = try await dataService.fetch(TestDataType.RowFetchRequest())
        XCTAssertEqual(rows, [])
    }
}
