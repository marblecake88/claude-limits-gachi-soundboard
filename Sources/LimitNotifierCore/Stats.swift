import Foundation

/// Статистика использования, посчитанная по локальным транскриптам.
///
/// Считаем input+output и НЕ считаем кэш: именно так считает сам Claude Code на
/// вкладке Stats. Проверено сверкой на моей машине: 35.9m против 37.4m у него,
/// доли моделей совпали до десятых. С кэшем цифра была бы в 170 раз больше и
/// ни с чем не сходилась бы.
///
/// Данные только с этой машины. Claude про свою вкладку честно пишет то же
/// самое: другие устройства и claude.ai сюда не попадают.
public struct UsageStats: Sendable, Equatable {
    /// Токены по дню: "2026-07-24" -> ["Opus 4.8": 12345]
    public let days: [String: [String: Int]]
    /// Токены по часу сегодняшнего дня: "21" -> ["Opus 5": 999]
    public let hours: [String: [String: Int]]
    /// Сообщений в день, для подписи к рекордному дню.
    public let requests: [String: Int]
    /// Сессий. Из кэша claude, поэтому совпадает с его вкладкой Stats;
    /// при запасном скане это число транскриптов с работой.
    public let transcripts: Int
    /// Полный объём за всё время, включая чтение и запись кэша.
    ///
    /// Дневные цифры этого не включают: и claude в своей вкладке Stats, и наш
    /// график считают только input+output. Разница огромная, на моей машине
    /// 8.0b против 36.9m, потому что 99.5% объёма это чтение кэша. Показываем
    /// отдельной строкой, чтоб не было ощущения, что счётчик врёт.
    public let lifetimeTokens: Int
    /// Дата, до которой (включительно) кэш claude достоверен. Дни после неё
    /// берём из транскриптов: кэш пересчитывается раз в сутки.
    public let cacheUpTo: String?
    /// Во сколько обошёлся бы весь объём по тарифам API, по моделям.
    ///
    /// Считается из тех же полей кэша, что и полный объём, то есть с кэшевыми
    /// токенами. Это важно: чтение кэша стоит десятую часть входа, но его в
    /// сотни раз больше, и без него сумма занижена в разы.
    public let lifetimeCost: [String: Double]
    public let bestStreak: Int
    public let currentStreak: Int
    public let scannedAt: Date

    public init(days: [String: [String: Int]], hours: [String: [String: Int]],
                requests: [String: Int], transcripts: Int,
                bestStreak: Int, currentStreak: Int, scannedAt: Date,
                lifetimeTokens: Int = 0, cacheUpTo: String? = nil,
                lifetimeCost: [String: Double] = [:]) {
        self.lifetimeTokens = lifetimeTokens
        self.cacheUpTo = cacheUpTo
        self.lifetimeCost = lifetimeCost
        self.days = days
        self.hours = hours
        self.requests = requests
        self.transcripts = transcripts
        self.bestStreak = bestStreak
        self.currentStreak = currentStreak
        self.scannedAt = scannedAt
    }

    public static let empty = UsageStats(days: [:], hours: [:], requests: [:], transcripts: 0,
                                         bestStreak: 0, currentStreak: 0,
                                         scannedAt: Date(timeIntervalSince1970: 0),
                                         lifetimeTokens: 0, cacheUpTo: nil, lifetimeCost: [:])

    public var isEmpty: Bool { days.isEmpty }
    /// Сумма по всем моделям, за которые есть тариф.
    public var lifetimeCostTotal: Double { lifetimeCost.values.reduce(0, +) }
    public var sortedDays: [String] { days.keys.sorted() }
    public var activeDays: Int { days.count }

    public func total(of day: String) -> Int {
        (days[day] ?? [:]).values.reduce(0, +)
    }

    /// День с наибольшим расходом. Нужен для строки "рекорд за день".
    public var busiestDay: String? {
        days.keys.max { total(of: $0) < total(of: $1) }
    }
}

// MARK: - Периоды

public enum StatsPeriod: String, CaseIterable, Sendable {
    case today, week, month, all

    public var title: String {
        switch self {
        case .today: return L.s("СЕГОДНЯ", "TODAY")
        case .week:  return L.s("НЕДЕЛЯ", "WEEK")
        case .month: return L.s("МЕСЯЦ", "MONTH")
        case .all:   return L.s("ВСЁ", "ALL")
        }
    }
}

/// Колонка графика: сегодня это час, иначе день или неделя.
public struct StatsColumn: Sendable, Equatable {
    public let id: String
    /// Подпись под осью.
    public let tick: String
    public let parts: [String: Int]

    public init(id: String, tick: String, parts: [String: Int]) {
        self.id = id
        self.tick = tick
        self.parts = parts
    }

    public var total: Int { parts.values.reduce(0, +) }
}

public struct StatsSlice: Sendable, Equatable {
    public let columns: [StatsColumn]
    /// Модели по убыванию расхода за выбранный период.
    public let models: [String]
    public let modelTotals: [String: Int]
    public let total: Int
    public let dayCount: Int
    /// Заголовок над графиком: по часам, по дням или по неделям.
    public let title: String
}

public enum StatsSlicer {
    /// Больше этого числа столбиков в 430 точках ширины уже не читается,
    /// поэтому длинные периоды сворачиваем в недели.
    static let maxColumns = 60

    public static func slice(_ stats: UsageStats, period: StatsPeriod,
                             now: Date = Date(), calendar: Calendar = .current) -> StatsSlice {
        let columns = buildColumns(stats, period: period, now: now, calendar: calendar)
        var totals: [String: Int] = [:]
        for column in columns {
            for (model, value) in column.parts { totals[model, default: 0] += value }
        }
        let models = totals.keys.sorted { (totals[$0] ?? 0) > (totals[$1] ?? 0) }
        let dayCount = period == .today ? 1 : days(stats, period: period, now: now, calendar: calendar).count
        return StatsSlice(columns: columns, models: models, modelTotals: totals,
                          total: totals.values.reduce(0, +), dayCount: dayCount,
                          title: title(period: period, columns: columns))
    }

    private static func title(period: StatsPeriod, columns: [StatsColumn]) -> String {
        if period == .today { return L.s("ТОКЕНЫ ПО ЧАСАМ", "TOKENS PER HOUR") }
        // Признак свёртки: id колонки это понедельник недели, а не подряд идущие дни.
        if columns.count > 1, period == .all, columns.count <= maxColumns,
           isWeekly(columns) { return L.s("ТОКЕНЫ ПО НЕДЕЛЯМ", "TOKENS PER WEEK") }
        return L.s("ТОКЕНЫ ПО ДНЯМ", "TOKENS PER DAY")
    }

    private static func isWeekly(_ columns: [StatsColumn]) -> Bool {
        guard columns.count >= 2,
              let a = isoDate(columns[0].id), let b = isoDate(columns[1].id) else { return false }
        return b.timeIntervalSince(a) >= 6 * 86400
    }

    private static func days(_ stats: UsageStats, period: StatsPeriod,
                             now: Date, calendar: Calendar) -> [String] {
        let all = stats.sortedDays
        guard period != .all else { return all }
        let span = period == .week ? 7 : 30
        guard let from = calendar.date(byAdding: .day, value: -(span - 1),
                                       to: calendar.startOfDay(for: now)) else { return all }
        return all.filter { (isoDate($0) ?? .distantPast) >= from }
    }

    private static func buildColumns(_ stats: UsageStats, period: StatsPeriod,
                                     now: Date, calendar: Calendar) -> [StatsColumn] {
        if period == .today {
            return stats.hours.keys.sorted().map {
                // "21:00" читается как время, голое "21" выглядит как число.
                StatsColumn(id: $0, tick: "\($0):00", parts: stats.hours[$0] ?? [:])
            }
        }
        let picked = days(stats, period: period, now: now, calendar: calendar)
        guard picked.count > maxColumns else {
            return picked.map {
                StatsColumn(id: $0, tick: String($0.dropFirst(5)), parts: stats.days[$0] ?? [:])
            }
        }
        // Сворачиваем в недели: ключ это понедельник.
        var buckets: [String: [String: Int]] = [:]
        for day in picked {
            guard let date = isoDate(day) else { continue }
            let weekday = (calendar.component(.weekday, from: date) + 5) % 7   // пн = 0
            guard let monday = calendar.date(byAdding: .day, value: -weekday, to: date) else { continue }
            let key = isoString(monday)
            for (model, value) in stats.days[day] ?? [:] {
                buckets[key, default: [:]][model, default: 0] += value
            }
        }
        return buckets.keys.sorted().map {
            StatsColumn(id: $0, tick: String($0.dropFirst(5)), parts: buckets[$0] ?? [:])
        }
    }

    static let isoFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    public static func isoDate(_ s: String) -> Date? { isoFormatter.date(from: s) }
    public static func isoString(_ d: Date) -> String { isoFormatter.string(from: d) }
}

// MARK: - Скан транскриптов

public enum StatsScanner {

    /// Кэш статистики, который ведёт сам Claude Code.
    public static var defaultCache: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/stats-cache.json")
    }

    /// Основной путь: готовые агрегаты из кэша claude плюс сегодняшний день
    /// из свежих транскриптов.
    ///
    /// Почему не считаем всё сами. Claude Code подчищает старые транскрипты, а
    /// свой кэш ведёт дальше: собственный скан показывал 33 активных дня там,
    /// где у claude их 44, остальные просто стёрты с диска. Плюс кэш это 12 КБ
    /// против 328 МБ транскриптов, читается мгновенно вместо двенадцати секунд.
    ///
    /// Формат кэша недокументированный, поэтому на любой неожиданности молча
    /// откатываемся на полный скан: он медленный, но работает всегда.
    public static func load(cache: URL? = nil, root: URL = CostScanner.defaultRoot,
                            now: Date = Date(), calendar: Calendar = .current) -> UsageStats {
        guard let cached = readCache(cache ?? defaultCache, now: now, calendar: calendar) else {
            return scan(root: root, now: now, calendar: calendar)
        }
        // Кэш пересчитывается раз в сутки, сегодняшнего дня в нём обычно нет.
        // Дочитываем только свежие файлы, это быстро.
        let fresh = scan(root: root, now: now, calendar: calendar,
                         changedSince: now.addingTimeInterval(-2 * 86400))
        return merge(cached, fresh: fresh, now: now, calendar: calendar)
    }

    /// Разбор ~/.claude/stats-cache.json. nil, если файла нет или формат чужой.
    static func readCache(_ url: URL, now: Date, calendar: Calendar) -> UsageStats? {
        guard let data = try? Data(contentsOf: url),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let daily = root["dailyModelTokens"] as? [[String: Any]], !daily.isEmpty
        else { return nil }

        var days: [String: [String: Int]] = [:]
        for entry in daily {
            guard let date = entry["date"] as? String,
                  let tokens = entry["tokensByModel"] as? [String: Any] else { continue }
            for (model, value) in tokens {
                days[date, default: [:]][shortName(model), default: 0] += CostScanner.int(value)
            }
        }
        guard !days.isEmpty else { return nil }

        // Запросов по дням в кэше нет, но есть сообщения: для подписи к
        // рекордному дню этого хватает, а выдумывать нечего.
        var requests: [String: Int] = [:]
        for entry in root["dailyActivity"] as? [[String: Any]] ?? [] {
            if let date = entry["date"] as? String {
                requests[date] = CostScanner.int(entry["messageCount"])
            }
        }

        // Полный объём: тут же в кэше лежат и кэшевые токены, по моделям за
        // всё время. По дням такой разбивки нет, поэтому только итог.
        var lifetime = 0
        var cost: [String: Double] = [:]
        for (model, usage) in root["modelUsage"] as? [String: Any] ?? [:] {
            guard let fields = usage as? [String: Any] else { continue }
            lifetime += CostScanner.int(fields["inputTokens"])
                + CostScanner.int(fields["outputTokens"])
                + CostScanner.int(fields["cacheReadInputTokens"])
                + CostScanner.int(fields["cacheCreationInputTokens"])

            // Поля кэша называются иначе, чем в транскриптах, поэтому
            // перекладываем их в тот вид, который понимает счётчик стоимости.
            guard let prices = Pricing.forModel(model) else { continue }
            let usageForPrice: [String: Any] = [
                "input_tokens": CostScanner.int(fields["inputTokens"]),
                "output_tokens": CostScanner.int(fields["outputTokens"]),
                "cache_read_input_tokens": CostScanner.int(fields["cacheReadInputTokens"]),
                "cache_creation_input_tokens": CostScanner.int(fields["cacheCreationInputTokens"]),
            ]
            cost[shortName(model)] = CostScanner.price(usage: usageForPrice, prices: prices)
        }

        let (best, current) = streaks(days.keys.sorted(), now: now, calendar: calendar)
        return UsageStats(days: days, hours: [:], requests: requests,
                          transcripts: CostScanner.int(root["totalSessions"]),
                          bestStreak: best, currentStreak: current, scannedAt: now,
                          lifetimeTokens: lifetime,
                          cacheUpTo: root["lastComputedDate"] as? String,
                          lifetimeCost: cost)
    }

    /// Свежий скан дополняет кэш днями, которых тот ещё не посчитал.
    ///
    /// Строго после cacheUpTo: свежий скан читает только недавно менявшиеся
    /// файлы, поэтому за уже посчитанный день он видит лишь часть работы и,
    /// затирая кэш, занижал бы цифру.
    static func merge(_ cached: UsageStats, fresh: UsageStats,
                      now: Date, calendar: Calendar) -> UsageStats {
        var days = cached.days
        var requests = cached.requests
        for (day, parts) in fresh.days {
            if let upTo = cached.cacheUpTo, day <= upTo { continue }
            days[day] = parts
            if let count = fresh.requests[day] { requests[day] = count }
        }
        let (best, current) = streaks(days.keys.sorted(), now: now, calendar: calendar)
        return UsageStats(days: days, hours: fresh.hours, requests: requests,
                          transcripts: max(cached.transcripts, fresh.transcripts),
                          bestStreak: best, currentStreak: current, scannedAt: now,
                          lifetimeTokens: cached.lifetimeTokens, cacheUpTo: cached.cacheUpTo,
                          lifetimeCost: cached.lifetimeCost)
    }

    /// Проход по транскриптам. Запасной путь и источник сегодняшних часов.
    /// С changedSince читает только недавно менявшиеся файлы.
    public static func scan(root: URL = CostScanner.defaultRoot, now: Date = Date(),
                            calendar: Calendar = .current,
                            changedSince: Date? = nil) -> UsageStats {
        var days: [String: [String: Int]] = [:]
        var hours: [String: [String: Int]] = [:]
        var requests: [String: Int] = [:]
        var transcripts = 0

        let today = StatsScanner.dayKey(now, calendar: calendar)
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: root,
                                         includingPropertiesForKeys: [.contentModificationDateKey],
                                         options: [.skipsHiddenFiles]) else {
            return .empty
        }

        for case let url as URL in walker {
            guard url.pathExtension == "jsonl" else { continue }
            if let changedSince {
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate
                if let modified, modified < changedSince { continue }
            }
            var used = false
            CostScanner.forEachLine(of: url) { line in
                guard line.contains("\"usage\"") else { return }
                guard let data = line.data(using: .utf8),
                      let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let message = root["message"] as? [String: Any],
                      let usage = message["usage"] as? [String: Any],
                      let model = message["model"] as? String,
                      !model.hasPrefix("<"),
                      let stamp = root["timestamp"] as? String,
                      let at = CostScanner.iso(stamp)
                else { return }

                // Без кэша: так считает вкладка Stats в самом claude.
                let tokens = CostScanner.int(usage["input_tokens"])
                    + CostScanner.int(usage["output_tokens"])
                guard tokens > 0 else { return }

                let short = shortName(model)
                let day = dayKey(at, calendar: calendar)
                days[day, default: [:]][short, default: 0] += tokens
                requests[day, default: 0] += 1
                if day == today {
                    hours[hourKey(at, calendar: calendar), default: [:]][short, default: 0] += tokens
                }
                used = true
            }
            if used { transcripts += 1 }
        }

        let (best, current) = streaks(days.keys.sorted(), now: now, calendar: calendar)
        return UsageStats(days: days, hours: hours, requests: requests, transcripts: transcripts,
                          bestStreak: best, currentStreak: current, scannedAt: now)
    }

    /// Подряд идущие активные дни. Текущий стрик обнуляем, если последний
    /// активный день был раньше вчера: иначе он висел бы вечно.
    static func streaks(_ sortedDays: [String], now: Date,
                        calendar: Calendar = .current) -> (best: Int, current: Int) {
        var best = 0, run = 0
        var previous: Date?
        for day in sortedDays {
            guard let date = StatsSlicer.isoDate(day) else { continue }
            if let previous, calendar.dateComponents([.day], from: previous, to: date).day == 1 {
                run += 1
            } else {
                run = 1
            }
            best = max(best, run)
            previous = date
        }
        guard let last = previous else { return (0, 0) }
        let sinceLast = calendar.dateComponents([.day], from: last,
                                                to: calendar.startOfDay(for: now)).day ?? 0
        return (best, sinceLast > 1 ? 0 : run)
    }

    /// "claude-opus-4-8" -> "Opus 4.8". Даты и суффиксы в id только мешают.
    static func shortName(_ id: String) -> String {
        var s = id
        if s.hasPrefix("claude-") { s.removeFirst("claude-".count) }
        // Отрезаем хвост даты вида -20251001 и пометку контекста [1m].
        if let r = s.range(of: "-20[0-9]{6}", options: .regularExpression) { s = String(s[..<r.lowerBound]) }
        if let r = s.range(of: "[", options: .literal) { s = String(s[..<r.lowerBound]) }
        let parts = s.split(separator: "-").map(String.init)
        guard let family = parts.first else { return s }
        let version = parts.dropFirst().joined(separator: ".")
        return version.isEmpty ? family.capitalized : "\(family.capitalized) \(version)"
    }

    static func dayKey(_ date: Date, calendar: Calendar) -> String {
        StatsSlicer.isoString(calendar.startOfDay(for: date))
    }

    static func hourKey(_ date: Date, calendar: Calendar) -> String {
        String(format: "%02d", calendar.component(.hour, from: date))
    }
}
