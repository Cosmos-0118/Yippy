import AppKit.NSEvent
import Defaults

enum HistoryItemAction {
  case unknown
  case copy
  case paste
  case pasteWithoutFormatting

  init(_ modifierFlags: NSEvent.ModifierFlags) {  // swiftlint:disable:this cyclomatic_complexity
    switch modifierFlags {
    case .command where !Defaults[.pasteByDefault]:
      self = .copy
    case .command where Defaults[.pasteByDefault]:
      self = .paste
    case .option where !Defaults[.pasteByDefault]:
      self = .paste
    case .option where Defaults[.pasteByDefault]:
      self = .copy
    case [.option, .shift] where !Defaults[.pasteByDefault] && Defaults[.removeFormattingByDefault]:
      self = .pasteWithoutFormatting
    case [.command, .shift] where Defaults[.pasteByDefault] && Defaults[.removeFormattingByDefault]:
      self = .pasteWithoutFormatting
    default:
      self = .unknown
    }
  }

  var modifierFlags: NSEvent.ModifierFlags {
    switch self {
    case .copy where !Defaults[.pasteByDefault]:
      return .command
    case .paste where Defaults[.pasteByDefault]:
      return .command
    case .paste where !Defaults[.pasteByDefault]:
      return .option
    case .copy where Defaults[.pasteByDefault]:
      return .option
    case .pasteWithoutFormatting where !Defaults[.pasteByDefault] && Defaults[.removeFormattingByDefault]:
      return [.option, .shift]
    case .pasteWithoutFormatting where Defaults[.pasteByDefault] && Defaults[.removeFormattingByDefault]:
      return [.command, .shift]
    default:
      return []
    }
  }
}
