# LFData

A small Swift package for doing SwiftData work off the main thread through typed, `Sendable` requests.

`SwiftDataService` is an actor that owns its own `ModelContext`. You describe what to fetch, insert or delete with request types; the service runs them serially on its own executor and hands back plain `Sendable` values (DTOs) instead of `@Model` objects, so results can cross actor boundaries safely.

- **Never blocks the main thread** — requests run on the actor even when awaited from `@MainActor` code.
- **Serialized** — one request runs at a time against a single context.
- **Rolls back on failure** — if a save throws, pending inserts and deletes are discarded.

## Requirements

- iOS 18+ / macOS 15+ / tvOS 18+ / watchOS 11+ / visionOS 2+
- Swift 6.4 (Xcode 27)

## Installation

Add the package in Xcode via **File › Add Package Dependencies…**, or in `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/Lofionic/lfdata.git", from: "2.0.0"),
],
targets: [
    .target(name: "MyApp", dependencies: ["LFData"]),
]
```

## Usage

### 1. Define a model and a DTO

```swift
import SwiftData

@Model
final class Person {
    var name: String
    init(name: String) { self.name = name }
}

struct PersonDTO: Sendable, Equatable {
    let name: String
}
```

### 2. Define requests

A fetch request supplies a predicate, sort order and limit, plus a mapping from model to DTO. The mapping can throw, for example when decoding stored data; the error is thrown from `fetch` and ends an `observe` stream:

```swift
import LFData

struct PeopleRequest: DataFetchRequest {
    var predicate: Predicate<Person>? = nil
    var sortDescriptors: [SortDescriptor<Person>] = [SortDescriptor(\.name)]
    var limit: Int? = nil

    static func map(_ model: Person) -> PersonDTO {
        PersonDTO(name: model.name)
    }
}
```

An insert request supplies the rows to insert, a predicate that identifies an existing row for each DTO, and a mapping from DTO to model. If any DTO matches a row already in the store, or an earlier row in the same request, the insert throws `DataServiceError.duplicateRow` and nothing is saved. Use an upsert to update rows that already exist.

```swift
struct InsertPeopleRequest: DataInsertRequest {
    let rows: [PersonDTO]
    var batchSize: Int { 20 }

    static func predicate(for dto: PersonDTO) -> Predicate<Person> {
        let name = dto.name
        return #Predicate { $0.name == name }
    }

    static func map(_ dto: PersonDTO) -> Person {
        Person(name: dto.name)
    }
}
```

A delete request supplies a predicate; every matching row is deleted. A `nil` predicate deletes every row of that model type:

```swift
struct DeletePeopleRequest: DataDeleteRequest {
    var predicate: Predicate<Person>?
}
```

To delete a single row, pass its `PersistentIdentifier`. The service resolves it in its own context, so the identifier can come from a model fetched on any context (for example, the main context behind `@Query`):

```swift
struct DeletePersonRequest: DataDeleteRowRequest {
    let id: PersistentIdentifier
}
```

An upsert request updates the row matching each DTO, or inserts a new one when nothing matches. All rows are applied in a single save, so a failure leaves the store untouched:

```swift
struct UpsertPeopleRequest: DataUpsertRequest {
    let rows: [PersonDTO]

    static func predicate(for dto: PersonDTO) -> Predicate<Person> {
        let name = dto.name
        return #Predicate { $0.name == name }
    }

    static func map(_ dto: PersonDTO) -> Person {
        Person(name: dto.name)
    }

    static func update(_ model: Person, with dto: PersonDTO) {
        model.name = dto.name
    }
}
```

An update request changes the rows matching its predicate and never inserts. Use it to change a field on rows that already exist, such as a status:

```swift
struct RenamePeopleRequest: DataUpdateRequest {
    let names: [String]
    let newName: String

    var predicate: Predicate<Person>? {
        let names = names
        return #Predicate { names.contains($0.name) }
    }

    func update(_ model: Person) {
        model.name = newName
    }
}
```

### 3. Create a shared service and run requests

```swift
let container = try ModelContainer(for: Person.self)
let dataService = SwiftDataService(modelContainer: container)

try await dataService.insert(InsertPeopleRequest(rows: [
    PersonDTO(name: "Ada"),
    PersonDTO(name: "Grace"),
]))

let people = try await dataService.fetch(PeopleRequest(limit: 10))

try await dataService.upsert(UpsertPeopleRequest(rows: [PersonDTO(name: "Ada")]))

try await dataService.update(RenamePeopleRequest(names: ["Ada"], newName: "Ada Lovelace"))

try await dataService.delete(DeletePeopleRequest(predicate: #Predicate { $0.name == "Ada" }))
// `person` is a Person from any context, e.g. a row from @Query
try await dataService.delete(DeletePersonRequest(id: person.persistentModelID))
```

It is safe to share one `SwiftDataService` across the app and call it from views, view models or background tasks.

### Observing changes

`observe(_:)` turns a fetch request into a live query. It yields the current rows straight away, then fetches again whenever the request's model type may have changed, and yields only when the rows differ from the last ones it yielded. It needs the request's DTO to be `Equatable`.

```swift
for try await people in dataService.observe(PeopleRequest()) {
    self.people = people
}
```

Run the loop in a task that's cancelled when you stop caring, such as SwiftUI's `.task`; cancelling ends the observation. Changes that arrive while a fetch is in progress are combined, so a burst of writes leads to one more fetch, not one per write.

To build your own live query across several model types, `changes(to:)` yields whenever any of them may have changed:

```swift
for await _ in dataService.changes(to: [Person.self, Pet.self]) {
    await reload()
}
```

A change is noticed when:

- this service writes the model type: insert, upsert, update, delete or delete-row;
- any other `ModelContext` on the same `ModelContainer` in this process saves inserts, updates or deletions of it.

It isn't noticed when another context bulk-deletes with `ModelContext.delete(model:where:)`, which doesn't post `ModelContext.didSave`, or when another process such as a widget writes to the same store.

### Choosing the queue

Each service runs its requests serially on a `DispatchSerialQueue`, which is also where it creates and uses its `ModelContext`. By default that is a private queue of its own, so work never runs on the main thread. Pass a queue to name it, or to have several services share one:

```swift
let dataService = SwiftDataService(
    modelContainer: container,
    queue: DispatchSerialQueue(label: "com.example.app.people")
)
```

The service can be created anywhere, including during app launch on the main thread: its `ModelContext` is created on first use, on the service's queue.

### Abstracting the service

Depend on the `DataService` protocol rather than the concrete actor to swap in a mock for tests or previews:

```swift
final class PeopleViewModel {
    private let dataService: any DataService
    init(dataService: any DataService) { self.dataService = dataService }
}
```

## Notes

- `SwiftDataService` is a plain actor with a custom executor rather than a `@ModelActor`. On current SDKs, `@ModelActor`'s executor runs work on the main thread when awaited from `@MainActor` code, and a `ModelContext` created on one thread and used on another triggers SwiftData's "Unbinding from the main queue" warning. Running on a serial queue and creating the context lazily on it avoids both. `SwiftDataServiceConcurrencyTests` and `SwiftDataServiceQueueTests` guard this.
- Changes saved by the service are written to the shared `ModelContainer`. `@Query` views on the main context may not reflect them until SwiftData merges the changes.

## Running the tests

```bash
swift test
```
