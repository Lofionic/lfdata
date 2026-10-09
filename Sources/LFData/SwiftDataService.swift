import Foundation
import SwiftData

public protocol DataService: Actor {
    func fetch<T: DataFetchRequest>(_ request: T) throws -> [T.DTOType]
    func insert<T: DataInsertRequest>(_ request: T) throws
}

public protocol DataFetchRequest: Sendable {
    associatedtype ModelType: PersistentModel
    associatedtype DTOType: Sendable

    var predicate: Predicate<ModelType>? { get }
    var sortDescriptors: [SortDescriptor<ModelType>] { get }
    var limit: Int? { get }
    static func map(_ model: ModelType) -> DTOType
}

public protocol DataInsertRequest: Sendable {
    associatedtype ModelType: PersistentModel
    associatedtype DTOType: Sendable

    var rows: [DTOType] { get }
    var batchSize: Int { get }
    static func map(_ dto: DTOType) -> ModelType
}

extension DataInsertRequest {
    var batchSize: Int { 20 }
}

public actor SwiftDataService: DataService {
    public nonisolated let modelContainer: ModelContainer
    private let modelContext: ModelContext

    public init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
        self.modelContext = ModelContext(modelContainer)
    }

    public func fetch<T: DataFetchRequest>(_ request: T) throws -> [T.DTOType] {
        assert(!Thread.isMainThread)
        var descriptor = FetchDescriptor<T.ModelType>(
            predicate: request.predicate,
            sortBy: request.sortDescriptors
        )
        descriptor.fetchLimit = request.limit

        let rows = try modelContext.fetch(descriptor)
        return rows.map(T.map)
    }

    public func insert<T: DataInsertRequest>(_ request: T) throws {
        assert(!Thread.isMainThread)
        
        var cursor = 0
        while (cursor < request.rows.count) {
            let upper = min(request.rows.count, cursor + request.batchSize) - 1
            for dto in request.rows[cursor...upper] {
                modelContext.insert(T.map(dto))
            }
            cursor += request.batchSize
        }
        
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }
}
