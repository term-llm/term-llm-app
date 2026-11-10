import Carbon
import ComputerUseCore
import Foundation

public enum Keys {
    public static let shift = 0x20000, control = 0x40000, option = 0x80000, command = 0x100000
    private static let plain = "BackSpace=51 Tab=48 Linefeed=36 Clear=71 Return=36 Escape=53 Delete=117 Home=115 Left=123 Up=126 Right=124 Down=125 Prior=116 Page_Up=116 Next=121 Page_Down=121 End=119 Begin=115 Menu=110 Help=114 KP_Delete=71 KP_Enter=76 KP_Equal=81 KP_Multiply=67 KP_Add=69 KP_Subtract=78 KP_Decimal=65 KP_Divide=75 KP_0=82 KP_1=83 KP_2=84 KP_3=85 KP_4=86 KP_5=87 KP_6=88 KP_7=89 KP_8=91 KP_9=92 F1=122 F2=120 F3=99 F4=118 F5=96 F6=97 F7=98 F8=100 F9=101 F10=109 F11=103 F12=111 F13=105 F14=107 F15=113 F16=106 F17=64 F18=79 F19=80 F20=90 Caps_Lock=57 Shift_Lock=57 space=49 apostrophe=39 comma=43 minus=27 period=47 slash=44 0=29 1=18 2=19 3=20 4=21 5=23 6=22 7=26 8=28 9=25 semicolon=41 bracketleft=33 backslash=42 bracketright=30 grave=50 a=0 b=11 c=8 d=2 e=14 f=3 g=5 h=4 i=34 j=38 k=40 l=37 m=46 n=45 o=31 p=35 q=12 r=15 s=1 t=17 u=32 v=9 w=13 x=7 y=16 z=6"
    private static let shifted = "exclam=18 quotedbl=39 numbersign=20 dollar=21 percent=23 ampersand=26 parenleft=25 parenright=29 asterisk=28 plus=24 colon=41 less=43 equal=24 greater=47 question=44 at=19 A=0 B=11 C=8 D=2 E=14 F=3 G=5 H=4 I=34 J=38 K=40 L=37 M=46 N=45 O=31 P=35 Q=12 R=15 S=1 T=17 U=32 V=9 W=13 X=7 Y=16 Z=6 asciicircum=22 underscore=27 braceleft=33 bar=42 braceright=30 asciitilde=50"
    private static let noMacKey = "Pause Scroll_Lock Sys_Req Back Select Print Execute Insert Undo Redo Find Cancel Break Mode_switch script_switch Num_Lock KP_Space KP_Tab KP_F1 KP_F2 KP_F3 KP_F4 KP_Home KP_Left KP_Up KP_Right KP_Down KP_Prior KP_Page_Up KP_Next KP_Page_Down KP_End KP_Begin KP_Insert KP_Separator Hyper_L Hyper_R"

    // Fixes: aliases, any case for names of two or more letters, spaces around
    // "+", and plain equal. Off means TABLE names must match letter for letter.
    public static let lenient = true
    // Without a layout match, send a key event carrying the character; off skips it.
    public static let typeUnmatched = true

    public struct Key: Equatable, Sendable {
        public let code: Int?
        public let flags: Int
        public init(_ code: Int?, _ flags: Int) { self.code = code; self.flags = flags }
    }
    public struct Chord: Equatable, Sendable {
        public let code: Int
        public let flags: Int
        public init(_ code: Int, _ flags: Int) { self.code = code; self.flags = flags }
    }
    public struct KeyPress: Equatable, Sendable {
        public let code: Int
        public let flags: Int
        public let text: String
        public init(_ code: Int, _ flags: Int, _ text: String) { self.code = code; self.flags = flags; self.text = text }
    }
    // Two tables, two jobs: named chords use fixed US codes whatever the layout;
    // typed text asks the current layout which key makes each character.
    public static let table: [String: Key] = {
        var table: [String: Key] = [:]
        for (text, flags) in [(plain, 0), (shifted, shift)] {
            for item in text.split(separator: " ") {
                let pair = item.split(separator: "="); table[String(pair[0])] = Key(Int(pair[1])!, flags)
            }
        }
        for (flags, names) in [(shift, "Shift_L Shift_R shift"), (control, "Control_L Control_R ctrl"), (option, "Alt_L Alt_R alt"), (command, "Meta_L Meta_R Super_L Super_R super meta command Command cmd")] {
            for name in names.split(separator: " ") { table[String(name)] = Key(nil, flags) }
        }
        for name in noMacKey.split(separator: " ") { table[String(name)] = Key(nil, 0) }
        table["equal"] = Key(24, 0) // The "=" key itself, not "+" (the lenient fix).
        return table
    }()
    public static let aliases = ["control": "ctrl", "ctrl": "ctrl", "option": "alt", "opt": "alt", "alt": "alt", "cmd": "cmd", "command": "cmd", "super": "cmd", "meta": "cmd", "shift": "shift", "enter": "Return", "esc": "Escape", "pageup": "Page_Up", "pagedown": "Page_Down", "del": "Delete", "arrowup": "Up", "arrowdown": "Down", "arrowleft": "Left", "arrowright": "Right", "spacebar": "space"]

    private static func lookup(_ name: String, lenient: Bool) throws -> Key {
        if let key = table[name] { return key }
        if lenient {
            if let alias = aliases[name.lowercased()] { return table[alias]! }
            let same = name.count > 1 ? table.keys.filter { $0.lowercased() == name.lowercased() } : []
            if same.count == 1 { return table[same[0]]! }
        }
        throw Errors.make("key_not_found", ["name": name])
    }
    private static func names(_ spec: String, lenient: Bool) -> [[String]] {
        let fixed = lenient ? spec.replacingOccurrences(of: " *\\+ *", with: "+", options: .regularExpression) : spec
        return fixed.split(separator: " ").map { $0.split(separator: "+").map(String.init) }
    }
    public static func chords(_ spec: String, lenient: Bool = Keys.lenient) throws -> [Chord] {
        // Look up every name before validating any chord (including later chords).
        let found = try names(spec, lenient: lenient).map { try $0.map { try lookup($0, lenient: lenient) } }
        return try (found.isEmpty ? [[]] : found).map { chord in
            var code: Int?, flags = 0
            for key in chord {
                if key == Key(nil, 0) { throw Errors.make("key_chord", ["case": "This key does not exist on a Mac"]) }
                if code != nil { throw Errors.make("key_chord", ["case": "A chord takes only one key that is not a modifier"]) }
                code = key.code; flags |= key.flags
            }
            guard let code else { throw Errors.make("key_chord", ["case": "A chord needs one key that is not a modifier"]) }
            return Chord(code, flags)
        }
    }
    public static func modifiers(_ spec: String, lenient: Bool = Keys.lenient) throws -> Int {
        let found = try names(spec, lenient: lenient).flatMap { try $0.map { try lookup($0, lenient: lenient) } }
        guard !found.isEmpty, found.allSatisfy({ $0.code == nil && $0.flags != 0 }) else { throw Errors.make("mouse_key_requires_single_key") }
        return found.reduce(0) { $0 | $1.flags }
    }
    public typealias Layout = (Int, Int) -> String?
    public static func currentLayout() throws -> Layout {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { throw Errors.make("no_keyboard_layout") }
        let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue()
        return try layoutTranslator(data: data, keyboard: UInt32(LMGetKbdType()))
    }
    static func layoutTranslator(data: CFData?, keyboard: UInt32) throws -> Layout {
        guard let data else { throw Errors.make("no_keyboard_layout") }
        return { code, mods in
            // Retain the data in this closure: the layout pointer must outlive the source.
            let layout = UnsafeRawPointer(CFDataGetBytePtr(data)!).assumingMemoryBound(to: UCKeyboardLayout.self)
            var dead: UInt32 = 0, count = 0
            var chars = [UniChar](repeating: 0, count: 4)
            let failed = UCKeyTranslate(layout, UInt16(code), 3, UInt32((mods >> 8) & 0xff), keyboard, 0, &dead, 4, &count, &chars)
            guard failed == noErr, count > 0 else { return nil }
            return String(utf16CodeUnits: chars, count: 1)
        }
    }
    /// Eight modifier states, then 128 codes; the first key producing a character wins.
    public static func presses(_ text: String, layout: Layout? = nil, typeUnmatched: Bool = Keys.typeUnmatched) throws -> [KeyPress] {
        let translate = try layout ?? currentLayout()
        var found: [String: (Int, Int)] = [:]
        for c in 0...1 { for o in 0...1 { for s in 0...1 {
            let mods = c * 4096 | o * 2048 | s * 512
            let flags = c * control | o * option | s * shift
            for code in 0..<128 {
                if let char = translate(code, mods), !char.isEmpty, found[char] == nil { found[char] = (code, flags) }
            }
        } } }
        // One Return per line, including Windows CRLF. One press per Unicode scalar,
        // not per grapheme cluster (Python iterates code points).
        return text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r").unicodeScalars.compactMap { scalar in
            let char = String(scalar)
            if let (code, flags) = found[char] { return KeyPress(code, flags, char) }
            return typeUnmatched ? KeyPress(0, 0, char) : nil
        }
    }
}
