import AppKit
import Foundation
import PDFKit
import WebKit

/// Pages drawn by the system's own web engine, off the screen and off the
/// network.
@MainActor
final class Drawn: NSObject, WKNavigationDelegate {
  private static let patience = 60.0
  nonisolated private static let mostPages = 2000
  private let view: WKWebView
  private var waiting: CheckedContinuation<Void, Error>?

  private init(width: CGFloat, height: CGFloat) async throws {
    let setup = WKWebViewConfiguration()
    setup.websiteDataStore = .nonPersistent()
    setup.defaultWebpagePreferences.allowsContentJavaScript = false
    let block = "[" + ["^https?:", "^wss?:", "^ftp:"].map { #"{"trigger":{"url-filter":"\#($0)"},"action":{"type":"block"}}"# }.joined(separator: ",") + "]"
    // Nothing is drawn if nothing can be kept from being fetched.
    guard let rules = try await WKContentRuleListStore.default()?.compileContentRuleList(forIdentifier: "forge-nothing-from-outside", encodedContentRuleList: block) else { throw Self.failed }
    setup.userContentController.add(rules)
    view = WKWebView(frame: CGRect(x: 0, y: 0, width: width, height: height), configuration: setup)
    super.init()
    view.navigationDelegate = self
  }

  static let failed = ProcessingError.conversionFailed(reason: "macOS could not draw it.")

  private func load(_ page: URL, within folder: URL) async throws {
    let limit = Task { [weak self] in
      try await Task.sleep(nanoseconds: UInt64(Self.patience * 1e9))
      self?.finish(Self.failed)
    }
    defer { limit.cancel() }
    try await withCheckedThrowingContinuation { waiting in
      self.waiting = waiting
      view.loadFileURL(page, allowingReadAccessTo: folder)
    }
  }

  private func finish(_ error: Error?) {
    if let error { waiting?.resume(throwing: error) } else { waiting?.resume() }
    waiting = nil
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(nil) }
  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(error) }
  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(error) }
  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { finish(Self.failed) }

  /// Where each of what the path finds is, in the order they come.
  private func boxes(_ xpath: String) async throws -> [CGRect] {
    let path = String(decoding: try JSONSerialization.data(withJSONObject: xpath, options: .fragmentsAllowed), as: UTF8.self)
    let found = try await view.evaluateJavaScript("""
      (() => { const all = document.evaluate(\(path), document, null, XPathResult.ORDERED_NODE_SNAPSHOT_TYPE, null); const out = [];
      for (let i = 0; i < Math.min(all.snapshotLength, 50000); i++) { const b = all.snapshotItem(i).getBoundingClientRect(); out.push([b.left + scrollX, b.top + scrollY, b.width, b.height]); } return out; })()
      """) as? [[Double]] ?? []
    return found.filter { $0.count == 4 }.map { CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) }
  }

  private func pdf(of box: CGRect) async throws -> PDFDocument {
    let setup = WKPDFConfiguration()
    setup.rect = box
    let data = try await view.pdf(configuration: setup)
    guard let pdf = PDFDocument(data: data), pdf.pageCount > 0 else { throw Self.failed }
    return pdf
  }

  // MARK: - What is drawn

  /// A drawing on a page the size of itself, with its lines still lines.
  static func vector(_ svg: URL, size: CGSize, to output: URL) async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("forge-drawn-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let page = folder.appendingPathComponent("page.html")
    try FileManager.default.copyItem(at: svg, to: folder.appendingPathComponent("drawing.svg"))
    try Data("<!doctype html><style>html,body{margin:0;background:none}img{display:block;width:\(size.width)px;height:\(size.height)px}</style><img src=\"drawing.svg\">".utf8).write(to: page)
    let drawn = try await Drawn(width: size.width, height: size.height)
    try await drawn.load(page, within: folder)
    guard try await drawn.pdf(of: CGRect(origin: .zero, size: size)).write(to: output) else { throw failed }
  }

  /// An Office file the way the Finder shows one, as pages.
  static func office(_ input: URL, to output: URL) async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("forge-office-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    try await Task.detached { try ExternalTools.run(URL(fileURLWithPath: "/usr/bin/qlmanage"), ["-p", "-o", folder.path, input.path]) }.value
    let inside = folder.appendingPathComponent(input.lastPathComponent + ".qlpreview"), page = inside.appendingPathComponent("Preview.html")
    guard FileManager.default.fileExists(atPath: page.path) else {
      throw ProcessingError.conversionFailed(reason: "macOS cannot show \(input.lastPathComponent): it may be damaged, or want a password.")
    }
    let facts = NSDictionary(contentsOf: inside.appendingPathComponent("PreviewProperties.plist"))
    let width = (facts?["Width"] as? Double).flatMap { $0 > 100 ? $0 : nil } ?? 760
    let drawn = try await Drawn(width: width, height: 1000)
    try await drawn.load(page, within: inside)
    let made = PDFDocument()
    let slides = try await drawn.boxes("//div[contains(concat(' ', @class, ' '), ' slide ')]").filter { $0.width > 20 && $0.height > 20 }
    if !slides.isEmpty {
      for slide in slides.prefix(mostPages) {
        try Task.checkCancellation()
        if let one = try await drawn.pdf(of: slide).page(at: 0) { made.insert(one, at: made.pageCount) }
      }
    } else {
      for box in pages(of: try await drawn.boxes("/html"), breaks: try await drawn.boxes("//tr | //p | //li | //h1 | //h2 | //h3 | //img"), width: width) {
        try Task.checkCancellation()
        if let one = try await drawn.pdf(of: box).page(at: 0) { made.insert(one, at: made.pageCount) }
      }
    }
    guard made.pageCount > 0, made.write(to: output) else { throw failed }
  }

  /// A long page cut where nothing is cut in two: between a line and the next.
  nonisolated static func pages(of whole: [CGRect], breaks: [CGRect], width: CGFloat) -> [CGRect] {
    let right = max(width, breaks.map(\.maxX).max() ?? width), bottom = max(whole.first?.maxY ?? 0, breaks.map(\.maxY).max() ?? 0)
    let tallest = (right * 11 / 8.5).rounded()
    let ends = Set(breaks.filter { $0.height > 0 && $0.height < tallest / 2 }.map { $0.maxY.rounded(.up) }).sorted()
    var out: [CGRect] = [], top: CGFloat = 0
    while top < bottom - 1, out.count < mostPages {
      let limit = top + tallest
      let end = limit >= bottom ? bottom : ends.last { $0 <= limit && $0 > top + tallest / 2 } ?? limit
      out.append(CGRect(x: 0, y: top, width: right, height: end - top))
      top = end
    }
    return out
  }
}
