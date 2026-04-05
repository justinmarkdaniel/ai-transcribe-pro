import Foundation

/// Lightweight event logger. Writes to stderr and to
/// `~/Library/Logs/AITranscribePro/app.log` so we can tail it while debugging:
///
///     tail -f ~/Library/Logs/AITranscribePro/app.log
enum Log {
    static let fileURL: URL = {
        let dir = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("AITranscribePro", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("app.log")
    }()

    private static let queue = DispatchQueue(label: "com.justindaniel.aitranscribepro.log")

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func log(_ category: String, _ message: String) {
        let line = "[\(formatter.string(from: Date()))] [\(category)] \(message)\n"
        queue.async {
            fputs(line, stderr)
            guard let data = line.data(using: .utf8) else { return }
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                try? data.write(to: fileURL)
                return
            }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                try? handle.write(contentsOf: data)
            }
        }
    }
}
