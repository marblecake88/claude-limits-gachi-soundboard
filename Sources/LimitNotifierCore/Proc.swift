import Foundation

/// Запуск внешнего процесса с обязательным таймаутом.
///
/// Вынесено отдельно, потому что этим пользуются двое: опрос лимитов и пинг
/// keep-alive. Оба запускают один и тот же claude, оба обязаны укладываться во
/// время и не виснуть на переполненном пайпе.
public enum Proc {

    public enum Result: Sendable {
        case launchFailed(String)
        case timedOut
        case finished(status: Int32, out: String, err: String)
    }

    /// Читает оба пайпа в фоне и обязательно укладывается в таймаут.
    /// Без фонового чтения большой вывод забьёт буфер пайпа и процесс повиснет
    /// намертво, а мы вместе с ним.
    public static func run(_ executable: String, _ args: [String],
                           timeout: TimeInterval, cwd: URL? = nil) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        if let cwd { process.currentDirectoryURL = cwd }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        // Запуск неинтерактивный, ввода не ждём.
        process.standardInput = FileHandle.nullDevice
        process.environment = environment()

        do {
            try process.run()
        } catch {
            return .launchFailed(error.localizedDescription)
        }

        let lock = NSLock()
        var outData = Data()
        var errData = Data()
        let readers = DispatchGroup()
        for (handle, isStdout) in [(outPipe.fileHandleForReading, true),
                                   (errPipe.fileHandleForReading, false)] {
            readers.enter()
            DispatchQueue.global(qos: .utility).async {
                let data = handle.readDataToEndOfFile()
                lock.lock()
                if isStdout { outData = data } else { errData = data }
                lock.unlock()
                readers.leave()
            }
        }

        // waitUntilExit блокирующий, поэтому ждём его в фоне, а тут семафор.
        let exited = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            exited.signal()
        }

        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            // Даём пару секунд умереть по-хорошему, потом добиваем.
            if exited.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 2)
            }
            _ = readers.wait(timeout: .now() + 2)
            return .timedOut
        }

        _ = readers.wait(timeout: .now() + 5)
        lock.lock()
        let out = String(data: outData, encoding: .utf8) ?? ""
        let err = String(data: errData, encoding: .utf8) ?? ""
        lock.unlock()
        return .finished(status: process.terminationStatus, out: out, err: err)
    }

    /// Окружение для дочернего процесса.
    ///
    /// PATH у приложения из Dock куцый, поэтому дописываем типичные места.
    /// А без USER клиент Claude Code отвечает "Not logged in", хотя токен на
    /// месте: проверено запуском с урезанным окружением.
    static func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let extra = "\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        env["PATH"] = env["PATH"].map { "\($0):\(extra)" } ?? extra
        if env["HOME"] == nil { env["HOME"] = NSHomeDirectory() }
        let user = NSUserName()
        if env["USER"] == nil { env["USER"] = user }
        if env["LOGNAME"] == nil { env["LOGNAME"] = user }
        return env
    }

    /// Ищет исполняемый claude. PATH у GUI-приложения не наследуется от шелла,
    /// поэтому просто написать "claude" и надеяться нельзя.
    public static func findClaude() -> String? {
        let fm = FileManager.default
        let candidates = [
            NSHomeDirectory() + "/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
        for path in candidates where fm.isExecutableFile(atPath: path) { return path }

        guard case .finished(let status, let out, _) =
                run("/usr/bin/env", ["which", "claude"], timeout: 5), status == 0 else { return nil }
        let path = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return fm.isExecutableFile(atPath: path) ? path : nil
    }
}
