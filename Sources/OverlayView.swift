import AppKit
import Carbon.HIToolbox

@MainActor
final class OverlayView: NSView {

    enum Mode { case zoom, draw, timer }

    weak var controller: OverlayController?

    var mode: Mode = .draw
    var background: NSImage?
    var canvasSize: CGSize = .zero

    // ---- สถานะการซูม ----
    var zoom: CGFloat = 1 { didSet { needsDisplay = true } }
    var focus: CGPoint = .zero
    var panFollowsMouse = true

    // ---- เครื่องมือวาด ----
    var tool: Tool = .arrow { didSet { needsDisplay = true } }
    var color: NSColor = Palette.all[0].color { didSet { needsDisplay = true } }
    var lineWidth: CGFloat = 5 { didSet { needsDisplay = true } }

    private(set) var strokes: [Stroke] = []
    private var undoStack: [[Stroke]] = []      // สถานะก่อนหน้าของแต่ละการกระทำ
    private var redoStack: [[Stroke]] = []
    private var current: Stroke?
    private var editingIndex: Int?
    private var pendingTextUndo: [Stroke]?
    private var showHelp = false
    private var hudHidden = false
    private var statusText: String?
    private var statusUntil: Date = .distantPast
    private var cursorHidden = false

    // ---- แถบเครื่องมือบนจอ ----
    private enum BarAction: Equatable {
        case tool(Tool), color(Int), undo, redo, clear, close
    }
    private struct BarButton {
        let rect: CGRect
        let action: BarAction
        let label: String
    }
    private var barButtons: [BarButton] = []
    private var barSeparators: [CGFloat] = []
    private var barRect: CGRect = .zero
    private var hoveredBar: Int?
    private var pointerOverBar = false
    private var iconCache: [String: NSImage] = [:]

    // ---- นาฬิกาจับเวลาถอยหลัง ----
    private(set) var timerDuration: TimeInterval = 600
    private var deadline: Date?
    private var pausedRemaining: TimeInterval?
    private var tick: Timer?
    private var chimed = false
    private var minuteBuffer = ""

    var remaining: TimeInterval {
        if let deadline { return max(0, deadline.timeIntervalSinceNow) }
        return pausedRemaining ?? 0
    }
    var timerRunning: Bool { deadline != nil }

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - ตั้งค่าเริ่มต้น

    func prepare(mode: Mode, background: NSImage?, canvasSize: CGSize,
                 startFocus: CGPoint, timerDuration: TimeInterval = 600) {
        self.mode = mode
        self.background = background
        self.canvasSize = canvasSize
        self.focus = startFocus
        self.zoom = (mode == .zoom) ? 2.0 : 1.0
        self.panFollowsMouse = (mode == .zoom)
        strokes.removeAll()
        undoStack.removeAll()
        redoStack.removeAll()
        current = nil
        editingIndex = nil
        pendingTextUndo = nil
        showHelp = false
        hudHidden = (mode == .timer)
        minuteBuffer = ""
        hoveredBar = nil
        pointerOverBar = false
        layoutToolbar()

        tick?.invalidate(); tick = nil
        if mode == .timer {
            self.timerDuration = timerDuration
            startCountdown(from: timerDuration)
        }

        switch mode {
        case .zoom:
            flashStatus("โหมดซูม — เลื่อนเมาส์เพื่อส่อง • สกอร์ล/+- ปรับซูม • คลิกลากเพื่อวาด • Esc ออก")
        case .draw:
            flashStatus("โหมดวาด — คลิกลากเพื่อวาด • ⌫ ย้อนกลับ • แถบเครื่องมือด้านบนคลิกได้ • Esc ออก")
        case .timer:
            break
        }
        needsDisplay = true
    }

    func didAppear() { updateCursorState() }

    func teardown() {
        showSystemCursor()
        tick?.invalidate(); tick = nil
        deadline = nil
        pausedRemaining = nil
        strokes.removeAll()
        undoStack.removeAll()
        redoStack.removeAll()
        current = nil
        editingIndex = nil
        pendingTextUndo = nil
    }

    // MARK: - แปลงพิกัด

    var visibleCanvasRect: CGRect {
        let w = canvasSize.width / zoom
        let h = canvasSize.height / zoom
        var x = focus.x - w / 2
        var y = focus.y - h / 2
        x = min(max(0, x), max(0, canvasSize.width - w))
        y = min(max(0, y), max(0, canvasSize.height - h))
        return CGRect(x: x, y: y, width: w, height: h)
    }

    private func canvasPoint(from viewPoint: CGPoint) -> CGPoint {
        let vis = visibleCanvasRect
        return CGPoint(x: viewPoint.x / zoom + vis.minX, y: viewPoint.y / zoom + vis.minY)
    }

    private func viewPoint(_ event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    private func canvasPoint(_ event: NSEvent) -> CGPoint {
        canvasPoint(from: viewPoint(event))
    }

    private func physicalMouseCanvasPoint() -> CGPoint {
        guard let screenFrame = window?.screen?.frame ?? window?.frame else { return focus }
        let p = NSEvent.mouseLocation
        return CGPoint(x: p.x - screenFrame.minX, y: p.y - screenFrame.minY)
    }

    // MARK: - วาดภาพ

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        renderScene(in: ctx, background: background, includeChrome: true, includeLiveStroke: true)
    }

    private func renderScene(in ctx: CGContext, background bg: NSImage?,
                             includeChrome: Bool, includeLiveStroke: Bool) {
        if mode != .draw {
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fill(CGRect(origin: .zero, size: canvasSize))
        }

        let vis = visibleCanvasRect

        if let bg {
            ctx.saveGState()
            ctx.scaleBy(x: zoom, y: zoom)
            ctx.translateBy(x: -vis.minX, y: -vis.minY)
            ctx.interpolationQuality = .high
            bg.draw(in: CGRect(origin: .zero, size: canvasSize),
                    from: .zero, operation: .copy, fraction: 1.0)
            ctx.restoreGState()
        }

        if mode == .timer { drawTimerFace(in: ctx) }

        ctx.saveGState()
        ctx.scaleBy(x: zoom, y: zoom)
        ctx.translateBy(x: -vis.minX, y: -vis.minY)
        for (i, stroke) in strokes.enumerated() {
            draw(stroke: stroke, in: ctx, editing: editingIndex == i)
        }
        if includeLiveStroke, let cur = current {
            draw(stroke: cur, in: ctx, editing: false)
        }
        ctx.restoreGState()

        if includeChrome && !hudHidden {
            drawToolbar(in: ctx)
            drawHUD(in: ctx)
        }
    }

    private func draw(stroke s: Stroke, in ctx: CGContext, editing: Bool) {
        ctx.saveGState()
        defer { ctx.restoreGState() }

        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        let isHL = (s.tool == .highlighter)
        let drawColor = isHL ? s.color.withAlphaComponent(0.30) : s.color
        let w = isHL ? s.width * 5 : s.width
        ctx.setStrokeColor(drawColor.cgColor)
        ctx.setFillColor(drawColor.cgColor)
        ctx.setLineWidth(w)

        switch s.tool {
        case .pen, .highlighter:
            guard s.points.count > 1 else {
                if let p = s.points.first {
                    ctx.fillEllipse(in: CGRect(x: p.x - w / 2, y: p.y - w / 2, width: w, height: w))
                }
                return
            }
            ctx.addLines(between: s.points)
            ctx.strokePath()

        case .line:
            guard s.points.count >= 2 else { return }
            ctx.move(to: s.points[0])
            ctx.addLine(to: s.points[1])
            ctx.strokePath()

        case .arrow:
            guard s.points.count >= 2 else { return }
            drawArrow(from: s.points[0], to: s.points[1], width: w, in: ctx)

        case .rect:
            guard s.points.count >= 2 else { return }
            ctx.stroke(rect(from: s.points[0], to: s.points[1]))

        case .ellipse:
            guard s.points.count >= 2 else { return }
            ctx.strokeEllipse(in: rect(from: s.points[0], to: s.points[1]))

        case .text:
            guard let origin = s.points.first else { return }
            let size = max(16, s.width * 6)
            let font = NSFont.systemFont(ofSize: size, weight: .semibold)
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
            shadow.shadowBlurRadius = size * 0.12
            shadow.shadowOffset = NSSize(width: 0, height: -1)
            let display = s.text + (editing ? "|" : "")
            NSAttributedString(string: display, attributes: [
                .font: font, .foregroundColor: s.color, .shadow: shadow
            ]).draw(at: origin)
        }
    }

    private func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
               width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    private func drawArrow(from a: CGPoint, to b: CGPoint, width w: CGFloat, in ctx: CGContext) {
        let dx = b.x - a.x, dy = b.y - a.y
        let len = hypot(dx, dy)
        guard len > 1 else { return }
        let ux = dx / len, uy = dy / len
        let head = min(max(w * 4.2, 16), len)
        let halfW = head * 0.44
        let baseX = b.x - ux * head
        let baseY = b.y - uy * head

        ctx.setLineWidth(w)
        ctx.move(to: a)
        ctx.addLine(to: CGPoint(x: b.x - ux * head * 0.8, y: b.y - uy * head * 0.8))
        ctx.strokePath()

        let px = -uy, py = ux
        ctx.move(to: b)
        ctx.addLine(to: CGPoint(x: baseX + px * halfW, y: baseY + py * halfW))
        ctx.addLine(to: CGPoint(x: baseX - px * halfW, y: baseY - py * halfW))
        ctx.closePath()
        ctx.fillPath()
    }

    // MARK: - แถบเครื่องมือบนจอ (คลิกได้ ไม่ต้องจำคีย์)

    private func layoutToolbar() {
        barButtons = []
        barSeparators = []
        barRect = .zero
        guard canvasSize.width > 420 else { return }

        let pad: CGFloat = 12, gap: CGFloat = 5, sepW: CGFloat = 16
        let big: CGFloat = 32, dot: CGFloat = 26, height: CGFloat = 48
        var x = pad
        var items: [BarButton] = []
        var seps: [CGFloat] = []

        func add(_ action: BarAction, _ label: String, _ size: CGFloat) {
            items.append(BarButton(rect: CGRect(x: x, y: (height - size) / 2, width: size, height: size),
                                   action: action, label: label))
            x += size + gap
        }
        func separator() {
            x -= gap
            seps.append(x + sepW / 2)
            x += sepW + gap
        }

        for t in Tool.allCases { add(.tool(t), "\(t.thaiName) (\(t.englishName))", big) }
        separator()
        for (i, pc) in Palette.all.enumerated() { add(.color(i), "สี\(pc.thaiName)", dot) }
        separator()
        add(.undo, "ย้อนกลับ (⌫ หรือ ⌘Z)", big)
        add(.redo, "ทำซ้ำ (⇧⌘Z)", big)
        add(.clear, "ลบทั้งหมด", big)
        separator()
        add(.close, "ออกจากโหมด (Esc)", big)

        let width = x - gap + pad
        barRect = CGRect(x: ((canvasSize.width - width) / 2).rounded(),
                         y: canvasSize.height - height - 18,
                         width: width, height: height)

        barButtons = items.map {
            BarButton(rect: $0.rect.offsetBy(dx: barRect.minX, dy: barRect.minY),
                      action: $0.action, label: $0.label)
        }
        barSeparators = seps.map { $0 + barRect.minX }
    }

    private func symbolImage(_ name: String) -> NSImage? {
        if let cached = iconCache[name] { return cached }
        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(config) else { return nil }
        let size = base.size
        let white = NSImage(size: size, flipped: false) { r in
            base.draw(in: r)
            NSColor.white.set()
            r.fill(using: .sourceAtop)
            return true
        }
        iconCache[name] = white
        return white
    }

    private func drawToolbar(in ctx: CGContext) {
        guard !barButtons.isEmpty else { return }

        ctx.saveGState()
        let path = CGPath(roundedRect: barRect, cornerWidth: 14, cornerHeight: 14, transform: nil)
        ctx.addPath(path)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.80).cgColor)
        ctx.fillPath()
        ctx.addPath(path)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.20).cgColor)
        ctx.setLineWidth(1)
        ctx.strokePath()

        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.16).cgColor)
        for sx in barSeparators {
            ctx.move(to: CGPoint(x: sx.rounded() + 0.5, y: barRect.minY + 12))
            ctx.addLine(to: CGPoint(x: sx.rounded() + 0.5, y: barRect.maxY - 12))
        }
        ctx.strokePath()
        ctx.restoreGState()

        let selectedColorIndex = Palette.index(of: color)

        for (i, b) in barButtons.enumerated() {
            let selected: Bool
            switch b.action {
            case .tool(let t):  selected = (t == tool)
            case .color(let c): selected = (c == selectedColorIndex)
            default:            selected = false
            }
            let enabled: Bool
            switch b.action {
            case .undo:  enabled = !undoStack.isEmpty
            case .redo:  enabled = !redoStack.isEmpty
            case .clear: enabled = !strokes.isEmpty
            default:     enabled = true
            }
            let hovered = (hoveredBar == i)

            ctx.saveGState()
            if selected || hovered {
                let bg = CGPath(roundedRect: b.rect.insetBy(dx: -2, dy: -2),
                                cornerWidth: 8, cornerHeight: 8, transform: nil)
                ctx.addPath(bg)
                ctx.setFillColor(NSColor.white.withAlphaComponent(selected ? 0.24 : 0.12).cgColor)
                ctx.fillPath()
            }
            ctx.restoreGState()

            switch b.action {
            case .color(let ci):
                let pc = Palette.all[ci]
                let dot = b.rect.insetBy(dx: 4, dy: 4)
                ctx.setFillColor(pc.color.cgColor)
                ctx.fillEllipse(in: dot)
                ctx.setLineWidth(selected ? 2.5 : 1)
                ctx.setStrokeColor(NSColor.white.withAlphaComponent(selected ? 0.95 : 0.35).cgColor)
                ctx.strokeEllipse(in: dot)

            default:
                let name: String
                var fallback = ""
                switch b.action {
                case .tool(let t): name = t.symbolName; fallback = t.key.uppercased()
                case .undo:  name = "arrow.uturn.backward"; fallback = "↶"
                case .redo:  name = "arrow.uturn.forward";  fallback = "↷"
                case .clear: name = "trash";                fallback = "E"
                case .close: name = "xmark";                fallback = "✕"
                case .color: name = ""
                }
                ctx.saveGState()
                ctx.setAlpha(enabled ? 1.0 : 0.32)
                if let image = symbolImage(name) {
                    let s = image.size
                    image.draw(in: CGRect(x: b.rect.midX - s.width / 2,
                                          y: b.rect.midY - s.height / 2,
                                          width: s.width, height: s.height))
                } else {
                    let attr = NSAttributedString(string: fallback, attributes: [
                        .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
                        .foregroundColor: NSColor.white
                    ])
                    let s = attr.size()
                    attr.draw(at: CGPoint(x: b.rect.midX - s.width / 2, y: b.rect.midY - s.height / 2))
                }
                ctx.restoreGState()
            }
        }

        // ชื่อปุ่มที่ชี้อยู่
        if let i = hoveredBar {
            let attr = NSAttributedString(string: barButtons[i].label, attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(0.92)
            ])
            let s = attr.size()
            let box = CGRect(x: barButtons[i].rect.midX - s.width / 2 - 8,
                             y: barRect.minY - s.height - 12,
                             width: s.width + 16, height: s.height + 7)
            ctx.saveGState()
            ctx.addPath(CGPath(roundedRect: box, cornerWidth: 7, cornerHeight: 7, transform: nil))
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.80).cgColor)
            ctx.fillPath()
            ctx.restoreGState()
            attr.draw(at: CGPoint(x: box.minX + 8, y: box.minY + 3))
        }
    }

    private func perform(_ action: BarAction) {
        switch action {
        case .tool(let t):
            commitText()
            tool = t
            controller?.tool = t
            flashStatus("เครื่องมือ: \(t.thaiName) (\(t.englishName))", seconds: 1.4)
        case .color(let i):
            let pc = Palette.all[i]
            color = pc.color
            controller?.color = pc.color
            if let idx = editingIndex { strokes[idx].color = pc.color }
            flashStatus("เปลี่ยนสีเป็น \(pc.thaiName) (\(pc.englishName))", seconds: 1.4)
        case .undo:  undo()
        case .redo:  redo()
        case .clear: clearAll()
        case .close: controller?.hide()
        }
        needsDisplay = true
    }

    // MARK: - หน้าปัดนาฬิกา

    private func startCountdown(from seconds: TimeInterval) {
        timerDuration = max(5, seconds)
        deadline = Date().addingTimeInterval(timerDuration)
        pausedRemaining = nil
        chimed = false
        tick?.invalidate()
        tick = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.onTick() }
        }
        needsDisplay = true
    }

    private func onTick() {
        if !chimed, timerRunning, remaining <= 0 {
            chimed = true
            playChime()
        }
        needsDisplay = true
    }

    private func playChime() {
        let path = "/System/Library/Sounds/Glass.aiff"
        for i in 0..<3 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.7) {
                if FileManager.default.fileExists(atPath: path),
                   let sound = NSSound(contentsOfFile: path, byReference: true) {
                    sound.play()
                } else {
                    NSSound.beep()
                }
            }
        }
    }

    private func adjustTimer(by delta: TimeInterval) {
        if let d = deadline {
            deadline = max(Date(), d.addingTimeInterval(delta))
        } else {
            pausedRemaining = max(0, (pausedRemaining ?? 0) + delta)
        }
        timerDuration = max(timerDuration, remaining)
        if remaining > 0 { chimed = false }
        let unit = abs(delta) >= 60 ? "\(Int(abs(delta) / 60)) นาที" : "\(Int(abs(delta))) วินาที"
        flashStatus((delta > 0 ? "เพิ่มเวลา " : "ลดเวลา ") + unit, seconds: 1.0)
        needsDisplay = true
    }

    private func toggleTimerPause() {
        if let d = deadline {
            pausedRemaining = max(0, d.timeIntervalSinceNow)
            deadline = nil
        } else {
            deadline = Date().addingTimeInterval(pausedRemaining ?? 0)
            pausedRemaining = nil
        }
        needsDisplay = true
    }

    private func drawTimerFace(in ctx: CGContext) {
        let W = canvasSize.width, H = canvasSize.height
        guard W > 0, H > 0 else { return }

        ctx.saveGState()
        defer { ctx.restoreGState() }

        ctx.setFillColor(NSColor.black.withAlphaComponent(background == nil ? 0.90 : 0.66).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))

        let remain = remaining
        let expired = remain <= 0
        let center = CGPoint(x: W / 2, y: H / 2 + H * 0.03)
        let radius = min(W, H) * 0.26
        let ringWidth = max(10, radius * 0.08)

        let accent: NSColor
        if expired {
            accent = NSColor(srgbRed: 1.0, green: 0.26, blue: 0.26, alpha: 1)
        } else if remain <= 60 {
            accent = NSColor(srgbRed: 1.0, green: 0.52, blue: 0.0, alpha: 1)
        } else {
            accent = NSColor(srgbRed: 0.24, green: 0.84, blue: 0.53, alpha: 1)
        }

        ctx.setLineWidth(ringWidth)
        ctx.setLineCap(.butt)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.15).cgColor)
        ctx.addArc(center: center, radius: radius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
        ctx.strokePath()

        let fraction = timerDuration > 0 ? max(0, min(1, remain / timerDuration)) : 0
        if fraction > 0.0005 {
            ctx.setLineCap(.round)
            ctx.setStrokeColor(accent.cgColor)
            let start = CGFloat.pi / 2
            ctx.addArc(center: center, radius: radius,
                       startAngle: start, endAngle: start - fraction * .pi * 2, clockwise: true)
            ctx.strokePath()
        }

        let total = Int(ceil(remain))
        let hh = total / 3600, mm = (total % 3600) / 60, ss = total % 60
        let timeText = hh > 0 ? String(format: "%d:%02d:%02d", hh, mm, ss)
                              : String(format: "%02d:%02d", mm, ss)
        let pulse: CGFloat = expired
            ? 0.55 + 0.45 * abs(CGFloat(sin(Date().timeIntervalSinceReferenceDate * 2.2)))
            : 1.0
        let timeAttr = NSAttributedString(string: timeText, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: radius * 0.62, weight: .bold),
            .foregroundColor: (expired ? accent : NSColor.white).withAlphaComponent(pulse)
        ])
        let timeSize = timeAttr.size()
        timeAttr.draw(at: CGPoint(x: center.x - timeSize.width / 2, y: center.y - timeSize.height / 2))

        let title = expired ? "หมดเวลาแล้ว" : (timerRunning ? "พักเบรก" : "หยุดชั่วคราว")
        let titleAttr = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: max(20, radius * 0.16), weight: .semibold),
            .foregroundColor: (expired ? accent : NSColor.white.withAlphaComponent(0.82))
        ])
        let titleSize = titleAttr.size()
        titleAttr.draw(at: CGPoint(x: center.x - titleSize.width / 2,
                                   y: center.y + radius + ringWidth + 18))

        var subtitle = ""
        if !expired && timerRunning {
            let fmt = DateFormatter()
            fmt.dateFormat = "HH:mm"
            subtitle = "กลับมาต่อเวลา \(fmt.string(from: Date().addingTimeInterval(remain))) น."
        } else if !expired {
            subtitle = "กด Space เพื่อเดินเวลาต่อ"
        }
        if !subtitle.isEmpty {
            let subAttr = NSAttributedString(string: subtitle, attributes: [
                .font: NSFont.systemFont(ofSize: max(15, radius * 0.11), weight: .regular),
                .foregroundColor: NSColor.white.withAlphaComponent(0.62)
            ])
            let s = subAttr.size()
            subAttr.draw(at: CGPoint(x: center.x - s.width / 2,
                                     y: center.y - radius - ringWidth - s.height - 14))
        }

        if !minuteBuffer.isEmpty {
            let attr = NSAttributedString(string: "ตั้งเวลา \(minuteBuffer) นาที — กด Enter เพื่อเริ่ม", attributes: [
                .font: NSFont.systemFont(ofSize: 20, weight: .semibold),
                .foregroundColor: NSColor(srgbRed: 1.0, green: 0.83, blue: 0.05, alpha: 1)
            ])
            let s = attr.size()
            attr.draw(at: CGPoint(x: center.x - s.width / 2, y: H * 0.14))
        }

        let hint = "Space หยุด/เดินต่อ   ·   ↑↓ ±1 นาที   ·   ←→ ±10 วินาที   ·   พิมพ์ตัวเลข+Enter ตั้งเวลา   ·   ⌘R เริ่มใหม่   ·   d แถบเครื่องมือ   ·   Esc ออก"
        let hintAttr = NSAttributedString(string: hint, attributes: [
            .font: NSFont.systemFont(ofSize: 14, weight: .regular),
            .foregroundColor: NSColor.white.withAlphaComponent(0.45)
        ])
        let hs = hintAttr.size()
        hintAttr.draw(at: CGPoint(x: center.x - hs.width / 2, y: 34))
    }

    // MARK: - HUD

    private static let helpLines: [String] = [
        "เครื่องมือ:  A ลูกศร   P ปากกา   L เส้นตรง   S สี่เหลี่ยม   C วงรี   H ไฮไลต์   T ข้อความ",
        "สีเส้น:  R แดง   G เขียว   Y เหลือง   K ดำ   B น้ำเงิน   W ขาว   O ส้ม   M ชมพู",
        "ย้อนกลับ:  ⌫ (Backspace)  หรือ  ⌘Z  หรือ  U        ทำซ้ำ: ⇧⌘Z        ลบทั้งหมด: E หรือ ⌘⌫",
        "ขนาดเส้น:  [ เล็กลง   ] ใหญ่ขึ้น        ซูม: สกอร์ล / + - / ↑ ↓        Tab ล็อกการแพน",
        "บันทึก:  ⌘S เซฟ PNG ลง Desktop   ⌘C คัดลอกลงคลิปบอร์ด",
        "อื่น ๆ:  Z แช่จอ+ซูม (จากโหมดวาด)   D ซ่อนแถบเครื่องมือ   ? ซ่อน/แสดงคีย์ลัด   Esc ออก",
        "คีย์ลัดทั้งหมดอ่านจากตำแหน่งปุ่ม — สลับแป้นเป็นภาษาไทยอยู่ก็กดได้ตามปกติ"
    ]

    private func drawHUD(in ctx: CGContext) {
        var lines: [NSAttributedString] = []
        let titleFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let bodyFont = NSFont.systemFont(ofSize: 12, weight: .regular)

        let modeName: String
        switch mode {
        case .zoom:  modeName = "ZOOM"
        case .draw:  modeName = "DRAW"
        case .timer: modeName = "TIMER"
        }
        let zoomText = (mode == .zoom) ? String(format: "  ·  ซูม %.1f×", zoom) : ""
        let panText = (mode == .zoom) ? (panFollowsMouse ? "  ·  แพน: ตามเมาส์" : "  ·  แพน: ล็อก") : ""
        lines.append(NSAttributedString(
            string: "\(modeName)  ·  \(tool.thaiName) (\(tool.englishName))  ·  \(Palette.name(for: color))  ·  เส้น \(Int(lineWidth))\(zoomText)\(panText)",
            attributes: [.font: titleFont, .foregroundColor: NSColor.white]))

        if let status = statusText, Date() < statusUntil {
            lines.append(NSAttributedString(string: status, attributes: [
                .font: bodyFont, .foregroundColor: NSColor.white.withAlphaComponent(0.85)
            ]))
        }

        if showHelp {
            for l in Self.helpLines {
                lines.append(NSAttributedString(string: l, attributes: [
                    .font: bodyFont, .foregroundColor: NSColor.white.withAlphaComponent(0.9)
                ]))
            }
        } else {
            lines.append(NSAttributedString(string: "กด ? เพื่อดูคีย์ลัดทั้งหมด", attributes: [
                .font: bodyFont, .foregroundColor: NSColor.white.withAlphaComponent(0.55)
            ]))
        }

        let padding: CGFloat = 14, lineGap: CGFloat = 5
        var maxW: CGFloat = 0, totalH: CGFloat = 0
        var sizes: [CGSize] = []
        for l in lines {
            let s = l.size()
            sizes.append(s)
            maxW = max(maxW, s.width)
            totalH += s.height + lineGap
        }
        totalH -= lineGap

        let swatch: CGFloat = 12
        let boxW = maxW + padding * 2 + swatch + 8
        let boxH = totalH + padding * 2
        let boxX: CGFloat = 24, boxY: CGFloat = 24
        let box = CGRect(x: boxX, y: boxY, width: boxW, height: boxH)

        ctx.saveGState()
        let path = CGPath(roundedRect: box, cornerWidth: 12, cornerHeight: 12, transform: nil)
        ctx.addPath(path)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.72).cgColor)
        ctx.fillPath()
        ctx.addPath(path)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.18).cgColor)
        ctx.setLineWidth(1)
        ctx.strokePath()

        let dot = CGRect(x: boxX + padding, y: boxY + boxH - padding - swatch - 1,
                         width: swatch, height: swatch)
        ctx.setFillColor(color.cgColor)
        ctx.fillEllipse(in: dot)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.7).cgColor)
        ctx.strokeEllipse(in: dot)
        ctx.restoreGState()

        var y = boxY + boxH - padding
        let x = boxX + padding + swatch + 8
        for (i, l) in lines.enumerated() {
            y -= sizes[i].height
            l.draw(at: CGPoint(x: x, y: y))
            y -= lineGap
        }
    }

    private func flashStatus(_ text: String, seconds: TimeInterval = 2.6) {
        statusText = text
        statusUntil = Date().addingTimeInterval(seconds)
        needsDisplay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds + 0.05) { [weak self] in
            self?.needsDisplay = true
        }
    }

    // MARK: - เคอร์เซอร์

    private func updateCursorState() {
        if mode == .zoom && panFollowsMouse && !pointerOverBar {
            hideSystemCursor()
        } else {
            showSystemCursor()
            (pointerOverBar ? NSCursor.arrow : NSCursor.crosshair).set()
        }
    }

    private func hideSystemCursor() {
        guard !cursorHidden else { return }
        NSCursor.hide()
        cursorHidden = true
    }

    private func showSystemCursor() {
        guard cursorHidden else { return }
        NSCursor.unhide()
        cursorHidden = false
    }

    // MARK: - เมาส์

    override func mouseDown(with event: NSEvent) {
        let vp = viewPoint(event)

        if !hudHidden, let i = barButtons.firstIndex(where: { $0.rect.contains(vp) }) {
            perform(barButtons[i].action)
            return
        }

        if mode == .zoom && panFollowsMouse {
            panFollowsMouse = false
            updateCursorState()
        }
        let p = canvasPoint(from: vp)

        if tool == .text {
            commitText()
            pendingTextUndo = strokes
            strokes.append(Stroke(tool: .text, color: color, width: lineWidth, points: [p], text: ""))
            editingIndex = strokes.count - 1
            flashStatus("พิมพ์ข้อความได้เลย — กด Enter หรือ Esc เพื่อจบ")
            needsDisplay = true
            return
        }

        commitText()
        var s = Stroke(tool: tool, color: color, width: lineWidth, points: [p, p])
        if tool == .pen || tool == .highlighter { s.points = [p] }
        current = s
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard var s = current else { return }
        let p = canvasPoint(event)
        if s.tool == .pen || s.tool == .highlighter {
            s.points.append(p)
        } else {
            var end = p
            if event.modifierFlags.contains(.shift), let start = s.points.first {
                end = constrain(start: start, end: p, tool: s.tool)
            }
            s.points[1] = end
        }
        current = s
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let s = current else { return }
        current = nil
        let worthKeeping: Bool
        if s.tool == .pen || s.tool == .highlighter {
            worthKeeping = s.points.count > 1
        } else {
            worthKeeping = s.points.count >= 2 &&
                hypot(s.points[1].x - s.points[0].x, s.points[1].y - s.points[0].y) > 3
        }
        if worthKeeping {
            pushUndo()
            strokes.append(s)
        }
        needsDisplay = true
    }

    private func constrain(start: CGPoint, end: CGPoint, tool: Tool) -> CGPoint {
        let dx = end.x - start.x, dy = end.y - start.y
        switch tool {
        case .line, .arrow:
            let angle = atan2(dy, dx)
            let step = CGFloat.pi / 4
            let snapped = (angle / step).rounded() * step
            let len = hypot(dx, dy)
            return CGPoint(x: start.x + cos(snapped) * len, y: start.y + sin(snapped) * len)
        case .rect, .ellipse:
            let side = max(abs(dx), abs(dy))
            return CGPoint(x: start.x + (dx < 0 ? -side : side),
                           y: start.y + (dy < 0 ? -side : side))
        default:
            return end
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let vp = viewPoint(event)
        let hit = hudHidden ? nil : barButtons.firstIndex(where: { $0.rect.contains(vp) })
        let overBar = !hudHidden && barRect.contains(vp)

        if hit != hoveredBar { hoveredBar = hit; needsDisplay = true }
        if overBar != pointerOverBar {
            pointerOverBar = overBar
            needsDisplay = true
        }
        updateCursorState()

        if mode == .zoom, panFollowsMouse, !overBar {
            focus = physicalMouseCanvasPoint()
            needsDisplay = true
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        controller?.hide()
    }

    override func scrollWheel(with event: NSEvent) {
        let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 4 : event.scrollingDeltaY
        guard dy != 0 else { return }
        if event.modifierFlags.contains(.command) || mode != .zoom {
            setLineWidth(lineWidth + (dy > 0 ? 1 : -1))
            return
        }
        setZoom(zoom * exp(dy * 0.03))
    }

    // MARK: - คีย์บอร์ด (อ่านจากตำแหน่งปุ่ม ใช้ได้ทั้งแป้นไทยและอังกฤษ)

    override func keyDown(with event: NSEvent) {
        let code = Int(event.keyCode)
        let cmd = event.modifierFlags.contains(.command)
        let shift = event.modifierFlags.contains(.shift)

        if cmd {
            switch code {
            case kVK_ANSI_Z: shift ? redo() : undo()
            case kVK_ANSI_S: controller?.saveSnapshot()
            case kVK_ANSI_C: controller?.copySnapshot()
            case kVK_ANSI_R: if mode == .timer { startCountdown(from: timerDuration) }
            case kVK_ANSI_Q: NSApp.terminate(nil)
            case kVK_Delete: clearAll()
            default: break
            }
            return
        }

        if editingIndex != nil {
            handleTextKey(event, code: code)
            return
        }

        if mode == .timer, handleTimerKey(code: code) { return }

        switch code {
        case kVK_Escape:
            controller?.hide(); return
        case kVK_Delete:                 // Backspace = ย้อนกลับ 1 ครั้ง
            undo(); return
        case kVK_ForwardDelete:
            clearAll(); return
        case kVK_Tab:
            guard mode == .zoom else { return }
            panFollowsMouse.toggle()
            if panFollowsMouse { focus = physicalMouseCanvasPoint() }
            updateCursorState()
            flashStatus(panFollowsMouse ? "แพนตามเมาส์: เปิด" : "แพนตามเมาส์: ล็อกภาพไว้")
            needsDisplay = true
            return
        case kVK_UpArrow:    setZoom(zoom * 1.15); return
        case kVK_DownArrow:  setZoom(zoom / 1.15); return
        case kVK_LeftArrow:  focus.x -= 40 / zoom; needsDisplay = true; return
        case kVK_RightArrow: focus.x += 40 / zoom; needsDisplay = true; return
        case kVK_F1:         showHelp.toggle(); needsDisplay = true; return
        default: break
        }

        if let pc = Palette.forCode(code) {
            perform(.color(Palette.all.firstIndex { $0.keyCode == pc.keyCode } ?? 0))
            return
        }
        if let t = Tool.forCode(code) {
            perform(.tool(t))
            return
        }

        switch code {
        case kVK_ANSI_U:            undo()
        case kVK_ANSI_E:            clearAll()
        case kVK_ANSI_LeftBracket:  setLineWidth(lineWidth - 1)
        case kVK_ANSI_RightBracket: setLineWidth(lineWidth + 1)
        case kVK_ANSI_Equal, kVK_ANSI_KeypadPlus:   setZoom(zoom * 1.15)
        case kVK_ANSI_Minus, kVK_ANSI_KeypadMinus:  setZoom(zoom / 1.15)
        case kVK_ANSI_0, kVK_ANSI_Keypad0:          setZoom(1)
        case kVK_ANSI_Slash:        showHelp.toggle(); needsDisplay = true
        case kVK_ANSI_D:            hudHidden.toggle(); hoveredBar = nil; needsDisplay = true
        case kVK_ANSI_Z:            if mode == .draw { controller?.freezeAndZoom(keeping: strokes) }
        default: break
        }
    }

    private func handleTimerKey(code: Int) -> Bool {
        switch code {
        case kVK_Space:      toggleTimerPause(); return true
        case kVK_UpArrow:    adjustTimer(by: 60); return true
        case kVK_DownArrow:  adjustTimer(by: -60); return true
        case kVK_RightArrow: adjustTimer(by: 10); return true
        case kVK_LeftArrow:  adjustTimer(by: -10); return true
        case kVK_Return, kVK_ANSI_KeypadEnter: applyMinuteBuffer(); return true
        case kVK_ANSI_Equal, kVK_ANSI_KeypadPlus:  adjustTimer(by: 60); return true
        case kVK_ANSI_Minus, kVK_ANSI_KeypadMinus: adjustTimer(by: -60); return true
        case kVK_Delete:
            if !minuteBuffer.isEmpty { minuteBuffer.removeLast(); needsDisplay = true; return true }
            return false
        default:
            if let d = DigitKeys.map[code] {
                if minuteBuffer.count < 3 { minuteBuffer.append(String(d)) }
                needsDisplay = true
                return true
            }
            return false
        }
    }

    private func applyMinuteBuffer() {
        guard let minutes = Int(minuteBuffer), minutes > 0 else { minuteBuffer = ""; return }
        minuteBuffer = ""
        controller?.defaultTimerMinutes = Double(minutes)
        startCountdown(from: TimeInterval(minutes * 60))
        flashStatus("ตั้งเวลาใหม่ \(minutes) นาที", seconds: 1.5)
    }

    /// ระหว่างพิมพ์ข้อความยังใช้ event.characters เพื่อให้พิมพ์ภาษาไทยได้
    private func handleTextKey(_ event: NSEvent, code: Int) {
        guard let idx = editingIndex else { return }
        switch code {
        case kVK_Escape, kVK_Return, kVK_ANSI_KeypadEnter:
            commitText()
        case kVK_Delete:
            if !strokes[idx].text.isEmpty { strokes[idx].text.removeLast() }
        default:
            if let ch = event.characters, !ch.isEmpty,
               ch.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
                strokes[idx].text += ch
            }
        }
        needsDisplay = true
    }

    private func commitText() {
        guard let idx = editingIndex else { return }
        editingIndex = nil
        let before = pendingTextUndo
        pendingTextUndo = nil
        if strokes[idx].text.isEmpty {
            strokes.remove(at: idx)          // ยกเลิกกล่องเปล่า ไม่นับเป็นการกระทำ
        } else if let before {
            undoStack.append(before)
            redoStack.removeAll()
        }
        needsDisplay = true
    }

    // MARK: - คำสั่ง

    func setZoom(_ value: CGFloat) {
        guard mode == .zoom else { return }
        zoom = min(max(1, value), 16)
        needsDisplay = true
    }

    func setLineWidth(_ value: CGFloat) {
        lineWidth = min(max(1, value.rounded()), 60)
        controller?.lineWidth = lineWidth
        flashStatus("ขนาดเส้น: \(Int(lineWidth))", seconds: 1.2)
    }

    /// เก็บสถานะปัจจุบันไว้ก่อนทำการกระทำใหม่ (วาดเส้น / ลบทั้งหมด / ใส่ข้อความ)
    private func pushUndo() {
        undoStack.append(strokes)
        if undoStack.count > 300 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    func undo() {
        commitText()
        guard let previous = undoStack.popLast() else {
            flashStatus("ไม่มีอะไรให้ย้อนกลับแล้ว", seconds: 1.2)
            return
        }
        redoStack.append(strokes)
        strokes = previous
        flashStatus("ย้อนกลับแล้ว (⇧⌘Z เพื่อทำซ้ำ)", seconds: 1.2)
        needsDisplay = true
    }

    func redo() {
        guard let next = redoStack.popLast() else {
            flashStatus("ไม่มีอะไรให้ทำซ้ำ", seconds: 1.2)
            return
        }
        undoStack.append(strokes)
        strokes = next
        needsDisplay = true
    }

    func clearAll() {
        commitText()
        guard !strokes.isEmpty else { return }
        pushUndo()
        strokes.removeAll()
        flashStatus("ลบภาพวาดทั้งหมดแล้ว (⌫ หรือ ⌘Z เพื่อเรียกคืน)", seconds: 1.6)
        needsDisplay = true
    }

    func restore(strokes list: [Stroke]) {
        strokes = list
        needsDisplay = true
    }

    // MARK: - ส่งออกภาพ

    func renderComposite(background bg: NSImage?) -> NSImage? {
        let scale = window?.backingScaleFactor ?? 2
        let pxW = Int((canvasSize.width * scale).rounded())
        let pxH = Int((canvasSize.height * scale).rounded())
        guard pxW > 0, pxH > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: pxW, pixelsHigh: pxH,
                                         bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        rep.size = canvasSize

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let gctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.current = gctx
        renderScene(in: gctx.cgContext, background: bg, includeChrome: false, includeLiveStroke: false)

        let image = NSImage(size: canvasSize)
        image.addRepresentation(rep)
        return image
    }

    func notify(_ text: String) { flashStatus(text) }

    // MARK: - ทดสอบ

    /// ใช้ในสคริปต์ทดสอบเท่านั้น — จำลองการกดปุ่มบนแถบเครื่องมือ / อ่านผังปุ่ม
    func testHitTest(_ point: CGPoint) -> String? {
        barButtons.first { $0.rect.contains(point) }?.label
    }
    var testToolbarRect: CGRect { barRect }
    func testShowChrome() { hudHidden = false; needsDisplay = true }
    func testHover(_ index: Int?) { hoveredBar = index; needsDisplay = true }
}
