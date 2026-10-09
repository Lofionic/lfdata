import Foundation
import os
import SwiftData

import XCTest
@testable import LFData

/// Records, from inside the actor's work, whether it ran on the main thread and how many
/// requests were executing at the same time.
final class ExecutionProbe: Sendable {
    struct State {
        var inFlight = 0
        var maxInFlight = 0
        var mainThreadHits = 0
        var calls = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var snapshot: State { state.withLock { $0 } }

    func reset() { state.withLock { $0 = State() } }

    func enter() {
        let isMain = Thread.isMainThread
        state.withLock {
            $0.inFlight += 1
            $0.maxInFlight = max($0.maxInFlight, $0.inFlight)
            $0.calls += 1
            if isMain { $0.mainThreadHits += 1 }
        }
    }

    func exit() { state.withLock { $0.inFlight -= 1 } }
}

final class SwiftDataServiceConcurrencyTests: XCTestCase {
    static let probe = ExecutionProbe()

    @Model
    class ProbeModel {
        var name: String

        init(name: String) {
            self.name = name
        }

        struct InsertRequest: DataInsertRequest {
            let rows: [String]

            static func map(_ dto: String) -> ProbeModel {
                SwiftDataServiceConcurrencyTests.probe.enter()
                defer { SwiftDataServiceConcurrencyTests.probe.exit() }
                // Widen the window so overlapping executions would be observed.
                usleep(200)
                return ProbeModel(name: dto)
            }
        }

        struct FetchRequest: DataFetchRequest {
            var predicate: Predicate<ProbeModel>? { nil }
            var sortDescriptors: [SortDescriptor<ProbeModel>] { [] }
            var limit: Int? { nil }

            static func map(_ model: ProbeModel) -> String {
                SwiftDataServiceConcurrencyTests.probe.enter()
                defer { SwiftDataServiceConcurrencyTests.probe.exit() }
                usleep(200)
                return model.name
            }
        }
    }

    /// Driven from the main actor, as an app-wide shared instance typically is, then hammered
    /// with concurrent inserts and fetches.
    @MainActor
    func testSharedServiceRunsOffMainAndSerializes() async throws {
        XCTAssertTrue(Thread.isMainThread)
        Self.probe.reset()

        let schema = Schema([ProbeModel.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)
        let service = SwiftDataService(modelContainer: container)

        let writers = 20
        let rowsPerWriter = 25

        // Main-thread heartbeat: if the actor's work ran on main, these ticks would stall.
        let heartbeat = Task { @MainActor in
            var longestGap: TimeInterval = 0
            var last = Date()
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(1))
                let now = Date()
                longestGap = max(longestGap, now.timeIntervalSince(last))
                last = now
            }
            return longestGap
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for writer in 0..<writers {
                group.addTask {
                    let rows = (0..<rowsPerWriter).map { "w\(writer)-r\($0)" }
                    try await service.insert(ProbeModel.InsertRequest(rows: rows))
                }
                group.addTask {
                    _ = try await service.fetch(ProbeModel.FetchRequest())
                }
            }
            try await group.waitForAll()
        }

        heartbeat.cancel()
        let longestMainGap = await heartbeat.value

        let rows = try await service.fetch(ProbeModel.FetchRequest())
        XCTAssertEqual(rows.count, writers * rowsPerWriter)
        XCTAssertEqual(Set(rows).count, writers * rowsPerWriter)

        let state = Self.probe.snapshot
        XCTAssertGreaterThan(state.calls, writers * rowsPerWriter)
        XCTAssertEqual(state.mainThreadHits, 0, "Actor work executed on the main thread")
        XCTAssertEqual(state.maxInFlight, 1, "Requests overlapped; actor work was not serialized")
        // 500 inserts × 200µs ≈ 100ms of actor work; main should never stall for anything close to that.
        XCTAssertLessThan(longestMainGap, 0.05, "Main thread stalled for \(longestMainGap)s")

        print("calls=\(state.calls) maxInFlight=\(state.maxInFlight) mainHits=\(state.mainThreadHits) longestMainGap=\(longestMainGap)")
    }
}
