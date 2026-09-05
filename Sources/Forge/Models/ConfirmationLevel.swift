import Foundation

/// How much of a question a conversion is.
///
/// The screen already refuses to show a control that would be ignored. This is
/// the same rule pointed at questions: one with an obvious answer is not asked.
/// A JPEG dropped onto a preset that makes JPEGs is not a decision, and neither
/// is a size somebody typed into the filename themselves.
enum ConfirmationLevel: Int, Comparable, Sendable {
  /// Run it. Nothing here the user did not already say.
  case silent
  /// Ask once, with what the result will actually be.
  case confirm
  /// Ask before touching what is already on disk. This is the existing
  /// replace-or-move dialog, routed through the same gate rather than beside it.
  case block

  static func < (lhs: ConfirmationLevel, rhs: ConfirmationLevel) -> Bool {
    lhs.rawValue < rhs.rawValue
  }

  /// The one question a whole batch is worth: the most serious thing in it.
  ///
  /// A batch where every file is settled asks nothing at all, which is the
  /// case this gate is built for - drop a folder onto a preset chosen a minute
  /// ago and it simply runs.
  static func forBatch(_ plans: [ConversionPlan]) -> ConfirmationLevel {
    plans.map { ConfirmationLevel(for: $0) }.max() ?? .silent
  }

  /// The rule, in one place and in order of seriousness.
  init(for plan: ConversionPlan) {
    if plan.touchesExistingFiles {
      self = .block
    } else if plan.hasUndefinedRequiredParams || plan.isCrossDomainOrExpanding {
      self = .confirm
    } else if plan.isLossyOrMagic && !plan.magicWasExplicit {
      self = .confirm
    } else {
      self = .silent
    }
  }
}

/// The five facts about a planned conversion that decide whether to ask.
///
/// Facts rather than file types: the rule is a table with five columns, and a
/// pile of `if`s about formats would be a different rule per format and a
/// different answer per reading of it.
struct ConversionPlan: Equatable, Sendable {
  /// Something is being thrown away that the encoder was not simply told to
  /// throw away — a ceiling on the finished size, which resolves to whatever
  /// quality it takes to get there.
  var isLossyOrMagic = false
  /// The user typed that ceiling into the filename. Then it is not a surprise,
  /// it is the instruction, and interrupting them to confirm their own typing
  /// is the interruption this whole gate exists to remove.
  var magicWasExplicit = false
  /// Nothing here says what the file should become.
  var hasUndefinedRequiredParams = false
  /// A picture asked to become a film, a PDF asked to become twenty images:
  /// the answer is not one file of the same sort, and that is worth a look.
  var isCrossDomainOrExpanding = false
  /// The originals are replaced or removed.
  var touchesExistingFiles = false

  var confirmationLevel: ConfirmationLevel { ConfirmationLevel(for: self) }

  /// Why this one is being asked about, for the sentence at the top of the
  /// sheet. The order matches the rule.
  var reason: Reason? {
    if touchesExistingFiles { return .touchesOriginals }
    if hasUndefinedRequiredParams { return .undefined }
    if isCrossDomainOrExpanding { return .crossDomain }
    if isLossyOrMagic && !magicWasExplicit { return .inferredCeiling }
    return nil
  }

  enum Reason: Sendable {
    case undefined
    case crossDomain
    case inferredCeiling
    case touchesOriginals

    var sentence: String {
      switch self {
      case .undefined:
        return "Nothing yet says what these should become."
      case .crossDomain:
        return "This makes something of a different kind, so here is what comes out."
      case .inferredCeiling:
        return "The size ceiling comes from the preset rather than from the name you typed, "
          + "so here is what it costs."
      case .touchesOriginals:
        return "This changes files you already have."
      }
    }
  }
}

extension ConversionPlan {
  /// What is actually about to happen to one file.
  ///
  /// The operations are read the way `ProcessingCoordinator` reads them, size
  /// in the filename included, because a plan that disagrees with the run is
  /// worse than no plan at all.
  init(file: ProcessableFile, preset: RulePreset?, destinationMode: DestinationMode) {
    let operations = preset.map { NameTokens.applying(to: $0.toOperations(), from: file.fileName) } ?? []
    let ceiling = SizeInName.ceiling(in: file.fileName)

    let source = ConvertKind(fileType: file.fileType)
    let target = preset?.targetFormat.flatMap { ConvertKind(fileType: $0) }
    let formats = preset.map { ProcessingCoordinator.formats(of: $0).count } ?? 0

    self.init(
      isLossyOrMagic: operations.contains { if case .limitSize = $0 { return true } else { return false } },
      magicWasExplicit: ceiling != nil,
      hasUndefinedRequiredParams: operations.isEmpty,
      // One input and more than one output file is expanding whatever the kinds
      // are: a preset naming two formats writes two files per file.
      isCrossDomainOrExpanding: formats > 1 || (target != nil && target != source),
      touchesExistingFiles: destinationMode != .copyTo
    )
  }
}
