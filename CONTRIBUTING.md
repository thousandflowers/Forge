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
- macOS 12.0+ (required for some APIs)
- Xcode 15+ or Swift 5.9 toolchain
- Command Line Tools: `xcode-select --install`

### Build & Test

```bash
# Build the project
swift build

# Build with release configuration
swift build -c release

# Run tests
swift test

# Generate sample test files
bash Scripts/generate_samples.sh
```

### Xcode Project
If you prefer Xcode:
```bash
open Forge.xcodeproj
```

## 📖 Code Style

- **Swift API Design Guidelines**: Follow Apple's official guidelines.
- **Naming**: Use clear, descriptive names. Types are `UpperCamelCase`, methods/variables are `lowerCamelCase`.
- **Concurrency**: Use `async/await` and actors. Avoid `@MainActor` unless needed.
- **Error Handling**: Throw descriptive errors. Use `ProcessingError` for processor errors.
- **Protocols**: Prefer protocols over concrete types for dependencies.
- **Memory**: Use streaming (avoid loading entire files). Use `AutomationQueue` for concurrency control.

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

- **Unit Tests**: Place in `Tests/ForgeTests/` mirroring source structure.
- **Test Coverage**: Aim for >80% coverage on critical code (processors, models).
- **Integration Tests**: Add to `IntegrationTests.swift` for end-to-end flows.
- **Performance Tests**: Use `measure` for time-sensitive code.

### Running Specific Tests

```bash
swift test --filter ImageProcessorTests
swift test --filter VideoProcessorTests/processMP4Conversion
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
- PDFKit (optional, may phase out for simpler approach)

External CLI tools (LibreOffice, ImageMagick, FFmpeg) are **optional** and invoked as separate processes.

## 🔧 Adding New Processors

To add a new processor for a file type:

1. Create a new file in `Sources/Forge/Processors/` (e.g., `PDFProcessor.swift`).
2. Implement `FileProcessor` protocol:
   ```swift
   final class PDFProcessor: FileProcessor {
     let name = "PDF Processor"
     let isNative = true
     let supportedTypes: [UTType] = [.pdf]

     func canProcess(_ file: ProcessableFile) -> Bool { ... }
     func supportedOutputTypes(for input: UTType) -> [UTType] { ... }
     func process(...) async throws -> ProcessingResult { ... }
   }
   ```
3. Register it in `ProcessorRegistry.init()` (Phase 1 only, Phase 3 will use discovery).
4. Add unit tests in `Tests/ForgeTests/Processors/`.
5. Update README format support table.

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
