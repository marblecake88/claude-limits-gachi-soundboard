import Foundation

/// Серьёзность лимита. Присылает сервер, свои пороги не выдумываем.
public enum Severity: String, Sendable, Equatable {
    case normal, warning, critical, unknown

    public init(api: String?) {
        switch api?.lowercased() {
        case "normal": self = .normal
        case "warning": self = .warning
        case "critical", "severe": self = .critical
        default: self = .unknown
        }
    }
}

/// Один ряд лимита. Строится из элемента массива `limits` в ответе API.
/// Именованные поля вроде `seven_day_opus` не используем: на разных аккаунтах
/// они null, а реально горящий лимит лежит в `limits` как weekly_scoped.
public struct LimitRow: Identifiable, Sendable, Equatable {
    public let id: String
    public let kind: String
    public let label: String
    public let percent: Int
    public let severity: Severity
    public let resetsAt: Date?
    public let group: String
    public let isSession: Bool

    public init(id: String, kind: String = "", label: String, percent: Int, severity: Severity,
                resetsAt: Date?, group: String, isSession: Bool) {
        self.id = id
        self.kind = kind
        self.label = label
        self.percent = percent
        self.severity = severity
        self.resetsAt = resetsAt
        self.group = group
        self.isSession = isSession
    }
}

/// Уровень тревоги по проценту. Пороги наши, а не серверные: severity от
/// сервера слишком грубая, у неё всего normal и warning.
public enum Level: String, Sendable, Equatable {
    case calm, yellow, pink, red

    public init(percent: Int) {
        switch percent {
        case ..<60: self = .calm
        case ..<79: self = .yellow
        case ..<89: self = .pink
        default:    self = .red
        }
    }
}

public struct UsageSnapshot: Sendable, Equatable {
    public let rows: [LimitRow]
    public let fetchedAt: Date
    /// Идёт ли прямо сейчас 5-часовое окно. Определяется наличием `five_hour`
    /// в ответе и тем, что его resets_at ещё не наступил.
    public let sessionWindowActive: Bool

    public init(rows: [LimitRow], fetchedAt: Date, sessionWindowActive: Bool) {
        self.rows = rows
        self.fetchedAt = fetchedAt
        self.sessionWindowActive = sessionWindowActive
    }

    public var session: LimitRow? { rows.first(where: \.isSession) }
    public var weekly: [LimitRow] { rows.filter { !$0.isSession } }
}

public enum UsageError: Error, Sendable, Equatable {
    /// Не нашли исполняемый claude.
    case claudeNotFound
    /// Claude Code отвечает, что не залогинен.
    case notLoggedIn
    /// Команда отработала успешно, но процентов в выводе нет.
    /// Так выглядит превышение частоты опроса, отвалившаяся сеть и аккаунт без
    /// подписки. Различить их по выводу нельзя, поэтому это отдельное
    /// состояние: показываем прошлые цифры и пишем, когда они получены.
    case noLimits
    case timedOut
    case launchFailed(String)

    /// Короткая подсказка для панели. Одна строка, без паники.
    public var hint: String {
        switch self {
        case .claudeNotFound:
            return "Не нашёл claude. Установи Claude Code."
        case .notLoggedIn:
            return "Claude Code не залогинен. Запусти claude и войди."
        case .noLimits:
            return "Лимиты сейчас не отдаются. Показываю прошлые цифры."
        case .timedOut:
            return "claude не ответил вовремя."
        case .launchFailed(let m):
            return "Не смог опросить claude. \(m)"
        }
    }

    /// Временные состояния не повод считать, что всё сломалось: показываем
    /// последний удачный снимок и молча ждём.
    public var isTransient: Bool {
        switch self {
        case .noLimits, .timedOut, .launchFailed: return true
        case .claudeNotFound, .notLoggedIn: return false
        }
    }
}

// MARK: - Отрисовка гейджа

public enum Gauge {
    /// Блочный гейдж фиксированной ширины. Ширина не должна плыть между
    /// значениями, иначе колонка в панели дёргается.
    /// Возвращает (заполненная часть, пустая часть).
    public static func bars(percent: Int, width: Int) -> (filled: String, empty: String) {
        precondition(width > 0, "ширина гейджа должна быть положительной")
        let clamped = min(max(percent, 0), 100)
        // Округляем к ближайшему, но не даём 0% показать блок, а 100% недобрать.
        var filled = Int((Double(clamped) / 100.0 * Double(width)).rounded())
        if clamped > 0 { filled = max(filled, 1) }
        if clamped < 100 { filled = min(filled, width - 1) }
        if clamped == 100 { filled = width }
        if clamped == 0 { filled = 0 }
        return (String(repeating: "█", count: filled),
                String(repeating: "█", count: width - filled))
    }

    /// Компактный вид для самой строки меню.
    public static func statusText(percent: Int?, width: Int = 6) -> String {
        guard let percent else { return "-- %" }
        let (f, e) = bars(percent: percent, width: width)
        return "\(f)\(e) \(percent)%"
    }
}

// MARK: - Строка меню

/// Куски статус-элемента вида 55/78/2h15, каждый со своей серьёзностью,
/// чтоб красить их по отдельности. Собирать строку целиком тут нельзя:
/// цвет накладывается уже во вьюхе.
public struct StatusParts: Sendable, Equatable {
    public let session: String
    public let weekly: String
    public let time: String
    public let sessionLevel: Level
    public let weeklyLevel: Level

    public init(session: String, weekly: String, time: String,
                sessionLevel: Level, weeklyLevel: Level) {
        self.session = session
        self.weekly = weekly
        self.time = time
        self.sessionLevel = sessionLevel
        self.weeklyLevel = weeklyLevel
    }
}

public enum StatusBar {
    /// Остаток времени в сжатом виде: "2h15" от часа и выше, "15m" ниже часа.
    /// Секунды не показываем, дёргающаяся строка в меню это раздражитель.
    public static func compact(_ date: Date?, from now: Date = Date()) -> String {
        guard let date else { return "--" }
        let s = Int(date.timeIntervalSince(now))
        if s <= 0 { return "--" }
        let h = s / 3600, m = (s % 3600) / 60
        return h > 0 ? String(format: "%dh%02d", h, m) : "\(m)m"
    }

    public static func parts(from snapshot: UsageSnapshot?, now: Date = Date()) -> StatusParts {
        guard let snapshot else {
            return StatusParts(session: "--", weekly: "--", time: "--",
                               sessionLevel: .calm, weeklyLevel: .calm)
        }
        let session = snapshot.session
        // Недельных лимитов бывает несколько: общий weekly_all и скоупные по
        // модели. В строку меню ставим именно общий, скоупные видно в панели.
        let weekly = snapshot.weekly.first { $0.kind == "weekly_all" }
            ?? snapshot.weekly.first

        return StatusParts(
            session: session.map { "\($0.percent)" } ?? "--",
            weekly: weekly.map { "\($0.percent)" } ?? "--",
            time: compact(snapshot.sessionWindowActive ? session?.resetsAt : nil, from: now),
            sessionLevel: Level(percent: session?.percent ?? 0),
            weeklyLevel: Level(percent: weekly?.percent ?? 0)
        )
    }
}

// MARK: - Форматирование времени

public enum Fmt {
    /// "1h 47m", "4d 6h", "12m". Для прошедшего времени возвращает "now".
    public static func until(_ date: Date, from now: Date = Date()) -> String {
        let s = Int(date.timeIntervalSince(now))
        if s <= 0 { return "now" }
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }
}

// MARK: - Частота опроса

/// Как часто дёргать сервер.
///
/// Смысл в том, чтоб спрашивать часто ровно тогда, когда цифра движется.
/// Окна нет, значит и меняться нечему, можно молчать. Окно горит и подходит
/// к лимиту, значит это как раз тот момент, ради которого всё и затевалось.
/// Плюс просьба сервера подождать всегда главнее наших расчётов.
public enum PollPlan {
    public static let minimum = 60

    public static func interval(snapshot: UsageSnapshot?,
                                failureStreak: Int,
                                retryAfter: Int? = nil) -> Int {
        // CLI не отдаёт Retry-After, но параметр оставлен: если данные снова
        // начнут приходить с подсказкой сервера, слушаться надо её.
        if let retryAfter { return max(retryAfter, minimum) }
        // Сеть лежит или токен протух: не долбим.
        if failureStreak >= 3 { return 900 }
        guard let snapshot else { return 300 }
        // Окна нет, проценты стоят на месте.
        guard snapshot.sessionWindowActive else { return 900 }
        // Близко к лимиту, тут точность важнее экономии запросов.
        if (snapshot.session?.percent ?? 0) >= 79 { return 120 }
        return 600
    }
}
