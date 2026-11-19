import SwiftUI
import AppKit

/// A number written into a block's sentence, as Shortcuts writes its
/// parameters. One click selects it, so typing replaces it; ↑ and ↓ step it
/// (⇧ for ten); a sideways drag scrubs it; Tab moves on; Esc puts back what was
/// there when it got the focus. Empty means automatic.
struct NumberToken: View {
  @Binding var value: Int?
  var placeholder = "auto"
  var range: ClosedRange<Int> = 1...20_000
  /// Where a scrub or a step starts when the value is empty.
  var startingFrom = 1000
  @State private var editing = false

  var body: some View {
    ScrubField(value: $value, editing: $editing, placeholder: placeholder, range: range, startingFrom: startingFrom)
      .fixedSize()
      .padding(.horizontal, 5).padding(.vertical, 1)
      .background(
        RoundedRectangle(cornerRadius: 5)
          .fill(Color.accentColor.opacity(editing ? 0.06 : 0.1))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 5)
          .strokeBorder(Color.accentColor, lineWidth: editing ? 1.5 : 0)
      )
      .animation(.easeOut(duration: 0.1), value: editing)
  }

  /// The next value after a step or a scrub, kept inside the range.
  static func stepped(_ value: Int?, by delta: Int, range: ClosedRange<Int>, startingFrom: Int) -> Int {
    min(max((value ?? startingFrom) + delta, range.lowerBound), range.upperBound)
  }

  /// What typing leaves behind: digits only, at most five of them.
  static func digits(of text: String) -> String {
    String(text.filter(\.isNumber).prefix(5))
  }
}

private struct ScrubField: NSViewRepresentable {
  @Binding var value: Int?
  @Binding var editing: Bool
  let placeholder: String
  let range: ClosedRange<Int>
  let startingFrom: Int

  func makeNSView(context: Context) -> TokenTextField {
    let field = TokenTextField()
    field.isBordered = false
    field.drawsBackground = false
    field.focusRingType = .none
    field.alignment = .center
    field.font = .systemFont(ofSize: NSFont.systemFontSize)
    field.textColor = .controlAccentColor
    field.placeholderAttributedString = NSAttributedString(
      string: placeholder,
      attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.systemFont(ofSize: NSFont.systemFontSize)]
    )
    field.stringValue = value.map(String.init) ?? ""
    field.delegate = context.coordinator
    field.onScrub = { [weak coordinator = context.coordinator] in coordinator?.scrub(field, by: $0) }
    field.onFocus = { [weak coordinator = context.coordinator] in coordinator?.focused() }
    return field
  }

  func updateNSView(_ field: TokenTextField, context: Context) {
    context.coordinator.parent = self
    let shown = value.map(String.init) ?? ""
    if field.currentEditor() == nil, field.stringValue != shown {
      field.stringValue = shown
      field.invalidateIntrinsicContentSize()
    }
  }

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  final class Coordinator: NSObject, NSTextFieldDelegate {
    var parent: ScrubField
    private var before: Int?
    private var scrubStart: Int?

    init(_ parent: ScrubField) { self.parent = parent }

    /// Esc goes back to what was there at focus, not at the first keystroke:
    /// arrows change the value without ever "beginning" an edit.
    func focused() {
      before = parent.value
      DispatchQueue.main.async { self.parent.editing = true }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
      parent.editing = false
    }

    func controlTextDidChange(_ obj: Notification) {
      guard let field = obj.object as? NSTextField else { return }
      let digits = NumberToken.digits(of: field.stringValue)
      if digits != field.stringValue { field.stringValue = digits }
      parent.value = Int(digits)
      field.invalidateIntrinsicContentSize()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
      guard let field = control as? NSTextField else { return false }
      // The key event's own flags: the keyboard may already have moved on.
      let step = NSApp.currentEvent?.modifierFlags.contains(.shift) == true ? 10 : 1
      switch selector {
      // With Shift held macOS sends "extend the selection", not "move".
      case #selector(NSResponder.moveUp(_:)), #selector(NSResponder.moveUpAndModifySelection(_:)):
        set(field, NumberToken.stepped(parent.value, by: step, range: parent.range, startingFrom: parent.startingFrom))
        field.currentEditor()?.selectAll(nil)
        return true
      case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveDownAndModifySelection(_:)):
        set(field, NumberToken.stepped(parent.value, by: -step, range: parent.range, startingFrom: parent.startingFrom))
        field.currentEditor()?.selectAll(nil)
        return true
      case #selector(NSResponder.cancelOperation(_:)):
        set(field, before)
        field.window?.makeFirstResponder(nil)
        return true
      case #selector(NSResponder.insertNewline(_:)):
        field.window?.makeFirstResponder(nil)
        return true
      default:
        return false
      }
    }

    /// A drag: points moved since the press, nil when it ends.
    func scrub(_ field: NSTextField, by delta: CGFloat?) {
      guard let delta else { scrubStart = nil; return }
      if scrubStart == nil { scrubStart = parent.value ?? parent.startingFrom }
      // Two points of drag per unit: fine enough to land on a value.
      set(field, NumberToken.stepped(scrubStart, by: Int(delta / 2), range: parent.range, startingFrom: parent.startingFrom))
    }

    private func set(_ field: NSTextField, _ value: Int?) {
      field.stringValue = value.map(String.init) ?? ""
      parent.value = value
      field.invalidateIntrinsicContentSize()
    }
  }
}

/// A text field that sizes to what it holds, selects everything on a click,
/// and turns a sideways drag into a scrub rather than a text selection.
private final class TokenTextField: NSTextField {
  var onScrub: ((CGFloat?) -> Void)?
  var onFocus: (() -> Void)?
  /// The click that gave this field the focus. NSWindow hands a clicked field
  /// the focus before its mouseDown runs, so "already editing" has to mean
  /// editing since before this click.
  private var focusedBy: TimeInterval?
  private let dragThreshold: CGFloat = 3

  override var intrinsicContentSize: NSSize {
    let shown = stringValue.isEmpty ? (placeholderAttributedString?.string ?? "") : stringValue
    let width = (shown as NSString).size(withAttributes: [.font: font ?? .systemFont(ofSize: NSFont.systemFontSize)]).width
    return NSSize(width: max(18, ceil(width) + 6), height: super.intrinsicContentSize.height)
  }

  override func resetCursorRects() {
    // At rest the cursor says "drag me"; while typing, the usual I-beam.
    if currentEditor() == nil { addCursorRect(bounds, cursor: .resizeLeftRight) } else { super.resetCursorRects() }
  }

  override func mouseDown(with event: NSEvent) {
    let editingBefore = currentEditor() != nil && focusedBy != event.timestamp
    guard !editingBefore, let window else { super.mouseDown(with: event); return }
    let start = event.locationInWindow
    var dragged = false
    while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
      if next.type == .leftMouseUp { break }
      let dx = next.locationInWindow.x - start.x
      if abs(dx) > dragThreshold { dragged = true }
      if dragged { onScrub?(dx) }
    }
    if dragged {
      onScrub?(nil)
      // A scrub is not an edit: the value is set and nothing stays focused.
      window.makeFirstResponder(nil)
      return
    }
    window.makeFirstResponder(self)
    currentEditor()?.selectAll(nil)
  }

  override func becomeFirstResponder() -> Bool {
    let became = super.becomeFirstResponder()
    if became {
      focusedBy = NSApp.currentEvent?.type == .leftMouseDown ? NSApp.currentEvent?.timestamp : nil
      onFocus?()
      DispatchQueue.main.async { self.currentEditor()?.selectAll(nil); self.window?.invalidateCursorRects(for: self) }
    }
    return became
  }

  override func textDidEndEditing(_ notification: Notification) {
    super.textDidEndEditing(notification)
    window?.invalidateCursorRects(for: self)
  }
}
