import Cocoa

var pass = 0, fail = 0
func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    if ok { pass += 1; print("  ✅ \(name)") }
    else  { fail += 1; print("  ❌ \(name) \(detail)") }
}

@MainActor
func ev(_ type: NSEvent.EventType, _ p: CGPoint, _ mods: NSEvent.ModifierFlags) -> NSEvent {
    NSEvent.mouseEvent(with: type, location: p, modifierFlags: mods, timestamp: 0,
                       windowNumber: 0, context: nil, eventNumber: 0,
                       clickCount: 1, pressure: 1)!
}

/// จำลองกดลากปล่อย แล้วคืน tool ของเส้นที่เพิ่งวาด
@MainActor
func drag(_ v: OverlayView, from a: CGPoint, to b: CGPoint,
          mods: NSEvent.ModifierFlags, right: Bool = false,
          dragMods: NSEvent.ModifierFlags? = nil) -> Stroke? {
    let before = v.strokes.count
    let dm = dragMods ?? mods
    if right {
        v.rightMouseDown(with: ev(.rightMouseDown, a, mods))
        v.rightMouseDragged(with: ev(.rightMouseDragged, CGPoint(x: (a.x+b.x)/2, y: (a.y+b.y)/2), dm))
        v.rightMouseDragged(with: ev(.rightMouseDragged, b, dm))
        v.rightMouseUp(with: ev(.rightMouseUp, b, dm))
    } else {
        v.mouseDown(with: ev(.leftMouseDown, a, mods))
        v.mouseDragged(with: ev(.leftMouseDragged, CGPoint(x: (a.x+b.x)/2, y: (a.y+b.y)/2), dm))
        v.mouseDragged(with: ev(.leftMouseDragged, b, dm))
        v.mouseUp(with: ev(.leftMouseUp, b, dm))
    }
    return v.strokes.count > before ? v.strokes.last : nil
}

@MainActor
func run() {
    _ = NSApplication.shared
    let size = CGSize(width: 1000, height: 700)
    let v = OverlayView(frame: CGRect(origin: .zero, size: size))
    v.prepare(mode: .draw, background: nil, canvasSize: size,
              startFocus: CGPoint(x: 500, y: 350))
    v.testShowChrome()

    print("\n— ค่าเริ่มต้น —")
    check("เครื่องมือเริ่มต้นเป็นปากกา", v.tool == .pen, "ได้ \(v.tool)")
    check("controller เริ่มต้นเป็นปากกาด้วย", OverlayController().tool == .pen)

    // จุดที่ไม่ทับแถบเครื่องมือ (แถบอยู่ขอบล่าง/บน) — ใช้กลางจอ
    let a = CGPoint(x: 300, y: 380), b = CGPoint(x: 620, y: 380)

    print("\n— ลากธรรมดา —")
    let s1 = drag(v, from: a, to: b, mods: [])
    check("ลากเปล่า ๆ ได้ปากกา", s1?.tool == .pen, "ได้ \(String(describing: s1?.tool))")

    print("\n— ⇧ = ลูกศร —")
    let s2 = drag(v, from: a, to: b, mods: [.shift])
    check("⇧ + ลาก ได้ลูกศร", s2?.tool == .arrow, "ได้ \(String(describing: s2?.tool))")
    check("เครื่องมือที่เลือกค้างไว้ไม่เปลี่ยน", v.tool == .pen, "ได้ \(v.tool)")

    print("\n— ⌃⇧ = สี่เหลี่ยม —")
    let s3 = drag(v, from: a, to: b, mods: [.shift, .control])
    check("⌃⇧ + ลาก ได้สี่เหลี่ยม", s3?.tool == .rect, "ได้ \(String(describing: s3?.tool))")
    check("เครื่องมือที่เลือกค้างไว้ยังเป็นปากกา", v.tool == .pen, "ได้ \(v.tool)")

    print("\n— ⌃+คลิก ที่ระบบส่งมาเป็นคลิกขวา —")
    let s4 = drag(v, from: a, to: b, mods: [.shift, .control], right: true)
    check("คลิกขวา+⌃⇧ ได้สี่เหลี่ยม (ไม่หลุดออกจากโหมด)", s4?.tool == .rect,
          "ได้ \(String(describing: s4?.tool))")
    let s5 = drag(v, from: a, to: b, mods: [.shift], right: true)
    check("คลิกขวา+⇧ ได้ลูกศร", s5?.tool == .arrow, "ได้ \(String(describing: s5?.tool))")

    print("\n— คลิกขวาเปล่า ๆ ยังต้องไม่วาด —")
    let n = v.strokes.count
    v.rightMouseDown(with: ev(.rightMouseDown, a, []))
    v.rightMouseUp(with: ev(.rightMouseUp, a, []))
    check("คลิกขวาเปล่า ๆ ไม่เกิดเส้นใหม่", v.strokes.count == n, "ได้ \(v.strokes.count) จาก \(n)")

    print("\n— สลับ ลูกศร ↔ สี่เหลี่ยม กลางคัน —")
    let s6 = drag(v, from: a, to: b, mods: [.shift], dragMods: [.shift, .control])
    check("เริ่มด้วย ⇧ แล้วกด ⌃ เพิ่ม กลายเป็นสี่เหลี่ยม", s6?.tool == .rect,
          "ได้ \(String(describing: s6?.tool))")

    print("\n— ⌥ บังคับมุม (ย้ายมาจาก ⇧) —")
    let diag = CGPoint(x: 620, y: 460)   // dx=320 dy=80 → ถ้าบังคับจะสแนปเป็นแนวนอน
    let s7 = drag(v, from: a, to: diag, mods: [.shift], dragMods: [.shift, .option])
    if let s7, s7.points.count >= 2 {
        let dy = abs(s7.points[1].y - s7.points[0].y)
        check("⌥ + ลาก สแนปเป็นแนวนอน (Δy≈0)", dy < 0.5, "Δy=\(dy)")
    } else { check("⌥ + ลาก สแนปเป็นแนวนอน", false, "ไม่มีเส้น") }

    let s8 = drag(v, from: a, to: diag, mods: [.shift])
    if let s8, s8.points.count >= 2 {
        let dy = abs(s8.points[1].y - s8.points[0].y)
        check("ไม่กด ⌥ = ไม่บังคับมุม (Δy=80)", abs(dy - 80) < 0.5, "Δy=\(dy)")
    } else { check("ไม่กด ⌥ = ไม่บังคับมุม", false, "ไม่มีเส้น") }

    print("\n— เลือกเครื่องมือเองแล้วทางลัดยังทำงาน —")
    v.tool = .highlighter
    let s9 = drag(v, from: a, to: b, mods: [])
    check("เลือกไฮไลต์แล้วลากเปล่า ได้ไฮไลต์", s9?.tool == .highlighter,
          "ได้ \(String(describing: s9?.tool))")
    let s10 = drag(v, from: a, to: b, mods: [.shift])
    check("เลือกไฮไลต์แล้ว ⇧ ยังได้ลูกศร", s10?.tool == .arrow,
          "ได้ \(String(describing: s10?.tool))")

    print("\n— เครื่องมือข้อความ —")
    v.tool = .text
    let before = v.strokes.count
    v.mouseDown(with: ev(.leftMouseDown, a, []))
    v.mouseUp(with: ev(.leftMouseUp, a, []))
    check("เลือกข้อความแล้วคลิก ได้ช่องพิมพ์ข้อความ",
          v.strokes.count == before + 1 && v.strokes.last?.tool == .text)
    // กล่องข้อความว่างจะถูกยกเลิกทิ้งตอนเริ่มลาก จำนวนเส้นจึงเท่าเดิม — ดูที่เส้นล่าสุดแทน
    _ = drag(v, from: a, to: b, mods: [.shift])
    check("เลือกข้อความแล้ว ⇧+ลาก ได้ลูกศร", v.strokes.last?.tool == .arrow,
          "ได้ \(String(describing: v.strokes.last?.tool))")
    check("กล่องข้อความว่างถูกยกเลิกทิ้ง ไม่ค้างในภาพ",
          !v.strokes.contains { $0.tool == .text && $0.text.isEmpty })

    print("\n=========== ผ่าน \(pass) / ตก \(fail) ===========")
    exit(fail == 0 ? 0 : 1)
}

MainActor.assumeIsolated { run() }
