import Foundation

/// Расход с других машин, где тоже работает claude.
///
/// Личная надстройка, а не часть приложения. Всё держится на двух файлах в
/// ~/.claude/remote-usage: списке хостов и скрипте сбора. Нет их, значит и
/// фичи нет: у того, кто просто поставил приложение, ничего не запускается,
/// ничего не показывается, и в бандл ничего лишнего не кладётся.
///
/// Данные собирает tools/remote-usage.py: ходит по ssh, считает транскрипты на
/// той стороне и кладёт сюда по json на хост. Приложение их только читает.
public struct RemoteUsage: Sendable, Equatable {
    /// Имя из ssh config: taras, tgs.
    public let host: String
    /// День -> модель -> input+output. Ровно как локальные дни, без кэша.
    public let days: [String: [String: Int]]
    /// Час -> модель -> input+output, только за сегодня: на этом периоде
    /// график строится по часам, и без них удалённый расход выпал бы из "сегодня".
    public let hours: [String: [String: Int]]
    public let requests: [String: Int]
    /// Когда собирали. Берём время файла, а не поле внутри: одно и то же, но
    /// не зависит от разбора чужой даты.
    public let collectedAt: Date?

    public init(host: String, days: [String: [String: Int]],
                hours: [String: [String: Int]] = [:],
                requests: [String: Int] = [:], collectedAt: Date? = nil) {
        self.host = host
        self.days = days
        self.hours = hours
        self.requests = requests
        self.collectedAt = collectedAt
    }

    public var total: Int { days.values.flatMap(\.values).reduce(0, +) }

    /// Та же структура, что у локальной статистики, чтобы считать периоды
    /// обычным слайсером, а не заводить вторую такую же арифметику.
    public var asStats: UsageStats {
        UsageStats(days: days, hours: hours, requests: requests, transcripts: 0,
                   bestStreak: 0, currentStreak: 0, scannedAt: collectedAt ?? Date())
    }

    // MARK: - Пути

    public static var defaultDir: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/remote-usage")
    }

    /// Включена ли фича вообще: список хостов заведён и не пуст.
    public static func enabled(in dir: URL = defaultDir) -> Bool {
        !hosts(in: dir).isEmpty
    }

    static func hosts(in dir: URL) -> [String] {
        guard let text = try? String(contentsOf: dir.appendingPathComponent("hosts"),
                                     encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            // omittingEmptySubsequences обязателен: без него у строки, которая
            // начинается с решётки, пустой кусок выбрасывается, и весь
            // комментарий уезжает в имя хоста.
            let clean = line.split(separator: "#", maxSplits: 1,
                                   omittingEmptySubsequences: false)[0]
                .trimmingCharacters(in: .whitespaces)
            return clean.isEmpty ? nil : clean
        }
    }

    // MARK: - Чтение

    /// Всё, что успели собрать. Пусто, если фича не заведена.
    public static func all(in dir: URL = defaultDir) -> [RemoteUsage] {
        let known = Set(hosts(in: dir))
        guard !known.isEmpty else { return [] }
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files
            .filter { $0.pathExtension == "json" && known.contains($0.deletingPathExtension().lastPathComponent) }
            .compactMap { parse($0) }
            .sorted { $0.host < $1.host }
    }

    static func parse(_ url: URL) -> RemoteUsage? {
        guard let data = try? Data(contentsOf: url),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        let host = root["ssh_host"] as? String ?? url.deletingPathExtension().lastPathComponent
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate

        var days: [String: [String: Int]] = [:]
        var requests: [String: Int] = [:]
        for (day, value) in root["days"] as? [String: Any] ?? [:] {
            guard let entry = value as? [String: Any] else { continue }
            requests[day] = CostScanner.int(entry["requests"])
            for (model, raw) in entry["models"] as? [String: Any] ?? [:] {
                guard let fields = raw as? [String: Any] else { continue }
                // Без кэша: дневная цифра должна считаться так же, как локальная.
                let tokens = CostScanner.int(fields["input"]) + CostScanner.int(fields["output"])
                guard tokens > 0 else { continue }
                days[day, default: [:]][StatsScanner.shortName(model), default: 0] += tokens
            }
        }

        var hours: [String: [String: Int]] = [:]
        for (hour, value) in root["hours"] as? [String: Any] ?? [:] {
            guard let models = value as? [String: Any] else { continue }
            for (model, tokens) in models {
                hours[hour, default: [:]][StatsScanner.shortName(model), default: 0]
                    += CostScanner.int(tokens)
            }
        }

        guard !days.isEmpty else { return nil }
        return RemoteUsage(host: host, days: days, hours: hours,
                           requests: requests, collectedAt: modified)
    }

    // MARK: - Сбор

    /// Запускает сбор, если пора. Раз в сутки: чаще незачем, данные суточные.
    ///
    /// Возвращает true, если что-то собрали и файлы стоит перечитать. Вызывать
    /// только из фонового потока: внутри ssh на все машины по очереди.
    @discardableResult
    public static func collectIfDue(in dir: URL = defaultDir, now: Date = Date(),
                                    maxAge: TimeInterval = 20 * 3600) -> Bool {
        let script = dir.appendingPathComponent("remote-usage.py")
        guard enabled(in: dir), FileManager.default.isReadableFile(atPath: script.path) else {
            return false
        }
        if let last = lastCollected(in: dir), now.timeIntervalSince(last) < maxAge { return false }

        let started = Date()
        // Таймаут с запасом: машин может быть несколько, каждая до трёх минут.
        let result = Proc.run("/usr/bin/env", ["python3", script.path], timeout: 600)
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        switch result {
        case .finished(let status, _, let err) where status == 0:
            Log.write("remote: собрано с \(hosts(in: dir).joined(separator: " ")), \(ms)ms"
                      + (err.isEmpty ? "" : ", stderr: " + err.prefix(200)))
            return true
        case .finished(let status, _, let err):
            Log.write("remote: скрипт вернул \(status), \(ms)ms, \(err.prefix(300))")
        case .timedOut:
            Log.write("remote: таймаут сбора, \(ms)ms")
        case .launchFailed(let why):
            Log.write("remote: не запустился, \(why)")
        }
        return false
    }

    /// Самый свежий собранный файл. nil, если не собирали ни разу.
    static func lastCollected(in dir: URL) -> Date? {
        all(in: dir).compactMap(\.collectedAt).max()
    }
}

public extension UsageStats {
    /// Подмешивает удалённые машины в дневные и почасовые цифры.
    ///
    /// Складываем, потому что аккаунт один на все машины: в лимит идёт общий
    /// расход, и раздельные цифры вводили бы в заблуждение. Разбивку по
    /// машинам панель показывает отдельно.
    ///
    /// Итоги за всё время не трогаем: удалённый сбор смотрит только последние
    /// недели, и добавлять его к полной истории значило бы смешивать разное.
    func adding(_ remote: [RemoteUsage]) -> UsageStats {
        guard !remote.isEmpty else { return self }
        var days = self.days
        var hours = self.hours
        var requests = self.requests
        for machine in remote {
            for (day, models) in machine.days {
                for (model, tokens) in models { days[day, default: [:]][model, default: 0] += tokens }
            }
            for (hour, models) in machine.hours {
                for (model, tokens) in models { hours[hour, default: [:]][model, default: 0] += tokens }
            }
            for (day, count) in machine.requests { requests[day, default: 0] += count }
        }
        return UsageStats(days: days, hours: hours, requests: requests, transcripts: transcripts,
                          bestStreak: bestStreak, currentStreak: currentStreak, scannedAt: scannedAt,
                          lifetimeTokens: lifetimeTokens, cacheUpTo: cacheUpTo,
                          lifetimeCost: lifetimeCost, totalsByDay: totalsByDay)
    }
}
