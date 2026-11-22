import Foundation
import PDFKit
import XCTest
@testable import Forge

final class LogicTests: BaseTestCase {
  private var big: Condition {
    var condition = Condition()
    condition.subject = .longestSide
    condition.comparison = .greaterThan
    condition.value = 2000
    return condition
  }

  func testForksSurviveJSON() throws {
    let chain: [Forge.Operation] = [
      .when(big, then: [.resize(width: 1600, height: nil, fitMode: .proportional)], otherwise: [.quality(level: 50)]),
      .split([Branch(name: "web", actions: [.quality(level: 70)]), Branch(name: "keep", actions: [])]),
    ]

    let back = try JSONDecoder().decode([Forge.Operation].self, from: JSONEncoder().encode(chain))

    XCTAssertEqual(back, chain)
    XCTAssertEqual(back.first?.title, "If longest side is more than 2000 px")
  }

  func testAnIfIsDecidedByTheFileAndASplitFansOut() throws {
    let large = try ProcessableFile(url: try Fixture.image(at: path("large.png"), width: 4000, height: 3000))
    let small = try ProcessableFile(url: try Fixture.image(at: path("small.png"), width: 800, height: 600))
    let chain: [Forge.Operation] = [
      .when(big, then: [.resize(width: 1600, height: nil, fitMode: .proportional)], otherwise: [.quality(level: 50)]),
      .split([Branch(name: "web", actions: [.quality(level: 70)]), Branch(name: "keep", actions: [])]),
    ]

    let forLarge = chain.resolved(for: large).chains
    let forSmall = chain.resolved(for: small).chains

    XCTAssertEqual(forLarge.map { $0.branch }, ["web", "keep"])
    XCTAssertEqual(forLarge[0].actions, [.resize(width: 1600, height: nil, fitMode: .proportional), .quality(level: 70)])
    XCTAssertEqual(forLarge[1].actions, [.resize(width: 1600, height: nil, fitMode: .proportional)])
    XCTAssertEqual(forSmall[0].actions, [.quality(level: 50), .quality(level: 70)])
  }

  func testAChainWithoutForksIsOnePlainChain() throws {
    let file = try ProcessableFile(url: try Fixture.image(at: path("plain.png")))
    let chains = [Forge.Operation.quality(level: 80)].resolved(for: file).chains

    XCTAssertEqual(chains.count, 1)
    XCTAssertNil(chains[0].branch)
  }

  func testASplitWritesOneFilePerCopyNamedAfterTheCopy() async throws {
    let source = try Fixture.image(at: path("photo.png"), width: 1200, height: 900)
    let out = try folder("out")
    var preset = RulePreset(name: "Two sizes", description: "", category: .image, actions: [
      .split([
        Branch(name: "small", actions: [.resize(width: 300, height: nil, fitMode: .proportional)]),
        Branch(name: "medium", actions: [.resize(width: 600, height: nil, fitMode: .proportional)]),
      ]),
    ])
    preset.nameTemplate = "{name}"

    let entry = try await coordinator().processFile(
      try ProcessableFile(url: source), with: preset, destinationMode: .copyTo, destinationURL: out
    ) { _ in }

    let written = Set(contents(of: out))
    XCTAssertEqual(entry.status, .completed)
    XCTAssertEqual(written, ["photo_small.png", "photo_medium.png"], "\(written)")
  }

  func testAMergeAfterASplitWritesOnePDFAndNoCopies() async throws {
    let source = try Fixture.image(at: path("photo.png"), width: 600, height: 400)
    let out = try folder("out")
    let preset = RulePreset(name: "Contact sheet", description: "", category: .image, actions: [
      .split([
        Branch(name: "small", actions: [.resize(width: 200, height: nil, fitMode: .proportional)]),
        Branch(name: "large", actions: []),
      ]),
      .merge(.pdf),
    ])

    let entry = try await coordinator().processFile(
      try ProcessableFile(url: source), with: preset, destinationMode: .copyTo, destinationURL: out
    ) { _ in }

    XCTAssertEqual(entry.status, .completed)
    XCTAssertEqual(contents(of: out), ["photo.pdf"])
    XCTAssertEqual(PDFDocument(url: out.appendingPathComponent("photo.pdf"))?.pageCount, 2)
  }

  func testAMergeNeverOverwritesAFileAlreadyInTheFolder() async throws {
    let source = try Fixture.image(at: path("photo.png"), width: 300, height: 200)
    let out = try folder("out")
    try Data("mine".utf8).write(to: out.appendingPathComponent("photo.pdf"))
    let preset = RulePreset(name: "Sheet", description: "", category: .image, actions: [
      .split([Branch(name: "a", actions: []), Branch(name: "b", actions: [])]), .merge(.pdf),
    ])

    let entry = try await coordinator().processFile(try ProcessableFile(url: source), with: preset, destinationMode: .copyTo, destinationURL: out) { _ in }

    XCTAssertEqual(entry.status, .completed)
    XCTAssertEqual(try String(contentsOf: out.appendingPathComponent("photo.pdf")), "mine", "what was there stays")
    XCTAssertEqual(contents(of: out).filter { $0.hasSuffix(".pdf") }.count, 2)
    XCTAssertNotEqual(entry.outputURL?.lastPathComponent, "photo.pdf")
  }

  func testAMergeWithMoveRemovesTheOriginalOnlyOnceTheFileIsWritten() async throws {
    let source = try Fixture.image(at: path("photo.png"), width: 300, height: 200)
    let out = try folder("out")
    let preset = RulePreset(name: "Sheet", description: "", category: .image, actions: [
      .split([Branch(name: "a", actions: []), Branch(name: "b", actions: [])]), .merge(.pdf),
    ])

    let entry = try await coordinator().processFile(try ProcessableFile(url: source), with: preset, destinationMode: .moveTo, destinationURL: out) { _ in }

    XCTAssertEqual(entry.status, .completed)
    XCTAssertFalse(exists(source), "a move is a move")
    XCTAssertEqual(contents(of: out), ["photo.pdf"])
  }

  func testAJoinIsPassedOverAndTheTailRunsOnEveryCopy() throws {
    let file = try ProcessableFile(url: try Fixture.image(at: path("plain.png")))
    let chain: [Forge.Operation] = [
      .split([Branch(name: "a", actions: [.quality(level: 60)]), Branch(name: "b", actions: [])]),
      .join,
      .stripMetadata(policy: .stripAll),
    ]

    let resolution = chain.resolved(for: file)

    XCTAssertNil(resolution.merge)
    XCTAssertEqual(resolution.chains.map { $0.actions }, [[.quality(level: 60), .stripMetadata(policy: .stripAll)], [.stripMetadata(policy: .stripAll)]])
  }

  func testABranchTokenPutsTheCopyNameWhereTheTemplateSays() {
    XCTAssertEqual(ProcessingCoordinator.template("{branch}-{name}", branch: "web"), "web-{name}")
    XCTAssertEqual(ProcessingCoordinator.template("{name}", branch: "web"), "{name}_web")
  }
}

final class ConditionTests: BaseTestCase {
  private func condition(_ subject: Condition.Subject, _ comparison: Condition.Comparison, text: String = "", value: Double = 0, kind: ConvertKind? = nil) -> Condition {
    var c = Condition()
    c.subject = subject; c.comparison = comparison; c.text = text; c.value = value; c.kind = kind
    return c
  }

  func testNameFolderKindAndAnyAreTested() throws {
    let file = try ProcessableFile(url: try Fixture.image(at: try folder("Holiday").appendingPathComponent("IMG_4821.png")))

    XCTAssertTrue(condition(.any, .equals).holds(for: file))
    XCTAssertTrue(condition(.name, .equals, text: "img_4821").holds(for: file), "case does not matter")
    XCTAssertTrue(condition(.name, .contains, text: "4821").holds(for: file))
    XCTAssertTrue(condition(.name, .startsWith, text: "IMG").holds(for: file))
    XCTAssertFalse(condition(.name, .endsWith, text: "IMG").holds(for: file))
    XCTAssertTrue(condition(.folder, .equals, text: "holiday").holds(for: file))
    XCTAssertTrue(condition(.kind, .equals, kind: .image).holds(for: file))
    XCTAssertTrue(condition(.kind, .differs, kind: .video).holds(for: file))
    XCTAssertTrue(condition(.fileExtension, .equals, text: ".PNG").holds(for: file))
    XCTAssertTrue(condition(.fileSize, .lessThan, value: 1).holds(for: file))
  }

  func testEverySubjectOffersOnlyComparisonsItCanMake() throws {
    XCTAssertEqual(Condition.Subject.any.comparisons, [])
    XCTAssertTrue(Condition.Subject.name.comparisons.contains(.contains))
    XCTAssertFalse(Condition.Subject.fileSize.comparisons.contains(.contains))
    XCTAssertEqual(condition(.name, .contains, text: "IMG").summary, "name contains “IMG”")
    XCTAssertEqual(condition(.kind, .equals, kind: .image).summary, "kind is image")

    let back = try JSONDecoder().decode(Condition.self, from: JSONEncoder().encode(condition(.kind, .equals, kind: .audio)))
    XCTAssertEqual(back.kind, .audio)
  }
}
