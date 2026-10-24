import Foundation

/// Plain-text log used during the Phase 0 spike. Lines go to the console and to
/// ~/Movies/MeetingAgent/spike-log.txt so detection and capture results can be reviewed afterwards.
enum Log {
    static let root: URL = {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
        let url = movies.appendingPathComponent("MeetingAgent", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private static let queue = DispatchQueue(label: "meetingagent.log")

    static func write(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date()))  \(message)\n"
        print(line, terminator: "")
        queue.async {
            let url = root.appendingPathComponent("spike-log.txt")
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? line.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }
}
