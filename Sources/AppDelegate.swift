import Cocoa
import Carbon.HIToolbox

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    let controller = OverlayController()
    let live = LiveZoomController()

    private let timerChoices: [Double] = [1, 3, 5, 10, 15, 20, 30, 45, 60]

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildStatusItem()

        live.onFailure = { [weak self] error in
            self?.controller.showPermissionAlert(error)
        }

        ZLog.log("=== ZoomJor เริ่มทำงาน ===")
        HotKeyCenter.shared.start()
        let ids = [
            HotKeyCenter.shared.register(keyCode: kVK_ANSI_1, modifiers: controlKey) { [weak self] in
                self?.live.stop(); self?.controller.toggleZoom()
            },
            HotKeyCenter.shared.register(keyCode: kVK_ANSI_2, modifiers: controlKey) { [weak self] in
                self?.live.stop(); self?.controller.toggleDraw()
            },
            HotKeyCenter.shared.register(keyCode: kVK_ANSI_3, modifiers: controlKey) { [weak self] in
                self?.live.stop(); self?.controller.toggleTimer()
            },
            HotKeyCenter.shared.register(keyCode: kVK_ANSI_4, modifiers: controlKey) { [weak self] in
                self?.controller.hide(); self?.live.toggle()
            }
        ]

        if ids.contains(where: { $0 == nil }) {
            let alert = NSAlert()
            alert.messageText = "ลงทะเบียนคีย์ลัดไม่สำเร็จบางตัว"
            alert.informativeText = "อาจมีแอปอื่นใช้ ⌃1 – ⌃4 อยู่ — ยังสั่งงานผ่านไอคอนบนแถบเมนูได้ตามปกติ"
            alert.runModal()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        live.stop()
        controller.hide()
    }

    // MARK: - แถบเมนู

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = Self.menuBarIcon()
            button.image?.isTemplate = true
            button.toolTip = "\(AppInfo.name) — \(AppInfo.tagline)"
        }

        let menu = NSMenu()

        addItem(menu, "ซูมหน้าจอ  (Zoom)          ⌃1", #selector(menuZoom))
        addItem(menu, "วาดบนหน้าจอ  (Draw)      ⌃2", #selector(menuDraw))
        addItem(menu, "จับเวลาถอยหลัง  (Timer)   ⌃3", #selector(menuTimer))
        addItem(menu, "ซูมสด  (Live zoom)          ⌃4", #selector(menuLiveZoom))

        menu.addItem(.separator())

        // เวลาเริ่มต้นของนาฬิกา
        let durationItem = NSMenuItem(title: "เวลาพักเริ่มต้น", action: nil, keyEquivalent: "")
        let durationMenu = NSMenu()
        for (i, m) in timerChoices.enumerated() {
            let item = NSMenuItem(title: "\(Int(m)) นาที",
                                  action: #selector(menuPickDuration(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
            durationMenu.addItem(item)
        }
        durationItem.submenu = durationMenu
        menu.addItem(durationItem)

        // สีเส้น
        let colorItem = NSMenuItem(title: "สีเส้น", action: nil, keyEquivalent: "")
        let colorMenu = NSMenu()
        for (i, pc) in Palette.all.enumerated() {
            let item = NSMenuItem(title: "\(pc.thaiName)  (\(pc.englishName))   [\(pc.key.uppercased())]",
                                  action: #selector(menuPickColor(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
            item.image = swatch(pc.color)
            colorMenu.addItem(item)
        }
        colorItem.submenu = colorMenu
        menu.addItem(colorItem)

        // เครื่องมือ
        let toolItem = NSMenuItem(title: "เครื่องมือ", action: nil, keyEquivalent: "")
        let toolMenu = NSMenu()
        for t in Tool.allCases {
            let item = NSMenuItem(title: "\(t.thaiName)  (\(t.englishName))   [\(t.key.uppercased())]",
                                  action: #selector(menuPickTool(_:)), keyEquivalent: "")
            item.target = self
            item.tag = t.rawValue
            toolMenu.addItem(item)
        }
        toolItem.submenu = toolMenu
        menu.addItem(toolItem)

        menu.addItem(.separator())
        addItem(menu, "วิธีใช้ / คีย์ลัด…", #selector(menuHelp))
        let quit = NSMenuItem(title: "ออกจากโปรแกรม", action: #selector(menuQuit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        menu.delegate = self
        statusItem.menu = menu
        refreshMenuState()
    }

    /// ใช้ไฟล์ Resources/MenuBarIcon.pdf (หรือ .png) ถ้ามี ไม่มีก็ใช้ SF Symbol
    private static func menuBarIcon() -> NSImage? {
        for name in ["MenuBarIcon"] {
            for ext in ["pdf", "png"] {
                if let url = Bundle.main.url(forResource: name, withExtension: ext),
                   let image = NSImage(contentsOf: url) {
                    image.size = NSSize(width: 18, height: 18)
                    return image
                }
            }
        }
        return NSImage(systemSymbolName: "plus.magnifyingglass",
                       accessibilityDescription: AppInfo.name)
    }

    @discardableResult
    private func addItem(_ menu: NSMenu, _ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return item
    }

    private func swatch(_ color: NSColor) -> NSImage {
        let size = NSSize(width: 12, height: 12)
        let image = NSImage(size: size)
        image.lockFocus()
        color.setFill()
        NSBezierPath(ovalIn: NSRect(origin: .zero, size: size)).fill()
        NSColor.gray.withAlphaComponent(0.6).setStroke()
        NSBezierPath(ovalIn: NSRect(x: 0.5, y: 0.5, width: 11, height: 11)).stroke()
        image.unlockFocus()
        return image
    }

    private func refreshMenuState() {
        guard let menu = statusItem.menu else { return }
        menu.item(withTitle: "สีเส้น")?.submenu?.items.forEach {
            $0.state = (Palette.all[$0.tag].color == controller.color) ? .on : .off
        }
        menu.item(withTitle: "เครื่องมือ")?.submenu?.items.forEach {
            $0.state = ($0.tag == controller.tool.rawValue) ? .on : .off
        }
        menu.item(withTitle: "เวลาพักเริ่มต้น")?.submenu?.items.forEach {
            $0.state = (timerChoices[$0.tag] == controller.defaultTimerMinutes) ? .on : .off
        }
    }

    // MARK: - Actions

    @objc private func menuZoom()  { live.stop(); controller.startZoom() }
    @objc private func menuDraw()  { live.stop(); controller.startDraw() }
    @objc private func menuTimer() { live.stop(); controller.startTimer() }
    @objc private func menuLiveZoom() { controller.hide(); live.toggle() }

    @objc private func menuPickDuration(_ sender: NSMenuItem) {
        controller.defaultTimerMinutes = timerChoices[sender.tag]
        refreshMenuState()
    }

    @objc private func menuPickColor(_ sender: NSMenuItem) {
        controller.color = Palette.all[sender.tag].color
        refreshMenuState()
    }

    @objc private func menuPickTool(_ sender: NSMenuItem) {
        controller.tool = Tool(rawValue: sender.tag) ?? .arrow
        refreshMenuState()
    }

    @objc private func menuQuit() { NSApp.terminate(nil) }

    @objc private func menuHelp() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "\(AppInfo.name) — คีย์ลัด"
        alert.informativeText = """
        ▸ เรียกใช้งาน (กดที่ไหนก็ได้)
          ⌃1  แช่หน้าจอ + ซูม          ⌃2  วาดทับหน้าจอสด
          ⌃3  นาฬิกาจับเวลาถอยหลัง   ⌃4  ซูมสด (Live zoom)

        ▸ คีย์ลัดทุกตัวอ่านจาก "ตำแหน่งปุ่ม" ไม่ใช่ตัวอักษร
          สลับแป้นพิมพ์เป็นภาษาไทยค้างอยู่ก็กดได้ตามปกติ ไม่ต้องสลับกลับเป็นอังกฤษ
          (ปุ่มที่เขียนว่า R = ปุ่มเดียวกับ พ / A = ปุ่มเดียวกับ ฟ)

        ▸ แถบเครื่องมือด้านบนจอ — คลิกเลือกได้ทุกอย่างโดยไม่ต้องจำคีย์
          เครื่องมือ · สีเส้น · ย้อนกลับ · ทำซ้ำ · ลบทั้งหมด · ออก      (กด D ซ่อน/แสดง)

        ▸ ย้อนกลับตอนวาดผิด
          ⌫ (Backspace)  หรือ  ⌘Z  หรือ  U  หรือกดปุ่ม ↶ บนแถบเครื่องมือ
          ทำซ้ำ: ⇧⌘Z          ลบทั้งหมด: E หรือ ⌘⌫

        ▸ โหมดซูม / วาด
          คลิกลาก = วาด        Esc / คลิกขวา = ออก
          เลื่อนเมาส์ = ส่องซูมตามเมาส์ (คลิกวาดครั้งแรกจะล็อกภาพให้)
          Tab = สลับล็อก/ปลดล็อกการแพน
          สกอร์ล หรือ + - หรือ ↑ ↓ = ปรับซูม     0 = กลับ 100%

        ▸ สีเส้น
          R แดง   G เขียว   Y เหลือง   K ดำ   B น้ำเงิน
          W ขาว   O ส้ม     M ชมพู

        ▸ เครื่องมือ
          A ลูกศร   P ปากกา   L เส้นตรง   S สี่เหลี่ยม
          C วงรี    H ไฮไลต์  T ข้อความ
          ทางลัดขณะลาก (ไม่ต้องเปลี่ยนเครื่องมือ):
            ⇧ ค้าง = ลูกศร      ⌃⇧ ค้าง = สี่เหลี่ยม
            ⌥ ค้าง = บังคับมุม 45° / จัตุรัส

        ▸ นาฬิกาจับเวลาถอยหลัง (⌃3)
          Space หยุด/เดินต่อ      ↑ ↓ ±1 นาที      ← → ±10 วินาที
          พิมพ์ตัวเลขแล้ว Enter = ตั้งเวลาใหม่ (นาที)
          ⌘R เริ่มนับใหม่          D เปิด/ปิดแถบเครื่องมือ
          วาดทับหน้าจอพักได้ด้วยเครื่องมือชุดเดียวกัน

        ▸ ซูมสด — Live zoom (⌃4)
          ขยายภาพจริงแบบเรียลไทม์ คลิก/พิมพ์ทะลุไปยังแอปข้างล่างได้ตามปกติ
          ⌃⌥↑ / ⌃⌥=  ขยาย          ⌃⌥↓ / ⌃⌥-  ย่อ
          ⌃⌥0  กลับ 200%            ⌃4 หรือปุ่ม ✕ บนแถบลอย = ปิด

        ▸ อื่น ๆ
          [ ]  ปรับขนาดเส้น        ⌘S เซฟ PNG ลง Desktop    ⌘C คัดลอกลงคลิปบอร์ด
          ?  แสดง/ซ่อนคีย์ลัดบนจอ   Z (ในโหมดวาด) แช่หน้าจอแล้วซูมต่อ
        """
        alert.addButton(withTitle: "เข้าใจแล้ว")
        alert.runModal()
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        refreshMenuState()
        menu.item(withTitle: "ซูมสด  (Live zoom)          ⌃4")?.state = live.isActive ? .on : .off
    }
}
