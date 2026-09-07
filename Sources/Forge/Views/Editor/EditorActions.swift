import SwiftUI
import UniformTypeIdentifiers

struct Action: Identifiable, Hashable {
  let id: UUID
  /// The step itself. For a fork the nested chains here are empty: the
  /// branches below hold them, with identities.
  var operation: Operation
  var branches: [ActionBranch]

  init(_ operation: Operation) {
    id = UUID()
    switch operation {
    case .when(let condition, let then, let otherwise):
      self.operation = .when(condition, then: [], otherwise: [])
      branches = [
        ActionBranch(name: "If it passes", actions: then.map(Action.init)),
        ActionBranch(name: "Otherwise", actions: otherwise.map(Action.init)),
      ]
    case .split(let split):
      self.operation = .split([])
      branches = split.map { ActionBranch(name: $0.name, actions: $0.actions.map(Action.init)) }
    default:
      self.operation = operation
      branches = []
    }
  }

  /// The operation with its branches folded back in, as the preset stores it.
  var resolved: Operation {
    switch operation {
    case .when(let condition, _, _):
      return .when(
        condition,
        then: branches.first?.actions.map(\.resolved) ?? [],
        otherwise: branches.dropFirst().first?.actions.map(\.resolved) ?? []
      )
    case .split:
      return .split(branches.map { Branch(name: $0.name, actions: $0.actions.map(\.resolved)) })
    default:
      return operation
    }
  }

  /// What the block is called on the canvas. A split counts its branches
  /// here, where they live, rather than the empty list the operation holds.
  var title: String {
    if case .split = operation { return "Split into \(branches.count) copies" }
    return operation.title
  }

  /// Whether a step with this id is this one or lives somewhere under it.
  func contains(_ other: UUID) -> Bool {
    id == other || branches.contains { $0.id == other || $0.actions.contains { $0.contains(other) } }
  }
}

/// One path out of a fork, on the canvas.
struct ActionBranch: Identifiable, Hashable {
  let id = UUID()
  var name: String
  var actions: [Action]
}

extension Array where Element == Action {
  /// Takes the step with this id out of the tree, wherever it is.
  mutating func removeStep(id: UUID) -> Action? {
    if let index = firstIndex(where: { $0.id == id }) { return remove(at: index) }
    for i in indices {
      for b in self[i].branches.indices {
        if let taken = self[i].branches[b].actions.removeStep(id: id) { return taken }
      }
    }
    return nil
  }

  /// Puts a step where a drop said, anywhere in the tree. False when the spot
  /// is nowhere to be found, which the caller treats as "at the end".
  mutating func insert(_ step: Action, at spot: PresetEditorView.DropSpot, root: UUID) -> Bool {
    switch spot {
    case .before(let id):
      if let index = firstIndex(where: { $0.id == id }) { insert(step, at: index); return true }
    case .endOf(let container):
      if container == root { append(step); return true }
    }
    for i in indices {
      for b in self[i].branches.indices {
        if case .endOf(let container) = spot, container == self[i].branches[b].id {
          self[i].branches[b].actions.append(step)
          return true
        }
        if self[i].branches[b].actions.insert(step, at: spot, root: root) { return true }
      }
    }
    return false
  }

  /// The spot right after a step, wherever it lives: before the next step in
  /// its chain, or the end of that chain when it is the last.
  func spotAfter(_ id: UUID, root: UUID) -> PresetEditorView.DropSpot? {
    if let index = firstIndex(where: { $0.id == id }) {
      return index + 1 < count ? .before(self[index + 1].id) : .endOf(root)
    }
    for action in self {
      for branch in action.branches {
        if let spot = branch.actions.spotAfter(id, root: branch.id) { return spot }
      }
    }
    return nil
  }

  /// The chain a branch holds, found by the branch's id.
  func actions(in container: UUID) -> [Action]? {
    for action in self {
      for branch in action.branches {
        if branch.id == container { return branch.actions }
        if let found = branch.actions.actions(in: container) { return found }
      }
    }
    return nil
  }

  /// A step after a fork, in any chain, gets a join in front of it when
  /// nothing rejoins the arms yet.
  mutating func ensureJoins() {
    if let index = lastIndex(where: { !$0.branches.isEmpty }), index + 1 < count {
      switch self[index + 1].operation {
      case .join, .merge: break
      default: insert(Action(.join), at: index + 1)
      }
    }
    for i in indices {
      for b in self[i].branches.indices { self[i].branches[b].actions.ensureJoins() }
    }
  }

  func step(_ id: UUID) -> Action? {
    for action in self {
      if action.id == id { return action }
      for branch in action.branches { if let found = branch.actions.step(id) { return found } }
    }
    return nil
  }
}

/// The steps that can be added, what each one starts as, and which kinds of
/// file it means anything for.
///
/// The format is not here: what a preset comes out as is its own block at the
/// top, because it is the one thing every preset answers and the one thing that
/// can be answered more than once.

extension Action {
  /// The library kind this step came from, so the library's own rules can
  /// say whether it still applies.
  var kind: ActionKind? {
    switch operation {
    case .convertFormat: return nil  // a format is not a step from the library
    case .resize(_, _, let mode): return mode == .cropCenter ? .crop : .resize
    case .quality: return .quality
    case .filter: return .filter
    case .recognizeText: return .recognizeText
    case .encode: return .encode
    case .limitSize: return .limitSize
    case .stripMetadata: return .privacy
    case .when: return .when
    case .split: return .split
    case .join: return .join
    case .merge: return .merge
    }
  }

  /// The colour of the group this step is filed under.
  var tint: Color {
    switch operation {
    case .convertFormat: return LibraryEntry.Group.output.color
    case .resize, .filter, .recognizeText: return LibraryEntry.Group.transform.color
    case .quality, .limitSize, .encode: return LibraryEntry.Group.encode.color
    case .stripMetadata: return LibraryEntry.Group.privacy.color
    case .when, .split, .join, .merge: return LibraryEntry.Group.logic.color
    }
  }

}

/// One row: what the action is, and the few settings it needs.
