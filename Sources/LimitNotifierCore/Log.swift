import Foundation

/// Лог действий приложения: опросы, пинги, ошибки.
/// Подрезается по времени, чтоб не рос бесконечно.

public enum Log {
    /// Пишем и из таймера, и из UI, поэтому файл под замком.
    private static let lock = NSLock()

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs", isDirectory: true)
            .appendingPathComponent("limitnotifier.log")
    }

    /// ISO8601 в локальной зоне: читать лог глазами удобнее по своему времени.
    private static func stamper() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        return f
    }

    public static func write(_ line: String, at url: URL = Log.defaultURL, now: Date = Date()) {
        let entry = "\(stamper().string(from: now)) \(line)\n"
        guard let data = entry.data(using: .utf8) else { return }

        lock.lock()
        defer { lock.unlock() }
        do {
            // Каталог и файл создаём лениво, при первой записи.
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: url)
            }
        } catch {
            // Лог не критичен, из-за него не падаем и не шумим.
        }
    }

    /// Оставляет только строки свежее отсечки. Строку, у которой метка времени
    /// не разобралась, оставляем: лучше держать мусор, чем молча съесть данные.
    public static func trim(olderThanHours hours: Int = 72, at url: URL = Log.defaultURL, now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-Double(hours) * 3600)

        lock.lock()
        defer { lock.unlock() }
        // Файла может ещё не быть, это нормальный случай, а не ошибка.
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return }

        let parser = stamper()
        let kept = raw.split(separator: "\n", omittingEmptySubsequences: false).filter { line in
            if line.isEmpty { return false }
            guard let head = line.split(separator: " ", maxSplits: 1).first,
                  let date = parser.date(from: String(head)) else { return true }
            return date >= cutoff
        }

        let text = kept.isEmpty ? "" : kept.joined(separator: "\n") + "\n"
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}
