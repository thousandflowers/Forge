import Foundation
import SwiftUI

/// What was done without being asked, said once in a corner.
struct ResultCard: Identifiable {
  let id = UUID()
  let title: String
  let file: URL
  let before: Int64
  let after: Int64
  /// Said where nothing was made, in place of what it weighs.
  var note: String?
  /// Whether it could be put back.
  let undo: @MainActor () -> Bool
  /// When the card has gone, whichever way it went.
  var gone: @MainActor () -> Void = {}

  /// Only a saving is claimed: a JPEG made of a HEIC is often the heavier.
  static func percent(from before: Int64, to after: Int64) -> String? {
    guard before > 0, after > 0, after < before else { return nil }
    return "−\(Int((Double(before - after) / Double(before) * 100).rounded()))%"
  }
}

@MainActor
final class ResultCenter: ObservableObject {
  /// More than this is a wall, not a notice.
  private static let most = 3
  private static let linger: UInt64 = 7_000_000_000

  @Published private(set) var cards: [ResultCard] = []
  private var panel: ResultPanel?
  private let shows: Bool

  init(shows: Bool = true) { self.shows = shows }

  func show(_ card: ResultCard) {
    cards.append(card)
    cards.dropLast(Self.most).forEach { close($0.id) }
    if shows {
      if panel == nil { panel = ResultPanel(center: self) }
      panel?.appear()
    }
    leave(card.id)
  }

  func close(_ id: UUID) {
    held.remove(id)
    guard let card = cards.first(where: { $0.id == id }) else { return }
    cards.removeAll { $0.id == id }
    card.gone()
    if cards.isEmpty { panel?.close() }
  }

  /// The one under the pointer waits until the pointer has gone.
  var held: Set<UUID> = []

  private func leave(_ id: UUID) {
    Task { [weak self] in
      repeat { try? await Task.sleep(nanoseconds: Self.linger) } while self?.held.contains(id) == true
      self?.close(id)
    }
  }
}
