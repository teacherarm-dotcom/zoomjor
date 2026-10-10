// ZoomJor tutorial video builder
// ฉากของ ZoomJor ถูกวาดด้วยโค้ดจริงของแอป (OverlayView / LiveZoomView) — คอมไพล์รวมกับ Sources/
// ฉากติดตั้ง/ตั้งค่าระบบใช้ภาพหน้าจอจริงใน video/captures/
import Cocoa
import AVFoundation
import CoreImage
import Carbon.HIToolbox

// MARK: - ค่าคงที่

let VW = 1920, VH = 1080
let FPS: Int32 = 30
let ROOT = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let ONLY_PREVIEW = CommandLine.arguments.contains("--preview")
let SCREEN = CGSize(width: 1512, height: 982)                 // จอจริง (point)
let SCREEN_RECT = CGRect(x: 48, y: 40, width: 1386, height: 900)   // ช่องจอในวิดีโอ (top-left)
let PANEL_X: CGFloat = 1468
let CAP_RECT = CGRect(x: 48, y: 952, width: 1824, height: 104)

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}
let C_BG = rgb(0x0E1320), C_BG2 = rgb(0x182136), C_ACCENT = rgb(0x2F7BF6), C_TEXT = rgb(0xEEF1F7)
let C_MUTED = rgb(0x97A1B6), C_CAP = rgb(0xE9EDF6), C_KEY = rgb(0xF4F6FA), C_KEYINK = rgb(0x1A2030)
let C_HL = rgb(0xFFC83D)

func font(_ size: CGFloat, _ w: String = "Medium") -> NSFont {
    for n in ["SukhumvitSet-\(w)", "SukhumvitSet-Text", "Thonburi-Bold", "Thonburi"] {
        if let f = NSFont(name: n, size: size) { return f }
    }
    return NSFont.systemFont(ofSize: size, weight: .medium)
}
func mono(_ size: CGFloat) -> NSFont { NSFont.monospacedSystemFont(ofSize: size, weight: .semibold) }

// MARK: - ตัวช่วยวาด (พิกัด top-left บนผืนวิดีโอ)

final class Painter {
    let ctx: CGContext
    init(_ ctx: CGContext) { self.ctx = ctx }

    func fill(_ r: CGRect, _ c: NSColor) { ctx.setFillColor(c.cgColor); ctx.fill(r) }
    func round(_ r: CGRect, _ radius: CGFloat, fill c: NSColor? = nil, stroke s: NSColor? = nil, lw: CGFloat = 2) {
        let p = CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
        if let c { ctx.addPath(p); ctx.setFillColor(c.cgColor); ctx.fillPath() }
        if let s { ctx.addPath(p); ctx.setStrokeColor(s.cgColor); ctx.setLineWidth(lw); ctx.strokePath() }
    }
    func image(_ img: CGImage, in r: CGRect, from src: CGRect? = nil, alpha: CGFloat = 1) {
        // src = พิกัดพิกเซลของภาพแบบ top-left
        var im = img
        if let src, let c = img.cropping(to: src.integral) { im = c }
        ctx.saveGState()
        ctx.setAlpha(alpha)
        ctx.interpolationQuality = .high
        ctx.translateBy(x: r.minX, y: r.maxY); ctx.scaleBy(x: 1, y: -1)
        ctx.draw(im, in: CGRect(origin: .zero, size: r.size))
        ctx.restoreGState()
    }
    @discardableResult
    func text(_ s: String, _ f: NSFont, _ c: NSColor, in r: CGRect, align: NSTextAlignment = .left,
              lineSpacing: CGFloat = 4, shadow: Bool = false) -> CGFloat {
        let ps = NSMutableParagraphStyle(); ps.alignment = align; ps.lineSpacing = lineSpacing
        ps.lineBreakMode = .byWordWrapping
        var attrs: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: c, .paragraphStyle: ps]
        if shadow { let sh = NSShadow(); sh.shadowColor = NSColor.black.withAlphaComponent(0.6)
                    sh.shadowBlurRadius = 6; sh.shadowOffset = NSSize(width: 0, height: -1); attrs[.shadow] = sh }
        let a = NSAttributedString(string: s, attributes: attrs)
        let b = a.boundingRect(with: CGSize(width: r.width, height: 10_000), options: [.usesLineFragmentOrigin])
        a.draw(with: CGRect(x: r.minX, y: r.minY, width: r.width, height: max(r.height, b.height)),
               options: [.usesLineFragmentOrigin])
        return b.height
    }
    func textHeight(_ s: String, _ f: NSFont, width: CGFloat, lineSpacing: CGFloat = 4) -> CGFloat {
        let ps = NSMutableParagraphStyle(); ps.lineSpacing = lineSpacing
        return NSAttributedString(string: s, attributes: [.font: f, .paragraphStyle: ps])
            .boundingRect(with: CGSize(width: width, height: 10_000), options: [.usesLineFragmentOrigin]).height
    }
    func textWidth(_ s: String, _ f: NSFont) -> CGFloat {
        NSAttributedString(string: s, attributes: [.font: f]).size().width
    }
    /// ปุ่มคีย์บอร์ด — คืนความกว้าง
    @discardableResult
    func keycap(_ s: String, at p: CGPoint, size: CGFloat = 44, dark: Bool = false) -> CGFloat {
        let f = s.count > 2 ? font(size * 0.42, "Bold") : mono(size * 0.5)
        let w = max(size, textWidth(s, f) + size * 0.55)
        let r = CGRect(x: p.x, y: p.y, width: w, height: size)
        round(r.offsetBy(dx: 0, dy: 3), 9, fill: NSColor.black.withAlphaComponent(0.35))
        round(r, 9, fill: dark ? rgb(0x2A3349) : C_KEY, stroke: dark ? rgb(0x47526C) : rgb(0xC9CFDB), lw: 1.5)
        let th = textHeight(s, f, width: w)
        text(s, f, dark ? C_TEXT : C_KEYINK, in: CGRect(x: r.minX, y: r.midY - th / 2, width: w, height: th), align: .center)
        return w
    }
    func keys(_ ks: [String], at p: CGPoint, size: CGFloat = 44, dark: Bool = false) -> CGFloat {
        var x = p.x
        for (i, k) in ks.enumerated() {
            if i > 0 { text("+", font(size * 0.45, "Bold"), C_MUTED, in: CGRect(x: x + 4, y: p.y + size * 0.2, width: 20, height: size)); x += 26 }
            x += keycap(k, at: CGPoint(x: x, y: p.y), size: size, dark: dark)
        }
        return x - p.x
    }
    func ring(_ c: CGPoint, _ r: CGFloat, _ color: NSColor, lw: CGFloat = 5, alpha: CGFloat = 1) {
        ctx.saveGState(); ctx.setAlpha(alpha)
        ctx.setStrokeColor(color.cgColor); ctx.setLineWidth(lw)
        ctx.strokeEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        ctx.restoreGState()
    }
    func arrow(from a: CGPoint, to b: CGPoint, color: NSColor, lw: CGFloat = 7) {
        let dx = b.x - a.x, dy = b.y - a.y, len = hypot(dx, dy); guard len > 2 else { return }
        let ux = dx / len, uy = dy / len, head = min(30, len * 0.6)
        ctx.saveGState()
        ctx.setStrokeColor(color.cgColor); ctx.setFillColor(color.cgColor); ctx.setLineWidth(lw); ctx.setLineCap(.round)
        ctx.move(to: a); ctx.addLine(to: CGPoint(x: b.x - ux * head * 0.8, y: b.y - uy * head * 0.8)); ctx.strokePath()
        let bx = b.x - ux * head, by = b.y - uy * head
        ctx.move(to: b); ctx.addLine(to: CGPoint(x: bx - uy * head * 0.5, y: by + ux * head * 0.5))
        ctx.addLine(to: CGPoint(x: bx + uy * head * 0.5, y: by - ux * head * 0.5)); ctx.closePath(); ctx.fillPath()
        ctx.restoreGState()
    }
    /// เคอร์เซอร์ลูกศรแบบ macOS (ปลายอยู่ที่ p)
    func cursor(at p: CGPoint, scale s: CGFloat = 1.25, pressed: Bool = false) {
        let pts: [CGPoint] = [(0, 0), (0, 22), (5.5, 17), (9.5, 26), (13, 24.5), (9, 15.5), (16, 15.5)]
            .map { CGPoint(x: p.x + $0.0 * s, y: p.y + $0.1 * s) }
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 2), blur: 4, color: NSColor.black.withAlphaComponent(0.45).cgColor)
        ctx.addLines(between: pts); ctx.closePath()
        ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
        ctx.restoreGState()
        let inner = [(1.6, 3.6), (1.6, 18.2), (5.9, 14.2), (10.1, 23.4), (11.6, 22.8), (7.4, 13.7), (12.6, 13.7)]
            .map { CGPoint(x: p.x + $0.0 * s, y: p.y + $0.1 * s) }
        ctx.addLines(between: inner); ctx.closePath()
        ctx.setFillColor(NSColor.white.cgColor); ctx.fillPath()
        if pressed { ring(p, 16, C_HL, lw: 3, alpha: 0.9) }
    }
    func crosshair(at p: CGPoint) {
        ctx.saveGState()
        for (c, w) in [(NSColor.white, 4.0), (NSColor.black, 1.6)] {
            ctx.setStrokeColor(c.cgColor); ctx.setLineWidth(w)
            ctx.move(to: CGPoint(x: p.x - 13, y: p.y)); ctx.addLine(to: CGPoint(x: p.x + 13, y: p.y))
            ctx.move(to: CGPoint(x: p.x, y: p.y - 13)); ctx.addLine(to: CGPoint(x: p.x, y: p.y + 13)); ctx.strokePath()
        }
        ctx.restoreGState()
    }
}

func pal(_ k: String) -> PaletteColor { Palette.all.first { $0.key == k }! }
func palOpt(_ k: String) -> PaletteColor? { Palette.all.first { $0.key == k } }

// MARK: - ช่องจอ (map พิกัดจอจริง → วิดีโอ พร้อม Ken Burns)

struct ScreenMap {
    var crop: CGRect          // พื้นที่ของจอจริงที่แสดง (point, top-left)
    var dest: CGRect = SCREEN_RECT
    /// p = พิกัดจอจริงแบบ top-left
    func v(_ p: CGPoint) -> CGPoint {
        CGPoint(x: dest.minX + (p.x - crop.minX) / crop.width * dest.width,
                y: dest.minY + (p.y - crop.minY) / crop.height * dest.height)
    }
    var k: CGFloat { dest.width / crop.width }
}
func full() -> CGRect { CGRect(origin: .zero, size: SCREEN) }
func ease(_ x: Double) -> Double { let t = min(1, max(0, x)); return t * t * (3 - 2 * t) }
func lerp(_ a: CGFloat, _ b: CGFloat, _ t: Double) -> CGFloat { a + (b - a) * CGFloat(t) }
func lerpR(_ a: CGRect, _ b: CGRect, _ t: Double) -> CGRect {
    CGRect(x: lerp(a.minX, b.minX, t), y: lerp(a.minY, b.minY, t), width: lerp(a.width, b.width, t), height: lerp(a.height, b.height, t))
}
func lerpP(_ a: CGPoint, _ b: CGPoint, _ t: Double) -> CGPoint { CGPoint(x: lerp(a.x, b.x, t), y: lerp(a.y, b.y, t)) }
/// กรอบซูมที่สัดส่วนเท่าจอ จุดกึ่งกลาง c (top-left) ขยาย z เท่า
func zoomRect(_ c: CGPoint, _ z: CGFloat) -> CGRect {
    let w = SCREEN.width / z, h = SCREEN.height / z
    return CGRect(x: min(max(0, c.x - w / 2), SCREEN.width - w), y: min(max(0, c.y - h / 2), SCREEN.height - h), width: w, height: h)
}

// MARK: - สเตจ: OverlayView ของจริง

let bitmapSpace = CGColorSpace(name: CGColorSpace.sRGB)!

@MainActor func renderNSView(_ v: NSView, scale: CGFloat = 2, useCache: Bool = false) -> CGImage {
    let size = v.bounds.size
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    if useCache {
        v.cacheDisplay(in: v.bounds, to: rep)
    } else {
        NSGraphicsContext.saveGraphicsState()
        let g = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.current = g
        g.cgContext.clear(CGRect(origin: .zero, size: size))
        v.draw(v.bounds)
        g.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
    }
    return rep.cgImage!
}

func tl2bl(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: SCREEN.height - p.y) }

@MainActor final class Stage {
    let v = OverlayView(frame: CGRect(origin: .zero, size: SCREEN))
    let slide: NSImage
    init(slide: NSImage) { self.slide = slide }

    func zoomMode(focusTL: CGPoint, zoom: CGFloat) {
        v.prepare(mode: .zoom, background: slide, canvasSize: SCREEN, startFocus: tl2bl(focusTL))
        v.zoom = zoom
        v.focus = tl2bl(focusTL)
    }
    func drawMode() { v.prepare(mode: .draw, background: nil, canvasSize: SCREEN, startFocus: .zero) }
    func timerMode(bg: NSImage, minutes: Double) {
        v.prepare(mode: .timer, background: bg, canvasSize: SCREEN, startFocus: .zero, timerDuration: minutes * 60)
    }
    func key(_ code: Int, _ chars: String = "", mods: NSEvent.ModifierFlags = []) {
        let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0, windowNumber: 0,
                                 context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                 isARepeat: false, keyCode: UInt16(code))!
        v.keyDown(with: e)
    }
    func click(_ pTL: CGPoint) {
        let p = tl2bl(pTL)
        for t in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let e = NSEvent.mouseEvent(with: t, location: p, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                       context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            t == .leftMouseDown ? v.mouseDown(with: e) : v.mouseUp(with: e)
        }
    }
    func strokes(_ list: [Stroke]) { v.restore(strokes: list) }
    func image() -> CGImage { renderNSView(v) }
}

/// เส้นในพิกัดจอ (top-left) → Stroke ของแอป (canvas bottom-left)
func mk(_ tool: Tool, _ colorKey: String, _ w: CGFloat, _ ptsTL: [CGPoint], text: String = "") -> Stroke {
    Stroke(tool: tool, color: pal(colorKey).color, width: w, points: ptsTL.map(tl2bl), text: text)
}
/// เส้นที่วาดไปได้ส่วน f (0..1)
func partial(_ s: Stroke, _ f: Double) -> Stroke? {
    guard f > 0 else { return nil }
    var c = s
    switch s.tool {
    case .pen, .highlighter:
        let n = max(2, Int(Double(s.points.count) * min(1, f)))
        c.points = Array(s.points.prefix(n))
    case .text:
        let n = Int(Double(s.text.count) * min(1, f))
        c.text = String(s.text.prefix(n))
    default:
        c.points = [s.points[0], lerpP(s.points[0], s.points[1], ease(f))]
    }
    return c
}
func circlePath(_ cTL: CGPoint, _ rx: CGFloat, _ ry: CGFloat, turns: Double = 1.08, n: Int = 48) -> [CGPoint] {
    (0...n).map { i in
        let a = -Double.pi * 0.6 + Double(i) / Double(n) * turns * 2 * .pi
        let wob = 1 + 0.04 * sin(Double(i) * 0.7)
        return CGPoint(x: cTL.x + rx * CGFloat(cos(a) * wob), y: cTL.y + ry * CGFloat(sin(a) * wob))
    }
}
func linePath(_ a: CGPoint, _ b: CGPoint, n: Int = 24, wave: CGFloat = 1.5) -> [CGPoint] {
    (0...n).map { i in let t = Double(i) / Double(n)
        return CGPoint(x: lerp(a.x, b.x, t), y: lerp(a.y, b.y, t) + wave * CGFloat(sin(t * 9))) }
}

/// ตำแหน่งปุ่มบนแถบเครื่องมือ (คำนวณแบบเดียวกับ OverlayView.layoutToolbar) → จุดกึ่งกลาง top-left
let TOOLBAR: [CGPoint] = {
    let pad: CGFloat = 12, gap: CGFloat = 5, sepW: CGFloat = 16, big: CGFloat = 32, dot: CGFloat = 26, height: CGFloat = 48
    var x = pad; var cs: [CGFloat] = []
    func add(_ s: CGFloat) { cs.append(x + s / 2); x += s + gap }
    func sep() { x -= gap; x += sepW + gap }
    for _ in Tool.allCases { add(big) }; sep()
    for _ in Palette.all { add(dot) }; sep()
    add(big); add(big); add(big); sep(); add(big)
    let width = x - gap + pad
    let minX = ((SCREEN.width - width) / 2).rounded()
    let yTL: CGFloat = 18 + height / 2
    return cs.map { CGPoint(x: minX + $0, y: yTL) }
}()
func toolIdx(_ t: Tool) -> Int { Tool.allCases.firstIndex(of: t)! }
func colorIdx(_ k: String) -> Int { Tool.allCases.count + Palette.all.firstIndex { $0.key == k }! }

// MARK: - ฉาก

struct Line { let cap: String; let say: String
    init(_ cap: String, say: String? = nil) { self.cap = cap; self.say = say ?? cap } }

struct FrameInfo {
    let p: Painter; let t: Double; let dur: Double; let cues: [Double]
    func cue(_ i: Int) -> Double { i < cues.count ? cues[i] : dur }
    /// ความคืบหน้า 0..1 ระหว่างเวลา a..b (วินาทีของฉาก)
    func prog(_ a: Double, _ b: Double) -> Double { ease((t - a) / max(0.001, b - a)) }
}

final class Scene {
    enum Kind { case title, chapter, screen }
    let kind: Kind
    var chapter = ""
    var lines: [Line] = []
    var panelTitle = ""
    var keys: [[String]] = []
    var bullets: [String] = []
    var note = ""
    var minDur = 0.0
    var draw: @MainActor (FrameInfo) -> Void = { _ in }
    // คำนวณภายหลัง
    var start = 0.0, dur = 0.0, cues: [Double] = [], lineDur: [Double] = [], audio: [URL] = []
    init(_ k: Kind) { kind = k }
}

// MARK: - โหลดทรัพยากร

func loadCG(_ path: String) -> CGImage {
    let url = ROOT.appendingPathComponent(path)
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { fatalError("โหลดภาพไม่ได้: \(path)") }
    return img
}

func blurred(_ img: CGImage, radius: CGFloat) -> CGImage {
    let ci = CIImage(cgImage: img)
    let f = CIFilter(name: "CIGaussianBlur")!
    f.setValue(ci.clampedToExtent(), forKey: kCIInputImageKey); f.setValue(radius, forKey: kCIInputRadiusKey)
    return CIContext().createCGImage(f.outputImage!.cropped(to: ci.extent), from: ci.extent)!
}

// MARK: - main

@MainActor func runMain() {
    _ = NSApplication.shared
    let slideCG = loadCG("assets/slide.png")
    let slide = NSImage(cgImage: slideCG, size: SCREEN)
    let slideBlur = NSImage(cgImage: blurred(slideCG, radius: 26), size: SCREEN)
    let capDMG = loadCG("captures/01_dmg_window.jpg")
    let capSec = loadCG("captures/02_privacy_security.jpg")
    let capRec = loadCG("captures/03_screen_recording.jpg")
    let icon = loadCG("assets/icon.png")
    let stage = Stage(slide: slide)
    var cache: [String: CGImage] = [:]
    func memo(_ key: String, _ make: () -> CGImage) -> CGImage {
        if let c = cache[key] { return c }; let i = make(); cache[key] = i; return i
    }

    var scenes: [Scene] = []
    func S(_ k: Scene.Kind, _ ch: String, _ build: (Scene) -> Void) { let s = Scene(k); s.chapter = ch; build(s); scenes.append(s) }

    // ---------- พื้นฐาน: วาดจอ ----------
    func screenFrame(_ p: Painter) {
        p.round(SCREEN_RECT.insetBy(dx: -2, dy: -2), 14, fill: rgb(0x05070C))
    }
    func drawScreen(_ p: Painter, _ img: CGImage, crop: CGRect, under: CGImage? = nil) {
        let sx = CGFloat(img.width) / SCREEN.width
        p.ctx.saveGState()
        p.ctx.addPath(CGPath(roundedRect: SCREEN_RECT, cornerWidth: 12, cornerHeight: 12, transform: nil)); p.ctx.clip()
        if let under {
            let ux = CGFloat(under.width) / SCREEN.width
            p.image(under, in: SCREEN_RECT, from: CGRect(x: crop.minX * ux, y: crop.minY * ux, width: crop.width * ux, height: crop.height * ux))
        }
        p.image(img, in: SCREEN_RECT, from: CGRect(x: crop.minX * sx, y: crop.minY * sx, width: crop.width * sx, height: crop.height * sx))
        p.ctx.restoreGState()
    }
    func desktopBG(_ p: Painter) {
        p.ctx.saveGState()
        p.ctx.addPath(CGPath(roundedRect: SCREEN_RECT, cornerWidth: 12, cornerHeight: 12, transform: nil)); p.ctx.clip()
        let g = CGGradient(colorsSpace: bitmapSpace, colors: [rgb(0x2B3F7A).cgColor, rgb(0x6A4C93).cgColor, rgb(0xD9757A).cgColor] as CFArray, locations: [0, 0.6, 1])!
        p.ctx.drawLinearGradient(g, start: CGPoint(x: SCREEN_RECT.minX, y: SCREEN_RECT.minY), end: CGPoint(x: SCREEN_RECT.maxX, y: SCREEN_RECT.maxY), options: [])
        p.ctx.restoreGState()
    }
    /// วางภาพหน้าต่างจริง (crop พิกเซล) ลงกลางจอ พร้อมเงา
    func windowShot(_ p: Painter, _ img: CGImage, crop: CGRect, maxW: CGFloat, maxH: CGFloat, center: CGPoint? = nil, scale: CGFloat = 1) -> CGRect {
        let k = min(maxW / crop.width, maxH / crop.height) * scale
        let w = crop.width * k, h = crop.height * k
        let c = center ?? CGPoint(x: SCREEN_RECT.midX, y: SCREEN_RECT.midY)
        let r = CGRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h)
        p.ctx.saveGState()
        p.ctx.setShadow(offset: CGSize(width: 0, height: 18), blur: 40, color: NSColor.black.withAlphaComponent(0.55).cgColor)
        p.round(r, 14, fill: .white)
        p.ctx.restoreGState()
        p.ctx.saveGState()
        p.ctx.addPath(CGPath(roundedRect: r, cornerWidth: 14, cornerHeight: 14, transform: nil)); p.ctx.clip()
        p.image(img, in: r, from: crop)
        p.ctx.restoreGState()
        return r
    }
    func callout(_ p: Painter, _ s: String, at pt: CGPoint, color: NSColor = C_HL, w: CGFloat = 340) {
        let f = font(24, "Bold"); let h = p.textHeight(s, f, width: w - 28) + 18
        let r = CGRect(x: pt.x, y: pt.y, width: w, height: h)
        p.ctx.saveGState(); p.ctx.setShadow(offset: CGSize(width: 0, height: 6), blur: 14, color: NSColor.black.withAlphaComponent(0.4).cgColor)
        p.round(r, 12, fill: color); p.ctx.restoreGState()
        p.text(s, f, rgb(0x1A1A1A), in: r.insetBy(dx: 14, dy: 9))
    }

    // ===================== สคริปต์ =====================

    // 0 · เปิดเรื่อง
    S(.title, "") { s in
        s.lines = [Line("สวัสดีค่ะ วิดีโอนี้จะพาใช้งานโปรแกรม ZoomJor ทีละขั้นตอน", say: "สวัสดีค่ะ วิดีโอนี้จะพาใช้งานโปรแกรมซูมจอ ทีละขั้นตอน"),
                   Line("ตั้งแต่การติดตั้ง การเรียกใช้ จนครบทุกโหมด")]
        s.draw = { f in
            let p = f.p
            let a = CGFloat(f.prog(0, 0.8))
            p.ctx.saveGState(); p.ctx.setAlpha(a)
            let ir = CGRect(x: 760 - 20, y: 250, width: 400, height: 400)
            p.ctx.setShadow(offset: CGSize(width: 0, height: 20), blur: 50, color: NSColor.black.withAlphaComponent(0.5).cgColor)
            p.image(icon, in: CGRect(x: 960 - 150, y: 210, width: 300, height: 300))
            p.ctx.restoreGState()
            _ = ir
            p.text("ZoomJor", font(110, "Bold"), C_TEXT, in: CGRect(x: 0, y: 540, width: VW, height: 140), align: .center)
            p.text("ซูมจอ · วิดีโอสอนการใช้งาน ทุกเมนู ทุกขั้นตอน", font(44, "Medium"), C_MUTED, in: CGRect(x: 0, y: 690, width: VW, height: 70), align: .center)
            let w = p.keys(["⌃", "1"], at: .zero, size: 0.01) // วัดไม่ใช้
            _ = w
            var x: CGFloat = 960 - 2 * 160 + 10
            for (k, label) in [("1", "ซูม"), ("2", "วาด"), ("3", "นาฬิกา"), ("4", "ซูมสด")] {
                let ww = p.keys(["⌃", k], at: CGPoint(x: x, y: 800), size: 46, dark: true)
                p.text(label, font(26, "SemiBold"), C_TEXT, in: CGRect(x: x, y: 856, width: ww, height: 40), align: .center)
                x += 160
            }
        }
    }

    // 0.5 · ภาพรวม 4 โหมด (บนจอจริง)
    S(.screen, "ภาพรวม") { s in
        s.panelTitle = "ZoomJor ทำอะไรได้"
        s.keys = [["⌃", "1"], ["⌃", "2"], ["⌃", "3"], ["⌃", "4"]]
        s.bullets = ["ซูมหน้าจอ (แช่ภาพ)", "วาดทับหน้าจอสด", "นาฬิกาจับเวลาพัก", "ซูมสด คลิกทะลุได้"]
        s.lines = [Line("ZoomJor เป็นโปรแกรมช่วยสอนและนำเสนอบนเครื่อง Mac", say: "ซูมจอเป็นโปรแกรมช่วยสอน และนำเสนอบนเครื่องแมค"),
                   Line("มี 4 โหมด: ซูมหน้าจอ · วาดทับหน้าจอ · นาฬิกาจับเวลาพัก · ซูมสด", say: "มีสี่โหมด คือ ซูมหน้าจอ วาดทับหน้าจอ นาฬิกาจับเวลาพัก และซูมสด"),
                   Line("ทุกโหมดเรียกด้วยปุ่ม Control คู่กับเลข 1 ถึง 4 กดได้จากทุกโปรแกรม", say: "ทุกโหมดเรียกด้วยปุ่มคอนโทรล คู่กับเลขหนึ่งถึงสี่ กดได้จากทุกโปรแกรม")]
        s.draw = { f in
            let z = lerpR(full(), zoomRect(CGPoint(x: 756, y: 491), 1.08), f.prog(0, f.dur))
            drawScreen(f.p, slideCG, crop: z)
        }
    }

    // ===== บทที่ 1 ติดตั้ง =====
    S(.chapter, "1 · ติดตั้ง") { s in s.lines = [Line("บทที่ 1 การติดตั้ง", say: "บทที่หนึ่ง การติดตั้ง")]; s.minDur = 2.2 }

    S(.screen, "1 · ติดตั้ง") { s in
        s.panelTitle = "ลากไปไว้ใน Applications"
        s.bullets = ["ดับเบิลคลิกไฟล์ ZoomJor-1.1.dmg", "ลากไอคอน ZoomJor ไปวางบน Applications", "เสร็จแล้ว ปิดหน้าต่างนี้ได้เลย"]
        s.lines = [Line("ดับเบิลคลิกไฟล์ ZoomJor-1.1.dmg จะมีหน้าต่างนี้ขึ้นมา", say: "ดับเบิลคลิกไฟล์ ซูมจอ ดอท ดีเอ็มจี จะมีหน้าต่างนี้ขึ้นมา"),
                   Line("ลากไอคอน ZoomJor ไปวางบนโฟลเดอร์ Applications ทางซ้าย เป็นอันติดตั้งเสร็จ", say: "ลากไอคอนซูมจอ ไปวางบนโฟลเดอร์ แอปพลิเคชัน ทางซ้าย เป็นอันติดตั้งเสร็จ")]
        let crop = CGRect(x: 0, y: 0, width: 1000, height: 470)
        s.draw = { f in
            desktopBG(f.p)
            let r = windowShot(f.p, capDMG, crop: crop, maxW: 1100, maxH: 560)
            let k = r.width / crop.width
            func at(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x * k, y: r.minY + y * k) }
            let appIcon = at(456, 130), apps = at(170, 130)
            let t0 = f.cue(1) + 0.3, t1 = t0 + 1.8
            let pr = f.prog(t0, t1)
            if f.t >= t0 - 0.6 {
                let cur = lerpP(appIcon, apps, pr)
                if pr > 0 && pr < 1 {
                    f.p.ctx.saveGState(); f.p.ctx.setAlpha(0.55)
                    f.p.image(capDMG, in: CGRect(x: cur.x - 40 * k, y: cur.y - 40 * k, width: 80 * k, height: 80 * k),
                              from: CGRect(x: 416, y: 90, width: 80, height: 80))
                    f.p.ctx.restoreGState()
                }
                if pr >= 1 { f.p.ring(apps, 70 * k, C_HL, lw: 6, alpha: 0.9) }
                f.p.arrow(from: CGPoint(x: appIcon.x, y: appIcon.y + 100 * k), to: CGPoint(x: apps.x + 20, y: apps.y + 100 * k), color: C_HL, lw: 6)
                f.p.cursor(at: CGPoint(x: cur.x + 6, y: cur.y + 6), pressed: pr > 0 && pr < 1)
            }
        }
    }

    S(.screen, "1 · ติดตั้ง") { s in
        s.panelTitle = "ปลดล็อกครั้งแรก"
        s.bullets = ["กล่องเตือน → กด “เสร็จสิ้น”", "การตั้งค่าระบบ → ความเป็นส่วนตัวและความปลอดภัย", "ส่วน Security → กด “เปิดอยู่ดี”", "ทำครั้งเดียวจบ"]
        s.lines = [Line("เปิดครั้งแรก เครื่องจะเตือนว่า “ตรวจสอบหามัลแวร์ไม่ได้” — เป็นเรื่องปกติของโปรแกรมแจกฟรี", say: "เปิดครั้งแรก เครื่องจะเตือนว่า ตรวจสอบหามัลแวร์ไม่ได้ ซึ่งเป็นเรื่องปกติ ของโปรแกรมแจกฟรี"),
                   Line("กด “เสร็จสิ้น” แล้วไปที่ การตั้งค่าระบบ → ความเป็นส่วนตัวและความปลอดภัย", say: "ให้กดเสร็จสิ้น แล้วไปที่ การตั้งค่าระบบ หัวข้อความเป็นส่วนตัว และความปลอดภัย"),
                   Line("เลื่อนลงมาที่ส่วน Security จะมีแถวแจ้งว่า ZoomJor ถูกบล็อก ให้กด “เปิดอยู่ดี” ทำครั้งเดียวจบ", say: "เลื่อนลงมาที่ส่วนความปลอดภัย จะมีแถวแจ้งว่าซูมจอถูกบล็อก ให้กดปุ่ม เปิดอยู่ดี ทำครั้งเดียวจบค่ะ")]
        let crop = CGRect(x: 375, y: 60, width: 770, height: 960)
        s.draw = { f in
            desktopBG(f.p)
            let r = windowShot(f.p, capSec, crop: crop, maxW: 800, maxH: 840, center: CGPoint(x: SCREEN_RECT.midX + 120, y: SCREEN_RECT.midY))
            let k = r.width / crop.width
            // ป้ายอธิบาย: ตำแหน่งที่แถว "ถูกบล็อก" จะขึ้น (ใต้ "Allow applications from")
            if f.t > f.cue(2) {
                let y = r.minY + (676 - 60) * k
                let box = CGRect(x: r.minX + 8 * k, y: y, width: r.width - 16 * k, height: 44 * k)
                f.p.ctx.saveGState(); f.p.ctx.setLineDash(phase: 0, lengths: [10, 7])
                f.p.round(box, 10, fill: C_HL.withAlphaComponent(0.25), stroke: C_HL, lw: 3); f.p.ctx.restoreGState()
                f.p.text("“ZoomJor” ถูกบล็อก…   [ เปิดอยู่ดี ]", font(22, "Bold"), rgb(0x3A2A00),
                         in: CGRect(x: box.minX + 14, y: box.midY - 14, width: box.width - 20, height: 30))
                callout(f.p, "แถวนี้ขึ้นหลังกด “เสร็จสิ้น” ที่กล่องเตือน", at: CGPoint(x: SCREEN_RECT.minX + 30, y: box.minY - 10), w: 300)
            } else if f.t > f.cue(1) {
                f.p.ring(CGPoint(x: r.minX + 560 * k, y: r.minY + (638 - 60) * k), 46, C_HL, lw: 5, alpha: 0.9)
            }
        }
    }

    S(.screen, "1 · ติดตั้ง") { s in
        s.panelTitle = "ให้สิทธิ์บันทึกหน้าจอ"
        s.bullets = ["ระบบถามตอนกด ⌃1 ครั้งแรก", "เปิดสวิตช์ของ ZoomJor", "ปิดแล้วเปิดโปรแกรมใหม่ 1 ครั้ง", "โหมดวาด ⌃2 ไม่ต้องขอสิทธิ์"]
        s.lines = [Line("ครั้งแรกที่กดซูม ระบบจะขอสิทธิ์ “การบันทึกหน้าจอ”", say: "ครั้งแรกที่กดซูม ระบบจะขอสิทธิ์ การบันทึกหน้าจอ"),
                   Line("เปิดสวิตช์ของ ZoomJor ในหน้านี้ แล้วปิด-เปิดโปรแกรมใหม่ 1 ครั้ง", say: "ให้เปิดสวิตช์ของซูมจอ ในหน้านี้ แล้วปิดเปิดโปรแกรมใหม่ หนึ่งครั้ง")]
        let crop = CGRect(x: 0, y: 70, width: 952, height: 887)
        s.draw = { f in
            desktopBG(f.p)
            let r = windowShot(f.p, capRec, crop: crop, maxW: 760, maxH: 830)
            let k = r.width / crop.width
            if f.t > f.cue(1) - 0.2 {
                let row = CGRect(x: r.minX + 18 * k, y: r.minY + (822 - 70) * k, width: r.width - 36 * k, height: 70 * k)
                f.p.round(row, 10, stroke: C_HL, lw: 4)
                let pulse = 0.5 + 0.5 * sin(f.t * 5)
                f.p.ring(CGPoint(x: r.minX + 878 * k, y: r.minY + (858 - 70) * k), 34 + CGFloat(pulse) * 6, C_HL, lw: 4)
            }
        }
    }

    // ===== บทที่ 2 เรียกใช้ =====
    S(.chapter, "2 · เรียกใช้งาน") { s in s.lines = [Line("บทที่ 2 การเรียกใช้งาน", say: "บทที่สอง การเรียกใช้งาน")]; s.minDur = 2.2 }

    S(.screen, "2 · เรียกใช้งาน") { s in
        s.panelTitle = "อยู่บนแถบเมนู"
        s.keys = [["⌃", "⌥", "M"]]
        s.bullets = ["เปิดแล้วไม่มีหน้าต่าง — ปกติ", "ไอคอนแว่นขยายอยู่ขวาบน", "แถบเมนูเต็ม → ⌃⌥M เปิดเมนู"]
        s.lines = [Line("เปิดโปรแกรมแล้วจะไม่มีหน้าต่างขึ้นมา เพราะ ZoomJor ทำงานอยู่บนแถบเมนูด้านขวาบน", say: "เปิดโปรแกรมแล้ว จะไม่มีหน้าต่างขึ้นมา เพราะซูมจอทำงานอยู่บนแถบเมนู ด้านขวาบน"),
                   Line("คลิกไอคอนแว่นขยาย หรือกด Control + Option + M เพื่อเปิดเมนูตรงตำแหน่งเมาส์", say: "คลิกไอคอนแว่นขยาย หรือกด คอนโทรล ออปชัน เอ็ม เพื่อเปิดเมนูตรงตำแหน่งเมาส์"),
                   Line("ในเมนูมีครบทุกโหมด เลือกสีเส้น เครื่องมือ และเวลาพักเริ่มต้นได้", say: "ในเมนูมีครบทุกโหมด เลือกสีเส้น เครื่องมือ และเวลาพักเริ่มต้นได้")]
        s.draw = { f in
            drawScreen(f.p, slideCG, crop: full())
            // แผนภาพเมนู (รายการตรงกับ AppDelegate)
            let items: [(String, String)] = [("ซูมหน้าจอ  (Zoom)", "⌃1"), ("วาดบนหน้าจอ  (Draw)", "⌃2"), ("จับเวลาถอยหลัง  (Timer)", "⌃3"),
                                             ("ซูมสด  (Live zoom)", "⌃4"), ("-", ""), ("เวลาพักเริ่มต้น", "›"), ("สีเส้น", "›"), ("เครื่องมือ", "›"),
                                             ("-", ""), ("วิธีใช้ / คีย์ลัด…", ""), ("ออกจากโปรแกรม", "⌃⌥Q")]
            let a = CGFloat(f.prog(f.cue(1), f.cue(1) + 0.4))
            guard a > 0 else {
                let pulse = CGFloat(0.5 + 0.5 * sin(f.t * 5))
                f.p.ring(CGPoint(x: SCREEN_RECT.maxX - 120, y: SCREEN_RECT.minY + 14), 22 + pulse * 5, C_HL, lw: 4)
                return
            }
            let mx = SCREEN_RECT.minX + 760, my = SCREEN_RECT.minY + 210
            let rowH: CGFloat = 40, w: CGFloat = 430
            let h = items.reduce(16) { $0 + ($1.0 == "-" ? 14 : rowH) }
            f.p.ctx.saveGState(); f.p.ctx.setAlpha(a)
            f.p.ctx.setShadow(offset: CGSize(width: 0, height: 14), blur: 30, color: NSColor.black.withAlphaComponent(0.4).cgColor)
            f.p.round(CGRect(x: mx, y: my, width: w, height: h), 14, fill: rgb(0xF2F3F6, 0.97))
            f.p.ctx.setShadow(offset: .zero, blur: 0, color: nil)
            var y = my + 8
            for (i, it) in items.enumerated() {
                if it.0 == "-" { f.p.fill(CGRect(x: mx + 14, y: y + 6, width: w - 28, height: 1), rgb(0xC9CDD6)); y += 14; continue }
                if i == 0 && f.t > f.cue(2) { f.p.round(CGRect(x: mx + 6, y: y, width: w - 12, height: rowH - 4), 8, fill: C_ACCENT) }
                let ink = (i == 0 && f.t > f.cue(2)) ? NSColor.white : rgb(0x1C2230)
                f.p.text(it.0, font(23, "Medium"), ink, in: CGRect(x: mx + 22, y: y + 5, width: 300, height: 34))
                f.p.text(it.1, font(22, "Medium"), (i == 0 && f.t > f.cue(2)) ? .white : rgb(0x7A8194), in: CGRect(x: mx + w - 120, y: y + 5, width: 100, height: 34), align: .right)
                y += rowH
            }
            f.p.cursor(at: CGPoint(x: mx - 6, y: my - 6))
            f.p.ctx.restoreGState()
            f.p.text("แผนภาพเมนู — รายการเดียวกับในโปรแกรม", font(19, "Medium"), rgb(0xFFFFFF, 0.85),
                     in: CGRect(x: mx, y: my + h + 10, width: w, height: 30), align: .center, shadow: true)
        }
    }

    // ===== บทที่ 3 ซูม =====
    S(.chapter, "3 · ซูมหน้าจอ ⌃1") { s in s.lines = [Line("บทที่ 3 ซูมหน้าจอ", say: "บทที่สาม ซูมหน้าจอ")]; s.minDur = 2.2 }

    S(.screen, "3 · ซูมหน้าจอ ⌃1") { s in
        s.panelTitle = "ซูมหน้าจอ"
        s.keys = [["⌃", "1"]]
        s.bullets = ["แช่ภาพหน้าจอ แล้วขยาย 2 เท่า", "เลื่อนเมาส์ = ส่องตามเมาส์", "สกอร์ล / ↑ ↓ = ปรับซูม 1–16×", "0 = กลับ 100%"]
        s.lines = [Line("กด Control + 1 หน้าจอจะถูกแช่ไว้ แล้วขยายขึ้น 2 เท่า", say: "กด คอนโทรล หนึ่ง หน้าจอจะถูกแช่ไว้ แล้วขยายขึ้นสองเท่า"),
                   Line("เลื่อนเมาส์เพื่อส่องไปยังจุดที่ต้องการ", say: "เลื่อนเมาส์ เพื่อส่องไปยังจุดที่ต้องการ"),
                   Line("หมุนลูกกลิ้งเมาส์ หรือกดลูกศรขึ้น-ลง เพื่อปรับระดับซูม ได้ถึง 16 เท่า", say: "หมุนลูกกลิ้งเมาส์ หรือกดลูกศรขึ้นลง เพื่อปรับระดับซูม ได้ถึงสิบหกเท่า")]
        s.draw = { f in
            let t1 = f.cue(0) + 1.0
            if f.t < t1 {
                drawScreen(f.p, slideCG, crop: full())
                if f.t > f.cue(0) + 0.2 { f.p.keys(["⌃", "1"], at: CGPoint(x: SCREEN_RECT.midX - 60, y: SCREEN_RECT.midY - 30), size: 64) }
                return
            }
            // focus เคลื่อนจาก R1 → ตาราง แล้วซูมเพิ่ม
            let a = CGPoint(x: 300, y: 300), b = CGPoint(x: 540, y: 380), c = CGPoint(x: 330, y: 280)
            var focus = a; var z: CGFloat = 2
            if f.t > f.cue(1) { focus = lerpP(a, b, f.prog(f.cue(1), f.cue(1) + 2.2)) }
            if f.t > f.cue(1) + 2.4 { focus = lerpP(b, c, f.prog(f.cue(1) + 2.4, f.cue(2))) }
            if f.t > f.cue(2) { z = lerp(2, 3.5, f.prog(f.cue(2) + 0.3, f.cue(2) + 2.6)) }
            let key = "z1-\(Int(focus.x))-\(Int(focus.y))-\(Int(z * 20))"
            let img = memo(key) { stage.zoomMode(focusTL: focus, zoom: z); return stage.image() }
            drawScreen(f.p, img, crop: full())
            f.p.text(String(format: "ซูม %.1f×", z), font(30, "Bold"), C_HL, in: CGRect(x: SCREEN_RECT.maxX - 190, y: SCREEN_RECT.maxY - 60, width: 170, height: 40), align: .right, shadow: true)
        }
    }

    S(.screen, "3 · ซูมหน้าจอ ⌃1") { s in
        s.panelTitle = "วาดบนภาพที่ซูม"
        s.keys = [["Esc"]]
        s.bullets = ["คลิกลาก = วาด (ภาพล็อกให้เอง)", "Tab = ปลดล็อกให้ส่องต่อ", "Esc หรือคลิกขวา = ออก"]
        s.lines = [Line("คลิกลากเพื่อวาดได้ทันที ภาพจะล็อกให้อัตโนมัติ", say: "คลิกลาก เพื่อวาดได้ทันที ภาพจะล็อกให้อัตโนมัติ"),
                   Line("เสร็จแล้วกด Esc หรือคลิกขวา เพื่อออกจากโหมด", say: "เสร็จแล้วกดเอสเคป หรือคลิกขวา เพื่อออกจากโหมด")]
        let focus = CGPoint(x: 330, y: 280), z: CGFloat = 3.5
        let arrow = mk(.arrow, "r", 5, [CGPoint(x: 420, y: 350), CGPoint(x: 296, y: 292)])
        let ring = mk(.pen, "r", 4, circlePath(CGPoint(x: 284, y: 248), 52, 20))
        s.draw = { f in
            let pa = f.prog(f.cue(0) + 0.5, f.cue(0) + 1.6), pr = f.prog(f.cue(0) + 1.9, f.cue(0) + 3.2)
            let qa = Int(pa * 20), qr = Int(pr * 24)
            let img = memo("z2-\(qa)-\(qr)") {
                stage.zoomMode(focusTL: focus, zoom: z)
                stage.strokes([partial(arrow, Double(qa) / 20), partial(ring, Double(qr) / 24)].compactMap { $0 })
                return stage.image()
            }
            drawScreen(f.p, img, crop: full())
            let m = ScreenMap(crop: zoomRect(focus, z))
            // เคอร์เซอร์ตามปลายเส้น (จอจริงซูม 3.5 → แปลงพิกัด)
            if pa > 0 && pa < 1 { f.p.crosshair(at: m.v(lerpP(arrow.points[0].tl, arrow.points[1].tl, pa))) }
            else if pr > 0 && pr < 1, let last = partial(ring, pr)?.points.last { f.p.crosshair(at: m.v(last.tl)) }
            if f.t > f.cue(1) { f.p.keys(["Esc"], at: CGPoint(x: SCREEN_RECT.midX - 50, y: SCREEN_RECT.maxY - 110), size: 60) }
        }
    }

    // ===== บทที่ 4 วาด =====
    S(.chapter, "4 · วาดทับหน้าจอ ⌃2") { s in s.lines = [Line("บทที่ 4 วาดทับหน้าจอ", say: "บทที่สี่ วาดทับหน้าจอ")]; s.minDur = 2.2 }

    // ชุดเส้นที่สะสมไปเรื่อย ๆ ในบทนี้
    let penLED = mk(.pen, "r", 5, circlePath(CGPoint(x: 617, y: 359), 58, 52))
    let arrWarn = mk(.arrow, "r", 6, [CGPoint(x: 720, y: 720), CGPoint(x: 560, y: 622)])
    let boxRow = mk(.rect, "r", 5, [CGPoint(x: 870, y: 333), CGPoint(x: 1424, y: 375)])
    let gCheck = mk(.pen, "g", 6, [CGPoint(x: 1352, y: 676), CGPoint(x: 1362, y: 688), CGPoint(x: 1372, y: 698), CGPoint(x: 1392, y: 672), CGPoint(x: 1410, y: 650)])
    let kUnder = mk(.line, "k", 4, [CGPoint(x: 925, y: 712), CGPoint(x: 1200, y: 712)])
    let bArrow = mk(.arrow, "b", 6, [CGPoint(x: 300, y: 520), CGPoint(x: 362, y: 456)])
    let yHL = mk(.highlighter, "y", 6, linePath(CGPoint(x: 100, y: 507), CGPoint(x: 560, y: 507), wave: 0.6))
    let bText = mk(.text, "b", 5, [CGPoint(x: 660, y: 470)], text: "ต่อขั้วให้ถูก!")
    let ovalA = mk(.ellipse, "o", 5, [CGPoint(x: 340, y: 416), CGPoint(x: 414, y: 474)])

    func drawModeImage(_ key: String, tool: Tool, colorKey: String, strokes: [Stroke], keys: [(Int, String)] = [], hover: Int? = nil, help: Bool = false) -> CGImage {
        memo(key) {
            stage.drawMode()
            for (c, ch) in keys { stage.key(c, ch) }
            stage.v.tool = tool
            stage.v.color = pal(colorKey).color
            stage.strokes(strokes)
            if let hover { stage.v.testHover(hover) }
            if help { stage.key(kVK_ANSI_Slash, "/") }
            return stage.image()
        }
    }

    S(.screen, "4 · วาดทับหน้าจอ ⌃2") { s in
        s.panelTitle = "วาดทับหน้าจอ"
        s.keys = [["⌃", "2"]]
        s.bullets = ["วาดบนจอสด ไม่แช่ภาพ", "แถบเครื่องมือด้านบน คลิกเลือกได้", "ค่าเริ่มต้น = ปากกา", "ไม่ต้องขอสิทธิ์บันทึกหน้าจอ"]
        s.lines = [Line("กด Control + 2 เพื่อวาดทับหน้าจอได้ทันที ด้านบนจะมีแถบเครื่องมือให้คลิกเลือก", say: "กด คอนโทรล สอง เพื่อวาดทับหน้าจอได้ทันที ด้านบนจะมีแถบเครื่องมือให้คลิกเลือก"),
                   Line("ค่าเริ่มต้นเป็นปากกา ลากเมาส์เพื่อเขียนได้อิสระ", say: "ค่าเริ่มต้นเป็นปากกา ลากเมาส์ เพื่อเขียนได้อิสระ")]
        s.draw = { f in
            let t0 = f.cue(0) + 0.8
            if f.t < t0 { drawScreen(f.p, slideCG, crop: full())
                if f.t > f.cue(0) + 0.2 { f.p.keys(["⌃", "2"], at: CGPoint(x: SCREEN_RECT.midX - 60, y: SCREEN_RECT.midY - 30), size: 64) }
                return }
            let m = ScreenMap(crop: full())
            let hoverOn = f.t > f.cue(0) + 2.2 && f.t < f.cue(1)
            let pp = f.prog(f.cue(1) + 0.5, f.cue(1) + 2.6); let q = Int(pp * 30)
            let img = drawModeImage("d1-\(hoverOn)-\(q)", tool: .pen, colorKey: "r",
                                    strokes: [partial(penLED, Double(q) / 30)].compactMap { $0 }, hover: hoverOn ? toolIdx(.pen) : nil)
            drawScreen(f.p, img, crop: full(), under: slideCG)
            if hoverOn { f.p.cursor(at: m.v(TOOLBAR[toolIdx(.pen)]).applying(.init(translationX: 2, y: 4))) }
            if pp > 0 && pp < 1, let last = partial(penLED, pp)?.points.last { f.p.crosshair(at: m.v(last.tl)) }
            if f.t > f.cue(0) + 1.2 && f.t < f.cue(1) {
                f.p.round(CGRect(x: m.v(TOOLBAR[0]).x - 26, y: m.v(TOOLBAR[0]).y - 30, width: m.v(TOOLBAR[18]).x - m.v(TOOLBAR[0]).x + 52, height: 60), 12, stroke: C_HL, lw: 4)
            }
        }
    }

    S(.screen, "4 · วาดทับหน้าจอ ⌃2") { s in
        s.panelTitle = "ทางลัดขณะลาก"
        s.keys = [["⇧"], ["⌃", "⇧"], ["⌥"]]
        s.bullets = ["⇧ ค้าง = ลูกศร", "⌃⇧ ค้าง = สี่เหลี่ยม", "⌥ ค้าง = บังคับมุม 45° / จัตุรัส", "ไม่ต้องเปลี่ยนเครื่องมือ"]
        s.lines = [Line("กด Shift ค้างไว้ขณะลาก จะได้ลูกศร", say: "กดปุ่มชิฟต์ค้างไว้ขณะลาก จะได้ลูกศร"),
                   Line("กด Control กับ Shift ค้างไว้ จะได้กรอบสี่เหลี่ยม", say: "กดคอนโทรลกับชิฟต์ค้างไว้ จะได้กรอบสี่เหลี่ยม"),
                   Line("และกด Option ค้าง เพื่อบังคับให้ตรง 45 องศา หรือเป็นจัตุรัส", say: "และกดออปชันค้าง เพื่อบังคับให้ตรงสี่สิบห้าองศา หรือเป็นจัตุรัส")]
        s.draw = { f in
            let m = ScreenMap(crop: full())
            let pa = f.prog(f.cue(0) + 0.6, f.cue(0) + 1.8), pb = f.prog(f.cue(1) + 0.6, f.cue(1) + 1.9)
            let qa = Int(pa * 20), qb = Int(pb * 20)
            let img = drawModeImage("d2-\(qa)-\(qb)", tool: .pen, colorKey: "r",
                                    strokes: [penLED, partial(arrWarn, Double(qa) / 20), partial(boxRow, Double(qb) / 20)].compactMap { $0 })
            drawScreen(f.p, img, crop: full(), under: slideCG)
            if pa > 0 && pa < 1 { let pt = m.v(lerpP(arrWarn.points[0].tl, arrWarn.points[1].tl, pa)); f.p.crosshair(at: pt)
                f.p.keycap("⇧", at: CGPoint(x: pt.x + 20, y: pt.y + 16), size: 42) }
            if pb > 0 && pb < 1 { let pt = m.v(lerpP(boxRow.points[0].tl, boxRow.points[1].tl, pb)); f.p.crosshair(at: pt)
                f.p.keys(["⌃", "⇧"], at: CGPoint(x: pt.x + 20, y: pt.y + 16), size: 42) }
        }
    }

    S(.screen, "4 · วาดทับหน้าจอ ⌃2") { s in
        s.panelTitle = "เปลี่ยนสีเส้น"
        s.keys = [["R"], ["G"], ["Y"], ["K"], ["B"]]
        s.bullets = ["R แดง · G เขียว · Y เหลือง", "K ดำ · B น้ำเงิน", "W ขาว · O ส้ม · M ชมพู", "ใช้ได้แม้แป้นเป็นภาษาไทย"]
        s.lines = [Line("เปลี่ยนสีด้วยตัวอักษร: R แดง · G เขียว · Y เหลือง · K ดำ · B น้ำเงิน", say: "เปลี่ยนสีเส้นด้วยตัวอักษร อาร์ แดง จี เขียว วาย เหลือง เค ดำ บี น้ำเงิน"),
                   Line("หรือคลิกจุดสีบนแถบเครื่องมือก็ได้ — ใช้ได้แม้แป้นพิมพ์เป็นภาษาไทยอยู่", say: "หรือคลิกจุดสีบนแถบเครื่องมือก็ได้ ใช้ได้แม้แป้นพิมพ์เป็นภาษาไทยอยู่")]
        s.draw = { f in
            let m = ScreenMap(crop: full())
            let base = [penLED, arrWarn, boxRow]
            // 4 ช่วง: G ✓ · K ขีดเส้นใต้ · B ลูกศร · (Y แสดงสีบนแถบ)
            let seq: [(String, Int, Stroke?)] = [("g", kVK_ANSI_G, gCheck), ("y", kVK_ANSI_Y, nil), ("k", kVK_ANSI_K, kUnder), ("b", kVK_ANSI_B, bArrow)]
            let span = max(1.2, (f.cue(1) - f.cue(0) - 0.4) / Double(seq.count))
            var done: [Stroke] = []; var curKey = "r"; var curCode = 0; var live: Stroke? = nil; var lp = 0.0
            for (i, it) in seq.enumerated() {
                let a = f.cue(0) + 0.4 + Double(i) * span
                if f.t >= a { curKey = it.0; curCode = it.1 }
                if let st = it.2 {
                    let p = f.prog(a + 0.25, a + span * 0.8)
                    if p >= 1 { done.append(st) } else if p > 0 { live = st; lp = p }
                }
            }
            let q = Int(lp * 16)
            let img = drawModeImage("d3-\(curKey)-\(done.count)-\(q)", tool: .pen, colorKey: curKey,
                                    strokes: base + done + [live.flatMap { partial($0, Double(q) / 16) }].compactMap { $0 },
                                    keys: curCode == 0 ? [] : [(curCode, curKey)])
            drawScreen(f.p, img, crop: full(), under: slideCG)
            let c = m.v(TOOLBAR[colorIdx(curKey)])
            f.p.ring(c, 26, C_HL, lw: 4)
            if f.t > f.cue(0) + 0.4 { f.p.keycap(curKey.uppercased(), at: CGPoint(x: c.x - 26, y: c.y + 40), size: 52) }
            if let live, lp > 0 && lp < 1, let last = partial(live, lp)?.points.last { f.p.crosshair(at: m.v(last.tl)) }
        }
    }

    S(.screen, "4 · วาดทับหน้าจอ ⌃2") { s in
        s.panelTitle = "เครื่องมืออื่น ๆ"
        s.keys = [["H"], ["T"], ["C"], ["L"], ["[", "]"]]
        s.bullets = ["H ปากกาไฮไลต์ (โปร่งแสง)", "T ข้อความ — พิมพ์ไทยได้", "C วงรี · S สี่เหลี่ยม · L เส้นตรง", "[ ] ปรับขนาดเส้น"]
        s.lines = [Line("เครื่องมืออื่น: H ปากกาไฮไลต์ · T ข้อความ · C วงรี · L เส้นตรง", say: "เครื่องมืออื่น ได้แก่ เอช ปากกาไฮไลต์ ที วางข้อความ ซี วงรี และ แอล เส้นตรง"),
                   Line("ข้อความพิมพ์ภาษาไทยได้ กด Enter เพื่อจบ · ปรับขนาดเส้นด้วยปุ่ม [ และ ]", say: "ข้อความพิมพ์ภาษาไทยได้ กดเอนเทอร์เพื่อจบ และปรับขนาดเส้นด้วยปุ่มวงเล็บเหลี่ยม")]
        s.draw = { f in
            let m = ScreenMap(crop: full())
            let base = [penLED, arrWarn, boxRow, gCheck, kUnder, bArrow]
            let a0 = f.cue(0) + 0.3, span = max(1.3, (f.cue(1) + 1.6 - a0) / 3)
            let ph = f.prog(a0 + 0.2, a0 + span * 0.85), pt = f.prog(a0 + span + 0.2, a0 + span * 1.85), po = f.prog(a0 + 2 * span + 0.2, a0 + span * 2.85)
            var tool: Tool = .highlighter; var ck = "y"
            if f.t > a0 + span { tool = .text; ck = "b" }
            if f.t > a0 + 2 * span { tool = .ellipse; ck = "o" }
            let qh = Int(ph * 20), qt = Int(pt * 14), qo = Int(po * 16)
            var list = base
            if let s1 = partial(yHL, Double(qh) / 20) { list.append(s1) }
            if let s2 = partial(bText, Double(qt) / 14) { list.append(s2) }
            if let s3 = partial(ovalA, Double(qo) / 16) { list.append(s3) }
            let img = drawModeImage("d4-\(tool)-\(qh)-\(qt)-\(qo)", tool: tool, colorKey: ck, strokes: list)
            drawScreen(f.p, img, crop: full(), under: slideCG)
            f.p.ring(m.v(TOOLBAR[toolIdx(tool)]), 26, C_HL, lw: 4)
            f.p.keycap(tool == .highlighter ? "H" : tool == .text ? "T" : "C", at: CGPoint(x: m.v(TOOLBAR[toolIdx(tool)]).x - 26, y: m.v(TOOLBAR[0]).y + 40), size: 52)
            if ph > 0 && ph < 1, let last = partial(yHL, ph)?.points.last { f.p.crosshair(at: m.v(last.tl)) }
            if po > 0 && po < 1 { f.p.crosshair(at: m.v(lerpP(ovalA.points[0].tl, ovalA.points[1].tl, po))) }
        }
    }

    S(.screen, "4 · วาดทับหน้าจอ ⌃2") { s in
        s.panelTitle = "ย้อนกลับ · ลบ · บันทึก"
        s.keys = [["⌫"], ["E"], ["⌘", "S"], ["⌘", "C"]]
        s.bullets = ["⌫ หรือ ⌘Z = ย้อนกลับ", "E = ลบทั้งหมด", "⌘S = เซฟ PNG ลง Desktop", "⌘C = คัดลอกภาพ"]
        s.lines = [Line("ทำพลาด กด Backspace เพื่อย้อนกลับทีละขั้น หรือกด E เพื่อลบทั้งหมด", say: "ทำพลาด กดแบ็กสเปซ เพื่อย้อนกลับทีละขั้น หรือกดอี เพื่อลบทั้งหมด"),
                   Line("กด Command + S เพื่อบันทึกภาพพร้อมลายเส้นลง Desktop หรือ Command + C เพื่อคัดลอก", say: "กดคอมมานด์ เอส เพื่อบันทึกภาพพร้อมลายเส้นลงเดสก์ท็อป หรือคอมมานด์ ซี เพื่อคัดลอก")]
        s.draw = { f in
            var list = [penLED, arrWarn, boxRow, gCheck, kUnder, bArrow, yHL, bText, ovalA]
            let a = f.cue(0) + 0.8
            var shownKey = ""
            for i in 0..<3 where f.t > a + Double(i) * 0.7 { list.removeLast(); shownKey = "⌫" }
            if f.t > f.cue(0) + 3.6 { list = []; shownKey = "E" }
            if f.t > f.cue(1) { shownKey = "⌘S" }
            let cleared = list.isEmpty
            let img = drawModeImage("d5-\(list.count)", tool: .pen, colorKey: "b", strokes: list,
                                    keys: cleared ? [(kVK_ANSI_E, "e")] : [])
            drawScreen(f.p, img, crop: full(), under: slideCG)
            let pos = CGPoint(x: SCREEN_RECT.midX - 50, y: SCREEN_RECT.maxY - 120)
            switch shownKey {
            case "⌫": f.p.keycap("⌫", at: pos, size: 64)
            case "E": f.p.keycap("E", at: pos, size: 64)
            case "⌘S": f.p.keys(["⌘", "S"], at: CGPoint(x: pos.x - 30, y: pos.y), size: 64)
                callout(f.p, "บันทึกแล้ว: ZoomJor-2026-10-10_….png (บน Desktop)", at: CGPoint(x: SCREEN_RECT.midX - 260, y: pos.y - 90), color: C_TEXT, w: 520)
            default: break
            }
        }
    }

    // ===== บทที่ 5 นาฬิกา =====
    S(.chapter, "5 · นาฬิกาจับเวลาพัก ⌃3") { s in s.lines = [Line("บทที่ 5 นาฬิกาจับเวลาพัก", say: "บทที่ห้า นาฬิกาจับเวลาพัก")]; s.minDur = 2.2 }

    // เรนเดอร์หน้าปัดนาฬิกาตามเวลาจริง (วินาทีละภาพ) ล่วงหน้า
    var timerFrames: [CGImage] = []
    stage.timerMode(bg: slideBlur, minutes: 10)
    for i in 0..<9 { timerFrames.append(stage.image()); if i < 8 { Thread.sleep(forTimeInterval: 1.0) } }
    stage.key(kVK_Space, " ")
    let timerPaused = stage.image()
    for _ in 0..<9 { stage.key(kVK_DownArrow) }
    stage.key(kVK_Space, " ")
    Thread.sleep(forTimeInterval: 1.0)
    let timerLastMin = stage.image()
    for _ in 0..<2 { stage.key(kVK_DownArrow) }
    let timerExpiredA = stage.image(); Thread.sleep(forTimeInterval: 0.55)
    let timerExpiredB = stage.image()

    S(.screen, "5 · นาฬิกาจับเวลาพัก ⌃3") { s in
        s.panelTitle = "นาฬิกาจับเวลาพัก"
        s.keys = [["⌃", "3"]]
        s.bullets = ["เต็มจอ บนพื้นหลังเบลอ", "ค่าเริ่มต้น 10 นาที", "บอกเวลาที่จะกลับมาเรียน", "เปลี่ยนค่าเริ่มต้นได้ในเมนู"]
        s.lines = [Line("กด Control + 3 จะได้นาฬิกาจับเวลาถอยหลังเต็มจอ ค่าเริ่มต้น 10 นาที", say: "กด คอนโทรล สาม จะได้นาฬิกาจับเวลาถอยหลังเต็มจอ ค่าเริ่มต้นสิบนาที"),
                   Line("มีบอกเวลาที่จะกลับมาเรียนต่อให้ด้วย", say: "มีบอกเวลาที่จะกลับมาเรียนต่อให้ด้วย")]
        s.draw = { f in
            let t0 = f.cue(0) + 1.0
            if f.t < t0 { drawScreen(f.p, slideCG, crop: full())
                if f.t > f.cue(0) + 0.2 { f.p.keys(["⌃", "3"], at: CGPoint(x: SCREEN_RECT.midX - 60, y: SCREEN_RECT.midY - 30), size: 64) }
                return }
            let i = min(timerFrames.count - 1, Int(f.t - t0))
            drawScreen(f.p, timerFrames[i], crop: full())
        }
    }

    S(.screen, "5 · นาฬิกาจับเวลาพัก ⌃3") { s in
        s.panelTitle = "ปรับเวลา"
        s.keys = [["Space"], ["↑"], ["↓"], ["←"], ["→"]]
        s.bullets = ["Space = หยุด / เดินต่อ", "↑ ↓ = ± 1 นาที", "← → = ± 10 วินาที", "พิมพ์ตัวเลข + Enter = ตั้งเวลาใหม่", "⌘R = เริ่มนับใหม่"]
        s.lines = [Line("กด Space เพื่อหยุดชั่วคราว · ลูกศรขึ้น-ลง เพิ่มลดทีละ 1 นาที", say: "กดสเปซบาร์ เพื่อหยุดชั่วคราว ลูกศรขึ้นลง เพิ่มลดทีละหนึ่งนาที"),
                   Line("หรือพิมพ์ตัวเลข แล้วกด Enter เพื่อตั้งเวลาใหม่", say: "หรือพิมพ์ตัวเลข แล้วกดเอนเทอร์ เพื่อตั้งเวลาใหม่"),
                   Line("เหลือไม่ถึงนาที วงแหวนจะเปลี่ยนเป็นสีส้ม และเมื่อหมดเวลาจะกะพริบสีแดงพร้อมเสียงเตือน", say: "เหลือไม่ถึงนาที วงแหวนจะเปลี่ยนเป็นสีส้ม และเมื่อหมดเวลา จะกะพริบสีแดง พร้อมเสียงเตือน")]
        s.draw = { f in
            var img = timerPaused; var key = "Space"
            if f.t > f.cue(1) - 0.3 { img = timerLastMin; key = "↓" }
            if f.t > f.cue(2) + 1.6 { img = Int(f.t * 2) % 2 == 0 ? timerExpiredA : timerExpiredB; key = "" }
            drawScreen(f.p, img, crop: full())
            if !key.isEmpty { f.p.keycap(key, at: CGPoint(x: SCREEN_RECT.midX - 55, y: SCREEN_RECT.maxY - 110), size: 60) }
        }
    }

    // ===== บทที่ 6 ซูมสด =====
    S(.chapter, "6 · ซูมสด ⌃4") { s in s.lines = [Line("บทที่ 6 ซูมสด", say: "บทที่หก ซูมสด")]; s.minDur = 2.2 }

    let live = LiveZoomView(frame: CGRect(origin: .zero, size: SCREEN))
    live.image = slide; live.canvasSize = SCREEN; live.zoom = 2
    let panelImg: CGImage = {
        // ประกอบแถบควบคุมแบบเดียวกับ LiveZoomController.makePanel
        let width: CGFloat = 214, height: CGFloat = 40
        let backdrop = HUDBackdropView(frame: CGRect(origin: .zero, size: CGSize(width: width, height: height)))
        func iconButton(_ name: String) -> NSButton {
            let b = NSButton(image: NSImage(systemSymbolName: name, accessibilityDescription: nil)!, target: nil, action: nil)
            b.isBordered = false; b.contentTintColor = .white; return b
        }
        let minus = iconButton("minus"); minus.frame = CGRect(x: 10, y: 4, width: 34, height: 32)
        let label = NSTextField(labelWithString: "200%"); label.frame = CGRect(x: 48, y: 10, width: 62, height: 20)
        label.alignment = .center; label.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold); label.textColor = .white
        let plus = iconButton("plus"); plus.frame = CGRect(x: 114, y: 4, width: 34, height: 32)
        let close = iconButton("xmark"); close.frame = CGRect(x: 168, y: 4, width: 34, height: 32)
        let divider = NSBox(frame: CGRect(x: 156, y: 10, width: 1, height: 20)); divider.boxType = .separator
        [minus, label, plus, divider, close].forEach { backdrop.addSubview($0) }
        return renderNSView(backdrop, scale: 2, useCache: true)
    }()

    S(.screen, "6 · ซูมสด ⌃4") { s in
        s.panelTitle = "ซูมสด"
        s.keys = [["⌃", "4"], ["⌃", "⌥", "↑"], ["⌃", "⌥", "↓"]]
        s.bullets = ["ขยายภาพแบบเรียลไทม์", "คลิก/พิมพ์กับแอปข้างล่างได้ปกติ", "แถบลอยด้านบน: − % + ✕", "ออก: ⌃4 อีกครั้ง หรือ ✕"]
        s.note = "ฉากนี้เรนเดอร์จากโค้ดของโปรแกรม เพราะหน้าต่างซูมสดตั้งใจปิดไม่ให้ถูกบันทึกภาพ"
        s.lines = [Line("กด Control + 4 เพื่อขยายภาพแบบสด จุดเด่นคือยังคลิกและพิมพ์กับโปรแกรมข้างล่างได้ตามปกติ", say: "กด คอนโทรล สี่ เพื่อขยายภาพแบบสด จุดเด่นคือ ยังคลิกและพิมพ์ กับโปรแกรมข้างล่างได้ตามปกติ"),
                   Line("ด้านบนมีแถบปรับระดับซูม หรือกด Control + Option + ลูกศรขึ้น-ลง", say: "ด้านบนมีแถบปรับระดับซูม หรือกด คอนโทรล ออปชัน ลูกศรขึ้นลง"),
                   Line("กด Control + 4 อีกครั้ง หรือปุ่ม ✕ บนแถบ เพื่อออก — ในโหมดนี้ Esc จะไม่ทำงาน", say: "กดคอนโทรล สี่ อีกครั้ง หรือปุ่มกากบาทบนแถบ เพื่อออก ในโหมดนี้ ปุ่มเอสเคปจะไม่ทำงานค่ะ")]
        s.draw = { f in
            let t0 = f.cue(0) + 0.9
            if f.t < t0 { drawScreen(f.p, slideCG, crop: full())
                if f.t > f.cue(0) + 0.2 { f.p.keys(["⌃", "4"], at: CGPoint(x: SCREEN_RECT.midX - 60, y: SCREEN_RECT.midY - 30), size: 64) }
                return }
            let path = [CGPoint(x: 290, y: 280), CGPoint(x: 600, y: 360), CGPoint(x: 1000, y: 330), CGPoint(x: 1160, y: 690)]
            let span = (f.dur - t0 - 0.5) / Double(path.count - 1)
            let seg = min(path.count - 2, max(0, Int((f.t - t0) / span)))
            let cur = lerpP(path[seg], path[seg + 1], ease((f.t - t0 - Double(seg) * span) / span))
            live.cursor = tl2bl(cur)
            live.zoom = f.t > f.cue(1) + 1.2 ? 3 : 2
            let img = memo("lz-\(Int(cur.x / 3))-\(Int(cur.y / 3))-\(live.zoom)") { renderNSView(live) }
            drawScreen(f.p, img, crop: full())
            // แถบควบคุมลอย กลางด้านบน
            let m = ScreenMap(crop: full())
            let pw: CGFloat = 214 * m.k, ph: CGFloat = 40 * m.k
            let pr = CGRect(x: SCREEN_RECT.midX - pw / 2, y: SCREEN_RECT.minY + 14 * m.k, width: pw, height: ph)
            f.p.image(panelImg, in: pr)
            if f.t > f.cue(1) && f.t < f.cue(2) { f.p.round(pr.insetBy(dx: -8, dy: -8), 14, stroke: C_HL, lw: 4) }
            // เคอร์เซอร์จริงอยู่ตำแหน่งเดียวกับจุดที่ขยาย (ยึดจุดใต้เคอร์เซอร์)
            f.p.cursor(at: m.v(cur))
        }
    }

    // ===== บทที่ 7 ปิดโปรแกรม =====
    S(.chapter, "7 · ปิดโปรแกรม") { s in s.lines = [Line("บทที่ 7 การปิดโปรแกรม", say: "บทที่เจ็ด การปิดโปรแกรม")]; s.minDur = 2.2 }

    S(.screen, "7 · ปิดโปรแกรม") { s in
        s.panelTitle = "ออกจากโหมด ≠ ปิดโปรแกรม"
        s.keys = [["Esc"], ["⌃", "⌥", "Q"]]
        s.bullets = ["Esc / คลิกขวา = ออกจากโหมด", "⌃⌥Q = ปิดโปรแกรมจริง", "หรือเมนู → ออกจากโปรแกรม", "⌘Q ใช้ได้ขณะอยู่ในโหมด"]
        s.lines = [Line("กด Esc เป็นแค่การออกจากโหมด โปรแกรมยังทำงานอยู่บนแถบเมนู", say: "กดเอสเคป เป็นแค่การออกจากโหมด โปรแกรมยังทำงานอยู่บนแถบเมนู"),
                   Line("ถ้าจะปิดโปรแกรมจริง กด Control + Option + Q หรือเลือก “ออกจากโปรแกรม” จากเมนู", say: "ถ้าจะปิดโปรแกรมจริง กดคอนโทรล ออปชัน คิว หรือเลือก ออกจากโปรแกรม จากเมนู")]
        s.draw = { f in
            drawScreen(f.p, slideCG, crop: full())
            let p = f.p
            let cx = SCREEN_RECT.midX
            p.round(CGRect(x: cx - 520, y: SCREEN_RECT.midY - 170, width: 1040, height: 340), 22, fill: rgb(0x0E1320, 0.88))
            let a = f.t > f.cue(0) ? 1.0 : 0.35, b = f.t > f.cue(1) ? 1.0 : 0.35
            p.ctx.saveGState(); p.ctx.setAlpha(a)
            p.keycap("Esc", at: CGPoint(x: cx - 470, y: SCREEN_RECT.midY - 120), size: 76)
            p.text("ออกจากโหมด — โปรแกรมยังรันอยู่", font(36, "SemiBold"), C_TEXT, in: CGRect(x: cx - 340, y: SCREEN_RECT.midY - 108, width: 820, height: 60))
            p.ctx.restoreGState()
            p.ctx.saveGState(); p.ctx.setAlpha(b)
            let w = p.keys(["⌃", "⌥", "Q"], at: CGPoint(x: cx - 470, y: SCREEN_RECT.midY + 40), size: 76)
            p.text("ปิดโปรแกรมจริง", font(36, "SemiBold"), C_HL, in: CGRect(x: cx - 470 + w + 30, y: SCREEN_RECT.midY + 52, width: 600, height: 60))
            p.ctx.restoreGState()
        }
    }

    // สรุป
    S(.title, "สรุป") { s in
        s.lines = [Line("สรุปคีย์ลัดทั้งหมดอยู่ในหน้านี้ คู่มือฉบับเต็มอยู่ที่ github.com/teacherarm-dotcom/zoomjor", say: "สรุปคีย์ลัดทั้งหมดอยู่ในหน้านี้ ดาวน์โหลดคู่มือฉบับเต็มได้ที่กิตฮับ"),
                   Line("ขอบคุณที่รับชมค่ะ")]
        s.minDur = 9
        s.draw = { f in
            let p = f.p
            p.text("สรุปคีย์ลัด ZoomJor", font(58, "Bold"), C_TEXT, in: CGRect(x: 0, y: 70, width: VW, height: 80), align: .center)
            let rows: [([String], String)] = [
                (["⌃", "1"], "ซูมหน้าจอ"), (["⌃", "2"], "วาดทับหน้าจอ"), (["⌃", "3"], "นาฬิกาจับเวลาพัก"), (["⌃", "4"], "ซูมสด"),
                (["⇧"], "ลากเป็นลูกศร"), (["⌃", "⇧"], "ลากเป็นสี่เหลี่ยม"), (["R", "G", "Y", "K", "B"], "สีเส้น"), (["⌫"], "ย้อนกลับ"),
                (["E"], "ลบทั้งหมด"), (["⌘", "S"], "บันทึกภาพ"), (["Esc"], "ออกจากโหมด"), (["⌃", "⌥", "Q"], "ปิดโปรแกรม")]
            for (i, r) in rows.enumerated() {
                let col = i / 6, row = i % 6
                let x: CGFloat = col == 0 ? 330 : 1010, y: CGFloat = 200 + CGFloat(row) * 108
                let a = CGFloat(f.prog(Double(i) * 0.12, Double(i) * 0.12 + 0.4))
                p.ctx.saveGState(); p.ctx.setAlpha(a)
                let ks = r.0.count == 5 ? ["R", "G", "Y", "K", "B"] : r.0
                var w: CGFloat = 0
                if r.0.count == 5 { var xx = x; for k in ks { xx += p.keycap(k, at: CGPoint(x: xx, y: y), size: 56) + 8 }; w = xx - x }
                else { w = p.keys(ks, at: CGPoint(x: x, y: y), size: 56) }
                p.text(r.1, font(34, "SemiBold"), C_TEXT, in: CGRect(x: x + max(w, 230) + 24, y: y + 8, width: 380, height: 50))
                p.ctx.restoreGState()
            }
            p.text("github.com/teacherarm-dotcom/zoomjor", font(30, "Medium"), C_ACCENT, in: CGRect(x: 0, y: 870, width: VW, height: 50), align: .center)
        }
    }

    // ===================== เสียงพากย์ + เวลา =====================

    let audioDir = ROOT.appendingPathComponent("build/audio")
    try? FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
    let lead = 0.55, gap = 0.4, tail = 0.9
    var tcur = 0.0
    var idx = 0
    for sc in scenes {
        sc.start = tcur
        var t = lead
        for ln in sc.lines {
            idx += 1
            let url = audioDir.appendingPathComponent(String(format: "l%03d.aiff", idx))
            if !FileManager.default.fileExists(atPath: url.path) {
                let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
                p.arguments = ["-v", "Kanya", "-r", "178", "-o", url.path, ln.say]
                try! p.run(); p.waitUntilExit()
            }
            let af = try! AVAudioFile(forReading: url)
            let d = Double(af.length) / af.processingFormat.sampleRate
            sc.cues.append(t); sc.lineDur.append(d); sc.audio.append(url)
            t += d + gap
        }
        sc.dur = max(sc.minDur, t - gap + tail)
        tcur += sc.dur
    }
    let total = tcur
    print(String(format: "ฉาก %d · ความยาว %.1f วินาที", scenes.count, total))

    // ===================== วาดเฟรม =====================

    func chrome(_ p: Painter, _ sc: Scene, _ t: Double) {
        guard sc.kind == .screen else { return }
        screenFrame(p)
        // แผงขวา
        var y: CGFloat = 52
        p.text(sc.chapter, font(24, "SemiBold"), C_ACCENT, in: CGRect(x: PANEL_X, y: y, width: 410, height: 36)); y += 44
        y += p.text(sc.panelTitle, font(40, "Bold"), C_TEXT, in: CGRect(x: PANEL_X, y: y, width: 410, height: 100), lineSpacing: 2) + 26
        for g in sc.keys.prefix(5) { _ = p.keys(g, at: CGPoint(x: PANEL_X, y: y), size: 50, dark: true); y += 66 }
        if !sc.keys.isEmpty { y += 10 }
        for b in sc.bullets {
            p.round(CGRect(x: PANEL_X, y: y + 14, width: 8, height: 8), 4, fill: C_ACCENT)
            y += p.text(b, font(25, "Medium"), C_MUTED, in: CGRect(x: PANEL_X + 22, y: y, width: 390, height: 200)) + 12
        }
        if !sc.note.isEmpty {
            p.text("ⓘ " + sc.note, font(18, "Medium"), rgb(0x7C869B), in: CGRect(x: PANEL_X, y: 860, width: 410, height: 80))
        }
    }

    func caption(_ p: Painter, _ sc: Scene, _ t: Double) {
        var cur: String? = nil
        for (i, c) in sc.cues.enumerated() where t >= c - 0.1 && t <= c + sc.lineDur[i] + gap * 0.9 { cur = sc.lines[i].cap }
        guard let s = cur, sc.kind != .title || true else { return }
        let f = font(34, "Medium")
        let h = p.textHeight(s, f, width: CAP_RECT.width - 80, lineSpacing: 2)
        let r = CGRect(x: CAP_RECT.minX, y: CAP_RECT.midY - h / 2 - 12, width: CAP_RECT.width, height: h + 24)
        p.round(r, 14, fill: NSColor.black.withAlphaComponent(sc.kind == .screen ? 0.0 : 0.35))
        p.text(s, f, C_CAP, in: r.insetBy(dx: 40, dy: 12), align: .center, lineSpacing: 2)
    }

    func background(_ p: Painter) {
        let g = CGGradient(colorsSpace: bitmapSpace, colors: [C_BG.cgColor, C_BG2.cgColor] as CFArray, locations: [0, 1])!
        p.ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: VW, y: VH), options: [])
    }

    func drawScene(_ p: Painter, _ sc: Scene, _ t: Double) {
        switch sc.kind {
        case .chapter:
            let a = CGFloat(ease(t / 0.5))
            p.ctx.saveGState(); p.ctx.setAlpha(a)
            let parts = sc.chapter.components(separatedBy: " · ")
            p.text("บทที่ " + (parts.first ?? ""), font(40, "SemiBold"), C_ACCENT, in: CGRect(x: 0, y: 400, width: VW, height: 60), align: .center)
            p.text(parts.count > 1 ? parts[1] : sc.chapter, font(96, "Bold"), C_TEXT, in: CGRect(x: 0, y: 470, width: VW, height: 140), align: .center)
            p.ctx.restoreGState()
        default:
            sc.draw(FrameInfo(p: p, t: t, dur: sc.dur, cues: sc.cues))
        }
    }

    func renderFrame(_ ctx: CGContext, _ T: Double) {
        let p = Painter(ctx)
        background(p)
        var si = scenes.count - 1
        for (i, sc) in scenes.enumerated() where T < sc.start + sc.dur { si = i; break }
        let sc = scenes[si], t = T - sc.start
        let fade = 0.4
        if si > 0 && t < fade {
            let prev = scenes[si - 1]
            chrome(p, prev, prev.dur); drawScene(p, prev, prev.dur - 0.001)
            p.ctx.saveGState(); p.ctx.setAlpha(CGFloat(t / fade)); p.ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            background(p); chrome(p, sc, t); drawScene(p, sc, t)
            p.ctx.endTransparencyLayer(); p.ctx.restoreGState()
        } else {
            chrome(p, sc, t); drawScene(p, sc, t)
        }
        caption(p, sc, t)
        // แถบความคืบหน้า
        p.fill(CGRect(x: 0, y: CGFloat(VH) - 6, width: CGFloat(VW), height: 6), rgb(0x232B3E))
        p.fill(CGRect(x: 0, y: CGFloat(VH) - 6, width: CGFloat(VW) * CGFloat(T / total), height: 6), C_ACCENT)
    }

    func makeContext(_ data: UnsafeMutableRawPointer?, _ bpr: Int) -> CGContext {
        let ctx = CGContext(data: data, width: VW, height: VH, bitsPerComponent: 8, bytesPerRow: bpr, space: bitmapSpace,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.translateBy(x: 0, y: CGFloat(VH)); ctx.scaleBy(x: 1, y: -1)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        return ctx
    }

    // --preview: เซฟภาพตัวอย่างกลางแต่ละฉาก
    if ONLY_PREVIEW {
        let dir = ROOT.appendingPathComponent("build/preview"); try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (i, sc) in scenes.enumerated() {
            for (j, frac) in [0.35, 0.8].enumerated() {
                let ctx = makeContext(nil, 0)
                renderFrame(ctx, sc.start + sc.dur * frac)
                let img = ctx.makeImage()!
                let url = dir.appendingPathComponent(String(format: "s%02d_%d.png", i, j))
                let d = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
                CGImageDestinationAddImage(d, img, nil); CGImageDestinationFinalize(d)
            }
        }
        print("preview → \(dir.path)")
        exit(0)
    }

    // ===================== เข้ารหัสวิดีโอ =====================

    let silent = ROOT.appendingPathComponent("build/video_silent.mov")
    let final = ROOT.appendingPathComponent("build/ZoomJor-สอนการใช้งาน.mp4")
    try? FileManager.default.removeItem(at: silent); try? FileManager.default.removeItem(at: final)
    let writer = try! AVAssetWriter(outputURL: silent, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: VW, AVVideoHeightKey: VH,
        AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 10_000_000, AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel]])
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: VW, kCVPixelBufferHeightKey as String: VH])
    writer.add(input); writer.startWriting(); writer.startSession(atSourceTime: .zero)
    let nFrames = Int(ceil(total * Double(FPS)))
    let t0 = Date()
    for fi in 0..<nFrames {
        while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
        let buf = pb!
        CVPixelBufferLockBaseAddress(buf, [])
        autoreleasepool {
            let ctx = makeContext(CVPixelBufferGetBaseAddress(buf), CVPixelBufferGetBytesPerRow(buf))
            renderFrame(ctx, Double(fi) / Double(FPS))
            NSGraphicsContext.current = nil
        }
        CVPixelBufferUnlockBaseAddress(buf, [])
        adaptor.append(buf, withPresentationTime: CMTime(value: Int64(fi), timescale: FPS))
        if fi % 300 == 0 { print(String(format: "  เฟรม %d/%d (%.0f วิ)", fi, nFrames, Date().timeIntervalSince(t0))) }
        if cache.count > 160 { cache.removeAll() }
    }
    input.markAsFinished()
    let sem = DispatchSemaphore(value: 0)
    writer.finishWriting { sem.signal() }; sem.wait()
    print("วิดีโอ (ไร้เสียง) เสร็จ: \(writer.status.rawValue) \(writer.error?.localizedDescription ?? "")")

    // ===================== รวมเสียง =====================

    let comp = AVMutableComposition()
    let vAsset = AVURLAsset(url: silent)
    let vTrack = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
    let srcV = vAsset.tracks(withMediaType: .video)[0]
    try! vTrack.insertTimeRange(CMTimeRange(start: .zero, duration: vAsset.duration), of: srcV, at: .zero)
    let aTrack = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
    for sc in scenes {
        for (i, url) in sc.audio.enumerated() {
            let a = AVURLAsset(url: url)
            guard let tr = a.tracks(withMediaType: .audio).first else { continue }
            let at = CMTime(seconds: sc.start + sc.cues[i], preferredTimescale: 600)
            try? aTrack.insertTimeRange(CMTimeRange(start: .zero, duration: a.duration), of: tr, at: at)
        }
    }
    let ex = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetHighestQuality)!
    ex.outputURL = final; ex.outputFileType = .mp4
    let sem2 = DispatchSemaphore(value: 0)
    ex.exportAsynchronously { sem2.signal() }; sem2.wait()
    print("ส่งออก: \(ex.status.rawValue) \(ex.error?.localizedDescription ?? "") → \(final.path)")
}

MainActor.assumeIsolated { runMain() }

extension CGPoint { var tl: CGPoint { CGPoint(x: x, y: SCREEN.height - y) } }
