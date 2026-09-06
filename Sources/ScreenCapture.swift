import AppKit
import ScreenCaptureKit

enum CaptureError: LocalizedError {
    case noDisplay
    var errorDescription: String? { "ไม่พบจอภาพที่จะจับภาพได้" }
}

enum ScreenCapture {
    /// จับภาพหน้าจอทั้งจอด้วย ScreenCaptureKit (ต้องได้รับสิทธิ์ Screen Recording)
    /// หน้าต่างของแอปเราเองจะถูกตัดออกเสมอ
    static func capture(displayID: CGDirectDisplayID, scale: CGFloat) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false,
                                                                          onScreenWindowsOnly: true)
        let display = content.displays.first { $0.displayID == displayID } ?? content.displays.first
        guard let display else { throw CaptureError.noDisplay }

        let myPID = ProcessInfo.processInfo.processIdentifier
        let filter: SCContentFilter
        if let me = content.applications.first(where: { $0.processID == myPID }) {
            filter = SCContentFilter(display: display,
                                     excludingApplications: [me],
                                     exceptingWindows: [])
        } else {
            filter = SCContentFilter(display: display, excludingWindows: [])
        }

        let config = SCStreamConfiguration()
        config.width = Int((CGFloat(display.width) * scale).rounded())
        config.height = Int((CGFloat(display.height) * scale).rounded())
        config.showsCursor = false
        config.captureResolution = .best
        config.scalesToFit = false
        config.ignoreGlobalClipDisplay = true

        return try await SCScreenshotManager.captureImage(contentFilter: filter,
                                                          configuration: config)
    }
}
