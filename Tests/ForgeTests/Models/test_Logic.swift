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
