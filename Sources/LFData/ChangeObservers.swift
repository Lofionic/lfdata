import Foundation
import SwiftData
import Synchronization

final class ChangeObservers: Sendable {
    private struct Observer: Sendable {
        let entityNames: Set<String>
        let continuation: AsyncStream<Void>.Continuation
    }

    private let observers = Mutex<[UUID: Observer]>([:])

    var count: Int {
        observers.withLock { $0.count }
    }

    func stream(for entityNames: Set<String>) -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        observers.withLock { $0[id] = Observer(entityNames: entityNames, continuation: continuation) }
        continuation.onTermination = { [weak self] _ in
            self?.observers.withLock { $0[id] = nil }
        }
        return stream
    }

    func notify(_ entityNames: Set<String>) {
        let affected = observers.withLock { observers in
            observers.values.filter { !$0.entityNames.isDisjoint(with: entityNames) }.map(\.continuation)
        }
        affected.forEach { $0.yield() }
    }

    func notifyOnSaves(to container: ModelContainer) -> any NSObjectProtocol {
        NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: nil) { [weak self] notification in
            guard let context = notification.object as? ModelContext, context.container === container else { return }

            let keys: [ModelContext.NotificationKey] = [.insertedIdentifiers, .updatedIdentifiers, .deletedIdentifiers]
            let identifiers = keys.flatMap { notification.userInfo?[$0.rawValue] as? [PersistentIdentifier] ?? [] }
            self?.notify(Set(identifiers.map(\.entityName)))
        }
    }
}
