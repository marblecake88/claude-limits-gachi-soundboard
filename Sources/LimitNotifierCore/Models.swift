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

    public init(id: String, kind: String = "", label: String, percent: Int, severity: Severity,
                resetsAt: Date?, group: String) {
        self.id = id
        self.kind = kind
        self.label = label
        self.percent = percent
        self.severity = severity
        self.resetsAt = resetsAt
        self.group = group
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

/// Снимок лимитов.
///
/// Пятичасового окна с 1 ноября 2026 нет: /usage отдаёт только недельные, общий
/// и скоупные по моделям. Если оно однажды вернётся, ряд просто появится в
/// панели ещё одним гейджем, ряды целиком задаёт сервер.
public struct UsageSnapshot: Sendable, Equatable {
    public let rows: [LimitRow]
    public let fetchedAt: Date
    /// Что съедает лимит, по словам самого claude. Приходит в том же ответе.
    public let insights: UsageInsights?

    public init(rows: [LimitRow], fetchedAt: Date, insights: UsageInsights? = nil) {
        self.rows = rows
        self.fetchedAt = fetchedAt
        self.insights = insights
    }

    /// Общий недельный лимит, по всем моделям. Именно он стоит в строке меню,
    /// скоупные видно в панели. Если общего почему-то нет, берём первый.
    public var main: LimitRow? {
        rows.first { $0.kind == "weekly_all" } ?? rows.first
    }
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
    /// В нагрузке однострочная выжимка вывода claude для лога: без доступа к
    /// чужой машине это единственный способ понять, что реально вернул CLI.
    case noLimits(String)
    case timedOut
    case launchFailed(String)

    /// Короткая подсказка для панели. Одна строка, без паники.
    public var hint: String {
        switch self {
        case .claudeNotFound:
            return L.s("Не нашёл claude. Установи Claude Code.",
                       "Can't find claude. Install Claude Code.")
        case .notLoggedIn:
            return L.s("Claude Code не залогинен. Запусти claude и войди.",
                       "Claude Code is logged out. Run claude and sign in.")
        case .noLimits:
            return L.s("Claude не отдаёт лимиты, похоже режет частоту. Показываю прошлые цифры и жду.",
                       "Claude isn't returning limits, looks rate limited. Showing the last numbers.")
        case .timedOut:
            return L.s("claude не ответил вовремя.", "claude didn't answer in time.")
        case .launchFailed(let m):
            return L.s("Не смог опросить claude. \(m)", "Couldn't ask claude. \(m)")
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

/// Куски статус-элемента вида 35/4d, каждый со своим цветом. Собирать строку
/// целиком тут нельзя: цвет накладывается уже во вьюхе.
public struct StatusParts: Sendable, Equatable {
    public let weekly: String
    /// Сколько осталось до сброса, крупно: "4d" или "11h". Минуты тут не
    /// нужны, на недельном горизонте они только шумят.
    public let weeklyTime: String
    public let weeklyLevel: Level

    public init(weekly: String, weeklyTime: String, weeklyLevel: Level) {
        self.weekly = weekly
        self.weeklyTime = weeklyTime
        self.weeklyLevel = weeklyLevel
    }
}

public enum StatusBar {
    /// Остаток крупными единицами: от суток и выше только дни, ниже только часы.
    /// Недельный лимит живёт днями, и минуты в строке меню там ни к чему.
    public static func coarse(_ date: Date?, from now: Date = Date()) -> String {
        guard let date else { return "--" }
        let s = Int(date.timeIntervalSince(now))
        if s <= 0 { return "--" }
        let d = s / 86400
        return d > 0 ? "\(d)d" : "\(s / 3600)h"
    }

    public static func parts(from snapshot: UsageSnapshot?, now: Date = Date()) -> StatusParts {
        let main = snapshot?.main
        return StatusParts(weekly: main.map { "\($0.percent)" } ?? "--",
                           weeklyTime: coarse(main?.resetsAt, from: now),
                           weeklyLevel: Level(percent: main?.percent ?? 0))
    }
}

// MARK: - Форматирование времени

public enum Fmt {
    /// "8.0b", "35.9m", "512k", "842". С кэшем счёт идёт на миллиарды, а
    /// "8021.0m" не читается, поэтому у миллиардов свой суффикс.
    public static func tokens(_ n: Int) -> String {
        if n >= 1_000_000_000 { return String(format: "%.1fb", Double(n) / 1_000_000_000) }
        if n >= 1_000_000 { return String(format: "%.1fm", Double(n) / 1_000_000) }
        if n >= 1_000 { return "\(Int((Double(n) / 1000).rounded()))k" }
        return "\(n)"
    }

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
        // Сюда приходит либо подсказка сервера, либо наш бэкофф из backoff().
        if let retryAfter { return max(retryAfter, minimum) }
        // Сеть лежит или токен протух: не долбим.
        if failureStreak >= 3 { return 900 }
        guard let snapshot else { return 300 }
        // Близко к лимиту, тут точность важнее экономии запросов. Смотрим на
        // самый горячий из рядов: скоупный по модели может упереться раньше.
        if (snapshot.rows.map(\.percent).max() ?? 0) >= 79 { return 120 }
        return 600
    }

    /// Пауза после того, как claude не отдал лимиты. Раньше этот случай не
    /// удлинял паузу вовсе, и приложение продолжало спрашивать раз в 2-10 минут.
    /// У пользователя, которому usage режут по частоте, это ограничение только
    /// поддерживало. Удваиваем от 7.5 минут до часа, при успехе сбрасывается.
    public static func backoff(previous: Int?) -> Int {
        min((previous ?? 450) * 2, 3600)
    }
}

// MARK: - Попап у края экрана

/// Куда поставить окно попапа, чтоб оно целиком влезло в экран.
///
/// Первая попытка двигала точку привязки (positioningRect), но AppKit
/// прижимает её к границам иконки и сдвиг в сотни точек просто игнорировал.
/// Поэтому двигаем само окно: стрелка перестаёт смотреть точно в иконку,
/// зато развёрнутая панель видна полностью.
public enum PopoverFit {
    /// Новая координата левого края окна. Если и так помещается, вернёт ту же.
    public static func fittedX(x: Double, width: Double,
                               screenMinX: Double, screenMaxX: Double,
                               margin: Double = 8) -> Double {
        // Окно шире экрана не подвинешь так, чтоб влезло целиком: тогда просто
        // прижимаем к левому краю, начало панели важнее хвоста.
        guard width <= (screenMaxX - screenMinX) - margin * 2 else { return screenMinX + margin }
        let maxX = screenMaxX - margin - width
        return min(max(x, screenMinX + margin), maxX)
    }
}

// MARK: - Вытеснение из строки меню

/// Считает промахи подряд, прежде чем признать элемент вытесненным.
///
/// Место в строке меню раздаёт система, и приложениям с длинным меню (JetBrains,
/// Xcode) её хватает целиком: наш элемент просто перестают рисовать. Проверять
/// это приходится опросом, а опрос попадает и в момент, когда строка ещё
/// перекладывается после смены активного приложения. Один промах там ничего не
/// значит, поэтому ждём подряд идущих.
public struct SqueezeWatch: Sendable {
    public let needed: Int
    private var misses = 0

    public init(needed: Int = 2) {
        precondition(needed > 0)
        self.needed = needed
    }

    /// Отдаёт true, когда элемент пора считать вытесненным. Одна удача сбрасывает
    /// счётчик: вернулось место, значит и плашка больше не нужна.
    public mutating func update(drawn: Bool) -> Bool {
        misses = drawn ? 0 : misses + 1
        return misses >= needed
    }
}

/// Нужна ли сейчас плавающая плашка.
/// Когда держать плавающую плашку.
public enum PlaqueMode: String, Sendable, CaseIterable {
    /// Никогда. Нужен затем, что определение вытеснения опирается на список
    /// окон системы, а он недокументирован: если он где-то соврёт, человек
    /// должен иметь возможность просто выключить, а не бороться с догадками.
    case off
    /// Только когда нас выкинули из строки меню. По умолчанию.
    case auto
    /// Всегда, в том числе в полном экране.
    case always
}

public enum PlaquePlan {
    /// Правило целиком, в одном месте.
    ///
    /// Главное тут третье условие. Строку меню бывает не видно вообще: полный
    /// экран, кино, автоскрытие. Тогда наш элемент тоже не нарисован, но это не
    /// вытеснение, а общая тишина, и вылезать поверх чужого кино незачем.
    ///
    /// Счётчик промахов передаётся замыканием намеренно: пока строки меню не
    /// видно, его нельзя трогать. Иначе полминуты в полном экране накрутят
    /// промахов, и на выходе плашка выскочит там, где места ей хватает.
    public static func wanted(mode: PlaqueMode, barShowing: Bool,
                              squeezed: () -> Bool) -> Bool {
        switch mode {
        case .off: return false
        case .always: return true
        case .auto:
            guard barShowing else { return false }
            return squeezed()
        }
    }
}
