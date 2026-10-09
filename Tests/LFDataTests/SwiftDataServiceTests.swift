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
}
