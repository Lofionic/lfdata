import SwiftData

import XCTest
@testable import LFData

final class SwiftDataServiceTests: XCTestCase {
    @Model
    class TestDataType {
        @Attribute(.unique)
        var uuid: UUID
        var name: String
        
        struct InsertRequest: DataInsertRequest {
            let rows: [String]
            let batchSize: Int
            
            init(rows: [String], batchSize: Int = 20) {
                self.rows = rows
                self.batchSize = batchSize
            }
            
            static func predicate(for dto: String) -> Predicate<TestDataType> {
                #Predicate { $0.name == dto }
            }
            
            static func map(_ dto: String) -> TestDataType {
                TestDataType(name: dto)
            }
        }
        
        struct FetchRequest: DataFetchRequest {
            let predicate: Predicate<SwiftDataServiceTests.TestDataType>?
            let sortDescriptors: [SortDescriptor<SwiftDataServiceTests.TestDataType>]
            let limit: Int?
            
            init(
                predicate: Predicate<SwiftDataServiceTests.TestDataType>? = nil,
                sortDescriptors: [SortDescriptor<SwiftDataServiceTests.TestDataType>] = [],
                limit: Int? = nil
            ) {
                self.predicate = predicate
                self.sortDescriptors = sortDescriptors
                self.limit = limit
            }
            
            static func map(_ model: TestDataType) -> String {
                model.name
            }
        }
        
        struct DeleteRequest: DataDeleteRequest {
            let predicate: Predicate<SwiftDataServiceTests.TestDataType>?
            
            init(predicate: Predicate<SwiftDataServiceTests.TestDataType>? = nil) {
                self.predicate = predicate
            }
        }
        
        struct DeleteRowRequest: DataDeleteRowRequest {
            let id: PersistentIdentifier
        }
        
        init(uuid: UUID = .init(), name: String) {
            self.uuid = uuid
            self.name = name
        }
    }
    
    func testInsertAndFetch() async throws {
        let schema = Schema([TestDataType.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        
        let modelContainer = try ModelContainer(for: schema, configurations: config)
        let dataService = SwiftDataService(modelContainer: modelContainer)
        
        let insertRequest = TestDataType.InsertRequest(rows: ["Chris Rivers"])
        try await dataService.insert(insertRequest)
        
        let fetchRequest = TestDataType.FetchRequest()
        let rows = try await dataService.fetch(fetchRequest)
        
        XCTAssertEqual(rows, ["Chris Rivers"])
    }
    
    func testInsertAndFetchWithZeroRows() async throws {
        let schema = Schema([TestDataType.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        
        let modelContainer = try ModelContainer(for: schema, configurations: config)
        let dataService = SwiftDataService(modelContainer: modelContainer)
        
        let insertRequest = TestDataType.InsertRequest(rows: [])
        try await dataService.insert(insertRequest)
        
        let fetchRequest = TestDataType.FetchRequest()
        let rows = try await dataService.fetch(fetchRequest)
        
        XCTAssertEqual(rows, [])
    }
    
    func testInsertAndFetchWithBatches() async throws {
        let schema = Schema([TestDataType.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        
        let modelContainer = try ModelContainer(for: schema, configurations: config)
        let dataService = SwiftDataService(modelContainer: modelContainer)
        
        let expectedRows = (0...500).map {
            "Name: \($0)"
        }
        
        let insertRequest = TestDataType.InsertRequest(rows: expectedRows)
        try await dataService.insert(insertRequest)
        
        let fetchRequest = TestDataType.FetchRequest(sortDescriptors: [.init(\.name)])
        let rows = try await dataService.fetch(fetchRequest)
        
        XCTAssertEqual(rows, expectedRows)
    }
    
    func testDeleteWithPredicate() async throws {
        let schema = Schema([TestDataType.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        
        let modelContainer = try ModelContainer(for: schema, configurations: config)
        let dataService = SwiftDataService(modelContainer: modelContainer)
        
        let insertRequest = TestDataType.InsertRequest(rows: ["Alice", "Bob", "Carol"])
        try await dataService.insert(insertRequest)
        
        let deleteRequest = TestDataType.DeleteRequest(predicate: #Predicate { $0.name == "Bob" })
        try await dataService.delete(deleteRequest)
        
        let fetchRequest = TestDataType.FetchRequest(sortDescriptors: [.init(\.name)])
        let rows = try await dataService.fetch(fetchRequest)
        
        XCTAssertEqual(rows, ["Alice", "Carol"])
    }
    
    func testDeleteWithNilPredicateDeletesAll() async throws {
        let schema = Schema([TestDataType.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        
        let modelContainer = try ModelContainer(for: schema, configurations: config)
        let dataService = SwiftDataService(modelContainer: modelContainer)
        
        let insertRequest = TestDataType.InsertRequest(rows: (0...100).map { "Name: \($0)" })
        try await dataService.insert(insertRequest)
        
        try await dataService.delete(TestDataType.DeleteRequest())
        
        let rows = try await dataService.fetch(TestDataType.FetchRequest())
        
        XCTAssertEqual(rows, [])
    }
    
    func testDeleteWithNoMatches() async throws {
        let schema = Schema([TestDataType.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        
        let modelContainer = try ModelContainer(for: schema, configurations: config)
        let dataService = SwiftDataService(modelContainer: modelContainer)
        
        let insertRequest = TestDataType.InsertRequest(rows: ["Alice", "Bob"])
        try await dataService.insert(insertRequest)
        
        let deleteRequest = TestDataType.DeleteRequest(predicate: #Predicate { $0.name == "Nobody" })
        try await dataService.delete(deleteRequest)
        
        let fetchRequest = TestDataType.FetchRequest(sortDescriptors: [.init(\.name)])
        let rows = try await dataService.fetch(fetchRequest)
        
        XCTAssertEqual(rows, ["Alice", "Bob"])
    }
    
    func testDeleteRowFromAnotherContext() async throws {
        let schema = Schema([TestDataType.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        
        let modelContainer = try ModelContainer(for: schema, configurations: config)
        let dataService = SwiftDataService(modelContainer: modelContainer)
        
        let insertRequest = TestDataType.InsertRequest(rows: ["Alice", "Bob"])
        try await dataService.insert(insertRequest)
        
        let callerContext = ModelContext(modelContainer)
        let bob = try XCTUnwrap(
            callerContext.fetch(FetchDescriptor<TestDataType>(predicate: #Predicate { $0.name == "Bob" })).first
        )
        
        try await dataService.delete(TestDataType.DeleteRowRequest(id: bob.persistentModelID))
        
        let fetchRequest = TestDataType.FetchRequest(sortDescriptors: [.init(\.name)])
        let rows = try await dataService.fetch(fetchRequest)
        
        XCTAssertEqual(rows, ["Alice"])
    }
    
    func testInsertThrowsWhenRowAlreadyExists() async throws {
        let schema = Schema([TestDataType.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        
        let modelContainer = try ModelContainer(for: schema, configurations: config)
        let dataService = SwiftDataService(modelContainer: modelContainer)
        
        try await dataService.insert(TestDataType.InsertRequest(rows: ["Alice"]))
        
        do {
            try await dataService.insert(TestDataType.InsertRequest(rows: ["Bob", "Alice"]))
            XCTFail("Expected duplicateRow")
        } catch {
            XCTAssertEqual(error as? DataServiceError, .duplicateRow)
        }
        
        let rows = try await dataService.fetch(TestDataType.FetchRequest(sortDescriptors: [.init(\.name)]))
        XCTAssertEqual(rows, ["Alice"])
    }
    
    func testInsertThrowsOnDuplicateWithinRequest() async throws {
        let schema = Schema([TestDataType.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        
        let modelContainer = try ModelContainer(for: schema, configurations: config)
        let dataService = SwiftDataService(modelContainer: modelContainer)
        
        do {
            try await dataService.insert(TestDataType.InsertRequest(rows: ["Alice", "Bob", "Alice"], batchSize: 2))
            XCTFail("Expected duplicateRow")
        } catch {
            XCTAssertEqual(error as? DataServiceError, .duplicateRow)
        }
        
        let rows = try await dataService.fetch(TestDataType.FetchRequest())
        XCTAssertEqual(rows, [])
        
        try await dataService.insert(TestDataType.InsertRequest(rows: ["Carol"]))
        let afterRows = try await dataService.fetch(TestDataType.FetchRequest())
        XCTAssertEqual(afterRows, ["Carol"])
    }
}
