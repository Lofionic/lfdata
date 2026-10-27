# Agent guide for LFData

LFData is a Swift package for running SwiftData work off the main thread through typed, `Sendable` requests. It supports iOS 18, macOS 15, tvOS 18, watchOS 11 and visionOS 2.

## Comments

- Never write code comments or documentation comments, including `//`, `///` and `/* */`. This applies to source files, tests and `Package.swift`.
- The only exception is the `// swift-tools-version` line at the top of `Package.swift`, which Swift Package Manager requires.
- Explain behaviour in the README instead, and keep names clear enough that the code doesn't need comments.

## Checks before committing

- `swift test` passes.
- The package builds for every supported platform, for example with `xcodebuild build -scheme LFData -destination 'generic/platform=watchOS'`.
