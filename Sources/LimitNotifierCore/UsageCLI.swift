import Foundation

/// Читает лимиты через официальный CLI: `claude -p "/usage"`.
///
/// Почему не HTTP напрямую, как было раньше. Прошлая версия доставала OAuth
/// токен подписки из связки ключей и ходила с ним в api.anthropic.com. Это
/// ровно то, что Anthropic запрещает в разделе "Authentication and credential
/// use": сторонним приложениям нельзя гонять запросы через креденшелы Pro/Max
/// от имени пользователя. Плюс каждый пользователь получал системный диалог
/// доступа к чужому итему связки.
///
/// Здесь запрос делает сам Claude Code, своим законным способом и со своим
/// собственным итемом, к которому у него доступ по определению. Ни диалога,
/// ни нарушения. Токенов при этом тратится ноль: num_turns 0, cost 0.
public struct UsageClient {
    private let claudePath: String?
    private let probeDir: URL

    public init(claudePath: String? = nil, probeDir: URL? = nil) {
        self.claudePath = claudePath
        self.probeDir = probeDir ?? Self.defaultProbeDir
    }

    /// Отдельный каталог для опроса, чтобы транскрипты запусков не смешивались
    /// с рабочими проектами и их можно было спокойно подчищать.
    public static var defaultProbeDir: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/LimitNotifier/probe")
    }

    public func fetch(now: Date = Date()) throws -> UsageSnapshot {
        guard let claude = claudePath ?? Proc.findClaude() else {
            throw UsageError.claudeNotFound
        }
        try? FileManager.default.createDirectory(at: probeDir, withIntermediateDirectories: true)

        // Свежий id на каждый запуск обязателен: при повторном использовании
        // того же --session-id команда отдаёт пустоту. Проверено.
        let session = UUID().uuidString.lowercased()
        defer { removeTranscript(session: session) }

        let result = Proc.run(claude,
                              ["-p", "/usage", "--session-id", session],
                              timeout: 45, cwd: probeDir)

        switch result {
        case .launchFailed(let m): throw UsageError.launchFailed(m)
        case .timedOut: throw UsageError.timedOut
        case .finished(let status, let out, let err):
            let text = out + "\n" + err
            if text.localizedCaseInsensitiveContains("not logged in") {
                throw UsageError.notLoggedIn
            }
            guard status == 0 else {
                let detail = err.trimmingCharacters(in: .whitespacesAndNewlines)
                throw UsageError.launchFailed(detail.isEmpty ? "код \(status)" : detail)
            }
            guard let snapshot = Self.parse(out, now: now) else {
                // Команда отработала успешно, а процентов в выводе нет.
                // Так выглядит превышение частоты опроса, отвалившаяся сеть и
                // аккаунт без подписки. Различить их по выводу нельзя, поэтому
                // это отдельное состояние, а не успех и не поломка: показываем
                // прошлые цифры и честно пишем, когда они получены.
                throw UsageError.noLimits
            }
            return snapshot
        }
    }

    /// Удаляет транскрипт, созданный нашим же запуском.
    ///
    /// Каждый вызов оставляет файл примерно на 12 КБ, при опросе раз в десять
    /// минут это сотни мегабайт в год. Трогаем строго свой файл, найденный по
    /// собственному session id, чужого не касаемся.
    private func removeTranscript(session: String) {
        let root = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/projects")
        guard let dirs = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil) else { return }
        for dir in dirs {
            let file = dir.appendingPathComponent("\(session).jsonl")
            if FileManager.default.fileExists(atPath: file.path) {
                try? FileManager.default.removeItem(at: file)
                return
            }
        }
    }

    // MARK: - Разбор вывода

    /// Вывод команды выглядит так:
    ///
    ///     Current session: 26% used · resets Jul 22 at 10:10pm (Europe/Riga)
    ///     Current week (all models): 83% used · resets Jul 24 at 9pm (Europe/Riga)
    ///     Current week (Fable): 88% used · resets Jul 24 at 9pm (Europe/Riga)
    ///
    /// Формат текстовый и недокументированный, поэтому парсер намеренно
    /// нестрогий: незнакомая строка просто пропускается, а не роняет разбор.
    /// Возвращает nil, если не нашлось ни одной строки с процентами.
    public static func parse(_ text: String, now: Date = Date()) -> UsageSnapshot? {
        var rows: [LimitRow] = []

        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let colon = line.firstIndex(of: ":") else { continue }
            let title = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            let tail = String(line[line.index(after: colon)...])

            guard title.lowercased().hasPrefix("current"),
                  let percent = percent(in: tail) else { continue }

            let (kind, label, isSession) = classify(title)
            rows.append(LimitRow(
                id: kind == "weekly_scoped" ? "\(kind):\(label)" : kind,
                kind: kind,
                label: label,
                percent: percent,
                severity: .unknown,
                resetsAt: resetDate(in: tail, now: now),
                group: isSession ? "session" : "weekly",
                isSession: isSession
            ))
        }

        guard !rows.isEmpty else { return nil }
        let session = rows.first(where: \.isSession)
        // Окно считаем идущим, если сброс ещё впереди.
        let active = session?.resetsAt.map { $0 > now } ?? false
        return UsageSnapshot(rows: rows, fetchedAt: now, sessionWindowActive: active)
    }

    /// "Current session" -> 5h, "Current week (all models)" -> Weekly,
    /// "Current week (Fable)" -> Fable weekly.
    private static func classify(_ title: String) -> (kind: String, label: String, isSession: Bool) {
        let lower = title.lowercased()
        if lower.contains("session") { return ("session", "5h", true) }
        guard let open = title.firstIndex(of: "("), let close = title.lastIndex(of: ")"),
              open < close else {
            return ("weekly_all", "Weekly", false)
        }
        let scope = String(title[title.index(after: open)..<close])
        if scope.lowercased().contains("all models") { return ("weekly_all", "Weekly", false) }
        return ("weekly_scoped", "\(scope) weekly", false)
    }

    private static func percent(in tail: String) -> Int? {
        guard let range = tail.range(of: #"\d+(\.\d+)?%"#, options: .regularExpression) else {
            return nil
        }
        let value = Double(tail[range].dropLast()) ?? 0
        return min(max(Int(value.rounded()), 0), 100)
    }

    /// Разбирает "resets Jul 22 at 10:10pm (Europe/Riga)".
    ///
    /// Года в выводе нет, поэтому подбираем тот, при котором дата попадает в
    /// разумное окно вокруг текущего момента: сброс всегда впереди, но под
    /// новый год прошлогодняя подстановка дала бы дату далеко в прошлом.
    static func resetDate(in tail: String, now: Date) -> Date? {
        guard let r = tail.range(of: #"resets\s+(.+?)\s*(\(([^)]+)\))?$"#,
                                 options: .regularExpression) else { return nil }
        var body = String(tail[r]).replacingOccurrences(of: "resets", with: "")
            .trimmingCharacters(in: .whitespaces)

        var zone = TimeZone.current
        if let open = body.lastIndex(of: "("), let close = body.lastIndex(of: ")"), open < close {
            let name = String(body[body.index(after: open)..<close])
            if let z = TimeZone(identifier: name) { zone = z }
            body = String(body[body.startIndex..<open]).trimmingCharacters(in: .whitespaces)
        }
        // "Jul 22 at 10:10pm" -> "Jul 22 10:10pm"
        body = body.replacingOccurrences(of: " at ", with: " ")

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let year = calendar.component(.year, from: now)

        for candidate in [year, year + 1, year - 1] {
            for format in ["MMM d h:mma", "MMM d ha", "MMM d HH:mm"] {
                let f = DateFormatter()
                f.locale = Locale(identifier: "en_US_POSIX")
                f.timeZone = zone
                f.dateFormat = "yyyy " + format
                guard let date = f.date(from: "\(candidate) \(body)") else { continue }
                // Сброс не бывает сильно в прошлом и не бывает через год.
                let delta = date.timeIntervalSince(now)
                if delta > -86_400 * 2 && delta < 86_400 * 60 { return date }
            }
        }
        return nil
    }
}
