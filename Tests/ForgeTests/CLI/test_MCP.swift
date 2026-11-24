import XCTest
@testable import Forge

final class MCPTests: ToolTestCase {
  private var server: MCPServer {
    let preset = RulePreset(name: "Web", description: "", category: .image, actions: [.convertFormat(to: .jpeg)])
    return MCPServer(presets: { [preset] }, coordinator: coordinator())
  }

  private func call(_ name: String, _ arguments: [String: Any]) async throws -> (text: String, isError: Bool) {
    let answer = await server.answer(["jsonrpc": "2.0", "id": 7, "method": "tools/call", "params": ["name": name, "arguments": arguments]])
    let result = try XCTUnwrap(answer?["result"] as? [String: Any])
    XCTAssertEqual(answer?["id"] as? Int, 7)
    return (try XCTUnwrap((result["content"] as? [[String: String]])?.first?["text"]), try XCTUnwrap(result["isError"] as? Bool))
  }

  func test_shakingHands() async {
    let hello = await server.answer(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-03-26"]])
    XCTAssertEqual((hello?["result"] as? [String: Any])?["protocolVersion"] as? String, "2025-03-26")
    let none = await server.answer(["jsonrpc": "2.0", "method": "notifications/initialized"])
    XCTAssertNil(none)
    let list = await server.answer(["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
    let tools = (list?["result"] as? [String: Any])?["tools"] as? [[String: Any]]
    XCTAssertEqual(tools?.compactMap { $0["name"] as? String }, ["convert", "join", "presets"])
    XCTAssertTrue(JSONSerialization.isValidJSONObject(list as Any))
    let strange = await server.answer(["jsonrpc": "2.0", "id": 3, "method": "nope"])
    XCTAssertNotNil(strange?["error"])
  }

  func test_converting() async throws {
    let source = path("a.png")
    try Quarters.image(at: source)
    let out = path("out").path
    let made = try await call("convert", ["files": [source.path], "to": "jpeg", "do": ["rotate90"], "out": out])
    XCTAssertFalse(made.isError, made.text)
    XCTAssertEqual(try Quarters.read(URL(fileURLWithPath: made.text)), [.blue, .red, .white, .green])
    XCTAssertTrue(exists(source), "the original is kept")
    let beside = try await call("convert", ["files": [source.path], "preset": "web"])
    XCTAssertEqual(URL(fileURLWithPath: beside.text).deletingLastPathComponent().path, workspace.path)
  }

  func test_mistakesAreSaid() async throws {
    let source = path("a.png")
    try Quarters.image(at: source)
    for arguments in [["files": [source.path], "do": ["teleport"]], ["files": [source.path]], ["files": []], ["files": ["/nowhere.png"], "to": "jpeg"], ["files": [source.path], "to": "nonsense"]] as [[String: Any]] {
      let said = try await call("convert", arguments)
      XCTAssertTrue(said.isError, "\(arguments)")
      XCTAssertFalse(said.text.isEmpty)
    }
  }

  func test_joining() async throws {
    let one = path("a.pdf"), two = path("b.pdf")
    try Fixture.pdf(at: one, pages: 1)
    try Fixture.pdf(at: two, pages: 2)
    let made = try await call("join", ["files": [one.path, two.path]])
    XCTAssertFalse(made.isError, made.text)
    XCTAssertTrue(made.text.hasSuffix("a joined.pdf"))
  }
}
