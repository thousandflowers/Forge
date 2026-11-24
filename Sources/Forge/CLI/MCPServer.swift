import ArgumentParser
import Foundation
import UniformTypeIdentifiers

/// Forge for an assistant: the Model Context Protocol, over standard input and
/// output. It converts copies and joins copies. An original is never replaced
/// from here, whoever asks.
struct MCPServer {
  typealias Object = [String: Any]

  private static let protocolVersion = "2025-06-18"

  let presets: () async throws -> [RulePreset]
  let coordinator: ProcessingCoordinator

  /// What to answer, or nil where nothing is expected.
  func answer(_ request: Object) async -> Object? {
    guard let method = request["method"] as? String else { return nil }
    // Without an id it is a notification.
    guard let id = request["id"] else { return nil }
    func reply(_ result: Object) -> Object { ["jsonrpc": "2.0", "id": id, "result": result] }
    switch method {
    case "initialize":
      let asked = (request["params"] as? Object)?["protocolVersion"] as? String
      return reply([
        "protocolVersion": asked ?? Self.protocolVersion, "capabilities": ["tools": Object()],
        "serverInfo": ["name": "forge", "version": Bundle.main.shortVersion],
      ])
    case "ping": return reply([:])
    case "tools/list": return reply(["tools": Self.tools])
    case "tools/call":
      let params = request["params"] as? Object ?? [:]
      do {
        let text = try await call(params["name"] as? String ?? "", params["arguments"] as? Object ?? [:])
        return reply(["content": [["type": "text", "text": text]], "isError": false])
      } catch {
        // A mistake the assistant can read and put right, not a broken server.
        let said = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        return reply(["content": [["type": "text", "text": said]], "isError": true])
      }
    default:
      return ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Forge has no method called \(method)"]]
    }
  }

  // MARK: - Tools

  private static let words = Tool.Kind.allCases.map { "\($0.blank.word) (\($0.summary.lowercased()))" }.joined(separator: ", ")

  static let tools: [Object] = {
    let files: Object = ["type": "array", "items": ["type": "string"], "description": "Paths of the files."]
    let out: Object = ["type": "string", "description": "Folder to write into. Without it, beside each file."]
    return [
      [
        "name": "convert", "description": "Convert files on this Mac, or do something to them. Originals are kept.",
        "inputSchema": ["type": "object", "required": ["files"], "properties": [
          "files": files, "out": out,
          "to": ["type": "string", "description": "Format to write, by extension: jpeg, mp4, txt, pdf…"],
          "do": ["type": "array", "items": ["type": "string"], "description": "Things to do to each, in order: \(words)."],
          "preset": ["type": "string", "description": "Name of a saved preset, as the presets tool lists them. It is the whole recipe: give it without to, do and maxBytes."],
          "answers": ["type": "object", "additionalProperties": ["type": "number"], "description": "Answers to what the preset asks, by key. What is not answered takes its usual value."],
          "maxBytes": ["type": "integer", "description": "Come out no larger than this."],
        ] as Object],
      ],
      [
        "name": "join", "description": "Make several files into one: PDFs and pictures, films, recordings, or a film with another file's sound or subtitles.",
        "inputSchema": ["type": "object", "required": ["files"], "properties": [
          "files": files, "out": out,
          "as": ["type": "string", "enum": Joiner.Kind.allCases.map(\.rawValue), "description": "Without it, what the files suggest."],
        ] as Object],
      ],
      ["name": "presets", "description": "The saved presets.", "inputSchema": ["type": "object", "properties": Object()]],
    ]
  }()

  private func call(_ name: String, _ arguments: Object) async throws -> String {
    switch name {
    case "convert": return try await convert(arguments)
    case "join": return try await join(arguments)
    case "presets": return try await presets().map(Self.describe).joined(separator: "\n")
    default: throw CLIError("Forge has no tool called “\(name)”.")
    }
  }

  /// What it does, which files it is for, and what it asks.
  private static func describe(_ preset: RulePreset) -> String {
    var line = "\(preset.name) (\(preset.inputFormats?.joined(separator: ", ") ?? preset.category.title.lowercased())): "
      + preset.actions.map(ForgeCommand.Presets.describe).joined(separator: " · ")
    for question in preset.parameters {
      let range = question.kind.range
      line += ". Asks \(question.key): \(question.label), \(Tool.text(range.lowerBound)) to \(Tool.text(range.upperBound)) \(question.kind.unit), usually \(Tool.text(question.defaultValue))"
    }
    return line
  }

  private func convert(_ arguments: Object) async throws -> String {
    let preset = try await preset(arguments)
    var lines: [String] = []
    var failed = 0
    for path in try paths(arguments) {
      do {
        let file = try ProcessableFile(url: URL(fileURLWithPath: path))
        guard preset.accepts(file.url) else { throw CLIError("“\(preset.name)” is not for this kind of file") }
        let entry = try await coordinator.processFile(
          file, with: preset, destinationMode: .copyTo, destinationURL: folder(arguments) ?? file.url.deletingLastPathComponent()
        ) { _ in }
        lines += entry.outputs.map(\.path)
      } catch {
        failed += 1
        lines.append("failed \(path): \((error as? LocalizedError)?.errorDescription ?? String(describing: error))")
      }
    }
    // Some of them done is an answer; none of them is not.
    if failed > 0, failed == lines.count { throw CLIError(lines.joined(separator: "\n")) }
    return lines.joined(separator: "\n")
  }

  private func join(_ arguments: Object) async throws -> String {
    let files = try paths(arguments).map { path in
      do { return try ProcessableFile(url: URL(fileURLWithPath: path)) } catch { throw CLIError("\(path): \(error.localizedDescription)") }
    }
    let possible = Joiner.kinds(for: files)
    let asked = (arguments["as"] as? String).flatMap(Joiner.Kind.init(rawValue:))
    guard let kind = asked ?? possible.first, possible.contains(kind) else { throw CLIError("These files cannot be made into one together.") }
    return try await coordinator.join(files, as: kind, into: folder(arguments)).path
  }

  private func preset(_ arguments: Object) async throws -> RulePreset {
    if let name = arguments["preset"] as? String {
      guard let found = try await presets().first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
        throw CLIError("No preset is called “\(name)”.")
      }
      // A preset is the whole recipe. What is beside it would be dropped without
      // a word, which reads as if it had been done.
      let beside = ["to", "do", "maxBytes"].filter { arguments[$0] != nil }
      guard beside.isEmpty else { throw CLIError("A preset is the whole recipe. Give it without \(beside.joined(separator: ", ")).") }
      return found.answered(with: try answers(arguments, to: found))
    }
    guard arguments["answers"] == nil else { throw CLIError("Answers are to a preset's questions, and no preset was given.") }
    var made = RulePreset(name: "Asked by an assistant", description: "", category: .custom)
    if let format = arguments["to"] as? String {
      made = try RecipeOptions.parse(["--to", format]).resolve(saved: [])
      made.name = "Asked by an assistant"
    }
    for word in arguments["do"] as? [String] ?? [] {
      guard let tool = Tool(word: word) else { throw CLIError("“\(word)” is not something Forge does.") }
      made.actions = made.actions.adding(tool)
    }
    if let bytes = (arguments["maxBytes"] as? NSNumber)?.intValue, bytes > 0 { made.actions.append(.limitSize(bytes: bytes)) }
    guard made.doesSomething else { throw CLIError("Say what to do: to, do, preset or maxBytes.") }
    return made
  }

  private func answers(_ arguments: Object, to preset: RulePreset) throws -> [String: Double] {
    var answers: [String: Double] = [:]
    for (key, value) in arguments["answers"] as? Object ?? [:] {
      guard let asked = preset.parameters.first(where: { $0.key == key }) else {
        let keys = preset.parameters.map(\.key).joined(separator: ", ")
        throw CLIError("“\(preset.name)” does not ask for “\(key)”. It asks for: \(keys.isEmpty ? "nothing" : keys).")
      }
      guard let number = (value as? NSNumber)?.doubleValue, asked.kind.range.contains(number) else {
        throw CLIError("\(key) is \(Tool.text(asked.kind.range.lowerBound)) to \(Tool.text(asked.kind.range.upperBound)).")
      }
      answers[key] = number
    }
    return answers
  }

  private func paths(_ arguments: Object) throws -> [String] {
    guard let paths = arguments["files"] as? [String], !paths.isEmpty else { throw CLIError("No files were given.") }
    return paths.map { ($0 as NSString).expandingTildeInPath }
  }

  private func folder(_ arguments: Object) -> URL? {
    (arguments["out"] as? String).map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
  }
}

extension ForgeCommand {
  @available(macOS 13, *)
  struct MCP: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "mcp",
      abstract: "Let an assistant convert files, over the Model Context Protocol.",
      discussion: """
        Speaks on standard input and output. In Claude Code:

          claude mcp add forge -- forge mcp
        """
    )

    func run() async throws {
      _ = ExternalBridge.pandocFormats
      let server = MCPServer(presets: { try await ForgeCommand.presets() }, coordinator: ProcessingCoordinator(settings: AppSettings.load()))
      for try await line in FileHandle.standardInput.bytes.lines {
        guard !line.isEmpty else { continue }
        let response: MCPServer.Object?
        if let request = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? MCPServer.Object {
          response = await server.answer(request)
        } else {
          response = ["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "That is not JSON"]]
        }
        guard let response, var data = try? JSONSerialization.data(withJSONObject: response, options: [.withoutEscapingSlashes]) else { continue }
        data.append(0x0A)
        try FileHandle.standardOutput.write(contentsOf: data)
      }
    }
  }
}
