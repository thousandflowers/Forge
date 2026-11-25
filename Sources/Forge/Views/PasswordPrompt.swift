import AppKit

/// Where a PDF's password is typed. One question at a time, and what is typed
/// goes to whoever asked and nowhere else.
@MainActor
enum PasswordPrompt {
  private static var last: Task<String?, Never>?

  static func ask(_ question: PDFLock.Question) async -> String? {
    let before = last
    let mine = Task { @MainActor () -> String? in
      _ = await before?.value
      return await show(question)
    }
    last = mine
    return await mine.value
  }

  private static func show(_ question: PDFLock.Question) async -> String? {
    let alert = NSAlert()
    alert.messageText = question.isNew ? "Add a password to “\(question.fileName)”" : "“\(question.fileName)” is locked"
    alert.informativeText = text(for: question)
    alert.addButton(withTitle: question.isNew ? "Add Password" : "Unlock")
    alert.addButton(withTitle: "Cancel")

    let field = NSSecureTextField(frame: NSRect(x: 0, y: 30, width: 260, height: 22))
    field.placeholderString = "Password"
    let again = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 22))
    again.placeholderString = "Again"
    let box = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: question.isNew ? 52 : 22))
    if question.isNew { box.addSubview(again) } else { field.frame.origin.y = 0 }
    box.addSubview(field)
    field.nextKeyView = again
    alert.accessoryView = box

    // Not modal: whatever else is being converted goes on meanwhile.
    return await withCheckedContinuation { continuation in
      let ok = alert.buttons[0], cancel = alert.buttons[1]
      ok.isEnabled = false
      let session = Session(isRight: {
        !field.stringValue.isEmpty && (!question.isNew || field.stringValue == again.stringValue)
      }, changed: { ok.isEnabled = $0 }, ended: { said in
        alert.window.close()
        continuation.resume(returning: said ? field.stringValue : nil)
        open = nil
      })
      open = session
      field.delegate = session
      again.delegate = session
      ok.target = session
      ok.action = #selector(Session.accept)
      cancel.target = session
      cancel.action = #selector(Session.refuse)
      cancel.keyEquivalent = "\u{1b}"
      alert.layout()
      alert.window.initialFirstResponder = field
      alert.window.level = .floating
      alert.window.center()
      NSApp.activate(ignoringOtherApps: true)
      alert.window.makeKeyAndOrderFront(nil)
    }
  }

  private static var open: Session?

  private static func text(for question: PDFLock.Question) -> String {
    if question.isNew { return "Forge does not keep it. Without it, nobody opens the PDF." }
    return question.isAgain ? "That was not it. Type its password again." : "Type its password to take it off."
  }

  @MainActor
  private final class Session: NSObject, NSTextFieldDelegate {
    private let isRight: () -> Bool
    private let changed: (Bool) -> Void
    private var ended: ((Bool) -> Void)?

    init(isRight: @escaping () -> Bool, changed: @escaping (Bool) -> Void, ended: @escaping (Bool) -> Void) {
      self.isRight = isRight
      self.changed = changed
      self.ended = ended
    }

    func controlTextDidChange(_ note: Notification) { changed(isRight()) }
    @objc func accept() { if isRight() { end(true) } }
    @objc func refuse() { end(false) }

    private func end(_ said: Bool) {
      let ended = ended
      self.ended = nil
      ended?(said)
    }
  }
}
