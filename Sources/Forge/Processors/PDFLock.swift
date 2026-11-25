import Foundation
import PDFKit

/// A PDF's password: put on, or taken off. It is asked for when it is needed,
/// and is never in a name, a preset or the history.
enum PDFLock {
  struct Question: Sendable {
    let fileName: String
    /// Chosen now, and so typed twice; otherwise the one it has.
    let isNew: Bool
    /// The one typed before was not it.
    let isAgain: Bool
  }

  struct Passwords: Sendable {
    var old: String?
    var new: String?
  }

  /// Puts the question. Nil where there is nobody to put it to.
  nonisolated(unsafe) static var ask: (@Sendable (Question) async -> String?)?

  /// For the file being worked on, and for as long as that takes.
  @TaskLocal static var passwords = Passwords()

  private static let tries = 3

  static func passwords(for tools: [Tool], of file: ProcessableFile) async throws -> Passwords {
    var found = Passwords()
    if tools.contains(.unlock) {
      guard let pdf = PDFDocument(url: file.url) else { throw ProcessingError.conversionFailed(reason: "Cannot open \(file.fileName)") }
      guard pdf.isEncrypted else { throw ProcessingError.leftAlone(reason: "It has no password.") }
      for attempt in 0..<tries {
        let typed = try await answer(Question(fileName: file.fileName, isNew: false, isAgain: attempt > 0))
        if opens(file.url, typed) { found.old = typed; break }
      }
      guard found.old != nil else { throw ProcessingError.conversionFailed(reason: "That is not the password of \(file.fileName).") }
    }
    if tools.contains(.lock) {
      if !tools.contains(.unlock) { try PDFTools.refuseIfSigned(file.url) }
      found.new = try await answer(Question(fileName: file.fileName, isNew: true, isAgain: false))
    }
    return found
  }

  private static func answer(_ question: Question) async throws -> String {
    guard let ask else {
      throw ProcessingError.conversionFailed(reason: "A password has to be typed, and there is nowhere here to ask for it.")
    }
    guard let typed = await ask(question), !typed.isEmpty else { throw CancellationError() }
    return typed
  }

  /// A fresh copy: a document that has been opened once stays open. One that
  /// opens by itself has a password only its owner knows, and that is the one.
  private static func opens(_ url: URL, _ password: String) -> Bool {
    guard let pdf = PDFDocument(url: url) else { return false }
    let opensByItself = !pdf.isLocked
    guard pdf.unlock(withPassword: password) else { return false }
    return !opensByItself || pdf.permissionsStatus == .owner
  }

  /// The same document with nothing asked of whoever opens it.
  static func unlock(_ url: URL, with password: String, to output: URL) throws {
    guard let pdf = PDFDocument(url: url), pdf.unlock(withPassword: password) else {
      throw ProcessingError.conversionFailed(reason: "That is not the password of \(url.lastPathComponent).")
    }
    guard anew(pdf).write(to: output), PDFDocument(url: output)?.isEncrypted == false else {
      throw ProcessingError.conversionFailed(reason: "The password of \(url.lastPathComponent) could not be taken off.")
    }
  }

  /// Its pages in another document. Saved as it is, an open one keeps its
  /// password; and one written years ago is locked the way they were then,
  /// which is no longer much of a lock.
  private static func anew(_ pdf: PDFDocument) -> PDFDocument {
    let open = PDFDocument()
    open.documentAttributes = pdf.documentAttributes
    // Where a link goes is a page of the old one, until it is told otherwise.
    var links: [(annotation: PDFAnnotation, page: Int, point: CGPoint)] = []
    let pages = (0..<pdf.pageCount).compactMap(pdf.page(at:))
    for page in pages {
      for annotation in page.annotations {
        guard let goal = annotation.destination ?? (annotation.action as? PDFActionGoTo)?.destination, let target = goal.page else { continue }
        links.append((annotation, pdf.index(for: target), goal.point))
      }
    }
    let outline = pdf.outlineRoot
    var marks: [(mark: PDFOutline, page: Int, point: CGPoint)] = []
    func walk(_ mark: PDFOutline) {
      if let goal = mark.destination, let target = goal.page { marks.append((mark, pdf.index(for: target), goal.point)) }
      for index in 0..<mark.numberOfChildren { mark.child(at: index).map(walk) }
    }
    outline.map(walk)
    for (index, page) in pages.enumerated() { open.insert(page, at: index) }
    for link in links {
      guard let page = open.page(at: link.page) else { continue }
      link.annotation.action = PDFActionGoTo(destination: PDFDestination(page: page, at: link.point))
    }
    for one in marks { if let page = open.page(at: one.page) { one.mark.destination = PDFDestination(page: page, at: one.point) } }
    if let outline { open.outlineRoot = outline }
    return open
  }

  /// In place: what is written is already the copy.
  static func lock(_ url: URL, with password: String) throws {
    guard let pdf = PDFDocument(url: url) else {
      throw ProcessingError.conversionFailed(reason: "Only a PDF can have a password put on it.")
    }
    let locked = url.deletingLastPathComponent().appendingPathComponent(".forge-lock-\(UUID().uuidString).pdf")
    defer { try? FileManager.default.removeItem(at: locked) }
    guard anew(pdf).write(to: locked, withOptions: [.userPasswordOption: password, .ownerPasswordOption: password]),
          PDFDocument(url: locked)?.isLocked == true else {
      throw ProcessingError.conversionFailed(reason: "The password could not be put on.")
    }
    _ = try FileManager.default.replaceItemAt(url, withItemAt: locked)
  }
}
