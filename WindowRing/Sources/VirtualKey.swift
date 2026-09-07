import AppKit

/// Virtual keycodes for the modifier keys Window Ring's global shortcut can be
/// built from, plus Escape. These are the standard, publicly documented ANSI
/// keyboard virtual keycodes (the same values Apple ships in
/// Carbon/HIToolbox's Events.h) — hardcoded here so this file has no Carbon
/// dependency, just the numbers.
enum VirtualKey {
    static let optionLeft: CGKeyCode = 58
    static let optionRight: CGKeyCode = 61
    static let controlLeft: CGKeyCode = 59
    static let controlRight: CGKeyCode = 62
    static let commandLeft: CGKeyCode = 55
    static let commandRight: CGKeyCode = 54
    static let shiftLeft: CGKeyCode = 56
    static let shiftRight: CGKeyCode = 60
    static let escape: CGKeyCode = 53
    static let returnKey: CGKeyCode = 36
    static let keypadEnter: CGKeyCode = 76
    static let leftArrow: CGKeyCode = 123
    static let rightArrow: CGKeyCode = 124
    static let tab: CGKeyCode = 48

    private static let allModifiers: Set<CGKeyCode> = [
        optionLeft, optionRight, controlLeft, controlRight,
        commandLeft, commandRight, shiftLeft, shiftRight
    ]

    static func isModifier(_ code: CGKeyCode) -> Bool {
        allModifiers.contains(code)
    }

    /// The NSEvent.ModifierFlags bit that corresponds to this key's family
    /// (left/right are not distinguished at the flags level, only via keycode).
    static func flagMask(for code: CGKeyCode) -> UInt {
        switch code {
        case optionLeft, optionRight: return NSEvent.ModifierFlags.option.rawValue
        case controlLeft, controlRight: return NSEvent.ModifierFlags.control.rawValue
        case commandLeft, commandRight: return NSEvent.ModifierFlags.command.rawValue
        case shiftLeft, shiftRight: return NSEvent.ModifierFlags.shift.rawValue
        default: return 0
        }
    }

    static func name(for code: CGKeyCode) -> String {
        switch code {
        case optionLeft: return "Left Option"
        case optionRight: return "Right Option"
        case controlLeft: return "Left Control"
        case controlRight: return "Right Control"
        case commandLeft: return "Left Command"
        case commandRight: return "Right Command"
        case shiftLeft: return "Left Shift"
        case shiftRight: return "Right Shift"
        default: return "Key \(code)"
        }
    }
}
