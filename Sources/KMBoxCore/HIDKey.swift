import Foundation

public struct HIDKey: Identifiable, Hashable, Sendable {
    public let code: UInt8
    public let name: String
    public var id: UInt8 { code }
    public init(_ code: UInt8, _ name: String) { self.code = code; self.name = name }
    public static let all: [HIDKey] = {
        var list = (0..<26).map { HIDKey(UInt8(4 + $0), String(UnicodeScalar(65 + $0)!)) }
        list += (1...9).map { HIDKey(UInt8(29 + $0), String($0)) }
        list += [HIDKey(39, "0"), HIDKey(40, "Enter"), HIDKey(41, "Escape"), HIDKey(42, "Backspace"),
                 HIDKey(43, "Tab"), HIDKey(44, "Space"), HIDKey(76, "Delete"), HIDKey(74, "Home"),
                 HIDKey(77, "End"), HIDKey(75, "Page Up"), HIDKey(78, "Page Down"),
                 HIDKey(79, "→"), HIDKey(80, "←"), HIDKey(81, "↓"), HIDKey(82, "↑")]
        list += (1...12).map { HIDKey(UInt8(57 + $0), "F\($0)") }
        list += [HIDKey(45, "-"), HIDKey(46, "="), HIDKey(47, "["), HIDKey(48, "]"),
                 HIDKey(49, "\\"), HIDKey(51, ";"), HIDKey(52, "'"), HIDKey(53, "`"),
                 HIDKey(54, ","), HIDKey(55, "."), HIDKey(56, "/"), HIDKey(57, "Caps Lock"),
                 HIDKey(70, "Print Screen"), HIDKey(71, "Scroll Lock"), HIDKey(72, "Pause"),
                 HIDKey(73, "Insert"), HIDKey(83, "Num Lock"), HIDKey(84, "Keypad /"),
                 HIDKey(85, "Keypad *"), HIDKey(86, "Keypad -"), HIDKey(87, "Keypad +"), HIDKey(88, "Keypad Enter")]
        list += (1...9).map { HIDKey(UInt8(88 + $0), "Keypad \($0)") }
        list += [HIDKey(98, "Keypad 0"), HIDKey(99, "Keypad ."), HIDKey(101, "Application")]
        list += (13...24).map { HIDKey(UInt8(91 + $0), "F\($0)") }
        list += [HIDKey(0xe0, "Left Control"), HIDKey(0xe1, "Left Shift"), HIDKey(0xe2, "Left Alt"), HIDKey(0xe3, "Left GUI"),
                 HIDKey(0xe4, "Right Control"), HIDKey(0xe5, "Right Shift"), HIDKey(0xe6, "Right Alt"), HIDKey(0xe7, "Right GUI")]
        return list
    }()
}
