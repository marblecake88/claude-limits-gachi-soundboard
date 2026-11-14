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
            if Self.looksLoggedOut(text) {
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
                // прошлые цифры. В нагрузку кладём выжимку вывода: на чужой
                // машине причина видна только так.
                throw UsageError.noLimits(Self.snippet(text))
            }
            return snapshot
        }
    }

    /// Признаки того, что Claude Code не залогинен в этом окружении. Одного
    /// "not logged in" мало: у разных версий формулировки разные, а тихий
    /// logged out иначе улетает в "показываю прошлые" и путает пользователя.
    static func looksLoggedOut(_ text: String) -> Bool {
        let t = text.lowercased()
        return ["not logged in", "please log in", "please run /login",
                "run `claude login`", "invalid api key"].contains { t.contains($0) }
    }

    /// Однострочная выжимка вывода claude для лога: строки склеены, лишние
    /// пробелы убраны, длина ограничена, чтобы не тащить в лог весь ответ.
    static func snippet(_ text: String, limit: Int = 200) -> String {
        let flat = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
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

            let (kind, label) = classify(title)
            rows.append(LimitRow(
                id: kind == "weekly_scoped" ? "\(kind):\(label)" : kind,
                kind: kind,
                label: label,
                percent: percent,
                severity: .unknown,
                resetsAt: resetDate(in: tail, now: now),
                group: kind == "session" ? "session" : "weekly"
            ))
        }

        guard !rows.isEmpty else { return nil }
        return UsageSnapshot(rows: rows, fetchedAt: now, insights: UsageInsights.parse(text))
    }

    /// "Current session" -> 5h, "Current week (all models)" -> Weekly,
    /// "Current week (Fable)" -> Fable weekly.
    private static func classify(_ title: String) -> (kind: String, label: String) {
        let lower = title.lowercased()
        if lower.contains("session") { return ("session", "5h") }
        guard let open = title.firstIndex(of: "("), let close = title.lastIndex(of: ")"),
              open < close else {
            return ("weekly_all", "Weekly")
        }
        let scope = String(title[title.index(after: open)..<close])
        if scope.lowercased().contains("all models") { return ("weekly_all", "Weekly") }
        return ("weekly_scoped", "\(scope) weekly")
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

// MARK: - Что съедает лимит

/// Раздел "What's contributing to your limits usage?" из того же вывода /usage.
///
/// Появился осенью 2026. Claude сам пишет, что цифры примерные и только по
/// сессиям этой машины, а поведения независимые, это не разбивка на части:
/// 77% с большим контекстом и 41% с субагентами могут пересекаться.
///
/// Приходит в том же ответе, что и лимиты, так что отдельных запросов не стоит.
public struct UsageInsights: Sendable, Equatable {
    public struct Window: Sendable, Equatable {
        /// Как пишет claude: "Last 24h", "Last 7d".
        public let title: String
        public let requests: Int
        public let sessions: Int
        public let behaviors: [Behavior]
        public let subagents: [Subagent]
    }

    /// "77% of your usage was at >150k context" -> 77, "was at >150k context".
    public struct Behavior: Sendable, Equatable {
        public let percent: Int
        public let text: String

        /// Короткая подпись. Известные формулировки переводим, незнакомые
        /// показываем как есть, только без служебного начала фразы.
        public var label: String {
            let lower = text.lowercased()
            if let range = lower.range(of: ">"), lower.contains("context") {
                let size = lower[range.upperBound...].prefix { $0.isNumber || $0 == "k" || $0 == "m" }
                if !size.isEmpty { return L.s("контекст больше \(size)", "context over \(size)") }
            }
            if lower.contains("subagent-heavy") {
                return L.s("сессии с субагентами", "subagent-heavy sessions")
            }
            for lead in ["was at ", "came from ", "was in ", "was ", "came "] where lower.hasPrefix(lead) {
                return String(text.dropFirst(lead.count))
            }
            return text
        }
    }

    public struct Subagent: Sendable, Equatable {
        public let name: String
        public let percent: Int
    }

    public let windows: [Window]

    /// nil, если раздела в выводе нет: на старых версиях claude его не было.
    public static func parse(_ text: String) -> UsageInsights? {
        var windows: [Window] = []
        var title = "", requests = 0, sessions = 0
        var behaviors: [Behavior] = [], subagents: [Subagent] = []
        var open = false

        func close() {
            guard open else { return }
            windows.append(Window(title: title, requests: requests, sessions: sessions,
                                  behaviors: behaviors, subagents: subagents))
            behaviors = []; subagents = []
        }

        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespaces)

            // Заголовок окна: "Last 24h · 276 requests · 4 sessions".
            if line.hasPrefix("Last ") {
                let parts = line.split(separator: "·").map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count >= 3 else { continue }
                close()
                title = parts[0]
                requests = leadingNumber(parts[1])
                sessions = leadingNumber(parts[2])
                open = true
                continue
            }
            guard open else { continue }

            if let mark = line.range(of: "% of your usage ") {
                let number = line[..<mark.lowerBound]
                if let percent = Int(number) {
                    behaviors.append(Behavior(percent: percent,
                                              text: String(line[mark.upperBound...])))
                }
                continue
            }

            // "Top subagents: workflow-subagent 30%, Explore 12%".
            if line.lowercased().hasPrefix("top subagent"), let colon = line.firstIndex(of: ":") {
                for item in line[line.index(after: colon)...].split(separator: ",") {
                    let words = item.trimmingCharacters(in: .whitespaces).split(separator: " ")
                    guard words.count >= 2, let last = words.last, last.hasSuffix("%"),
                          let percent = Int(last.dropLast()) else { continue }
                    subagents.append(Subagent(name: words.dropLast().joined(separator: " "),
                                              percent: percent))
                }
            }
        }
        close()
        return windows.isEmpty ? nil : UsageInsights(windows: windows)
    }

    /// "1,258 requests" -> 1258.
    private static func leadingNumber(_ text: String) -> Int {
        Int(text.prefix { $0.isNumber || $0 == "," }.replacingOccurrences(of: ",", with: "")) ?? 0
    }
}
