import AppKit

/// "Convert with Forge" and "Cut with Forge", in the menu a right click on a
/// file brings up, under Services. A key can be given to either in System
/// Settings › Keyboard.
@MainActor
final class FinderService: NSObject {
  var convert: ([URL]) -> Void = { _ in }
  var cut: ([URL]) -> Void = { _ in }

  static func files(on pasteboard: NSPasteboard) -> [URL] {
    pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
  }

  @objc func convertFiles(_ pasteboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
    let files = Self.files(on: pasteboard)
    guard !files.isEmpty else { error.pointee = "There are no files to convert."; return }
    convert(files)
  }

  @objc func cutFile(_ pasteboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
    let files = Self.files(on: pasteboard)
    guard !files.isEmpty else { error.pointee = "There are no files to cut."; return }
    cut(files)
  }
}
