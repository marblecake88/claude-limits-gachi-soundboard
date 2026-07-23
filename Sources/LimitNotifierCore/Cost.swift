import Foundation

/// Цены за миллион токенов. Проверены сверкой с total_cost_usd, который
/// возвращает сам Claude Code: на тестовом запросе сошлось до последнего знака.
///
/// Это единственное место в проекте, которое протухает само по себе: выходят
/// новые модели, меняются тарифы. Модель без записи тут не считается молча в
/// ноль, а попадает в Spend.unknownModels, чтоб было видно.
public struct Prices: Sendable, Equatable {
    public let input: Double
    public let output: Double

    public init(input: Double, output: Double) {
        self.input = input
        self.output = output
    }

    /// Запись в кэш на час стоит 2x от input, на 5 минут 1.25x.
    public var cacheWrite1h: Double { input * 2 }
    public var cacheWrite5m: Double { input * 1.25 }
    /// Чтение из кэша стоит 0.1x от input.
    public var cacheRead: Double { input * 0.1 }
}

public enum Pricing {
    /// Сверено с документацией на 2026-07-22. Ключ это префикс id модели.
    /// Старые модели, по которым у меня нет подтверждённой цены, сюда не
    /// внесены намеренно: лучше показать их в списке неизвестных, чем выдумать.
    public static let table: [(prefix: String, prices: Prices)] = [
        ("claude-fable-5",   Prices(input: 10, output: 50)),
        ("claude-mythos-5",  Prices(input: 10, output: 50)),
        ("claude-opus-4-8",  Prices(input: 5,  output: 25)),
        ("claude-opus-4-7",  Prices(input: 5,  output: 25)),
        ("claude-opus-4-6",  Prices(input: 5,  output: 25)),
        ("claude-sonnet-5",  Prices(input: 3,  output: 15)),
        ("claude-sonnet-4-6", Prices(input: 3, output: 15)),
        ("claude-haiku-4-5", Prices(input: 1,  output: 5)),
    ]

    public static func forModel(_ id: String) -> Prices? {
        table.first { id.hasPrefix($0.prefix) }?.prices
    }
}

public struct Spend: Sendable, Equatable {
    public let today: Double
    public let week: Double
    /// Модели, встреченные в транскриптах, но отсутствующие в таблице цен.
    /// Их токены в сумму не попали.
    public let unknownModels: [String]
    public let scannedAt: Date

    public init(today: Double, week: Double, unknownModels: [String], scannedAt: Date) {
        self.today = today
        self.week = week
        self.unknownModels = unknownModels
        self.scannedAt = scannedAt
    }

    public static let empty = Spend(today: 0, week: 0, unknownModels: [],
                                    scannedAt: Date(timeIntervalSince1970: 0))
}

/// Считает, во сколько обошёлся бы трафик по тарифам API.
///
/// Важно: на подписке это НЕ то, что списывают. Это метрика окупаемости, и
/// подписывать её в интерфейсе надо честно.
public enum CostScanner {

    public static var defaultRoot: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects")
    }

    /// Полный проход по транскриптам за последние 7 суток.
    ///
    /// Транскриптов у меня на машине 674 штуки на 328 МБ, но за неделю
    /// менялись только 121. Поэтому: сначала отсекаем файлы по дате изменения,
    /// потом читаем кусками (самый большой файл 64 МБ, целиком в память его
    /// тянуть незачем), и разбираем json только у строк, где вообще есть
    /// "usage". Без этих трёх отсечек скан упирается в диск на секунды.
    public static func scan(root: URL = defaultRoot, now: Date = Date(),
                            calendar: Calendar = .current) -> Spend {
        let weekAgo = now.addingTimeInterval(-7 * 86400)
        let dayStart = calendar.startOfDay(for: now)

        var today = 0.0
        var week = 0.0
        var unknown = Set<String>()

        let fm = FileManager.default
        guard let walker = fm.enumerator(at: root,
                                         includingPropertiesForKeys: [.contentModificationDateKey],
                                         options: [.skipsHiddenFiles]) else {
            return Spend(today: 0, week: 0, unknownModels: [], scannedAt: now)
        }

        for case let url as URL in walker {
            guard url.pathExtension == "jsonl" else { continue }
            // Файл, не менявшийся неделю, не может содержать свежих записей.
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            if let modified, modified < weekAgo { continue }

            forEachLine(of: url) { line in
                // Дешёвая отсечка до разбора json: строк без usage большинство.
                guard line.contains("\"usage\"") else { return }
                guard let data = line.data(using: .utf8),
                      let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let message = root["message"] as? [String: Any],
                      let usage = message["usage"] as? [String: Any],
                      let model = message["model"] as? String,
                      let stamp = root["timestamp"] as? String,
                      let at = iso(stamp), at >= weekAgo
                else { return }

                guard let prices = Pricing.forModel(model) else {
                    // Записи с нулевым usage (служебный <synthetic> и подобные)
                    // в список неизвестных не тащим: считать там нечего, а в
                    // панели это выглядело бы как потерянные деньги.
                    if hasTokens(usage) { unknown.insert(model) }
                    return
                }
                let cost = price(usage: usage, prices: prices)
                week += cost
                if at >= dayStart { today += cost }
            }
        }

        return Spend(today: today, week: week,
                     unknownModels: unknown.sorted(), scannedAt: now)
    }

    /// Считает стоимость одной записи usage. Вынесено отдельно ради теста:
    /// именно эта формула сверялась с total_cost_usd от Claude Code.
    public static func price(usage: [String: Any], prices: Prices) -> Double {
        let input = int(usage["input_tokens"])
        let output = int(usage["output_tokens"])
        let cacheRead = int(usage["cache_read_input_tokens"])
        let cacheTotal = int(usage["cache_creation_input_tokens"])

        // Разбивка по TTL приходит не всегда. Если её нет, считаем по часовому:
        // Claude Code пишет кэш именно на час, это видно в ephemeral_1h.
        let breakdown = usage["cache_creation"] as? [String: Any]
        let write1h = breakdown.map { int($0["ephemeral_1h_input_tokens"]) } ?? cacheTotal
        let write5m = breakdown.map { int($0["ephemeral_5m_input_tokens"]) } ?? 0

        return (Double(input) * prices.input
                + Double(output) * prices.output
                + Double(cacheRead) * prices.cacheRead
                + Double(write1h) * prices.cacheWrite1h
                + Double(write5m) * prices.cacheWrite5m) / 1_000_000
    }

    // MARK: - Мелочи

    static func hasTokens(_ usage: [String: Any]) -> Bool {
        int(usage["input_tokens"]) + int(usage["output_tokens"])
            + int(usage["cache_creation_input_tokens"])
            + int(usage["cache_read_input_tokens"]) > 0
    }

    private static func int(_ any: Any?) -> Int {
        (any as? Int) ?? Int((any as? Double) ?? 0)
    }

    private static let isoParser: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoPlain = ISO8601DateFormatter()

    private static func iso(_ s: String) -> Date? {
        isoParser.date(from: s) ?? isoPlain.date(from: s)
    }

    /// Построчное чтение кусками по мегабайту: файлы бывают на десятки
    /// мегабайт, целиком в память их тянуть не надо.
    private static func forEachLine(of url: URL, _ body: (String) -> Void) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }

        var buffer = Data()
        let newline = UInt8(ascii: "\n")
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            buffer.append(chunk)
            while let idx = buffer.firstIndex(of: newline) {
                let lineData = buffer[buffer.startIndex..<idx]
                buffer.removeSubrange(buffer.startIndex...idx)
                if let line = String(data: lineData, encoding: .utf8) { body(line) }
            }
        }
        if !buffer.isEmpty, let line = String(data: buffer, encoding: .utf8) { body(line) }
    }
}
