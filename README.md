# LFData

A small Swift package for doing SwiftData work off the main thread through typed, `Sendable` requests.

`SwiftDataService` is an actor that owns its own `ModelContext`. You describe what to fetch or insert with request types; the service runs them serially on its own executor and hands back plain `Sendable` values (DTOs) instead of `@Model` objects, so results can cross actor boundaries safely.

- **Never blocks the main thread** — requests run on the actor even when awaited from `@MainActor` code.
- **Serialized** — one request runs at a time against a single context.
- **Rolls back on failure** — if a save throws, pending inserts are discarded.

## Requirements

- iOS 17+ / macOS 14+
- Swift 6.4 (Xcode 27)

## Installation

Add the package in Xcode via **File › Add Package Dependencies…**, or in `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/<owner>/LFData.git", branch: "main"),
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

A fetch request supplies a predicate, sort order and limit, plus a mapping from model to DTO:

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

An insert request supplies the rows to insert and a mapping from DTO to model:

```swift
struct InsertPeopleRequest: DataInsertRequest {
    let rows: [PersonDTO]
    var batchSize: Int { 20 }

    static func map(_ dto: PersonDTO) -> Person {
        Person(name: dto.name)
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
```

It is safe to share one `SwiftDataService` across the app and call it from views, view models or background tasks.

### Abstracting the service

Depend on the `DataService` protocol rather than the concrete actor to swap in a mock for tests or previews:

```swift
final class PeopleViewModel {
    private let dataService: any DataService
    init(dataService: any DataService) { self.dataService = dataService }
}
```

## Notes

- `SwiftDataService` is a plain actor rather than a `@ModelActor`. On current SDKs, `@ModelActor`'s executor runs work on the main thread when awaited from `@MainActor` code; a default actor executor does not. `SwiftDataServiceConcurrencyTests` guards this.
- Changes saved by the service are written to the shared `ModelContainer`. `@Query` views on the main context may not reflect them until SwiftData merges the changes.

## Running the tests

```bash
swift test
```
