# Contributing to Forge

Thank you for your interest in contributing to Forge! This document provides guidelines and information for contributors.

## 🎯 Getting Started

1. **Fork the repository** and clone your fork locally.
2. **Create a branch** for your feature: `git checkout -b feature/my-feature`
3. **Make your changes** following the coding style below.
4. **Run tests** to ensure nothing broke: `swift test`
5. **Commit** with clear, descriptive messages.
6. **Push** to your fork: `git push origin feature/my-feature`
7. **Open a Pull Request** against `main` branch.

## 🏗️ Development Setup

### Prerequisites
- macOS 13.0 Ventura or later
- Xcode 15+ or Swift 5.9 toolchain
- Command Line Tools: `xcode-select --install`

> **The code has to compile on Swift 5.9**, which is what `Package.swift`
> declares and what CI builds with. A recent Xcode will happily accept things
> 5.9 rejects, so a green build on your machine is not the last word - watch
> the CI run. The two that have caught us out: trailing commas in argument
> lists (Swift 6.1+), and using a `self` captured by an outer closure inside a
> nested `Task` without re-capturing it.

### Build & Test

```bash
# Build the project
swift build

# Build with release configuration
swift build -c release

# Run tests
swift test

# Build the app bundle (plain `swift build` gives a windowless executable)
./Scripts/build_app.sh
```

### Xcode
There is no `.xcodeproj`: Forge is a SwiftPM package, so open the folder itself.
```bash
xed .
```

## 📖 Code Style

- **Swift API Design Guidelines**: Follow Apple's official guidelines.
- **Naming**: Use clear, descriptive names. Types are `UpperCamelCase`, methods/variables are `lowerCamelCase`.
- **Concurrency**: Use `async/await` and actors. Avoid `@MainActor` unless needed.
- **Error Handling**: Throw descriptive errors. Use `ProcessingError` for processor errors.
- **Protocols**: Prefer protocols over concrete types for dependencies.
- **Memory**: Stream rather than loading whole files. `ProcessingCoordinator` bounds how many conversions run at once.

### Example

```swift
func processFile(_ file: ProcessableFile) async throws -> ProcessingResult {
  // Validate
  try validate(file)

  // Process with streaming
  let result = try await processor.process(file)

  // Log or notify
  await logResult(result)

  return result
}
```

## 🧪 Testing

- **Where**: `Tests/ForgeTests/`, mirroring the source structure.
- **Fixtures**: build them at runtime with `Fixture.image/pdf/audio/video`. No
  binary files in the repository, and nothing that depends on tools a CI
  machine may not have.
- **Storage**: take the store from `BaseTestCase`, which is rooted in a scratch
  directory. Tests must never touch the real Application Support folder.
- **One test per defect**: a fix without a test that fails before it is not
  finished. Most of this suite exists because the old one only asserted that
  processors *claimed* to support a format.

### Running Specific Tests

```bash
swift test --filter ConversionTests
swift test --filter OutputHandlingTests/test_moveTo_removesTheOriginal
```

## 🎨 UI Guidelines

- **SwiftUI**: Use SwiftUI for all new views.
- **Accessibility**: Add labels, hints, and VoiceOver support.
- **Dark Mode**: Use system colors (`.background`, `.foreground`) not hardcoded.
- **Layout**: Use `VStack`, `HStack`, `Form`, and `ScrollView`. Avoid fixed sizes when possible.
- **User Feedback**: Show progress for long operations, errors clearly.

## 📦 Dependencies

We aim for **zero external dependencies** for the core. All code uses Apple frameworks:
- Foundation
- SwiftUI
- Core Image / ImageIO
- AVFoundation
- PDFKit
- AppKit (document readers, panels)

There are no external tools. If a conversion cannot be done with an Apple
framework, Forge says so rather than shelling out.

## 🔧 Adding New Processors

To add a new processor for a file type:

1. Create a new file in `Sources/Forge/Processors/` (e.g., `PDFProcessor.swift`).
2. Implement `FileProcessor`:
   ```swift
   final class SomethingProcessor: FileProcessor, @unchecked Sendable {
     let name = "Something Processor"

     func canProcess(_ file: ProcessableFile) -> Bool { ... }

     func process(
       _ input: URL,
       to output: URL,
       with operations: [Operation],
       progress: @escaping @Sendable (Double) -> Void
     ) async throws -> ProcessingResult { ... }
   }
   ```
3. Add it to `processors` in `ProcessingCoordinator`. Order matters: the first
   processor that claims a file gets it.
4. Ask `FormatCatalog` what the machine can read and write. Never write a list
   of UTI strings by hand - that is how WAV, FLAC and ALAC ended up silently
   unsupported.
5. Write to the `output` URL you are given and nowhere else. The coordinator
   hands you a scratch file and moves it into place.
6. Add tests in `Tests/ForgeTests/Processors/`.
7. Update the README format section.

## 🔍 Pull Request Guidelines

### Before Submitting
- [ ] All tests pass (`swift test`).
- [ ] No lint warnings (we don't have linter yet - add SwiftLint if desired).
- [ ] Code follows style guidelines.
- [ ] Added tests for new functionality.
- [ ] Updated documentation (README, code comments) if needed.
- [ ] Commits are clean and descriptive (squash redundant commits).

### PR Template (use this)
```markdown
## Description
What does this PR change?

## Motivation
Why is this needed?

## Changes
- [ ] List of changes

## Testing
How did you test this? Manual? Unit tests?

## Screenshots (if UI)
Attach screenshots.

## Checklist
- [ ] Tests added/updated
- [ ] README updated
- [ ] Code follows style guide
```

## 🐛 Bug Reports

Use GitHub Issues. Include:
- **Steps to reproduce** (clear, numbered)
- **Expected behavior**
- **Actual behavior** (include logs, screenshots)
- **Environment**: macOS version, Forge version/branch
- **Sample file** (if applicable, attach or link)

## 💡 Feature Requests

Also use GitHub Issues. Describe:
- **Problem** you're trying to solve
- **Proposed solution**
- **Alternatives considered**
- **Impact** (how many users would benefit?)

## 📝 Code of Conduct

We follow the [Contributor Covenant](https://www.contributor-covenant.org/). Be respectful, inclusive, and constructive.

## 🏆 Recognition

Contributors will be listed in:
- README.md (for significant contributions)
- GitHub's contributors graph
- Release notes

## ❓ Questions?

- **General discussion**: Use GitHub Discussions
- **Quick question**: Check existing docs first
- **Complex design**: Open an Issue for RFC (Request for Comments)

---

Thank you for contributing to Forge! 🚀
