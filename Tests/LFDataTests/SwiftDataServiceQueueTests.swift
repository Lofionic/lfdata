import Foundation
import os
import SwiftData

import XCTest
@testable import LFData

final class QueueProbe: Sendable {
    private let hits = OSAllocatedUnfairLock(initialState: [Bool]())

    var recorded: [Bool] { hits.withLock { $0 } }

    func reset() { hits.withLock { $0 = [] } }

    func record() {
        let isOnProbeQueue = DispatchQueue.getSpecific(key: SwiftDataServiceQueueTests.queueKey) == true
        let isMain = Thread.isMainThread
        hits.withLock { $0.append(isOnProbeQueue && !isMain) }
    }
}

final class SwiftDataServiceQueueTests: XCTestCase {
    static let queueKey = DispatchSpecificKey<Bool>()
    static let probe = QueueProbe()

    @Model
    class QueueModel {
        var name: String

        init(name: String) {
            self.name = name
        }

        struct InsertRequest: DataInsertRequest {
            let rows: [String]

            static func predicate(for dto: String) -> Predicate<QueueModel> {
                #Predicate { $0.name == dto }
            }

            static func map(_ dto: String) -> QueueModel {
                SwiftDataServiceQueueTests.probe.record()
                return QueueModel(name: dto)
            }
        }

        struct FetchRequest: DataFetchRequest {
            var predicate: Predicate<QueueModel>? { nil }
            var sortDescriptors: [SortDescriptor<QueueModel>] { [SortDescriptor(\.name)] }
            var limit: Int? { nil }

            static func map(_ model: QueueModel) -> String {
                SwiftDataServiceQueueTests.probe.record()
                return model.name
            }
        }
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([QueueModel.self])
        return try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
    }

    override func setUp() {
        super.setUp()
        Self.probe.reset()
    }

    @MainActor
    func testRequestsRunOnTheGivenQueue() async throws {
        let queue = DispatchSerialQueue(label: "LFDataTests.queue")
        queue.setSpecific(key: Self.queueKey, value: true)
        let container = try makeContainer()
        let service = SwiftDataService(modelContainer: container, queue: queue)

        try await service.insert(QueueModel.InsertRequest(rows: ["a", "b"]))
        let names = try await service.fetch(QueueModel.FetchRequest())

        XCTAssertEqual(names, ["a", "b"])
        XCTAssertEqual(Self.probe.recorded, [true, true, true, true])
    }

    @MainActor
    func testDefaultQueueIsPrivateAndOffTheMainThread() async throws {
        let container = try makeContainer()
        let service = SwiftDataService(modelContainer: container)

        try await service.insert(QueueModel.InsertRequest(rows: ["a"]))
        let names = try await service.fetch(QueueModel.FetchRequest())

        XCTAssertEqual(names, ["a"])
        XCTAssertEqual(Self.probe.recorded, [false, false])
    }

    @MainActor
    func testServicesSharingAContainerOnDifferentQueuesSeeEachOthersWrites() async throws {
        let container = try makeContainer()
        let writer = SwiftDataService(modelContainer: container, queue: DispatchSerialQueue(label: "LFDataTests.writer"))
        let reader = SwiftDataService(modelContainer: container, queue: DispatchSerialQueue(label: "LFDataTests.reader"))

        try await writer.insert(QueueModel.InsertRequest(rows: ["shared"]))
        let names = try await reader.fetch(QueueModel.FetchRequest())

        XCTAssertEqual(names, ["shared"])
    }
}
