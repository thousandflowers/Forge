# Forge Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring the look and the micro-interactions approved in the look-only shell (`scratchpad/forgemock`, study in `~/Desktop/forge-studio-comandi-rapidi/studio.md`) into the real Forge, screen by screen, without changing what the engine does.

**Architecture:** Shared design tokens and small reusable views live in `DesignSystem.swift`. Each screen keeps its own file and its own logic; only its layout changes. The preset editor is the large piece and comes after the simple screens. The Preview strip needs one new engine entry point (run a chain prefix on a sample file into scratch), which gets its own phase and its own tests.

**Tech Stack:** Swift 5.9 tools / Swift 6.4 toolchain, SwiftUI on macOS 13+, XCTest. Build `swift build`, test `swift test`, runnable app `Scripts/build_app.sh` (a bare `swift build` binary draws no window).

**Rules that hold for every phase**
- Branch `feat/redesign`, one commit per task, never push or merge without the user's yes.
- Look from Shortcuts (sizes, shapes, sentence blocks, sidebar-style library), structure from Forge (its screens, its "Files that come in", its colours per group, Cancel/Save). See memory `feedback-borrow-pieces-not-identity`.
- Logic changes get a failing test first. Pure layout changes are verified by building the app and looking at it (screenshot), never claimed from code alone.
- `swift test` green before each commit (400 tests at the start).

---

## Phases

| Phase | What | Engine change |
|---|---|---|
| 1 | Design tokens; Gallery cards all the same, one identical + button; Capabilities: no status pill beside an Install/Download button; sidebar counts | none |
| 2 | Folders as sentence rows with an on/off switch; History rows with a ⋯ menu; Settings as grouped rows; Presets cards restyled with a context menu; Convert and Preset menus in the menu bar | none |
| 3 | Preset editor: icon + name in the bar, blocks as one-line sentences (43 pt), library as a Shortcuts-style sidebar, empty canvas for a new preset, number micro-interactions (click selects, ↑↓, drag, Tab, Esc) | none |
| 4 | Micro menus: Custom size (frame dragged over the picture, aspect ratios, numbers, fit), Quality (slider + estimated weight) in the editor and in the Convert sheet | none |
| 5 | Preview: run each prefix of the chain on a sample file into scratch, measure it; strip of small thumbnails at the foot of the editor, hover to peek, click for the big before/after | new: `PreviewRunner` |

Phases 2–5 are planned in detail when Phase 1 is done and seen by the user.

---

## Phase 1

### Task 1.1: Design tokens

**Files:**
- Modify: `Sources/Forge/DesignSystem.swift` (append)

- [ ] **Step 1: Append the tokens and the card style**

```swift
/// Sizes measured from Shortcuts on macOS 26, used wherever Forge draws a
/// block, a row or a card. Colours stay Forge's.
enum Metrics {
  static let blockHeight: CGFloat = 43
  static let blockColumn: CGFloat = 600
  static let blockGap: CGFloat = 12
  static let iconSize: CGFloat = 22
  static let bodyText: CGFloat = 13
  static let blockRadius: CGFloat = 20
  static let cardRadius: CGFloat = 16
}

extension View {
  /// Forge's cards in Shortcuts' shape: flat, generously rounded.
  func forgeCard(radius: CGFloat = Metrics.cardRadius) -> some View {
    background(
      RoundedRectangle(cornerRadius: radius, style: .continuous)
        .fill(Color(nsColor: .controlBackgroundColor))
    )
  }
}
```

- [ ] **Step 2: Build** — `swift build` → `Build complete!`
- [ ] **Step 3: Commit** — `git commit -am "feat: design tokens measured from Shortcuts"`

### Task 1.2: Gallery cards all the same, one identical + button

**Files:**
- Modify: `Sources/Forge/Views/GalleryView.swift` (`card(_:)`, ~line 209)

- [ ] **Step 1: Replace the Add/Added text button with one + button, the same on every card**

```swift
        Button {
          model.install(entry.preset)
        } label: {
          Image(systemName: "plus.circle.fill").font(.title3)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(Color.accentColor)
        .disabled(isInstalled(entry))
        .help(isInstalled(entry) ? "Already in your presets" : "Add “\(entry.preset.name)” to your presets")
        .accessibilityLabel(Text(isInstalled(entry) ? "\(entry.preset.name), already added" : "Add \(entry.preset.name)"))
```

- [ ] **Step 2: Same size for every card** — the summary always takes two lines, the card has a fixed height, the shape is `forgeCard()`:

```swift
      Text(entry.summary)
        .font(.callout)
        .foregroundStyle(.secondary)
        .lineLimit(2, reservesSpace: true)
        .frame(maxWidth: .infinity, alignment: .leading)
```
and replace the card's `.frame(minHeight: 172, …)`, `.background`, `.overlay` with:
```swift
    .padding(14)
    .frame(height: 196, alignment: .top)
    .forgeCard()
```
Chip rows: show the tag row on every card (an empty row of the same height when a preset has no tags), so the two rows line up across cards.

- [ ] **Step 3: Build the app and look** — `bash Scripts/build_app.sh`, open Gallery, screenshot: every card the same height, every + the same.
- [ ] **Step 4: `swift test`** — 400 passed.
- [ ] **Step 5: Commit** — `git commit -am "feat: gallery cards are all the same, with one + button"`

### Task 1.3: Capabilities — no status pill beside an action button

**Files:**
- Modify: `Sources/Forge/Views/CapabilitiesView.swift` (card header ~line 239, `badge` ~line 409)

- [ ] **Step 1: Add `offersAction`** to the card — true exactly when the card shows a Download or Install button (the same conditions as the button branch at ~line 368–381):

```swift
  /// A card with a Download or Install button already says what can be done;
  /// a pill saying "Add" or "Needs a tool" beside it repeats it.
  private var offersAction: Bool {
    guard case .needsPack(let pack) = capability.status, let tool = pack.tool, !tool.isInstalled else {
      return false
    }
    return installer.offered[tool.binary] != nil || ExternalTools.hasHomebrew
  }
```

- [ ] **Step 2: Show the badge only when `!offersAction`** in the card header.
- [ ] **Step 3: Build the app and look** — a card with Install has no pill; Available cards keep theirs.
- [ ] **Step 4: `swift test`** — 400 passed.
- [ ] **Step 5: Commit** — `git commit -am "fix: no status pill beside an Install or Download button"`

### Task 1.4: Sidebar counts

**Files:**
- Modify: `Sources/Forge/DesignSystem.swift` (`AppSection`)
- Modify: `Sources/Forge/Views/ContentView.swift` (sidebar row)
- Test: `Tests/ForgeTests/Models/test_Models.swift`

- [ ] **Step 1: Failing test**

```swift
  /// The sidebar counts what is there, as Shortcuts does: presets, folders.
  func test_sidebarCountsPresetsAndFolders() {
    XCTAssertEqual(AppSection.presets.count(presets: 6, folders: 2), 6)
    XCTAssertEqual(AppSection.folders.count(presets: 6, folders: 2), 2)
    XCTAssertEqual(AppSection.process.count(presets: 6, folders: 2), 0)
  }
```

- [ ] **Step 2: Run, expect FAIL** — `swift test --filter test_sidebarCountsPresetsAndFolders` → "has no member 'count'".
- [ ] **Step 3: Implement**

```swift
  /// What the sidebar shows beside the row; 0 shows nothing. History is not
  /// counted: a number in the hundreds says nothing and only grows.
  func count(presets: Int, folders: Int) -> Int {
    switch self {
    case .presets: return presets
    case .folders: return folders
    default: return 0
    }
  }
```
and in `ContentView` the row becomes
```swift
        Label(item.title, systemImage: item.icon)
          .badge(item.count(presets: model.presets.count, folders: model.folders.count))
          .tag(item)
```

- [ ] **Step 4: Run, expect PASS**; then `swift test` — 401 passed.
- [ ] **Step 5: Build the app and look** — counts beside Presets and Folders.
- [ ] **Step 6: Commit** — `git commit -am "feat: the sidebar counts presets and folders"`
