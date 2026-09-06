import AppKit
import Carbon.HIToolbox
import CoreMedia
import ScreenCaptureKit
import VideoToolbox

// MARK: - ตัวรับเฟรมสด

/// สตรีมภาพหน้าจอต่อเนื่องด้วย SCStream (ตัดหน้าต่างของแอปเราออก จึงไม่เกิดภาพซ้อนวน)
final class LiveFrameSource: NSObject, SCStreamOutput, SCStreamDelegate {

    private var stream: SCStream?
    private let queue = DispatchQueue(label: "net.kruarm.zoomit.live", qos: .userInteractive)
    private let onFrame: (CGImage) -> Void
    private let onStop: (Error?) -> Void

    init(onFrame: @escaping (CGImage) -> Void, onStop: @escaping (Error?) -> Void) {
        self.onFrame = onFrame
        self.onStop = onStop
    }

    func start(displayID: CGDirectDisplayID, scale: CGFloat, fps: Int32 = 60) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false,
                                                                          onScreenWindowsOnly: true)
        let display = content.displays.first { $0.displayID == displayID } ?? content.displays.first
        guard let display else { throw CaptureError.noDisplay }

        let myPID = ProcessInfo.processInfo.processIdentifier
        let filter: SCContentFilter
        if let me = content.applications.first(where: { $0.processID == myPID }) {
            filter = SCContentFilter(display: display, excludingApplications: [me], exceptingWindows: [])
        } else {
            filter = SCContentFilter(display: display, excludingWindows: [])
        }

        let config = SCStreamConfiguration()
        config.width = Int((CGFloat(display.width) * scale).rounded())
        config.height = Int((CGFloat(display.height) * scale).rounded())
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.minimumFrameInterval = CMTime(value: 1, timescale: fps)
        config.queueDepth = 4
        config.showsCursor = false      // เคอร์เซอร์จริงอยู่ตรงจุดเดียวกันอยู่แล้ว จึงไม่ต้องซ้อน
        config.capturesAudio = false

        let s = SCStream(filter: filter, configuration: config, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await s.startCapture()
        stream = s
    }

    func stop() async {
        guard let s = stream else { return }
        stream = nil
        try? await s.stopCapture()
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen else { return }
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer,
                                                                        createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw),
              status == .complete,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }

        var image: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &image)
        guard let image else { return }
        DispatchQueue.main.async { self.onFrame(image) }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { self.onStop(error) }
    }
}

// MARK: - มุมมองภาพขยายสด

final class LiveZoomView: NSView {
    var image: NSImage?
    var zoom: CGFloat = 2
    var cursor: CGPoint = .zero        // ตำแหน่งเมาส์ในพิกัด canvas (point, origin ล่างซ้าย)
    var canvasSize: CGSize = .zero

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(bounds)
        guard let image, canvasSize.width > 0 else { return }

        // ยึดจุดใต้เคอร์เซอร์ไว้กับที่ เพื่อให้เคอร์เซอร์จริงตรงกับเนื้อหาที่ขยายเสมอ
        // (คลิกตรงไหน = โดนตรงนั้นจริง)
        let k = 1 - 1 / zoom
        let src = CGRect(x: cursor.x * k,
                         y: cursor.y * k,
                         width: canvasSize.width / zoom,
                         height: canvasSize.height / zoom)
        ctx.interpolationQuality = .high
        image.draw(in: bounds, from: src, operation: .copy, fraction: 1.0)
    }
}

// MARK: - แถบควบคุมลอย (คลิกได้โดยไม่แย่งโฟกัสจากแอปที่ใช้อยู่)

final class HUDBackdropView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let path = CGPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                          cornerWidth: 12, cornerHeight: 12, transform: nil)
        ctx.addPath(path)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.84).cgColor)
        ctx.fillPath()
        ctx.addPath(path)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.20).cgColor)
        ctx.setLineWidth(1)
        ctx.strokePath()
    }
}

// MARK: - ตัวควบคุมโหมด Live zoom

@MainActor
final class LiveZoomController {

    private var window: NSWindow?
    private var view: LiveZoomView?
    private var panel: NSPanel?
    private var zoomLabel: NSTextField?
    private var source: LiveFrameSource?
    private var hotkeys: [UInt32] = []
    private var pumpTimer: Timer?
    private var screenFrame: CGRect = .zero
    private var lastMouse: CGPoint = .init(x: -1, y: -1)

    private(set) var isActive = false
    var onFailure: ((Error) -> Void)?

    var zoom: CGFloat = 2.0 {
        didSet {
            zoom = min(max(1.25, zoom), 12)
            view?.zoom = zoom
            view?.needsDisplay = true
            zoomLabel?.stringValue = String(format: "%.0f%%", zoom * 100)
        }
    }

    func toggle() { isActive ? stop() : start() }

    func start() {
        guard !isActive else { return }
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens[0]
        screenFrame = screen.frame
        isActive = true

        makeWindow(on: screen)
        makePanel(on: screen)
        installHotkeys()

        let src = LiveFrameSource(onFrame: { [weak self] image in
            MainActor.assumeIsolated { self?.receive(image) }
        }, onStop: { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        })
        source = src

        let displayID = screen.displayID
        let scale = screen.backingScaleFactor
        Task { @MainActor in
            do {
                try await src.start(displayID: displayID, scale: scale)
            } catch {
                self.stop()
                self.onFailure?(error)
            }
        }

        pumpTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pump() }
        }
        pump()
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        pumpTimer?.invalidate(); pumpTimer = nil
        HotKeyCenter.shared.unregister(hotkeys); hotkeys.removeAll()

        let src = source
        source = nil
        Task { await src?.stop() }

        window?.orderOut(nil); window = nil; view = nil
        panel?.orderOut(nil); panel = nil; zoomLabel = nil
        lastMouse = CGPoint(x: -1, y: -1)
    }

    // MARK: ภายใน

    private func receive(_ image: CGImage) {
        guard isActive, let view else { return }
        view.image = NSImage(cgImage: image, size: screenFrame.size)
        view.needsDisplay = true
    }

    /// ตามตำแหน่งเมาส์แม้ภาพหน้าจอจะนิ่ง (SCStream จะไม่ส่งเฟรมเมื่อไม่มีอะไรเปลี่ยน)
    private func pump() {
        guard let view else { return }
        let p = NSEvent.mouseLocation
        guard p != lastMouse else { return }
        lastMouse = p
        view.cursor = CGPoint(
            x: min(max(0, p.x - screenFrame.minX), screenFrame.width),
            y: min(max(0, p.y - screenFrame.minY), screenFrame.height))
        view.needsDisplay = true
    }

    private func makeWindow(on screen: NSScreen) {
        let w = NSWindow(contentRect: screen.frame, styleMask: [.borderless],
                         backing: .buffered, defer: false)
        w.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        w.isOpaque = true
        w.backgroundColor = .black
        w.hasShadow = false
        w.ignoresMouseEvents = true        // คลิกทะลุลงไปยังแอปข้างล่างได้ตามปกติ
        w.isReleasedWhenClosed = false

        let v = LiveZoomView(frame: CGRect(origin: .zero, size: screen.frame.size))
        v.canvasSize = screen.frame.size
        v.zoom = zoom
        v.cursor = CGPoint(x: NSEvent.mouseLocation.x - screen.frame.minX,
                           y: NSEvent.mouseLocation.y - screen.frame.minY)
        w.contentView = v

        // orderFrontRegardless = แสดงโดยไม่ต้อง activate แอป (แอปที่ผู้ใช้ทำงานอยู่ไม่เสียโฟกัส)
        w.orderFrontRegardless()
        window = w
        view = v
    }

    private func makePanel(on screen: NSScreen) {
        let width: CGFloat = 214, height: CGFloat = 40
        let rect = CGRect(x: screen.frame.midX - width / 2,
                          y: screen.frame.maxY - height - 14,
                          width: width, height: height)
        let p = NSPanel(contentRect: rect,
                        styleMask: [.nonactivatingPanel, .borderless],
                        backing: .buffered, defer: false)
        p.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.isFloatingPanel = true
        p.becomesKeyOnlyIfNeeded = true
        p.hidesOnDeactivate = false        // สำคัญ: ค่าเริ่มต้นของ NSPanel คือ true
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true

        let backdrop = HUDBackdropView(frame: CGRect(origin: .zero,
                                                     size: CGSize(width: width, height: height)))
        let minus = iconButton("minus", action: #selector(panelZoomOut))
        minus.frame = CGRect(x: 10, y: 4, width: 34, height: 32)
        let label = NSTextField(labelWithString: String(format: "%.0f%%", zoom * 100))
        label.frame = CGRect(x: 48, y: 10, width: 62, height: 20)
        label.alignment = .center
        label.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        label.textColor = .white
        let plus = iconButton("plus", action: #selector(panelZoomIn))
        plus.frame = CGRect(x: 114, y: 4, width: 34, height: 32)
        let close = iconButton("xmark", action: #selector(panelClose))
        close.frame = CGRect(x: 168, y: 4, width: 34, height: 32)

        let divider = NSBox(frame: CGRect(x: 156, y: 10, width: 1, height: 20))
        divider.boxType = .separator

        backdrop.addSubview(minus)
        backdrop.addSubview(label)
        backdrop.addSubview(plus)
        backdrop.addSubview(divider)
        backdrop.addSubview(close)
        p.contentView = backdrop
        p.orderFrontRegardless()

        panel = p
        zoomLabel = label
    }

    private func iconButton(_ symbol: String, action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        let b = NSButton(image: image ?? NSImage(), target: self, action: action)
        b.isBordered = false
        b.bezelStyle = .regularSquare
        b.contentTintColor = .white
        return b
    }

    @objc private func panelZoomIn()  { zoom *= 1.25 }
    @objc private func panelZoomOut() { zoom /= 1.25 }
    @objc private func panelClose()   { stop() }

    /// คีย์ลัดชั่วคราว มีผลเฉพาะตอน Live zoom ทำงาน แล้วถอนคืนตอนปิด
    private func installHotkeys() {
        let mods = controlKey | optionKey
        let zoomIn: @MainActor () -> Void  = { [weak self] in self?.zoom *= 1.25 }
        let zoomOut: @MainActor () -> Void = { [weak self] in self?.zoom /= 1.25 }
        let reset: @MainActor () -> Void   = { [weak self] in self?.zoom = 2.0 }
        let specs: [(Int, @MainActor () -> Void)] = [
            (kVK_UpArrow, zoomIn), (kVK_ANSI_Equal, zoomIn),
            (kVK_DownArrow, zoomOut), (kVK_ANSI_Minus, zoomOut),
            (kVK_ANSI_0, reset)
        ]
        for (code, action) in specs {
            if let id = HotKeyCenter.shared.register(keyCode: code, modifiers: mods, handler: action) {
                hotkeys.append(id)
            }
        }
    }
}
