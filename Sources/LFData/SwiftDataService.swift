import Foundation
import SwiftData

public enum DataServiceError: Error, Equatable {
    /// An inserted DTO matched a row already in the store, or earlier in the same request.
    case duplicateRow
}

public protocol DataService: Actor {
    func fetch<T: DataFetchRequest>(_ request: T) throws -> [T.DTOType]
    func insert<T: DataInsertRequest>(_ request: T) throws
    func delete<T: DataDeleteRequest>(_ request: T) throws
    func delete<T: DataDeleteRowRequest>(_ request: T) throws
    func upsert<T: DataUpsertRequest>(_ request: T) throws
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
    /// Identifies an existing row for `dto`. Any match makes the insert throw `DataServiceError.duplicateRow`.
    static func predicate(for dto: DTOType) -> Predicate<ModelType>
    static func map(_ dto: DTOType) -> ModelType
}

extension DataInsertRequest {
    var batchSize: Int { 20 }
}

public protocol DataDeleteRequest: Sendable {
    associatedtype ModelType: PersistentModel
    var predicate: Predicate<ModelType>? { get }
}

public protocol DataDeleteRowRequest: Sendable {
    var id: PersistentIdentifier { get }
}

/// Updates the row matching each DTO, or inserts a new row when none matches.
public protocol DataUpsertRequest: Sendable {
    associatedtype ModelType: PersistentModel
    associatedtype DTOType: Sendable

    var rows: [DTOType] { get }
    /// Identifies the existing row for `dto`. Only the first match is updated.
    static func predicate(for dto: DTOType) -> Predicate<ModelType>
    static func map(_ dto: DTOType) -> ModelType
    static func update(_ model: ModelType, with dto: DTOType)
}

public actor SwiftDataService: DataService {
    private let modelContainer: ModelContainer
    private let modelContext: ModelContext

    public init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
        self.modelContext = ModelContext(modelContainer)
    }

    public func fetch<T: DataFetchRequest>(_ request: T) throws -> [T.DTOType] {
        var descriptor = FetchDescriptor<T.ModelType>(
            predicate: request.predicate,
            sortBy: request.sortDescriptors
        )
        descriptor.fetchLimit = request.limit

        let rows = try modelContext.fetch(descriptor)
        return rows.map(T.map)
    }

    public func insert<T: DataInsertRequest>(_ request: T) throws {
        do {
            var cursor = 0
            while (cursor < request.rows.count) {
                let upper = min(request.rows.count, cursor + request.batchSize) - 1
                for dto in request.rows[cursor...upper] {
                    // Fetches include pending inserts, so repeated DTOs in one request are caught too.
                    let descriptor = FetchDescriptor<T.ModelType>(predicate: T.predicate(for: dto))
                    guard try modelContext.fetchCount(descriptor) == 0 else {
                        throw DataServiceError.duplicateRow
                    }
                    modelContext.insert(T.map(dto))
                }
                cursor += request.batchSize
            }
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }
    
    public func delete<T: DataDeleteRequest>(_ request: T) throws {
        do {
            try modelContext.delete(model: T.ModelType.self, where: request.predicate)
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }
    
    public func delete<T: DataDeleteRowRequest>(_ request: T) throws {
        modelContext.delete(modelContext.model(for: request.id))
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    public func upsert<T: DataUpsertRequest>(_ request: T) throws {
        do {
            for dto in request.rows {
                var descriptor = FetchDescriptor<T.ModelType>(predicate: T.predicate(for: dto))
                descriptor.fetchLimit = 1
                // Fetches include pending inserts, so repeated DTOs in one request hit the same row.
                if let existing = try modelContext.fetch(descriptor).first {
                    T.update(existing, with: dto)
                } else {
                    modelContext.insert(T.map(dto))
                }
            }
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }
}
