import Foundation

/// Сообщение от хука Claude Code: в таком-то проекте работа закончилась.
public struct ReadyEvent: Sendable, Equatable {
    public let cwd: String
    public let sessionId: String
    /// Транскрипт сессии. По его времени изменения видно, продолжилась ли
    /// работа после того, как claude отчитался о конце ответа.
    public let transcript: String
    public let at: Date

    public init(cwd: String, sessionId: String, transcript: String = "", at: Date) {
        self.cwd = cwd
        self.sessionId = sessionId
        self.transcript = transcript
        self.at = at
    }

    /// Имя для строки меню: последняя часть пути.
    public var project: String {
        URL(fileURLWithPath: cwd).lastPathComponent
    }
}

/// Файл, в который пишет хук, и чтение его нами.
///
/// Через файл, а не через сокет или URL-схему: хук это отдельный короткий
/// процесс, ему проще всего дописать строку, а нам проще всего дочитать хвост.
/// Ни портов, ни разрешений на сеть, ни гонок за адрес.
public enum ReadyLog {
    /// Папка без пробелов в пути намеренно. Claude Code запускает команду хука
    /// через шелл без кавычек, поэтому путь с пробелом рвётся на первом же:
    /// "~/Library/Application Support/..." не выполняется вообще и молча.
    /// Проверено: тот же скрипт из /tmp отрабатывает, из Application Support нет.
    public static var directory: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".limitnotifier")
    }

    public static var defaultURL: URL {
        directory.appendingPathComponent("ready.jsonl")
    }

    /// Наши собственные вызовы claude (опрос лимитов) идут из этой папки.
    /// Их надо выбрасывать, иначе приложение будет звать само себя каждые
    /// десять минут.
    public static func isOurProbe(cwd: String) -> Bool {
        cwd.contains("/LimitNotifier/probe")
    }

    /// Разбирает то, что записал хук: по строке на событие, каждая строка это
    /// JSON от Claude Code. Битые строки молча пропускаем, файл пишет не наш код.
    public static func parse(_ text: String, now: Date = Date()) -> [ReadyEvent] {
        var out: [ReadyEvent] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let cwd = json["cwd"] as? String, !cwd.isEmpty,
                  !isOurProbe(cwd: cwd)
            else { continue }
            let session = json["session_id"] as? String ?? ""
            let transcript = json["transcript_path"] as? String ?? ""
            let at = (json["at"] as? Double).map { Date(timeIntervalSince1970: $0) } ?? now
            out.append(ReadyEvent(cwd: cwd, sessionId: session, transcript: transcript, at: at))
        }
        return out
    }

    /// Читает новые события и опустошает файл: обработанное нам больше не нужно,
    /// а расти без предела он не должен.
    public static func drain(at url: URL? = nil, now: Date = Date()) -> [ReadyEvent] {
        let path = url ?? defaultURL
        guard let text = try? String(contentsOf: path, encoding: .utf8), !text.isEmpty else {
            return []
        }
        try? Data().write(to: path)
        return parse(text, now: now)
    }
}

/// Установка хука в настройки Claude Code.
///
/// Правим ~/.claude/settings.json, потому что хуки живут там и работают
/// одинаково для CLI и для расширения VS Code: под капотом это один бинарь.
/// Чужие настройки и чужие хуки не трогаем, свой узнаём по пути к скрипту.
public enum HookInstaller {
    public static var settingsURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/settings.json")
    }

    public static var scriptURL: URL {
        ReadyLog.directory.appendingPathComponent("on-stop.sh")
    }

    /// Где скрипт лежал до того, как выяснилось, что пробел в пути ломает хук.
    /// Нужен, чтобы вычистить нерабочий хук у тех, кто успел его поставить.
    static var legacyScriptPath: String {
        NSHomeDirectory() + "/Library/Application Support/LimitNotifier/on-stop.sh"
    }

    /// Событие одно: Stop приходит, когда Claude закончил ответ и ждёт человека.
    /// Это покрывает и "задача готова", и "нужен твой ответ". SubagentStop не
    /// берём: субагентов в одной задаче десятки.
    static let event = "Stop"

    /// Скрипт, который дописывает событие хука в наш файл. Пишем именно скрипт,
    /// а не зовём приложение: хук должен отработать мгновенно и не зависеть от
    /// того, запущено ли приложение прямо сейчас.
    public static func script(logPath: String) -> String {
        """
        #!/bin/bash
        # Создан LimitNotifier. Дописывает событие хука Claude Code в свой файл.
        # Ничего не блокирует и всегда выходит с нулём.
        payload=$(cat)
        dir=$(dirname "\(logPath)")
        mkdir -p "$dir"
        printf '%s\\n' "$payload" >> "\(logPath)"
        exit 0
        """
    }

    /// Вписывает наш хук, сохраняя всё остальное. Возвращает готовый json.
    static func settings(byInstallingInto current: [String: Any],
                         command: String) -> [String: Any] {
        var root = current
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        var groups = hooks[event] as? [[String: Any]] ?? []

        // Свой хук не дублируем: если уже стоит, оставляем как есть.
        let ours = ["type": "command", "command": command]
        let alreadyThere = groups.contains { group in
            (group["hooks"] as? [[String: Any]] ?? []).contains {
                ($0["command"] as? String) == command
            }
        }
        if !alreadyThere {
            groups.append(["hooks": [ours]])
        }
        hooks[event] = groups
        root["hooks"] = hooks
        return root
    }

    /// Убирает только свой хук. Пустые группы и пустой раздел подчищаем, чтобы
    /// не оставлять мусор в чужом файле.
    static func settings(byRemovingFrom current: [String: Any],
                         command: String) -> [String: Any] {
        var root = current
        guard var hooks = root["hooks"] as? [String: Any],
              let groups = hooks[event] as? [[String: Any]] else { return root }

        let cleaned: [[String: Any]] = groups.compactMap { group in
            let handlers = (group["hooks"] as? [[String: Any]] ?? []).filter {
                ($0["command"] as? String) != command
            }
            if handlers.isEmpty { return nil }
            var copy = group
            copy["hooks"] = handlers
            return copy
        }
        if cleaned.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = cleaned }
        if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        return root
    }

    static func installed(in current: [String: Any], command: String) -> Bool {
        let groups = (current["hooks"] as? [String: Any])?[event] as? [[String: Any]] ?? []
        return groups.contains { group in
            (group["hooks"] as? [[String: Any]] ?? []).contains {
                ($0["command"] as? String) == command
            }
        }
    }

    // MARK: - Работа с диском

    public static var isInstalled: Bool {
        guard let root = readSettings() else { return false }
        return installed(in: root, command: scriptURL.path)
    }

    /// Ставит скрипт и хук. Возвращает текст ошибки, если что-то не вышло.
    public static func install() -> String? {
        do {
            try FileManager.default.createDirectory(
                at: scriptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try script(logPath: ReadyLog.defaultURL.path)
                .write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                  ofItemAtPath: scriptURL.path)
            var root = readSettings() ?? [:]
            // Сначала убираем прежний, нерабочий путь с пробелами.
            root = settings(byRemovingFrom: root, command: legacyScriptPath)
            try writeSettings(settings(byInstallingInto: root, command: scriptURL.path))
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    public static func remove() -> String? {
        guard let root = readSettings() else { return nil }
        do {
            var next = settings(byRemovingFrom: root, command: scriptURL.path)
            next = settings(byRemovingFrom: next, command: legacyScriptPath)
            try writeSettings(next)
            try? FileManager.default.removeItem(at: scriptURL)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    static func readSettings() -> [String: Any]? {
        guard let data = try? Data(contentsOf: settingsURL),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        return root
    }

    static func writeSettings(_ root: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: root,
                                              options: [.prettyPrinted, .sortedKeys,
                                                        .withoutEscapingSlashes])
        try FileManager.default.createDirectory(
            at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: settingsURL, options: .atomic)
    }
}


/// Ожидание тишины перед тем, как звать.
///
/// Событие Stop приходит в конце каждого ответа, а не в конце задачи: если
/// claude разбудила фоновая задача или человек написал что-то посреди работы,
/// ответ делится на несколько, и Stop приходит несколько раз. Звать на каждый
/// такой Stop бессмысленно, строка меню начинает дёргаться.
///
/// Поэтому ждём тишины: если после события транскрипт сессии снова изменился,
/// значит работа продолжилась, и звать не о чем.
public enum Quiet {
    /// Сколько тишины считаем достаточной.
    ///
    /// Восемь секунд, а не полминуты. Задержка нужна только чтобы транскрипт
    /// успел показать, что работа продолжилась, а это видно почти сразу. Долгое
    /// ожидание вредно: за него человек успевает вернуться к окну, и проверка
    /// фокуса решает, что звать не надо, хотя в момент окончания он был не тут.
    public static let delay: TimeInterval = 8

    public enum Verdict: Sendable, Equatable {
        /// Работа продолжилась, событие устарело.
        case resumed
        /// Тишины пока мало, ждём дальше.
        case waiting
        /// Пора звать.
        case call
    }

    /// Решение по одному ожидающему событию.
    /// - transcriptChangedAt: время последней записи в транскрипт, если он есть.
    public static func verdict(event: ReadyEvent, now: Date,
                               transcriptChangedAt: Date?,
                               delay: TimeInterval = delay) -> Verdict {
        // Секунда запаса: сам Stop тоже попадает в транскрипт, и его запись
        // почти всегда чуть позже времени события.
        if let changed = transcriptChangedAt, changed > event.at.addingTimeInterval(1) {
            return .resumed
        }
        return now.timeIntervalSince(event.at) >= delay ? .call : .waiting
    }
}
