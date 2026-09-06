import AppKit
import CoreImage

final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class OverlayController {

    private var window: OverlayWindow?
    private var view: OverlayView?
    private var busy = false

    // ค่าที่จำไว้ระหว่างการเรียกใช้แต่ละครั้ง
    var tool: Tool = .arrow
    var color: NSColor = Palette.all[0].color
    var lineWidth: CGFloat = 5

    private let timerMinutesKey = "defaultTimerMinutes"
    var defaultTimerMinutes: Double {
        get {
            let v = UserDefaults.standard.double(forKey: timerMinutesKey)
            return v > 0 ? v : 10
        }
        set { UserDefaults.standard.set(newValue, forKey: timerMinutesKey) }
    }

    var isActive: Bool { window?.isVisible == true }
    var activeMode: OverlayView.Mode? { view?.mode }

    // MARK: - เปิด/ปิด

    func toggleZoom() { if isActive { hide() } else { startZoom() } }
    func toggleDraw() { if isActive { hide() } else { startDraw() } }

    func toggleTimer() {
        if isActive, view?.mode == .timer { hide() } else { startTimer() }
    }

    func startDraw() {
        guard !busy else { return }
        show(on: screenWithMouse(), mode: .draw, background: nil, keeping: nil)
    }

    func startZoom() {
        guard !busy else { return }
        busy = true
        let screen = screenWithMouse()
        captureThen(screen: screen, alertOnFailure: true) { [weak self] image in
            guard let self else { return }
            self.busy = false
            guard let image else { return }
            self.show(on: screen, mode: .zoom, background: image, keeping: nil)
        }
    }

    func startTimer(minutes: Double? = nil) {
        guard !busy else { return }
        busy = true
        let screen = screenWithMouse()
        let duration = (minutes ?? defaultTimerMinutes) * 60
        // จับภาพไม่ได้ก็ยังใช้ได้ — จะขึ้นนาฬิกาบนพื้นหลังทึบแทน
        captureThen(screen: screen, alertOnFailure: false) { [weak self] image in
            guard let self else { return }
            self.busy = false
            let blurredImage = image.flatMap { Self.blurred($0, radius: 26) } ?? image
            self.show(on: screen, mode: .timer, background: blurredImage,
                      keeping: nil, duration: duration)
        }
    }

    /// จากโหมดวาด → แช่หน้าจอแล้วเข้าโหมดซูม (คงภาพวาดเดิมไว้)
    func freezeAndZoom(keeping strokes: [Stroke]) {
        guard let screen = window?.screen, !busy else { return }
        busy = true
        hide()
        captureThen(screen: screen, alertOnFailure: true) { [weak self] image in
            guard let self else { return }
            self.busy = false
            guard let image else { return }
            self.show(on: screen, mode: .zoom, background: image, keeping: strokes)
        }
    }

    func hide() {
        view?.teardown()
        window?.orderOut(nil)
        window = nil
        view = nil
    }

    // MARK: - สร้างหน้าต่างซ้อนหน้าจอ

    private func show(on screen: NSScreen, mode: OverlayView.Mode,
                      background image: CGImage?, keeping strokes: [Stroke]?,
                      duration: TimeInterval = 600) {
        hide()

        let frame = screen.frame
        let w = OverlayWindow(contentRect: frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        w.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        w.isOpaque = (mode != .draw)
        w.backgroundColor = (mode != .draw) ? .black : .clear
        w.hasShadow = false
        w.acceptsMouseMovedEvents = true
        w.ignoresMouseEvents = false
        w.isReleasedWhenClosed = false

        let v = OverlayView(frame: CGRect(origin: .zero, size: frame.size))
        v.controller = self
        v.tool = tool
        v.color = color
        v.lineWidth = lineWidth

        let bgImage = image.map { NSImage(cgImage: $0, size: frame.size) }
        let mouse = NSEvent.mouseLocation
        let startFocus = CGPoint(x: mouse.x - frame.minX, y: mouse.y - frame.minY)
        v.prepare(mode: mode, background: bgImage, canvasSize: frame.size,
                  startFocus: startFocus, timerDuration: duration)
        if let strokes { v.restore(strokes: strokes) }

        w.contentView = v
        window = w
        view = v

        w.setFrame(frame, display: true)
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        w.makeFirstResponder(v)
        w.invalidateCursorRects(for: v)
        v.didAppear()
    }

    // MARK: - จับภาพหน้าจอ

    private func captureThen(screen: NSScreen, alertOnFailure: Bool,
                             completion: @escaping (CGImage?) -> Void) {
        let displayID = screen.displayID
        let scale = screen.backingScaleFactor
        Task { @MainActor in
            do {
                completion(try await ScreenCapture.capture(displayID: displayID, scale: scale))
            } catch {
                completion(nil)
                if alertOnFailure { self.showPermissionAlert(error) }
            }
        }
    }

    private static func blurred(_ image: CGImage, radius: CGFloat) -> CGImage? {
        let ci = CIImage(cgImage: image)
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return nil }
        filter.setValue(ci.clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(radius, forKey: kCIInputRadiusKey)
        guard let output = filter.outputImage?.cropped(to: ci.extent) else { return nil }
        return CIContext().createCGImage(output, from: ci.extent)
    }

    func showPermissionAlert(_ error: Error) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "จับภาพหน้าจอไม่ได้"
        alert.informativeText = """
        โหมดซูมและ Live zoom ต้องใช้สิทธิ์ "การบันทึกหน้าจอ" (Screen Recording)

        เปิดที่:  การตั้งค่าระบบ → ความเป็นส่วนตัวและความปลอดภัย → การบันทึกหน้าจอ
        แล้วติ๊กอนุญาตให้แอปนี้ จากนั้นเปิดแอปใหม่อีกครั้ง

        (โหมดวาดใช้ได้เลยโดยไม่ต้องขอสิทธิ์นี้)

        รายละเอียด: \(error.localizedDescription)
        """
        alert.addButton(withTitle: "เปิดการตั้งค่า")
        alert.addButton(withTitle: "ปิด")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - บันทึก / คัดลอก

    func saveSnapshot() {
        makeSnapshot { [weak self] image in
            guard let image,
                  let dir = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            else { return }
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd_HH-mm-ss"
            let url = dir.appendingPathComponent("\(AppInfo.fileprefix)-\(fmt.string(from: Date())).png")
            guard let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { return }
            try? png.write(to: url)
            self?.view?.notify("บันทึกแล้ว: \(url.lastPathComponent) (บน Desktop)")
        }
    }

    func copySnapshot() {
        makeSnapshot { [weak self] image in
            guard let image else { return }
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects([image])
            self?.view?.notify("คัดลอกภาพลงคลิปบอร์ดแล้ว")
        }
    }

    private func makeSnapshot(_ completion: @escaping (NSImage?) -> Void) {
        guard let view else { completion(nil); return }
        if view.mode != .draw {
            completion(view.renderComposite(background: view.background))
            return
        }
        guard let screen = window?.screen else { completion(nil); return }
        captureThen(screen: screen, alertOnFailure: true) { image in
            guard let image else { completion(nil); return }
            completion(view.renderComposite(background: NSImage(cgImage: image, size: view.canvasSize)))
        }
    }

    // MARK: - ช่วยเหลือ

    private func screenWithMouse() -> NSScreen {
        let p = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            ?? CGMainDisplayID()
    }
}
