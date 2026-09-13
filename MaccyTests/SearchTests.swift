import XCTest
import Defaults
@testable import Maccy

class SearchTests: XCTestCase {
  let savedSearchMode = Defaults[.searchMode]
  var items: [Search.Searchable]!

  override func tearDown() {
    super.tearDown()
    Defaults[.searchMode] = savedSearchMode
  }

  @MainActor
  func testSimpleSearch() { // swiftlint:disable:this function_body_length
    Defaults[.searchMode] = Search.Mode.exact
    items = [
      HistoryItemDecorator(historyItemWithTitle("foo bar baz")),
      HistoryItemDecorator(historyItemWithTitle("foo bar zaz")),
      HistoryItemDecorator(historyItemWithTitle("xxx yyy zzz"))
    ]

    XCTAssertEqual(search(""), [
      Search.SearchResult(score: nil, object: items[0], ranges: []),
      Search.SearchResult(score: nil, object: items[1], ranges: []),
      Search.SearchResult(score: nil, object: items[2], ranges: [])
    ])
    XCTAssertEqual(search("z"), [
      Search.SearchResult(
        score: nil,
        object: items[0],
        ranges: [range(from: 10, to: 10, in: items[0])]
      ),
      Search.SearchResult(
        score: nil,
        object: items[1],
        ranges: [range(from: 8, to: 8, in: items[1])]
      ),
      Search.SearchResult(
        score: nil,
        object: items[2],
        ranges: [range(from: 8, to: 8, in: items[2])]
      )
    ])
    XCTAssertEqual(search("foo"), [
      Search.SearchResult(
        score: nil,
        object: items[0],
        ranges: [range(from: 0, to: 2, in: items[0])]
      ),
      Search.SearchResult(
        score: nil,
        object: items[1],
        ranges: [range(from: 0, to: 2, in: items[1])]
      )
    ])
    XCTAssertEqual(search("za"), [
      Search.SearchResult(
        score: nil,
        object: items[1],
        ranges: [range(from: 8, to: 9, in: items[1])]
      )
    ])
    XCTAssertEqual(search("yyy"), [
      Search.SearchResult(
        score: nil,
        object: items[2],
        ranges: [range(from: 4, to: 6, in: items[2])]
      )
    ])
    XCTAssertEqual(search("fbb"), [])
    XCTAssertEqual(search("m"), [])
  }

  @MainActor
  func testFuzzySearch() {
    Defaults[.searchMode] = Search.Mode.fuzzy
    items = [
      HistoryItemDecorator(historyItemWithTitle("foo bar baz")),
      HistoryItemDecorator(historyItemWithTitle("foo bar zaz")),
      HistoryItemDecorator(historyItemWithTitle("xxx yyy zzz"))
    ]

    XCTAssertEqual(search(""), [
      Search.SearchResult(score: nil, object: items[0], ranges: []),
      Search.SearchResult(score: nil, object: items[1], ranges: []),
      Search.SearchResult(score: nil, object: items[2], ranges: [])
    ])
    XCTAssertEqual(search("foo").map(\.object), [items[0], items[1]])
    XCTAssertEqual(search("za").map(\.object), [items[1]])

    let fbb = search("fbb")
    XCTAssertEqual(fbb.map(\.object), [items[0]])
    XCTAssertEqual(fbb[0].ranges, [
      range(from: 0, to: 0, in: items[0]),
      range(from: 4, to: 4, in: items[0]),
      range(from: 8, to: 8, in: items[0])
    ])

    // Only the characters that explain a fuzzy match are highlighted.
    XCTAssertEqual(search("z")[0].ranges, [range(from: 8, to: 8, in: items[1])])
    XCTAssertEqual(search("m"), [])
  }

  @MainActor
  func testFuzzySearchRanksWordStartsAndHandlesDiacritics() {
    Defaults[.searchMode] = Search.Mode.fuzzy
    items = [
      HistoryItemDecorator(historyItemWithTitle("open system settings")),
      HistoryItemDecorator(historyItemWithTitle("applicationSettings")),
      HistoryItemDecorator(historyItemWithTitle("Café résumé"))
    ]

    XCTAssertEqual(search("os").map(\.object), [items[0], items[1]])
    XCTAssertEqual(search("cafe").map(\.object), [items[2]])
    XCTAssertEqual(search("cafe")[0].ranges, [range(from: 0, to: 3, in: items[2])])

    let scattered = HistoryItemDecorator(historyItemWithTitle(
      "c" + String(repeating: "x", count: 60) + "hanges"
    ))
    items.append(scattered)
    XCTAssertFalse(search("changes").contains { $0.object == scattered })
  }

  @MainActor
  func testRegexpSearch() { // swiftlint:disable:this function_body_length
    Defaults[.searchMode] = Search.Mode.regexp
    items = [
      HistoryItemDecorator(historyItemWithTitle("foo bar baz")),
      HistoryItemDecorator(historyItemWithTitle("foo bar zaz")),
      HistoryItemDecorator(historyItemWithTitle("xxx yyy zzz"))
    ]

    XCTAssertEqual(search(""), [
      Search.SearchResult(score: nil, object: items[0], ranges: []),
      Search.SearchResult(score: nil, object: items[1], ranges: []),
      Search.SearchResult(score: nil, object: items[2], ranges: [])
    ])
    XCTAssertEqual(search("z+"), [
      Search.SearchResult(
        score: nil,
        object: items[0],
        ranges: [range(from: 10, to: 10, in: items[0])]
      ),
      Search.SearchResult(
        score: nil,
        object: items[1],
        ranges: [range(from: 8, to: 8, in: items[1])]
      ),
      Search.SearchResult(
        score: nil,
        object: items[2],
        ranges: [range(from: 8, to: 10, in: items[2])]
      )
    ])
    XCTAssertEqual(search("z*"), [
      Search.SearchResult(
        score: nil,
        object: items[0],
        ranges: [range(from: 0, to: -1, in: items[0])]
      ),
      Search.SearchResult(
        score: nil,
        object: items[1],
        ranges: [range(from: 0, to: -1, in: items[1])]
      ),
      Search.SearchResult(
        score: nil,
        object: items[2],
        ranges: [range(from: 0, to: -1, in: items[2])]
      )
    ])
    XCTAssertEqual(search("^foo"), [
      Search.SearchResult(
        score: nil,
        object: items[0], ranges: [range(from: 0, to: 2, in: items[0])]
      ),
      Search.SearchResult(
        score: nil,
        object: items[1], ranges: [range(from: 0, to: 2, in: items[1])]
      )
    ])
    XCTAssertEqual(search(" za"), [
      Search.SearchResult(
        score: nil,
        object: items[1],
        ranges: [range(from: 7, to: 9, in: items[1])]
      )
    ])
    XCTAssertEqual(search("[y]+"), [
      Search.SearchResult(
        score: nil,
        object: items[2],
        ranges: [range(from: 4, to: 6, in: items[2])]
      )
    ])
    XCTAssertEqual(search("fbb"), [])
    XCTAssertEqual(search("m"), [])
  }

  @MainActor
  func testFuzzyModeRanksWordBoundaryAboveInteriorSubstring() {
    Defaults[.searchMode] = Search.Mode.fuzzy
    items = [
      // "settings" occurs interior/mid-word here...
      HistoryItemDecorator(historyItemWithTitle("assetsettingsmanager")),
      // ...but at a word boundary here, so it must rank first despite
      // appearing later in the (irrelevant) creation order.
      HistoryItemDecorator(historyItemWithTitle("open settings"))
    ]

    XCTAssertEqual(search("settings").map(\.object), [items[1], items[0]])
  }

  @MainActor
  func testMixedModeBlendsRatherThanFallsBackToWeakestStage() {
    Defaults[.searchMode] = Search.Mode.mixed
    items = [
      // A literal substring exists here, but only interior/mid-word.
      HistoryItemDecorator(historyItemWithTitle("assetsettingsmanager")),
      // A word-boundary literal substring, which should outrank the above
      // even though both are found by the same (non-regex) literal pass.
      HistoryItemDecorator(historyItemWithTitle("open settings"))
    ]

    // Previously, mixed mode returned the first non-empty stage's results
    // verbatim (unranked among themselves beyond original order), so a
    // weak interior match could sit ahead of a strong boundary match.
    XCTAssertEqual(search("settings").map(\.object), [items[1], items[0]])
  }

  @MainActor
  func testMixedModeDoesNotImplicitlyRunRegex() {
    Defaults[.searchMode] = Search.Mode.mixed
    items = [
      HistoryItemDecorator(historyItemWithTitle("foo bar baz"))
    ]

    // "ba." is a valid regex (matches "bar"/"baz" via the wildcard) but
    // contains no literal "." character and no fuzzy-matchable subsequence
    // against this title, since the title has no "." anywhere. Previously,
    // mixed mode tried regex as an implicit stage between exact and fuzzy,
    // which would have surfaced this item.
    XCTAssertEqual(search("ba.").map(\.object), [])
  }

  @MainActor
  func testFuzzyModeTreatsSpaceSeparatedTermsAsAnd() {
    Defaults[.searchMode] = Search.Mode.fuzzy
    items = [
      HistoryItemDecorator(historyItemWithTitle("open system settings")),
      HistoryItemDecorator(historyItemWithTitle("open settings only")),
      HistoryItemDecorator(historyItemWithTitle("system only"))
    ]

    // Both terms must match somewhere in the title for the item to surface.
    XCTAssertEqual(search("open settings").map(\.object), [items[1], items[0]])
  }

  @MainActor
  func testFuzzyModeQuotedPhraseIsMatchedLiterally() {
    Defaults[.searchMode] = Search.Mode.fuzzy
    items = [
      HistoryItemDecorator(historyItemWithTitle("settings, open")),
      HistoryItemDecorator(historyItemWithTitle("open settings"))
    ]

    XCTAssertEqual(search("\"open settings\"").map(\.object), [items[1]])
  }

  @MainActor
  func testFuzzySearchHandlesLongNonContiguousQueryWithoutHardCutoff() {
    Defaults[.searchMode] = Search.Mode.fuzzy
    // Previously, any subsequence query longer than 64 characters was
    // rejected outright, even when the text plainly supported it.
    let queryCharacters = (0..<70).map { Character(UnicodeScalar(97 + $0 % 26)!) }
    let query = String(queryCharacters)
    let text = queryCharacters.map(String.init).joined(separator: "-")
    items = [HistoryItemDecorator(historyItemWithTitle(text))]

    XCTAssertEqual(search(query).map(\.object), [items[0]])
  }

  @MainActor
  func testFuzzySearchPerformanceStaysBounded() {
    Defaults[.searchMode] = Search.Mode.fuzzy
    // A long, non-contiguous query scattered across a long title forces
    // every item through the DP scorer (not a substring fast path) with a
    // wide match window, mirroring the audit's worst-case shape -- long
    // titles, genuinely fuzzy queries -- where the old implementation
    // allocated a fresh pair of query-length x title-length matrices per
    // candidate on every keystroke.
    let queryCharacters = (0..<70).map { Character(UnicodeScalar(97 + $0 % 26)!) }
    let query = String(queryCharacters)
    let fillerBetweenLetters = String(repeating: "x", count: 3)
    let scattered = queryCharacters.map(String.init).joined(separator: fillerBetweenLetters)
    items = (0..<300).map { index in
      HistoryItemDecorator(historyItemWithTitle("item \(index) \(scattered)"))
    }

    let start = Date()
    let results = search(query)
    let elapsed = Date().timeIntervalSince(start)

    XCTAssertEqual(results.count, items.count)
    // A very generous bound: this is a debug-build regression guard against
    // a return to per-item unbounded matrix allocation, not an assertion of
    // the audit's release-mode latency targets (measure those in Release).
    XCTAssertLessThan(elapsed, 8.0)
  }

  private func search(_ string: String) -> [Search.SearchResult] {
    return Search().search(string: string, within: items)
  }

  // swiftlint:disable:next identifier_name
  private func range(from: Int, to: Int, in item: HistoryItemDecorator) -> Range<String.Index> {
    let startIndex = item.title.startIndex
    let lowerBound = item.title.index(startIndex, offsetBy: from)
    let upperBound = item.title.index(startIndex, offsetBy: to + 1)

    return lowerBound..<upperBound
  }

  @MainActor
  private func historyItemWithTitle(_ value: String?) -> HistoryItem {
    let contents = [
      HistoryItemContent(
        type: NSPasteboard.PasteboardType.string.rawValue,
        value: value?.data(using: .utf8)
      )
    ]
    let item = HistoryItem()
    Storage.shared.context.insert(item)
    item.contents = contents
    item.title = item.generateTitle()

    return item
  }
}
