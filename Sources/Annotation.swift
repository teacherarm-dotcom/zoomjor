import AppKit
import Carbon.HIToolbox

enum Tool: Int, CaseIterable {
    case arrow, pen, line, rect, ellipse, highlighter, text

    var thaiName: String {
        switch self {
        case .arrow:       return "ลูกศร"
        case .pen:         return "ปากกา"
        case .line:        return "เส้นตรง"
        case .rect:        return "สี่เหลี่ยม"
        case .ellipse:     return "วงรี"
        case .highlighter: return "ไฮไลต์"
        case .text:        return "ข้อความ"
        }
    }

    var englishName: String {
        switch self {
        case .arrow:       return "Arrow"
        case .pen:         return "Pen"
        case .line:        return "Line"
        case .rect:        return "Box"
        case .ellipse:     return "Ellipse"
        case .highlighter: return "Highlight"
        case .text:        return "Text"
        }
    }

    /// ตัวอักษรที่พิมพ์บนแป้น (ไว้แสดงในเมนู/คู่มือ)
    var key: String {
        switch self {
        case .arrow: return "a"
        case .pen: return "p"
        case .line: return "l"
        case .rect: return "s"
        case .ellipse: return "c"
        case .highlighter: return "h"
        case .text: return "t"
        }
    }

    /// ตำแหน่งปุ่มจริงบนแป้นพิมพ์ — ใช้จับคีย์แทนตัวอักษร
    /// เพื่อให้กดได้เหมือนกันไม่ว่าจะสลับภาษาเป็นไทยหรืออังกฤษ
    var keyCode: Int {
        switch self {
        case .arrow:       return kVK_ANSI_A
        case .pen:         return kVK_ANSI_P
        case .line:        return kVK_ANSI_L
        case .rect:        return kVK_ANSI_S
        case .ellipse:     return kVK_ANSI_C
        case .highlighter: return kVK_ANSI_H
        case .text:        return kVK_ANSI_T
        }
    }

    var symbolName: String {
        switch self {
        case .arrow:       return "arrow.up.right"
        case .pen:         return "scribble"
        case .line:        return "line.diagonal"
        case .rect:        return "rectangle"
        case .ellipse:     return "circle"
        case .highlighter: return "highlighter"
        case .text:        return "textformat"
        }
    }

    static func forCode(_ code: Int) -> Tool? { allCases.first { $0.keyCode == code } }
}

struct PaletteColor {
    let key: String
    let keyCode: Int
    let thaiName: String
    let englishName: String
    let color: NSColor
}

enum Palette {
    static let all: [PaletteColor] = [
        PaletteColor(key: "r", keyCode: kVK_ANSI_R, thaiName: "แดง", englishName: "Red",
                     color: NSColor(srgbRed: 0.93, green: 0.13, blue: 0.16, alpha: 1)),
        PaletteColor(key: "g", keyCode: kVK_ANSI_G, thaiName: "เขียว", englishName: "Green",
                     color: NSColor(srgbRed: 0.10, green: 0.78, blue: 0.31, alpha: 1)),
        PaletteColor(key: "y", keyCode: kVK_ANSI_Y, thaiName: "เหลือง", englishName: "Yellow",
                     color: NSColor(srgbRed: 1.00, green: 0.83, blue: 0.05, alpha: 1)),
        PaletteColor(key: "k", keyCode: kVK_ANSI_K, thaiName: "ดำ", englishName: "Black",
                     color: NSColor(srgbRed: 0.04, green: 0.04, blue: 0.06, alpha: 1)),
        PaletteColor(key: "b", keyCode: kVK_ANSI_B, thaiName: "น้ำเงิน", englishName: "Blue",
                     color: NSColor(srgbRed: 0.09, green: 0.42, blue: 0.96, alpha: 1)),
        PaletteColor(key: "w", keyCode: kVK_ANSI_W, thaiName: "ขาว", englishName: "White",
                     color: NSColor.white),
        PaletteColor(key: "o", keyCode: kVK_ANSI_O, thaiName: "ส้ม", englishName: "Orange",
                     color: NSColor(srgbRed: 1.00, green: 0.52, blue: 0.00, alpha: 1)),
        PaletteColor(key: "m", keyCode: kVK_ANSI_M, thaiName: "ชมพู", englishName: "Pink",
                     color: NSColor(srgbRed: 0.96, green: 0.24, blue: 0.66, alpha: 1)),
    ]

    static func forCode(_ code: Int) -> PaletteColor? { all.first { $0.keyCode == code } }

    static func index(of color: NSColor) -> Int? { all.firstIndex { $0.color == color } }

    static func name(for color: NSColor) -> String {
        for item in all where item.color == color {
            return "\(item.thaiName) (\(item.englishName))"
        }
        return "กำหนดเอง"
    }
}

/// ตัวเลข 0–9 ตามตำแหน่งปุ่มจริง (แถวบน + แป้นตัวเลข) ใช้ตั้งเวลาในโหมดนาฬิกา
enum DigitKeys {
    static let map: [Int: Int] = [
        kVK_ANSI_0: 0, kVK_ANSI_1: 1, kVK_ANSI_2: 2, kVK_ANSI_3: 3, kVK_ANSI_4: 4,
        kVK_ANSI_5: 5, kVK_ANSI_6: 6, kVK_ANSI_7: 7, kVK_ANSI_8: 8, kVK_ANSI_9: 9,
        kVK_ANSI_Keypad0: 0, kVK_ANSI_Keypad1: 1, kVK_ANSI_Keypad2: 2, kVK_ANSI_Keypad3: 3,
        kVK_ANSI_Keypad4: 4, kVK_ANSI_Keypad5: 5, kVK_ANSI_Keypad6: 6, kVK_ANSI_Keypad7: 7,
        kVK_ANSI_Keypad8: 8, kVK_ANSI_Keypad9: 9
    ]
}

/// หนึ่งเส้น/รูปที่วาดไว้ — เก็บพิกัดใน "canvas space" (พิกัดหน้าจอจริง)
/// เพื่อให้ยังเกาะตำแหน่งเดิมเมื่อซูม/เลื่อนภาพ
struct Stroke {
    var tool: Tool
    var color: NSColor
    var width: CGFloat
    var points: [CGPoint]
    var text: String = ""
}
