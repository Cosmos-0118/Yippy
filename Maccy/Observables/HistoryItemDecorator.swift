import AppKit.NSWorkspace
import Defaults
import Foundation
import ImageIO
import Observation
import Sauce

@Observable
class HistoryItemDecorator: Identifiable, Hashable, HasVisibility {
  static func == (lhs: HistoryItemDecorator, rhs: HistoryItemDecorator) -> Bool {
    return lhs.id == rhs.id
  }

  static var previewImageSize: NSSize { NSScreen.forPopup?.visibleFrame.size ?? NSSize(width: 2048, height: 1536) }
  static var thumbnailImageSize: NSSize { NSSize(width: 340, height: Defaults[.imageMaxHeight]) }

  let id = UUID()

  var title: String = ""
  var attributedTitle: AttributedString?

  var isVisible: Bool = true
  var selectionIndex: Int = -1
  var isSelected: Bool {
    return selectionIndex != -1
  }
  var shortcuts: [KeyShortcut] = []

  // Cached per bundle identifier -- like `ApplicationImageCache` -- rather
  // than resolved once per decorator at `init`: `History.load()` builds a
  // decorator for every fetched item (up to ~1000) up front, most of which
  // are never rendered, so eagerly resolving this for every one of them
  // would move `NSWorkspace` Launch Services lookups onto the launch path
  // to save re-running them for the handful of rows actually shown. This
  // still turns every *repeat* access (e.g. `accessibilityLabel`, read on
  // every row render) into a dictionary lookup instead of a fresh query.
  var application: String? {
    if item.universalClipboard {
      return "iCloud"
    }
    guard let bundle = item.application else {
      return nil
    }
    return Self.cachedApplicationName(forBundleIdentifier: bundle)
  }

  private static var applicationNameCache: [String: String] = [:]

  private static func cachedApplicationName(forBundleIdentifier bundleIdentifier: String) -> String? {
    if let cached = applicationNameCache[bundleIdentifier] {
      return cached
    }
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
      return nil
    }
    let name = url.deletingPathExtension().lastPathComponent
    applicationNameCache[bundleIdentifier] = name
    return name
  }

  var hasImage: Bool { item.image != nil }

  var previewImageGenerationTask: Task<(), Error>?
  var thumbnailImageGenerationTask: Task<(), Error>?
  var previewImage: NSImage?
  var previewText: String {
    item.previewableText
  }
  var thumbnailImage: NSImage?
  var applicationImage: ApplicationImage

  // 10k characters seems to be more than enough on large displays
  var text: String { previewText.shortened(to: 10_000) }

  var isPinned: Bool { item.pin != nil }
  var isUnpinned: Bool { item.pin == nil }

  func hash(into hasher: inout Hasher) {
    // We need to hash title and attributedTitle, so SwiftUI knows it needs to update the view if they chage
    hasher.combine(id)
    hasher.combine(title)
    hasher.combine(attributedTitle)
  }

  private(set) var item: HistoryItem
  
  var multiSelectionIndex: Int? {
    guard AppState.shared.navigator.isMultiSelectInProgress else {
      return nil
    }
    return selectionIndex
  }
  
  // Describe the complete item independently of its potentially truncated visual content.
  var accessibilityLabel: String {
    var parts: [String] = []
    if hasImage, let image = item.image {
      let size = image.pixelSize
      parts.append(String(format: NSLocalizedString("history_item_image_accessibility_label_no_app", comment: ""), Int(size.width), Int(size.height)))
    } else {
      parts.append(title)
    }
    if let application = application {
      parts.append(application)
    }
    if isPinned {
      parts.append(NSLocalizedString("history_item_pinned_accessibility_value", comment: ""))
    }
    if let index = multiSelectionIndex {
      parts.append(String(format: NSLocalizedString("history_item_selected_accessibility_value", comment: ""), index + 1, AppState.shared.navigator.selection.count))
    }
    return parts.joined(separator: ", ")
  }

  init(_ item: HistoryItem, shortcuts: [KeyShortcut] = []) {
    self.item = item
    self.shortcuts = shortcuts
    self.title = item.title
    self.applicationImage = ApplicationImageCache.shared.getImage(item: item)

    synchronizeItemPin()
    synchronizeItemTitle()
  }

  // `item` is a SwiftData model and can only be touched on the main actor,
  // so this reads the raw `Data` here (a plain, Sendable value) and hands
  // that -- not the model -- across to the background decode below. Reading
  // `item.imageData` (not `item.image`) is what actually keeps the full
  // decode off the main actor: `item.image` (Models/HistoryItem.swift)
  // decodes and caches a full-resolution `NSImage` as a side effect of just
  // checking non-nil, which would defeat this entirely.
  @MainActor
  func ensureThumbnailImage() {
    guard thumbnailImage == nil else {
      return
    }
    guard thumbnailImageGenerationTask == nil else {
      return
    }
    guard let data = item.imageData else {
      return
    }
    let scale = Self.mainScreenScale()
    let maxPixelSize = Self.maxPixelSize(for: HistoryItemDecorator.thumbnailImageSize, scale: scale)
    thumbnailImageGenerationTask = Task { [weak self] in
      let image = await Self.downsampledImage(data: data, maxPixelSize: maxPixelSize, scale: scale)
      guard let self, !Task.isCancelled else { return }
      self.thumbnailImage = image
      // Deliberately not cleared to nil here (matching the previous
      // behavior this replaced): a permanently-undecodable image would
      // otherwise retry its decode on every row appearance forever.
    }
  }

  @MainActor
  func ensurePreviewImage() {
    guard previewImage == nil else {
      return
    }
    guard previewImageGenerationTask == nil else {
      return
    }
    guard let data = item.imageData else {
      return
    }
    let scale = Self.mainScreenScale()
    let maxPixelSize = Self.maxPixelSize(for: HistoryItemDecorator.previewImageSize, scale: scale)
    previewImageGenerationTask = Task { [weak self] in
      let image = await Self.downsampledImage(data: data, maxPixelSize: maxPixelSize, scale: scale)
      guard let self, !Task.isCancelled else { return }
      self.previewImage = image
    }
  }

  @MainActor
  private static func mainScreenScale() -> CGFloat {
    NSScreen.main?.backingScaleFactor ?? 2
  }

  @MainActor
  private static func maxPixelSize(for size: NSSize, scale: CGFloat) -> CGFloat {
    max(size.width, size.height) * scale
  }

  /// Downsamples off the main actor using Image I/O, which decodes directly
  /// to the target pixel size instead of first fully decoding the source
  /// image the way `NSImage.resized(to:)` (still used by `sizeImages()`)
  /// does -- the full decode plus draw-based resize is exactly the
  /// main-actor CPU cost that made scrolling image-heavy history hitch.
  nonisolated private static func downsampledImage(data: Data, maxPixelSize: CGFloat, scale: CGFloat) async -> NSImage? {
    await Task.detached(priority: .userInitiated) {
      guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
        return nil
      }
      let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true
      ]
      guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
        return nil
      }
      // `maxPixelSize` was scaled up for the screen's backing scale, so the
      // resulting `CGImage` is in device pixels -- divide back out to get
      // the logical point size `NSImage.size` (and every consumer sizing a
      // view off it) expects, or this renders 2x too large on Retina.
      let pointSize = NSSize(
        width: CGFloat(thumbnail.width) / scale,
        height: CGFloat(thumbnail.height) / scale
      )
      return NSImage(cgImage: thumbnail, size: pointSize)
    }.value
  }

  @MainActor
  func asyncGetPreviewImage() async -> NSImage? {
    if let image = previewImage {
      return image
    }
    ensurePreviewImage()
    _ = await previewImageGenerationTask?.result
    return previewImage
  }

  @MainActor
  func cleanupImages() {
    thumbnailImageGenerationTask?.cancel()
    previewImageGenerationTask?.cancel()
    thumbnailImage?.recache()
    previewImage?.recache()
    thumbnailImage = nil
    previewImage = nil
    item.clearDecodedImageCache()
  }

  @MainActor
  private func generateThumbnailImage() {
    guard let image = item.image else {
      return
    }
    thumbnailImage = image.resized(to: HistoryItemDecorator.thumbnailImageSize)
  }

  @MainActor
  private func generatePreviewImage() {
    guard let image = item.image else {
      return
    }
    previewImage = image.resized(to: HistoryItemDecorator.previewImageSize)
  }

  @MainActor
  func sizeImages() {
    generatePreviewImage()
    generateThumbnailImage()
  }

  func highlight(_ query: String, _ ranges: [Range<String.Index>]) {
    guard !query.isEmpty, !title.isEmpty else {
      attributedTitle = nil
      return
    }

    let display = matchFocusedDisplay(for: ranges)
    var attributedString = AttributedString(display.text)
    for range in display.ranges {
      if let lowerBound = AttributedString.Index(range.lowerBound, within: attributedString),
         let upperBound = AttributedString.Index(range.upperBound, within: attributedString) {
        switch Defaults[.highlightMatch] {
        case .bold:
          attributedString[lowerBound..<upperBound].font = .bold(.body)()
        case .italic:
          attributedString[lowerBound..<upperBound].font = .italic(.body)()
        case .underline:
          attributedString[lowerBound..<upperBound].underlineStyle = .single
        case .color:
          // A foreground accent leaves the row's selection state intact and
          // makes fuzzy subsequences readable instead of looking like text
          // selection markers.
          attributedString[lowerBound..<upperBound].foregroundColor = .systemYellow
          attributedString[lowerBound..<upperBound].font = .bold(.body)()
        }
      }
    }

    attributedTitle = attributedString
  }

  /// Builds a short, search-specific title that keeps the best match visible.
  /// The full title remains on `item` for copying and accessibility; only the
  /// one-line visual representation is shortened.
  private func matchFocusedDisplay(for ranges: [Range<String.Index>]) -> (text: String, ranges: [Range<String.Index>]) {
    let validRanges = ranges.filter { $0.lowerBound >= title.startIndex && $0.upperBound <= title.endIndex }
    guard let focalRange = densestMatchRange(in: validRanges) else {
      return (title.shortened(to: Self.maximumRenderedTitleLength), validRanges)
    }

    let matchOffset = title.distance(from: title.startIndex, to: focalRange.upperBound)
    guard title.count > Self.matchFocusedDisplayLimit || matchOffset > Self.safeVisibleMatchOffset else {
      return (title.shortened(to: Self.maximumRenderedTitleLength), validRanges)
    }

    let focalLength = title.distance(from: focalRange.lowerBound, to: focalRange.upperBound)
    let availableContext = max(0, Self.matchFocusedDisplayLimit - focalLength)
    let leadingContext = min(Self.leadingMatchContext, availableContext / 3)
    let trailingContext = availableContext - leadingContext
    let start = title.index(focalRange.lowerBound, offsetBy: -leadingContext, limitedBy: title.startIndex) ?? title.startIndex
    let end = title.index(focalRange.upperBound, offsetBy: trailingContext, limitedBy: title.endIndex) ?? title.endIndex
    let prefix = start > title.startIndex ? "… " : ""
    let suffix = end < title.endIndex ? " …" : ""
    let visibleText = String(title[start..<end])
    let displayText = prefix + visibleText + suffix

    let displayRanges = validRanges.compactMap { range -> Range<String.Index>? in
      guard range.lowerBound < end, range.upperBound > start else {
        return nil
      }
      let lowerBound = range.lowerBound < start ? start : range.lowerBound
      let upperBound = range.upperBound > end ? end : range.upperBound
      let lowerOffset = title.distance(from: start, to: lowerBound) + prefix.count
      let upperOffset = title.distance(from: start, to: upperBound) + prefix.count
      let displayStart = displayText.index(displayText.startIndex, offsetBy: lowerOffset)
      let displayEnd = displayText.index(displayText.startIndex, offsetBy: upperOffset)
      return displayStart..<displayEnd
    }

    return (displayText, displayRanges)
  }

  private func densestMatchRange(in ranges: [Range<String.Index>]) -> Range<String.Index>? {
    let sortedRanges = ranges.sorted { $0.lowerBound < $1.lowerBound }
    guard var current = sortedRanges.first else {
      return nil
    }

    var candidates: [Range<String.Index>] = []
    for range in sortedRanges.dropFirst() {
      let gap = title.distance(from: current.upperBound, to: range.lowerBound)
      if gap <= Self.matchClusterGap {
        current = current.lowerBound..<max(current.upperBound, range.upperBound)
      } else {
        candidates.append(current)
        current = range
      }
    }
    candidates.append(current)

    return candidates.max { lhs, rhs in
      let lhsLength = title.distance(from: lhs.lowerBound, to: lhs.upperBound)
      let rhsLength = title.distance(from: rhs.lowerBound, to: rhs.upperBound)
      if lhsLength == rhsLength {
        return lhs.lowerBound > rhs.lowerBound
      }
      return lhsLength < rhsLength
    }
  }

  private static let maximumRenderedTitleLength = 500
  // The popup is commonly only wide enough for roughly one short sentence.
  // Keep the match early in that sentence so tail truncation cannot hide it.
  private static let matchFocusedDisplayLimit = 80
  private static let leadingMatchContext = 18
  private static let safeVisibleMatchOffset = 52
  private static let matchClusterGap = 24

  @MainActor
  func togglePin() {
    if item.pin != nil {
      item.pin = nil
    } else {
      let pin = HistoryItem.randomAvailablePin
      item.pin = pin
    }
  }

  private func synchronizeItemPin() {
    _ = withObservationTracking {
      item.pin
    } onChange: {
      Task { @MainActor in
        if let pin = self.item.pin {
          self.shortcuts = KeyShortcut.create(character: pin)
        }
        self.synchronizeItemPin()
      }
    }
  }

  private func synchronizeItemTitle() {
    _ = withObservationTracking {
      item.title
    } onChange: {
      Task { @MainActor in
        self.title = self.item.title
        self.synchronizeItemTitle()
      }
    }
  }
}
