import Foundation

/// log ลงไฟล์ ~/Library/Logs/ZoomJor.log — ใช้ไล่ปัญหาที่เกิดเฉพาะตอนรันบนหน้าจอจริง
/// (เช่น สตรีมภาพของโหมดซูมสด ซึ่งดูจาก debugger ไม่ได้)
enum ZLog {
    private static let queue = DispatchQueue(label: "net.kruarm.zoomjor.log")

    private static let fileURL: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("ZoomJor.log")
    }()

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func log(_ message: String) {
        let line = "\(stamp.string(from: Date()))  \(message)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: fileURL)
            }
        }
    }
}
