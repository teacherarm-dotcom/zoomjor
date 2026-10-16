import AppKit
import QuartzCore

/// เมาส์ใหญ่ + วงแสงรอบเมาส์ + เอฟเฟกต์ตอนคลิก (⌃5)
///
/// macOS ไม่เปิดให้แอปขยายเคอร์เซอร์ของระบบ จึงวาด "เมาส์ตัวใหญ่" ลงหน้าต่างใสคลุมทุกจอ
/// ที่คลิกทะลุได้ แล้ววางปลายลูกศรให้ตรงกับปลายเมาส์จริงเสมอ (เมาส์จริงจะซ้อนอยู่ที่ปลายพอดี)
///
/// - ฟังเมาส์ด้วย global monitor — เหตุการณ์เมาส์ไม่ต้องขอสิทธิ์ Accessibility (ต่างจากคีย์บอร์ด)
/// - หน้าต่างนี้ "ติด" ในโปรแกรมอัดจอ/แชร์จอ (ตั้งใจ — ผู้ชมต้องเห็นเมาส์กับจุดคลิก)
///   แต่ภาพที่ ZoomJor จับเอง (⌃1/⌃4) ตัดหน้าต่างของแอปเราออกอยู่แล้ว จึงไม่ติดลงภาพแช่
@MainActor
final class CursorFX {

    // MARK: - ค่าที่ผู้ใช้เลือก (จำไว้ข้ามการเปิดโปรแกรม)

    nonisolated static let scaleChoices: [CGFloat] = [2, 3, 4]

    private enum Key {
        static let enabled = "cursorFX.enabled"
        static let scale = "cursorFX.scale"
        static let halo = "cursorFX.halo"
        static let clicks = "cursorFX.clicks"
    }

    var isEnabled: Bool { UserDefaults.standard.bool(forKey: Key.enabled) }

    var scale: CGFloat {
        get { Self.clampScale(UserDefaults.standard.double(forKey: Key.scale)) }
        set { UserDefaults.standard.set(Double(Self.clampScale(newValue)), forKey: Key.scale); rebuildShapes() }
    }

    var showsHalo: Bool {
        get { UserDefaults.standard.object(forKey: Key.halo) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Key.halo); rebuildShapes() }
    }

    var showsClicks: Bool {
        get { UserDefaults.standard.object(forKey: Key.clicks) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Key.clicks) }
    }

    /// ค่าที่ไม่รู้จัก/ค่าขยะ → 3× (ค่าเริ่มต้น)
    nonisolated static func clampScale(_ v: Double) -> CGFloat {
        let c = CGFloat(v)
        return scaleChoices.contains(c) ? c : 3
    }

    /// คืน true = ซ่อนเมาส์ใหญ่ชั่วคราว (เช่น ตอนอยู่ในโหมดวาด ⌃2 ที่มีเคอร์เซอร์ปากกาของตัวเอง)
    var isSuppressed: () -> Bool = { false }

    // MARK: - สถานะภายใน

    private var views: [CursorFXView] = []
    private var monitors: [Any] = []
    private var pollTimer: Timer?
    private var lastPoint: CGPoint = CGPoint(x: CGFloat.nan, y: CGFloat.nan)
    private var lastHidden = false
    private var screenObserver: NSObjectProtocol?

    // MARK: - เปิด/ปิด

    func restoreIfNeeded() { if isEnabled { start() } }

    func toggle() { if isEnabled { stop() } else { start() } }

    func start() {
        UserDefaults.standard.set(true, forKey: Key.enabled)
        guard monitors.isEmpty else { return }
        buildWindows()

        let move: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        let down: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]

        if let m = NSEvent.addGlobalMonitorForEvents(matching: move.union(down), handler: { [weak self] e in
            MainActor.assumeIsolated { self?.handle(e) }
        }) { monitors.append(m) }
        // หน้าต่างของแอปเราเอง (แถบเมนู/กล่องข้อความ) ส่งเหตุการณ์มาทาง local แทน
        if let m = NSEvent.addLocalMonitorForEvents(matching: move.union(down), handler: { [weak self] e in
            MainActor.assumeIsolated { self?.handle(e) }
            return e
        }) { monitors.append(m) }

        // ตาข่ายกันพลาด: บางจังหวะระบบไม่ส่งเหตุการณ์ (เช่น ตอนแอปอื่นจับเมาส์ไว้) → เช็คตำแหน่งเองเป็นระยะ
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.moveTo(NSEvent.mouseLocation) }
        }

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.buildWindows() }
        }

        lastPoint = CGPoint(x: CGFloat.nan, y: CGFloat.nan)
        moveTo(NSEvent.mouseLocation)
        ZLog.log("cursorFX: เปิด (×\(scale), วงแสง=\(showsHalo), คลิก=\(showsClicks))")
    }

    func stop() {
        UserDefaults.standard.set(false, forKey: Key.enabled)
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        pollTimer?.invalidate(); pollTimer = nil
        if let o = screenObserver { NotificationCenter.default.removeObserver(o) }
        screenObserver = nil
        views.forEach { $0.window?.orderOut(nil) }
        views.removeAll()
        ZLog.log("cursorFX: ปิด")
    }

    /// ตอนปิดโปรแกรม — เก็บหน้าต่างโดยไม่ลบค่า "เปิดอยู่" (เปิดโปรแกรมครั้งหน้าจะกลับมาเอง)
    func hideWindows() {
        views.forEach { $0.window?.orderOut(nil) }
    }

    // MARK: - หน้าต่าง

    private func buildWindows() {
        views.forEach { $0.window?.orderOut(nil) }
        views.removeAll()
        for screen in NSScreen.screens {
            let w = NSWindow(contentRect: screen.frame, styleMask: .borderless,
                             backing: .buffered, defer: false)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.ignoresMouseEvents = true
            w.isReleasedWhenClosed = false
            // เหนือแถบลอยของซูมสด (Shielding+1) เพื่อให้เห็นเมาส์ใหญ่ทับทุกอย่าง
            w.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 2)
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            let v = CursorFXView(frame: NSRect(origin: .zero, size: screen.frame.size))
            v.screenFrame = screen.frame
            w.contentView = v
            w.setFrame(screen.frame, display: false)
            w.orderFrontRegardless()
            views.append(v)
        }
        rebuildShapes()
        lastPoint = CGPoint(x: CGFloat.nan, y: CGFloat.nan)
    }

    private func rebuildShapes() {
        views.forEach { $0.configure(scale: scale, halo: showsHalo) }
        lastPoint = CGPoint(x: CGFloat.nan, y: CGFloat.nan)
        if !monitors.isEmpty { moveTo(NSEvent.mouseLocation) }
    }

    // MARK: - เหตุการณ์เมาส์

    private func handle(_ e: NSEvent) {
        let p = NSEvent.mouseLocation
        moveTo(p)
        guard showsClicks, !isSuppressed() else { return }
        switch e.type {
        case .leftMouseDown:  ripple(at: p, kind: .left)
        case .rightMouseDown: ripple(at: p, kind: .right)
        case .otherMouseDown: ripple(at: p, kind: .other)
        default: break
        }
    }

    private func moveTo(_ p: CGPoint) {
        let hidden = isSuppressed()
        if p == lastPoint && hidden == lastHidden { return }
        lastPoint = p
        lastHidden = hidden
        for v in views {
            v.showCursor(at: hidden ? nil : v.local(p))
        }
    }

    private func ripple(at p: CGPoint, kind: ClickKind) {
        guard let v = views.first(where: { $0.screenFrame.contains(p) }) ?? views.first else { return }
        v.ripple(at: v.local(p), color: kind.color, scale: scale)
    }

    // MARK: - รูปทรง (แยกออกมาเพื่อเทสต์ได้)

    enum ClickKind {
        case left, right, other
        var color: NSColor {
            switch self {
            case .left:  return NSColor(srgbRed: 1.00, green: 0.23, blue: 0.19, alpha: 1)  // แดง
            case .right: return NSColor(srgbRed: 0.04, green: 0.52, blue: 1.00, alpha: 1)  // น้ำเงิน
            case .other: return NSColor(srgbRed: 0.20, green: 0.78, blue: 0.35, alpha: 1)  // เขียว
            }
        }
    }

    /// ลูกศรแบบเคอร์เซอร์มาตรฐานของ macOS — ปลายลูกศรอยู่ที่ (0,0) ชี้ขึ้นซ้าย (แกน y ขึ้นบน)
    /// ขนาดที่ ×1 ราว 12×18.5 pt ใกล้เคียงเคอร์เซอร์จริง
    nonisolated static func arrowPath(scale s: CGFloat) -> CGPath {
        let pts: [CGPoint] = [
            .init(x: 0, y: 0), .init(x: 0, y: -16), .init(x: 4.2, y: -12.2),
            .init(x: 7, y: -18.5), .init(x: 9.6, y: -17.4), .init(x: 6.9, y: -11.2),
            .init(x: 12, y: -11.2),
        ]
        let path = CGMutablePath()
        path.addLines(between: pts.map { CGPoint(x: $0.x * s, y: $0.y * s) })
        path.closeSubpath()
        return path
    }

    /// รัศมีวงแสงรอบเมาส์ ตามขนาดเมาส์
    nonisolated static func haloRadius(scale s: CGFloat) -> CGFloat { 10 + 8 * s }

    /// รัศมีวงกระเพื่อมตอนคลิกเมื่อขยายสุด
    nonisolated static func rippleRadius(scale s: CGFloat) -> CGFloat { 24 + 14 * s }

    /// แปลงพิกัดจอรวม (มุมล่างซ้ายของจอหลัก) → พิกัดในจอนั้น
    nonisolated static func local(_ p: CGPoint, in screenFrame: CGRect) -> CGPoint {
        CGPoint(x: p.x - screenFrame.minX, y: p.y - screenFrame.minY)
    }
}

// MARK: - มุมมองที่วาดจริง (Core Animation ล้วน — ขยับเมาส์ไม่ต้องวาดใหม่ทั้งจอ)

@MainActor
final class CursorFXView: NSView {

    var screenFrame: CGRect = .zero

    private let pointer = CALayer()       // กลุ่มที่เลื่อนตามเมาส์ (ปลายลูกศร = จุดกำเนิด)
    private let halo = CAShapeLayer()
    private let arrow = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        layer?.masksToBounds = false
        pointer.bounds = .zero
        pointer.anchorPoint = .zero
        pointer.isHidden = true
        pointer.addSublayer(halo)
        pointer.addSublayer(arrow)
        layer?.addSublayer(pointer)
    }

    required init?(coder: NSCoder) { fatalError() }

    func local(_ p: CGPoint) -> CGPoint { CursorFX.local(p, in: screenFrame) }

    func configure(scale s: CGFloat, halo showHalo: Bool) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let r = CursorFX.haloRadius(scale: s)
        halo.path = CGPath(ellipseIn: CGRect(x: -r, y: -r, width: 2 * r, height: 2 * r), transform: nil)
        halo.fillColor = NSColor(srgbRed: 1, green: 0.85, blue: 0.1, alpha: 0.35).cgColor
        halo.strokeColor = NSColor(srgbRed: 1, green: 0.75, blue: 0, alpha: 0.85).cgColor
        halo.lineWidth = 2
        halo.isHidden = !showHalo

        arrow.path = CursorFX.arrowPath(scale: s)
        arrow.fillColor = NSColor.black.cgColor
        arrow.strokeColor = NSColor.white.cgColor
        arrow.lineWidth = max(1.5, s * 0.9)
        arrow.lineJoin = .round
        arrow.shadowColor = NSColor.black.cgColor
        arrow.shadowOpacity = 0.35
        arrow.shadowRadius = 1.5 * s
        arrow.shadowOffset = CGSize(width: 0, height: -s)
        CATransaction.commit()
    }

    /// nil = ซ่อน (เมาส์อยู่จออื่น หรือถูกพักไว้)
    func showCursor(at p: CGPoint?) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if let p, bounds.contains(p) {
            pointer.position = p
            pointer.isHidden = false
        } else {
            pointer.isHidden = true
        }
        CATransaction.commit()
    }

    func ripple(at p: CGPoint, color: NSColor, scale s: CGFloat) {
        let R = CursorFX.rippleRadius(scale: s)
        let ring = CAShapeLayer()
        ring.path = CGPath(ellipseIn: CGRect(x: -R, y: -R, width: 2 * R, height: 2 * R), transform: nil)
        ring.fillColor = color.withAlphaComponent(0.22).cgColor
        ring.strokeColor = color.cgColor
        ring.lineWidth = 3 + 1.2 * s
        ring.position = p
        ring.opacity = 0
        // ให้วงอยู่ใต้ลูกศรเสมอ
        layer?.insertSublayer(ring, below: pointer)

        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.15
        grow.toValue = 1.0
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0.95, 0.85, 0]
        fade.keyTimes = [0, 0.4, 1]
        let group = CAAnimationGroup()
        group.animations = [grow, fade]
        group.duration = 0.55
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)

        CATransaction.begin()
        CATransaction.setCompletionBlock { ring.removeFromSuperlayer() }
        ring.add(group, forKey: "ripple")
        CATransaction.commit()
    }
}
