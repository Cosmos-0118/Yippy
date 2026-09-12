import AppKit
import Defaults

class Search {
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

  private let fuzzySearchLimit = 5_000

  func search(string: String, within: [Searchable]) -> [SearchResult] {
    guard !string.isEmpty else {
      return within.map { SearchResult(object: $0) }
    }

    switch Defaults[.searchMode] {
    case .mixed:
      return mixedSearch(string: string, within: within)
    case .regexp:
      return simpleSearch(string: string, within: within, options: .regularExpression)
    case .fuzzy:
      return fuzzySearch(string: string, within: within)
    default:
      return simpleSearch(string: string, within: within, options: .caseInsensitive)
    }
  }

  private func fuzzySearch(string: String, within: [Searchable]) -> [SearchResult] {
    let searchResults: [(index: Int, result: SearchResult)] = within.enumerated().compactMap { index, item in
      guard let result = fuzzySearch(for: string, in: item.title, of: item) else {
        return nil
      }
      return (index, result)
    }

    // Preserve clipboard order for equally relevant matches. It makes the
    // result list predictable while the query is being typed.
    return searchResults.sorted {
      ($0.result.score ?? 0, $0.index) < ($1.result.score ?? 0, $1.index)
    }.map(\.result)
  }

  private func fuzzySearch(
    for query: String,
    in searchString: String,
    of item: Searchable
  ) -> SearchResult? {
    let searchableText = String(searchString.prefix(fuzzySearchLimit))
    guard let match = FuzzyMatcher.match(query: query, in: searchableText) else {
      return nil
    }

    // SearchResult sorts ascending. FuzzyMatcher produces a relevance score
    // where higher is better, so negate it at this boundary.
    return SearchResult(score: -match.score, object: item, ranges: match.ranges)
  }

  private func simpleSearch(
    string: String,
    within: [Searchable],
    options: NSString.CompareOptions
  ) -> [SearchResult] {
    return within.compactMap { simpleSearch(for: string, in: $0.title, of: $0, options: options) }
  }

  private func simpleSearch(
    for string: String,
    in searchString: String,
    of item: Searchable,
    options: NSString.CompareOptions
  ) -> SearchResult? {
    if let range = searchString.range(of: string, options: options, range: nil, locale: nil) {
      return SearchResult(object: item, ranges: [range])
    } else {
      return nil
    }
  }

  private func mixedSearch(string: String, within: [Searchable]) -> [SearchResult] {
    var results = simpleSearch(string: string, within: within, options: .caseInsensitive)
    guard results.isEmpty else {
      return results
    }

    results = simpleSearch(string: string, within: within, options: .regularExpression)
    guard results.isEmpty else {
      return results
    }

    results = fuzzySearch(string: string, within: within)
    guard results.isEmpty else {
      return results
    }

    return []
  }
}

/// A deterministic subsequence matcher for command-palette style search.
///
/// It intentionally does not use edit-distance matching: a query must still
/// describe characters in order, which prevents surprising results and makes
/// every colored character an honest explanation of why an item matched.
private enum FuzzyMatcher {
  struct Match {
    let score: Double
    let ranges: [Range<String.Index>]
  }

  private static let noMatch = -Double.greatestFiniteMagnitude
  private static let gapPenalty = 0.35
  private static let maximumFuzzyQueryLength = 64

  static func match(query: String, in text: String) -> Match? {
    // A contiguous hit is both the clearest result and a fast path for long
    // pasted queries. It also prevents a very long query from allocating an
    // impractically large dynamic-programming table.
    if let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) {
      let location = text.distance(from: text.startIndex, to: range.lowerBound)
      return Match(score: 1_000 - Double(location), ranges: [range])
    }

    let queryCharacters = Array(query)
    let textCharacters = Array(text)
    guard !queryCharacters.isEmpty, !textCharacters.isEmpty,
          queryCharacters.count <= textCharacters.count,
          queryCharacters.count <= maximumFuzzyQueryLength else {
      return nil
    }

    let normalizedQuery = queryCharacters.map(normalize)
    let normalizedText = textCharacters.map(normalize)
    guard !normalizedQuery.contains(where: \.isEmpty), !normalizedText.contains(where: \.isEmpty) else {
      return nil
    }

    var scores = Array(
      repeating: Array(repeating: noMatch, count: textCharacters.count),
      count: queryCharacters.count
    )
    var previous = Array(
      repeating: Array(repeating: -1, count: textCharacters.count),
      count: queryCharacters.count
    )

    for textIndex in textCharacters.indices where normalizedText[textIndex] == normalizedQuery[0] {
      scores[0][textIndex] = characterScore(
        at: textIndex,
        in: textCharacters,
        exactCase: textCharacters[textIndex] == queryCharacters[0]
      ) - Double(textIndex) * gapPenalty
    }

    guard scores[0].contains(where: { $0 > noMatch / 2 }) else {
      return nil
    }

    for queryIndex in 1..<queryCharacters.count {
      var bestPreviousScore = noMatch
      var bestPreviousIndex = -1

      for textIndex in textCharacters.indices {
        let priorIndex = textIndex - 1
        if priorIndex >= 0, scores[queryIndex - 1][priorIndex] > noMatch / 2 {
          let candidate = scores[queryIndex - 1][priorIndex] + Double(priorIndex) * gapPenalty
          if candidate > bestPreviousScore {
            bestPreviousScore = candidate
            bestPreviousIndex = priorIndex
          }
        }

        guard normalizedText[textIndex] == normalizedQuery[queryIndex], bestPreviousIndex >= 0 else {
          continue
        }

        let baseScore = characterScore(
          at: textIndex,
          in: textCharacters,
          exactCase: textCharacters[textIndex] == queryCharacters[queryIndex]
        ) - Double(textIndex - 1) * gapPenalty

        var chosenScore = bestPreviousScore + baseScore
        var chosenPreviousIndex = bestPreviousIndex

        if priorIndex >= 0, scores[queryIndex - 1][priorIndex] > noMatch / 2 {
          let consecutiveScore = scores[queryIndex - 1][priorIndex]
            + characterScore(
              at: textIndex,
              in: textCharacters,
              exactCase: textCharacters[textIndex] == queryCharacters[queryIndex]
            )
            + 12
          if consecutiveScore > chosenScore {
            chosenScore = consecutiveScore
            chosenPreviousIndex = priorIndex
          }
        }

        scores[queryIndex][textIndex] = chosenScore
        previous[queryIndex][textIndex] = chosenPreviousIndex
      }
    }

    guard let endIndex = scores[queryCharacters.count - 1].indices.max(by: {
      scores[queryCharacters.count - 1][$0] < scores[queryCharacters.count - 1][$1]
    }), scores[queryCharacters.count - 1][endIndex] > noMatch / 2 else {
      return nil
    }

    var matchIndexes: [Int] = []
    var currentIndex = endIndex
    for queryIndex in stride(from: queryCharacters.count - 1, through: 0, by: -1) {
      matchIndexes.append(currentIndex)
      currentIndex = previous[queryIndex][currentIndex]
    }

    return Match(score: scores[queryCharacters.count - 1][endIndex], ranges: ranges(for: matchIndexes.reversed(), in: text))
  }

  private static func normalize(_ character: Character) -> String {
    String(character).folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
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

  private static func ranges(for indexes: ReversedCollection<[Int]>, in text: String) -> [Range<String.Index>] {
    let characterIndexes = Array(text.indices)
    var ranges: [Range<String.Index>] = []
    var start: Int?
    var previous: Int?

    for index in indexes {
      if let previous, index != previous + 1 {
        ranges.append(makeRange(from: start!, through: previous, characterIndexes: characterIndexes, text: text))
        start = index
      } else if start == nil {
        start = index
      }
      previous = index
    }

    if let start, let previous {
      ranges.append(makeRange(from: start, through: previous, characterIndexes: characterIndexes, text: text))
    }
    return ranges
  }

  private static func makeRange(
    from start: Int,
    through end: Int,
    characterIndexes: [String.Index],
    text: String
  ) -> Range<String.Index> {
    characterIndexes[start]..<(end + 1 < characterIndexes.count ? characterIndexes[end + 1] : text.endIndex)
  }
}
