import Carbon.HIToolbox
import Foundation

/// ลงทะเบียนคีย์ลัดระดับระบบ (global hotkey) ด้วย Carbon
/// ข้อดี: ไม่ต้องขอสิทธิ์ Accessibility และถอนคืนได้ (ใช้กับคีย์ชั่วคราวของโหมด Live zoom)
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private var handlers: [UInt32: @MainActor () -> Void] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var nextID: UInt32 = 1
    private var installed = false

    func start() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { (_, event, _) -> OSStatus in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var hkID = EventHotKeyID()
            let status = GetEventParameter(event,
                                           EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID),
                                           nil,
                                           MemoryLayout<EventHotKeyID>.size,
                                           nil,
                                           &hkID)
            guard status == noErr else { return status }
            HotKeyCenter.shared.fire(hkID.id)
            return noErr
        }, 1, &spec, nil, nil)
    }

    /// คืนค่า id ไว้ใช้ถอนคืน — คืน nil เมื่อจองคีย์ไม่สำเร็จ (มีแอปอื่นจองอยู่)
    @discardableResult
    func register(keyCode: Int, modifiers: Int, handler: @escaping @MainActor () -> Void) -> UInt32? {
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: OSType(0x5A4F4D49), id: id) // 'ZOMI'
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hkID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return nil }
        handlers[id] = handler
        refs[id] = ref
        return id
    }

    func unregister(_ id: UInt32) {
        if let ref = refs[id] { UnregisterEventHotKey(ref) }
        refs[id] = nil
        handlers[id] = nil
    }

    func unregister(_ ids: [UInt32]) { ids.forEach(unregister) }

    fileprivate func fire(_ id: UInt32) {
        guard let handler = handlers[id] else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated { handler() }
        }
    }
}
