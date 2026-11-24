import PDFKit
import UniformTypeIdentifiers
import XCTest
@testable import Forge

/// A file given another extension becomes that kind of file.
final class RetypeTests: ToolTestCase {
  private func renamed(_ url: URL, to name: String) throws -> URL {
    let after = url.deletingLastPathComponent().appendingPathComponent(name)
    try FileManager.default.moveItem(at: url, to: after)
    return after
  }

  private func wanted(_ url: URL, _ before: String) -> String? {
    Retype.wanted(of: url, before: before).map { "\($0.from)>\($0.to)" }
  }

  func test_aPDFCalledAPictureIsToBecomeOne() throws {
    let pdf = try Fixture.pdf(at: path("foto.pdf"), pages: 1)
    XCTAssertEqual(wanted(try renamed(pdf, to: "foto.jpg"), "foto.pdf"), "pdf>jpg")
  }

  /// What it is inside is what it is, whatever it was called before.
  func test_aNameThatWasWrongAlreadyIsSeenThrough() throws {
    let pdf = try Fixture.pdf(at: path("a.pdf"), pages: 1)
    XCTAssertEqual(wanted(try renamed(pdf, to: "a.jpg"), "a.png"), "pdf>jpg")
  }

  func test_aWrongExtensionPutRightIsLeftAlone() throws {
    let image = try Fixture.image(at: path("a.png"))
    let wrong = try renamed(image, to: "a.jpg")
    XCTAssertNil(wanted(try renamed(wrong, to: "a.png"), "a.jpg"))
    let pdf = try Fixture.pdf(at: path("b.pdf"), pages: 1)
    let odd = try renamed(pdf, to: "b.png")
    XCTAssertNil(wanted(try renamed(odd, to: "b.pdf"), "b.png"))
  }

  func test_anotherSpellingIsNotAnotherKind() throws {
    let image = try Fixture.image(at: path("a.jpg"))
    XCTAssertNil(wanted(try renamed(image, to: "a.jpeg"), "a.jpg"))
    XCTAssertNil(wanted(try renamed(path("a.jpeg"), to: "a.JPG"), "a.jpeg"))
    XCTAssertNil(wanted(try renamed(path("a.JPG"), to: "b.JPG"), "a.JPG"), "only the name")
  }

  func test_whatForgeCannotMakeIsLeftAsItIs() throws {
    let sound = try Fixture.audio(at: path("a.wav"), seconds: 1)
    XCTAssertNil(wanted(try renamed(sound, to: "a.obj"), "a.wav"))
    let words = path("notes.txt")
    try Data("hello".utf8).write(to: words)
    XCTAssertNil(wanted(try renamed(words, to: "notes.zzz"), "notes.txt"))
  }

  func test_itGetsItsOwnNameBack_andNobodyElseIsWrittenOver() throws {
    let pdf = try Fixture.pdf(at: path("foto.pdf"), pages: 1), whole = try Data(contentsOf: pdf)
    let wrong = try renamed(pdf, to: "foto_x.jpg")
    let job = try XCTUnwrap(Retype.wanted(of: wrong, before: "foto.pdf"))
    try Data("mine".utf8).write(to: path("foto_x.pdf"))
    let back = try job.putBack(wrong)
    XCTAssertEqual(back.lastPathComponent, "foto_x 2.pdf")
    XCTAssertEqual(try Data(contentsOf: back), whole)
    XCTAssertEqual(try Data(contentsOf: path("foto_x.pdf")), Data("mine".utf8))
  }

  func test_theNameBeforeIsRemembered() throws {
    let home = try folder("watched"), pdf = try Fixture.pdf(at: home.appendingPathComponent("a.pdf"), pages: 1)
    let memory = RenameMemory()
    memory.remember(home, subfolders: false)
    XCTAssertNil(memory.nameBefore(pdf))
    let after = try renamed(pdf, to: "a.jpg")
    XCTAssertEqual(memory.nameBefore(after), "a.pdf")
    XCTAssertNil(memory.nameBefore(after), "once")
    memory.know(try renamed(after, to: "a.pdf"))
    XCTAssertNil(memory.nameBefore(pdf), "Forge put it back")
  }

  /// A list has no name to be given in a TOML: it cannot be made after all, and
  /// nothing is lost by having asked.
  func test_whatCannotBeMadeAfterAllIsStillWhatItWas() async throws {
    let table = path("a.csv"), bytes = Data("a,b\n1,x\n".utf8)
    try bytes.write(to: table)
    let wrong = try renamed(table, to: "a.toml")
    let job = try XCTUnwrap(Retype.wanted(of: wrong, before: "a.csv"))
    let back = try job.putBack(wrong)
    let coordinator = ProcessingCoordinator(settings: AppSettings(), persistence: store)
    do {
      _ = try await coordinator.processFile(try ProcessableFile(url: back), with: job.preset, destinationMode: .overwrite) { _ in }
      XCTFail("it was made")
    } catch {}
    XCTAssertEqual(try Data(contentsOf: table), bytes)
    XCTAssertFalse(exists(wrong))
  }

  /// An underscore with nothing after it is part of the name.
  func test_anUnderscoreOnItsOwnStays() async throws {
    for (given, made) in [("foto3_.jpg", "foto3_.jpg"), ("_.jpg", "_.jpg"), ("a_b_.jpg", "a_b_.jpg"), ("c_rotate90.jpg", "c.jpg")] {
      let source = try Fixture.pdf(at: path("source.pdf"), pages: 1)
      let wrong = try renamed(source, to: given)
      let job = try XCTUnwrap(Retype.wanted(of: wrong, before: "source.pdf"))
      let coordinator = ProcessingCoordinator(settings: AppSettings(), persistence: store)
      let entry = try await coordinator.processFile(try ProcessableFile(url: try job.putBack(wrong)), with: job.preset, destinationMode: .overwrite) { _ in }
      XCTAssertEqual(entry.outputURL?.lastPathComponent, made)
    }
  }

  /// Three pages are three pictures, and the document is kept.
  func test_aDocumentOfSeveralPages() async throws {
    let pdf = try Fixture.pdf(at: path("doc.pdf"), pages: 3), whole = try Data(contentsOf: pdf)
    let wrong = try renamed(pdf, to: "doc.jpg")
    let job = try XCTUnwrap(Retype.wanted(of: wrong, before: "doc.pdf"))
    let coordinator = ProcessingCoordinator(settings: AppSettings(), persistence: store)
    let entry = try await coordinator.processFile(try ProcessableFile(url: try job.putBack(wrong)), with: job.preset, destinationMode: .overwrite) { _ in }
    XCTAssertEqual(entry.outputs.count, 3)
    XCTAssertEqual(entry.outputURL?.lastPathComponent, "doc.jpg")
    XCTAssertTrue(entry.outputs.allSatisfy { Signature.fits($0, "jpg") == true })
    XCTAssertTrue(Undo.isPossible(for: entry))
    let kept = FileManager.default.enumerator(at: store.root, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL }.filter { $0.pathExtension == "pdf" } ?? []
    XCTAssertEqual(try kept.map { try Data(contentsOf: $0) }, [whole])
  }

  /// Every kind Forge has, each under another's name: what comes out is what the
  /// name says, and the original is kept.
  func test_fromAnyKindToAnyOther() async throws {
    let home = try folder("kinds")
    try Fixture.image(at: home.appendingPathComponent("a.png"))
    try Fixture.image(at: home.appendingPathComponent("b.jpg"))
    try Fixture.heic(at: home.appendingPathComponent("c.heic"))
    _ = try Fixture.scannedPDF(at: home.appendingPathComponent("d.pdf"), pages: ["Some words on a page"])
    _ = try Fixture.audio(at: home.appendingPathComponent("e.wav"), seconds: 1)
    _ = try await Fixture.video(at: home.appendingPathComponent("f.mp4"), seconds: 1)
    try Data("# Title\n\nSome words.\n".utf8).write(to: home.appendingPathComponent("g.md"))
    try Data("Some words, plainly.\n".utf8).write(to: home.appendingPathComponent("h.txt"))
    try Data(#"[{"a":1,"b":"x"}]"#.utf8).write(to: home.appendingPathComponent("i.json"))
    try Data("a,b\n1,x\n".utf8).write(to: home.appendingPathComponent("j.csv"))
    try Data("1\n00:00:00,000 --> 00:00:01,000\nHello\n".utf8).write(to: home.appendingPathComponent("k.srt"))
    let names = try FileManager.default.contentsOfDirectory(atPath: home.path).sorted()
    var made = 0, wrong: [String] = []
    for name in names {
      let source = home.appendingPathComponent(name), bytes = try Data(contentsOf: source)
      let file = try ProcessableFile(url: source)
      let kind = try XCTUnwrap(ConvertKind(fileType: file.fileType))
      let targets = kind.leading(of: kind.outputGroups(for: [file]).flatMap(\.formats)).compactMap { $0.type }.filter { $0 != file.fileType }
      for target in targets {
        let ext = Conversions.fileExtension(of: target), pair = "\(source.pathExtension)>\(ext)"
        // What is said or read in it takes a voice, and minutes.
        guard !(kind == .video || kind == .audio) || !["txt", "srt", "vtt"].contains(ext), !(kind == .document && ["m4a", "wav"].contains(ext)), !["csv>toml", "json>toml"].contains(pair) else { continue }
        let work = try folder("work-\(pair.replacingOccurrences(of: ">", with: "-"))")
        let given = work.appendingPathComponent("x.\(ext)")
        try bytes.write(to: given)
        guard let job = Retype.wanted(of: given, before: "x.\(source.pathExtension)") else { wrong.append("\(pair): not seen"); continue }
        let back = try job.putBack(given)
        do {
          let coordinator = ProcessingCoordinator(settings: AppSettings(), persistence: PersistenceManager(root: try folder("store")))
          let entry = try await coordinator.processFile(try ProcessableFile(url: back), with: job.preset, destinationMode: .overwrite, destinationURL: nil) { _ in }
          let out = try XCTUnwrap(entry.outputURL)
          if out.pathExtension != ext { wrong.append("\(pair): called \(out.lastPathComponent)") }
          if Signature.fits(out, ext) == false { wrong.append("\(pair): \(out.lastPathComponent) is not one") }
          if (try Data(contentsOf: out)).isEmpty { wrong.append("\(pair): empty") }
          made += 1
        } catch { wrong.append("\(pair): \(error.localizedDescription)") }
      }
    }
    XCTAssertEqual(wrong, [])
    XCTAssertGreaterThan(made, 30)
    print("RETYPE", made, "pairs")
  }
}

/// The whole of it: a watched folder, and a rename in it.
@MainActor
final class RetypeWatchedTests: BaseTestCase {
  private func waitFor(_ seconds: Double = 12, _ done: () -> Bool) async throws {
    let end = Date().addingTimeInterval(seconds)
    while !done(), Date() < end { try await Task.sleep(nanoseconds: 100_000_000) }
  }

  func test_renamingIsEnough_again_andAgain() async throws {
    let model = AppModel(persistence: store)
    let home = try folder("watched")
    let pdf = try Fixture.pdf(at: home.appendingPathComponent("foto.pdf"), pages: 1), jpg = home.appendingPathComponent("foto.jpg")
    model.addFolder(url: home, presetID: AppModel.noPreset, mode: .copyTo, destination: home, includeSubfolders: false, onlyWhenRenamed: true)
    defer { model.folders.forEach { model.toggleFolder($0, active: false) } }
    try await Task.sleep(nanoseconds: 800_000_000)
    try FileManager.default.moveItem(at: pdf, to: jpg)
    try await waitFor { Signature.fits(jpg, "jpg") == true }
    XCTAssertEqual(Signature.fits(jpg, "jpg"), true)
    // And what came of it, under another name again.
    let png = home.appendingPathComponent("altra.png")
    try await Task.sleep(nanoseconds: 2_500_000_000)
    try FileManager.default.moveItem(at: jpg, to: png)
    try await waitFor { Signature.fits(png, "png") == true }
    XCTAssertEqual(Signature.fits(png, "png"), true)
    // And back to a name that has been used.
    try await Task.sleep(nanoseconds: 2_500_000_000)
    try FileManager.default.moveItem(at: png, to: jpg)
    try await waitFor { Signature.fits(jpg, "jpg") == true }
    XCTAssertEqual(Signature.fits(jpg, "jpg"), true)
    XCTAssertNil(model.lastError)
  }
}
