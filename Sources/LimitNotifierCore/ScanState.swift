import Foundation

/// Накопленный проход по транскриптам: что уже прочитано и что из этого вышло.
///
/// Транскрипты только дописываются, поэтому перечитывать их целиком незачем.
/// Помним по каждому файлу, сколько байт учтено, и в следующий раз читаем только
/// дописанное. На моей машине разница решающая: за сутки меняется 193 МБ в 89
/// файлах, и полный проход по ним это шестнадцать секунд, а дочитывание единицы
/// мегабайт и доли секунды. Без этого "статистика в прямом эфире" означала бы
/// перечитывать двести мегабайт каждые полминуты.
///
/// Копим итоги, а не файлы: удалённый claude'ом транскрипт остаётся посчитанным.
public struct ScanState: Codable, Sendable {
    /// Путь файла -> сколько байт из него уже учтено.
    public var offsets: [String: UInt64] = [:]
    /// Токены по дню и модели, без кэшевых: так же считает вкладка Stats у claude.
    public var days: [String: [String: Int]] = [:]
    public var requests: [String: Int] = [:]
    /// Полные итоги дня: деньги и объём с кэшевыми токенами.
    public var totals: [String: UsageStats.DayTotals] = [:]
    /// Часы с датой в ключе: "2026-07-31 14". Дата нужна, чтобы на смене суток
    /// вчерашние часы отвалились сами, а не остались поверх сегодняшних.
    public var hours: [String: [String: Int]] = [:]
    /// Файлов, из которых что-то посчитано.
    public var files = 0
    /// Модели, для которых нет тарифа: их объём есть, а денег нет, и об этом
    /// надо знать по логу, а не гадать, почему сумма занижена.
    public var unknownModels: [String] = []
    public var scannedAt = Date(timeIntervalSince1970: 0)

    public init() {}

    // MARK: - Дочитывание

    /// Дочитывает всё, что появилось с прошлого раза.
    ///
    /// `since` отсекает файлы, которые с тех пор не менялись: их содержимое уже
    /// лежит в кэше claude, открывать их незачем. На выброшенные файлы позиция
    /// не заводится, поэтому если такой файл однажды допишут, он прочитается
    /// целиком и посчитается ровно один раз.
    public mutating func advance(root: URL = CostScanner.defaultRoot,
                                 since: Date? = nil,
                                 now: Date = Date(),
                                 calendar: Calendar = .current,
                                 retry: Bool = true) {
        let fm = FileManager.default
        // Ключом держим путь относительно корня, и обе стороны нормализуем
        // одинаково. Иначе один и тот же файл однажды придёт как /var/..., а в
        // другой раз как /private/var/..., позиция не найдётся, и он
        // прочитается заново, то есть посчитается дважды.
        let base = root.resolvingSymlinksInPath()
        let prefix = base.path.hasSuffix("/") ? base.path : base.path + "/"
        guard let walker = fm.enumerator(
            at: base, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]) else { return }

        // Все увиденные файлы, включая пропущенные по дате: позицию сбрасываем
        // только для тех, которых на диске больше нет. Иначе файл, выпавший из
        // окна, при следующей дописке прочитался бы с нуля и посчитался дважды.
        var present = Set<String>()
        var shrank = false

        for case let url as URL in walker {
            guard url.pathExtension == "jsonl" else { continue }
            let path = url.resolvingSymlinksInPath().path
            let key = path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
            present.insert(key)

            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey,
                                                           .fileSizeKey])
            if let since, let modified = values?.contentModificationDate, modified < since {
                continue
            }
            let size = UInt64(values?.fileSize ?? 0)
            let known = offsets[key]
            // Транскрипты только дописываются. Стал короче, значит переписан, и
            // накопленные по нему цифры больше ничему не соответствуют.
            if let known, size < known { shrank = true; break }
            guard size > (known ?? 0) else { continue }

            var used = false
            let end = CostScanner.forEachLine(of: url, from: known ?? 0) { line in
                if take(line, calendar: calendar) { used = true }
            }
            offsets[key] = end
            if used, known == nil { files += 1 }
        }

        if shrank {
            guard retry else { return }
            // Считаем всё заново: случай редкий, и лучше медленно, но верно.
            self = ScanState()
            advance(root: root, since: since, now: now, calendar: calendar, retry: false)
            return
        }

        offsets = offsets.filter { present.contains($0.key) }
        scannedAt = now
    }

    /// Разбирает одну строку транскрипта. true, если она пошла в счёт.
    private mutating func take(_ line: String, calendar: Calendar) -> Bool {
        guard line.contains("\"usage\"") else { return false }
        guard let data = line.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let message = root["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              let model = message["model"] as? String, !model.hasPrefix("<"),
              let stamp = root["timestamp"] as? String,
              let at = CostScanner.iso(stamp)
        else { return false }

        let tokens = CostScanner.int(usage["input_tokens"]) + CostScanner.int(usage["output_tokens"])
        guard tokens > 0 else { return false }

        let short = StatsScanner.shortName(model)
        let day = StatsScanner.dayKey(at, calendar: calendar)
        days[day, default: [:]][short, default: 0] += tokens
        requests[day, default: 0] += 1
        hours["\(day) \(StatsScanner.hourKey(at, calendar: calendar))",
              default: [:]][short, default: 0] += tokens

        var totalsForDay = totals[day] ?? UsageStats.DayTotals()
        totalsForDay.tokens += tokens
            + CostScanner.int(usage["cache_read_input_tokens"])
            + CostScanner.int(usage["cache_creation_input_tokens"])
        if let prices = Pricing.forModel(model) {
            totalsForDay.cost[short, default: 0] += CostScanner.price(usage: usage, prices: prices)
        } else if !unknownModels.contains(model) {
            unknownModels.append(model)
        }
        totals[day] = totalsForDay
        return true
    }

    // MARK: - Что из накопленного показываем

    public func stats(now: Date = Date(), calendar: Calendar = .current) -> UsageStats {
        let today = StatsScanner.dayKey(now, calendar: calendar)
        var todayHours: [String: [String: Int]] = [:]
        for (key, parts) in hours where key.hasPrefix(today + " ") {
            todayHours[String(key.dropFirst(today.count + 1))] = parts
        }

        var lifetime = 0
        var cost: [String: Double] = [:]
        for totals in totals.values {
            lifetime += totals.tokens
            for (model, money) in totals.cost { cost[model, default: 0] += money }
        }

        let (best, current) = StatsScanner.streaks(days.keys.sorted(), now: now,
                                                   calendar: calendar)
        return UsageStats(days: days, hours: todayHours, requests: requests, transcripts: files,
                          bestStreak: best, currentStreak: current, scannedAt: scannedAt,
                          lifetimeTokens: lifetime, lifetimeCost: cost, totalsByDay: totals)
    }

    /// Деньги за сегодня и за неделю из уже посчитанных дневных сумм.
    ///
    /// Отдельный проход по транскриптам ради этих двух чисел больше не нужен, а
    /// раньше он читал те же сотни мегабайт каждые пять минут.
    public func spend(now: Date = Date(), calendar: Calendar = .current) -> Spend {
        let today = StatsScanner.dayKey(now, calendar: calendar)
        var week = 0.0
        for back in 0..<7 {
            guard let date = calendar.date(byAdding: .day, value: -back, to: now) else { continue }
            let key = StatsScanner.dayKey(date, calendar: calendar)
            week += (totals[key]?.cost.values.reduce(0, +)) ?? 0
        }
        return Spend(today: (totals[today]?.cost.values.reduce(0, +)) ?? 0,
                     week: week, unknownModels: unknownModels, scannedAt: scannedAt)
    }

    // MARK: - Хранение

    /// Рядом с хуком и логом зова: папка без пробелов в пути, это принципиально.
    public static var defaultURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".limitnotifier/scan.json")
    }

    public static func read(_ url: URL = defaultURL) -> ScanState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ScanState.self, from: data)
    }

    public func write(to url: URL = defaultURL) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
