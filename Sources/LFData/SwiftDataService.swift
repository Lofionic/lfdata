import Foundation
import SwiftData

public enum DataServiceError: Error, Equatable {
    case duplicateRow
}

public protocol DataService: Actor {
    func fetch<T: DataFetchRequest>(_ request: T) throws -> [T.DTOType]
    func insert<T: DataInsertRequest>(_ request: T) throws
    func delete<T: DataDeleteRequest>(_ request: T) throws
    func delete<T: DataDeleteRowRequest>(_ request: T) throws
    func upsert<T: DataUpsertRequest>(_ request: T) throws

    nonisolated func observe<T: DataFetchRequest>(_ request: T) -> AsyncThrowingStream<[T.DTOType], any Error>
        where T.DTOType: Equatable
    nonisolated func changes(to modelTypes: [any PersistentModel.Type]) -> AsyncStream<Void>
}

public protocol DataFetchRequest: Sendable {
    associatedtype ModelType: PersistentModel
    associatedtype DTOType: Sendable

    var predicate: Predicate<ModelType>? { get }
    var sortDescriptors: [SortDescriptor<ModelType>] { get }
    var limit: Int? { get }
    static func map(_ model: ModelType) throws -> DTOType
}

public protocol DataInsertRequest: Sendable {
    associatedtype ModelType: PersistentModel
    associatedtype DTOType: Sendable

    var rows: [DTOType] { get }
    var batchSize: Int { get }
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

public protocol DataUpsertRequest: Sendable {
    associatedtype ModelType: PersistentModel
    associatedtype DTOType: Sendable

    var rows: [DTOType] { get }
    static func predicate(for dto: DTOType) -> Predicate<ModelType>
    static func map(_ dto: DTOType) -> ModelType
    static func update(_ model: ModelType, with dto: DTOType)
}

public actor SwiftDataService: DataService {
    private let modelContainer: ModelContainer
    private let queue: DispatchSerialQueue
    private lazy var modelContext = ModelContext(modelContainer)
    nonisolated let observers = ChangeObservers()
    private nonisolated(unsafe) let saveObserver: any NSObjectProtocol

    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    public init(
        modelContainer: ModelContainer,
        queue: DispatchSerialQueue = DispatchSerialQueue(label: "LFData.SwiftDataService")
    ) {
        self.modelContainer = modelContainer
        self.queue = queue
        saveObserver = observers.notifyOnSaves(to: modelContainer)
    }

    deinit {
        NotificationCenter.default.removeObserver(saveObserver)
    }

    public func fetch<T: DataFetchRequest>(_ request: T) throws -> [T.DTOType] {
        var descriptor = FetchDescriptor<T.ModelType>(
            predicate: request.predicate,
            sortBy: request.sortDescriptors
        )
        descriptor.fetchLimit = request.limit

        let rows = try modelContext.fetch(descriptor)
        return try rows.map(T.map)
    }

    public nonisolated func observe<T: DataFetchRequest>(_ request: T) -> AsyncThrowingStream<[T.DTOType], any Error>
        where T.DTOType: Equatable {
        let changes = changes(to: [T.ModelType.self])
        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                do {
                    var latest = try await freshFetch(request)
                    continuation.yield(latest)
                    for await _ in changes {
                        let rows = try await freshFetch(request)
                        if rows != latest {
                            latest = rows
                            continuation.yield(rows)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public nonisolated func changes(to modelTypes: [any PersistentModel.Type]) -> AsyncStream<Void> {
        observers.stream(for: Set(modelTypes.map { Schema.entityName(for: $0) }))
    }

    private func freshFetch<T: DataFetchRequest>(_ request: T) throws -> [T.DTOType] {
        var descriptor = FetchDescriptor<T.ModelType>(
            predicate: request.predicate,
            sortBy: request.sortDescriptors
        )
        descriptor.fetchLimit = request.limit

        return try ModelContext(modelContainer).fetch(descriptor).map(T.map)
    }

    private func didChange(_ modelType: any PersistentModel.Type) {
        observers.notify([Schema.entityName(for: modelType)])
    }

    public func insert<T: DataInsertRequest>(_ request: T) throws {
        do {
            var cursor = 0
            while (cursor < request.rows.count) {
                let upper = min(request.rows.count, cursor + request.batchSize) - 1
                for dto in request.rows[cursor...upper] {
                    let descriptor = FetchDescriptor<T.ModelType>(predicate: T.predicate(for: dto))
                    guard try modelContext.fetchCount(descriptor) == 0 else {
                        throw DataServiceError.duplicateRow
                    }
                    modelContext.insert(T.map(dto))
                }
                cursor += request.batchSize
            }
            try modelContext.save()
            didChange(T.ModelType.self)
        } catch {
            modelContext.rollback()
            throw error
        }
    }
    
    public func delete<T: DataDeleteRequest>(_ request: T) throws {
        do {
            try modelContext.delete(model: T.ModelType.self, where: request.predicate)
            try modelContext.save()
            didChange(T.ModelType.self)
        } catch {
            modelContext.rollback()
            throw error
        }
    }
    
    public func delete<T: DataDeleteRowRequest>(_ request: T) throws {
        modelContext.delete(modelContext.model(for: request.id))
        do {
            try modelContext.save()
            observers.notify([request.id.entityName])
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
                if let existing = try modelContext.fetch(descriptor).first {
                    T.update(existing, with: dto)
                } else {
                    modelContext.insert(T.map(dto))
                }
            }
            try modelContext.save()
            didChange(T.ModelType.self)
        } catch {
            modelContext.rollback()
            throw error
        }
    }
}
