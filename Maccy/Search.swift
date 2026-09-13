import AppKit
import Defaults

final class Search: Sendable {
  enum Mode: String, CaseIterable, Identifiable, CustomStringConvertible, Defaults.Serializable {
    case exact
    case fuzzy
    case regexp
    case mixed

    var id: Self { self }

    var description: String {
      switch self {
      case .exact:
        return NSLocalizedString("Exact", tableName: "GeneralSettings", comment: "")
      case .fuzzy:
        return NSLocalizedString("Fuzzy", tableName: "GeneralSettings", comment: "")
      case .regexp:
        return NSLocalizedString("Regex", tableName: "GeneralSettings", comment: "")
      case .mixed:
        return NSLocalizedString("Mixed", tableName: "GeneralSettings", comment: "")
      }
    }
  }

  struct SearchResult: Equatable {
    var score: Double?
    var object: Searchable
    var ranges: [Range<String.Index>] = []
  }

  typealias Searchable = HistoryItemDecorator

  /// An immutable, `Sendable` snapshot of the searchable content of one item.
  /// Building these on the main actor (a cheap string copy) is what lets the
  /// actual matching run on a background task without touching the mutable,
  /// non-isolated `HistoryItemDecorator` from off the main thread.
  struct SearchDocument: Sendable, Equatable {
    let id: UUID
    let title: String
  }

  /// The result of matching one `SearchDocument`. `title` is carried along so
  /// the caller can detect that the underlying item's title changed between
  /// snapshot and apply time (e.g. a live async title update) and discard
  /// ranges that no longer describe the current string.
  struct SearchMatch: Sendable {
    let id: UUID
    let title: String
    var score: Double?
    var ranges: [Range<String.Index>] = []
  }

  static func documents(from items: [Searchable]) -> [SearchDocument] {
    items.map { SearchDocument(id: $0.id, title: $0.title) }
  }

  /// Synchronous convenience wrapper kept for simple/test call sites that
  /// already have `HistoryItemDecorator` values in hand. Production code with
  /// large histories should prefer building `SearchDocument`s on the main
  /// actor and calling `match(query:mode:in:)` on a background task instead,
  /// since this function's matching cost scales with history size.
  func search(string: String, within: [Searchable]) -> [SearchResult] {
    guard !string.isEmpty else {
      return within.map { SearchResult(object: $0) }
    }

    let documents = Self.documents(from: within)
    let matches = match(query: string, mode: Defaults[.searchMode], in: documents)
    let byId = Dictionary(uniqueKeysWithValues: within.map { ($0.id, $0) })

    return matches.compactMap { match in
      guard let object = byId[match.id] else {
        return nil
      }
      return SearchResult(score: match.score, object: object, ranges: match.ranges)
    }
  }

  /// The core, pure matching function. Contains no shared mutable state, so
  /// it is safe to call from any thread/task.
  func match(query: String, mode: Mode, in documents: [SearchDocument]) -> [SearchMatch] {
    guard !query.isEmpty else {
      return documents.map { SearchMatch(id: $0.id, title: $0.title) }
    }

    switch mode {
    case .mixed, .fuzzy:
      // Both modes rank documents through the same tiered matcher: exact >
      // prefix > word-boundary substring > interior substring > fuzzy
      // subsequence. "Fuzzy" no longer special-cases contiguous matches with
      // a naive "closer to the start wins" score, and "Mixed" no longer
      // falls back through exact -> regex -> fuzzy, where one weak result at
      // an earlier stage could suppress every better result at a later one.
      return tieredSearch(query: query, in: documents)
    case .regexp:
      return literalMatch(query: query, in: documents, options: .regularExpression)
    case .exact:
      return literalMatch(query: query, in: documents, options: .caseInsensitive)
    }
  }

  private func literalMatch(
    query: String,
    in documents: [SearchDocument],
    options: NSString.CompareOptions
  ) -> [SearchMatch] {
    documents.compactMap { document in
      guard let range = document.title.range(of: query, options: options, range: nil, locale: nil) else {
        return nil
      }
      return SearchMatch(id: document.id, title: document.title, ranges: [range])
    }
  }

  private func tieredSearch(query: String, in documents: [SearchDocument]) -> [SearchMatch] {
    let terms = Self.tokenize(query)
    guard !terms.isEmpty else {
      return documents.map { SearchMatch(id: $0.id, title: $0.title) }
    }

    // A single matcher instance is reused across every document in this
    // call so its scratch buffers (sized to the largest window seen so far)
    // are not reallocated per item.
    let matcher = TieredMatcher()

    var scored: [(tier: Int, fineScore: Double, index: Int, match: SearchMatch)] = []
    scored.reserveCapacity(documents.count)

    for (index, document) in documents.enumerated() {
      guard let result = matcher.match(terms: terms, in: document) else {
        continue
      }
      scored.append((
        result.tier.rawValue,
        result.fineScore,
        index,
        SearchMatch(id: document.id, title: document.title, score: result.fineScore, ranges: result.ranges)
      ))
    }

    scored.sort { lhs, rhs in
      if lhs.tier != rhs.tier {
        return lhs.tier < rhs.tier
      }
      if lhs.fineScore != rhs.fineScore {
        return lhs.fineScore < rhs.fineScore
      }
      // Preserve clipboard order for equally relevant matches. It makes the
      // result list predictable while the query is being typed.
      return lhs.index < rhs.index
    }

    return scored.map(\.match)
  }

  /// Splits a query into AND-ed search terms. A double-quoted span is kept
  /// together as one literal phrase; everything else is split on whitespace.
  /// Repeated or trailing whitespace (the UI leaves a trailing space after a
  /// word-delete) produces no empty terms.
  private static func tokenize(_ query: String) -> [String] {
    var tokens: [String] = []
    var current = ""
    var inQuotes = false

    for character in query {
      if character == "\"" {
        inQuotes.toggle()
        continue
      }
      if character.isWhitespace && !inQuotes {
        if !current.isEmpty {
          tokens.append(current)
          current = ""
        }
      } else {
        current.append(character)
      }
    }
    if !current.isEmpty {
      tokens.append(current)
    }

    return tokens
  }
}

/// Ranks a document against a set of AND-ed search terms using one shared
/// normalization pipeline (fixed-locale case/diacritic/width folding) for
/// every tier, so the same query normalizes identically whether it ends up
/// classified as a substring or a fuzzy match.
///
/// Matches are ranked, best first, in tiers:
///   exact equality > prefix > word-boundary substring > interior substring
///   > fuzzy subsequence
/// A multi-term query's overall tier is its worst-matching term's tier
/// (every term must match), which is what makes "mixed" mode a genuine
/// blended ranking instead of a fallback chain.
///
/// The fuzzy tier scores with a modified Smith-Waterman-style alignment,
/// like fzf and VS Code's fuzzy matcher, rewarding word starts, camelCase
/// boundaries, exact case, and consecutive runs. Unlike a full O(query x
/// text) scan, the dynamic-programming table is bounded to the window
/// between the first possible match of the query's first character and the
/// last possible match of its last character -- a provable superset of
/// every valid alignment -- which keeps worst-case cost bounded regardless
/// of how long the surrounding text is.
private final class TieredMatcher {
  enum Tier: Int, Comparable {
    case exact
    case prefix
    case boundary
    case substring
    case fuzzy

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
  }

  struct Result {
    let tier: Tier
    let fineScore: Double
    let ranges: [Range<String.Index>]
  }

  private struct TermMatch {
    let tier: Tier
    let fineScore: Double
    let ranges: [Range<String.Index>]
  }

  private static let locale = Locale(identifier: "en_US_POSIX")
  private static let gapPenalty = 0.35
  private static let minimumFuzzySpan = 32
  private static let maximumFuzzySpanMultiplier = 7
  // Defensive cap on the bounded DP's cell count. Only reachable with a very
  // long query against a very long, sparsely-matching window; beyond it we
  // fall back to a cheap greedy alignment rather than allocate unbounded
  // scratch space.
  private static let cellCap = 50_000
  private static let noMatch = -Double.greatestFiniteMagnitude
  private static let fuzzyScoreBand = 500_000.0

  // Reusable scratch buffers, grown (never shrunk) across documents within a
  // single `tieredSearch` call.
  private var scoreRowPrev: [Double] = []
  private var scoreRowCurr: [Double] = []
  private var direction: [Int32] = []

  func match(terms: [String], in document: Search.SearchDocument) -> Result? {
    let chars = Array(document.title)
    guard !chars.isEmpty else {
      return nil
    }

    let folded = chars.map(Self.normalize)
    let boundaries = Self.boundaryFlags(chars)
    let originalIndices = Array(document.title.indices)

    var foldedJoined = ""
    var foldedToOriginal: [Int] = []
    foldedToOriginal.reserveCapacity(chars.count)
    for (index, piece) in folded.enumerated() {
      for _ in piece {
        foldedToOriginal.append(index)
      }
      foldedJoined += piece
    }

    var worstTier = Tier.exact
    var totalScore = 0.0
    var allRanges: [Range<String.Index>] = []

    for term in terms {
      guard let termMatch = matchTerm(
        term,
        chars: chars,
        folded: folded,
        boundaries: boundaries,
        originalIndices: originalIndices,
        foldedJoined: foldedJoined,
        foldedToOriginal: foldedToOriginal,
        title: document.title
      ) else {
        return nil
      }

      if termMatch.tier > worstTier {
        worstTier = termMatch.tier
      }
      totalScore += termMatch.fineScore
      allRanges.append(contentsOf: termMatch.ranges)
    }

    allRanges.sort { $0.lowerBound < $1.lowerBound }
    return Result(tier: worstTier, fineScore: totalScore, ranges: allRanges)
  }

  private func matchTerm(
    _ term: String,
    chars: [Character],
    folded: [String],
    boundaries: [Bool],
    originalIndices: [String.Index],
    foldedJoined: String,
    foldedToOriginal: [Int],
    title: String
  ) -> TermMatch? {
    let termChars = Array(term)
    guard !termChars.isEmpty else {
      return nil
    }
    let foldedTermJoined = termChars.map(Self.normalize).joined()
    guard !foldedTermJoined.isEmpty else {
      return nil
    }

    if foldedJoined == foldedTermJoined {
      return TermMatch(tier: .exact, fineScore: 0, ranges: [title.startIndex..<title.endIndex])
    }

    if foldedJoined.hasPrefix(foldedTermJoined) {
      let endOriginal = foldedTermJoined.count < foldedToOriginal.count
        ? foldedToOriginal[foldedTermJoined.count]
        : chars.count
      let end = endOriginal < originalIndices.count ? originalIndices[endOriginal] : title.endIndex
      return TermMatch(tier: .prefix, fineScore: 0, ranges: [originalIndices[0]..<end])
    }

    if let occurrence = Self.firstOccurrence(
      of: foldedTermJoined,
      in: foldedJoined,
      foldedToOriginal: foldedToOriginal,
      boundaries: boundaries
    ) {
      let start = originalIndices[occurrence.startChar]
      let end = occurrence.endChar < originalIndices.count ? originalIndices[occurrence.endChar] : title.endIndex
      return TermMatch(
        tier: occurrence.isBoundary ? .boundary : .substring,
        fineScore: Double(occurrence.startChar),
        ranges: [start..<end]
      )
    }

    return fuzzyMatch(
      termChars: termChars,
      chars: chars,
      folded: folded,
      originalIndices: originalIndices,
      title: title
    )
  }

  private func fuzzyMatch(
    termChars: [Character],
    chars: [Character],
    folded: [String],
    originalIndices: [String.Index],
    title: String
  ) -> TermMatch? {
    guard termChars.count <= chars.count else {
      return nil
    }

    let foldedTerm = termChars.map(Self.normalize)

    guard let windowStart = chars.indices.first(where: { folded[$0] == foldedTerm[0] }),
          let windowEnd = chars.indices.last(where: { folded[$0] == foldedTerm[foldedTerm.count - 1] }),
          windowStart <= windowEnd else {
      return nil
    }

    let windowFolded = Array(folded[windowStart...windowEnd])
    let windowLen = windowFolded.count
    let queryLen = foldedTerm.count

    guard queryLen <= windowLen else {
      return nil
    }

    guard windowLen * queryLen <= Self.cellCap else {
      return greedyFuzzyMatch(
        foldedTerm: foldedTerm,
        termChars: termChars,
        chars: chars,
        folded: folded,
        windowStart: windowStart,
        originalIndices: originalIndices,
        title: title
      )
    }

    if scoreRowPrev.count < windowLen {
      scoreRowPrev = Array(repeating: Self.noMatch, count: windowLen)
      scoreRowCurr = Array(repeating: Self.noMatch, count: windowLen)
    }
    if direction.count < windowLen * queryLen {
      direction = Array(repeating: -1, count: windowLen * queryLen)
    }

    for w in 0..<windowLen {
      scoreRowPrev[w] = Self.noMatch
    }

    for w in 0..<windowLen where windowFolded[w] == foldedTerm[0] {
      let globalIndex = windowStart + w
      scoreRowPrev[w] = Self.characterScore(
        at: globalIndex,
        in: chars,
        exactCase: chars[globalIndex] == termChars[0]
      ) - Double(globalIndex) * Self.gapPenalty
    }

    guard (0..<windowLen).contains(where: { scoreRowPrev[$0] > Self.noMatch / 2 }) else {
      return nil
    }

    for q in 1..<queryLen {
      for w in 0..<windowLen {
        scoreRowCurr[w] = Self.noMatch
      }

      var bestPreviousScore = Self.noMatch
      var bestPreviousIndex = -1

      for w in 0..<windowLen {
        let priorLocal = w - 1
        if priorLocal >= 0, scoreRowPrev[priorLocal] > Self.noMatch / 2 {
          let priorGlobal = windowStart + priorLocal
          let candidate = scoreRowPrev[priorLocal] + Double(priorGlobal) * Self.gapPenalty
          if candidate > bestPreviousScore {
            bestPreviousScore = candidate
            bestPreviousIndex = priorLocal
          }
        }

        guard windowFolded[w] == foldedTerm[q], bestPreviousIndex >= 0 else {
          continue
        }

        let globalIndex = windowStart + w
        let exactCase = chars[globalIndex] == termChars[q]
        let baseScore = Self.characterScore(at: globalIndex, in: chars, exactCase: exactCase)
          - Double(max(0, globalIndex - 1)) * Self.gapPenalty

        var chosenScore = bestPreviousScore + baseScore
        var chosenPreviousIndex = bestPreviousIndex

        if priorLocal >= 0, scoreRowPrev[priorLocal] > Self.noMatch / 2 {
          let consecutiveScore = scoreRowPrev[priorLocal]
            + Self.characterScore(at: globalIndex, in: chars, exactCase: exactCase)
            + 12
          if consecutiveScore > chosenScore {
            chosenScore = consecutiveScore
            chosenPreviousIndex = priorLocal
          }
        }

        scoreRowCurr[w] = chosenScore
        direction[q * windowLen + w] = Int32(chosenPreviousIndex)
      }

      swap(&scoreRowPrev, &scoreRowCurr)
    }

    guard let endLocal = (0..<windowLen).max(by: { scoreRowPrev[$0] < scoreRowPrev[$1] }),
          scoreRowPrev[endLocal] > Self.noMatch / 2 else {
      return nil
    }

    var localPositions: [Int] = []
    var current = endLocal
    for q in stride(from: queryLen - 1, through: 0, by: -1) {
      localPositions.append(current)
      if q > 0 {
        let previous = direction[q * windowLen + current]
        guard previous >= 0 else {
          return nil
        }
        current = Int(previous)
      }
    }
    localPositions.reverse()

    let globalPositions = localPositions.map { $0 + windowStart }
    guard let first = globalPositions.first, let last = globalPositions.last,
          last - first + 1 <= max(Self.minimumFuzzySpan, queryLen * Self.maximumFuzzySpanMultiplier) else {
      // A scattered subsequence is technically a match but a poor search
      // result: it produces unexplained single-letter highlights.
      return nil
    }

    let ranges = Self.buildRanges(from: globalPositions, originalIndices: originalIndices, title: title)
    let fineScore = max(0, Self.fuzzyScoreBand - scoreRowPrev[endLocal])
    return TermMatch(tier: .fuzzy, fineScore: fineScore, ranges: ranges)
  }

  /// A defensive fallback for pathologically large windows: finds the
  /// earliest valid greedy alignment (not necessarily the optimal one) in
  /// O(window length) instead of running the full DP.
  private func greedyFuzzyMatch(
    foldedTerm: [String],
    termChars: [Character],
    chars: [Character],
    folded: [String],
    windowStart: Int,
    originalIndices: [String.Index],
    title: String
  ) -> TermMatch? {
    var positions: [Int] = []
    var searchFrom = windowStart

    for (index, target) in foldedTerm.enumerated() {
      guard let position = (searchFrom..<chars.count).first(where: { folded[$0] == target }) else {
        return nil
      }
      positions.append(position)
      searchFrom = position + 1
      _ = index
    }

    guard let first = positions.first, let last = positions.last,
          last - first + 1 <= max(Self.minimumFuzzySpan, termChars.count * Self.maximumFuzzySpanMultiplier) else {
      return nil
    }

    let approximateScore = positions.enumerated().reduce(0.0) { total, pair in
      let (index, position) = pair
      return total + Self.characterScore(at: position, in: chars, exactCase: chars[position] == termChars[index])
    }

    let ranges = Self.buildRanges(from: positions, originalIndices: originalIndices, title: title)
    return TermMatch(tier: .fuzzy, fineScore: max(0, Self.fuzzyScoreBand - approximateScore), ranges: ranges)
  }

  private static func firstOccurrence(
    of term: String,
    in text: String,
    foldedToOriginal: [Int],
    boundaries: [Bool]
  ) -> (startChar: Int, endChar: Int, isBoundary: Bool)? {
    var searchRange = text.startIndex..<text.endIndex
    var firstOverall: (start: Int, end: Int)?

    while let found = text.range(of: term, options: .literal, range: searchRange) {
      let startPos = text.distance(from: text.startIndex, to: found.lowerBound)
      let endPos = text.distance(from: text.startIndex, to: found.upperBound)
      let startChar = foldedToOriginal[startPos]
      let endChar = endPos < foldedToOriginal.count ? foldedToOriginal[endPos] : (foldedToOriginal.last.map { $0 + 1 } ?? 0)

      if firstOverall == nil {
        firstOverall = (startChar, endChar)
      }
      if boundaries[startChar] {
        return (startChar, endChar, true)
      }

      searchRange = found.upperBound..<text.endIndex
    }

    guard let firstOverall else {
      return nil
    }
    return (firstOverall.start, firstOverall.end, false)
  }

  private static func boundaryFlags(_ chars: [Character]) -> [Bool] {
    var flags: [Bool] = []
    flags.reserveCapacity(chars.count)

    for index in chars.indices {
      if index == 0 {
        flags.append(true)
        continue
      }
      let previous = chars[index - 1]
      let isSeparator = previous.isWhitespace || previous.isPunctuation
        || previous == "/" || previous == "_" || previous == "-"
      let isCamelBoundary = String(chars[index]).rangeOfCharacter(from: .uppercaseLetters) != nil
        && String(previous).rangeOfCharacter(from: .lowercaseLetters) != nil
      flags.append(isSeparator || isCamelBoundary)
    }

    return flags
  }

  private static func normalize(_ character: Character) -> String {
    String(character).folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Self.locale)
  }

  private static func characterScore(at index: Int, in characters: [Character], exactCase: Bool) -> Double {
    var score = 1.0
    if index == 0 {
      score += 10
    } else {
      let previous = characters[index - 1]
      if previous.isWhitespace || previous.isPunctuation || previous == "/" || previous == "_" || previous == "-" {
        score += 8
      } else if String(characters[index]).rangeOfCharacter(from: .uppercaseLetters) != nil,
                String(previous).rangeOfCharacter(from: .lowercaseLetters) != nil {
        score += 7
      }
    }
    if exactCase {
      score += 1
    }
    return score
  }

  private static func buildRanges(
    from positions: [Int],
    originalIndices: [String.Index],
    title: String
  ) -> [Range<String.Index>] {
    var ranges: [Range<String.Index>] = []
    var start: Int?
    var previous: Int?

    for position in positions {
      if let previous, position != previous + 1 {
        ranges.append(makeRange(from: start!, through: previous, originalIndices: originalIndices, title: title))
        start = position
      } else if start == nil {
        start = position
      }
      previous = position
    }

    if let start, let previous {
      ranges.append(makeRange(from: start, through: previous, originalIndices: originalIndices, title: title))
    }

    return ranges
  }

  private static func makeRange(
    from start: Int,
    through end: Int,
    originalIndices: [String.Index],
    title: String
  ) -> Range<String.Index> {
    originalIndices[start]..<(end + 1 < originalIndices.count ? originalIndices[end + 1] : title.endIndex)
  }
}
