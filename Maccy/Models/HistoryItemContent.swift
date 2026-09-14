import Foundation
import SwiftData

@Model
class HistoryItemContent {
  var type: String = ""
  var value: Data?

  // Index of the NSPasteboardItem this content was read from, so multiple
  // pasteboard items (table cells, multi-selection) can be told apart from
  // a single item's alternate representations (RTF + HTML + plain text).
  var itemIndex: Int = 0

  @Relationship
  var item: HistoryItem?

  init(type: String, value: Data? = nil, itemIndex: Int = 0) {
    self.type = type
    self.value = value
    self.itemIndex = itemIndex
  }
}
