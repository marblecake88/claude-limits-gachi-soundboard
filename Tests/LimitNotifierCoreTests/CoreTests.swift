import Foundation
import Testing
@testable import LimitNotifierCore

// MARK: - Мелкие помощники

/// Календарь с фиксированной зоной UTC+3 без перевода часов.
/// Прибит намеренно, чтоб тесты не зависели от настроек машины.
private func fixedCalendar() -> Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(secondsFromGMT: 3 * 3600)!
    c.locale = Locale(identifier: "en_US_POSIX")
    return c
}

/// Дата в зоне прибитого календаря.
private func local(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
    var dc = DateComponents()
    dc.year = y; dc.month = mo; dc.day = d
    dc.hour = h; dc.minute = mi; dc.second = 0
    return fixedCalendar().date(from: dc)!
}

/// Дата в UTC. Нужна, чтоб сравнивать с resets_at из ответа API.
private func utc(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int = 0) -> Date {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(secondsFromGMT: 0)!
    var dc = DateComponents()
    dc.year = y; dc.month = mo; dc.day = d
    dc.hour = h; dc.minute = mi; dc.second = s
    return c.date(from: dc)!
}

// MARK: - Гейдж

@Suite("Гейдж")
struct GaugeTests {

    /// Главная регрессия: суммарная ширина обязана быть одинаковой на любом
    /// проценте, иначе колонка в меню-баре дёргается при каждом обновлении.
    @Test("Ширина не плывёт", arguments: [0, 1, 50, 99, 100])
    func widthIsConstant(percent: Int) {
        for width in [3, 6, 10, 20] {
            let (filled, empty) = Gauge.bars(percent: percent, width: width)
            #expect(filled.count + empty.count == width,
                    "процент \(percent), ширина \(width)")
        }
    }

    @Test("Ноль процентов не рисует ни одного заполненного блока")
    func zeroIsEmpty() {
        let (filled, empty) = Gauge.bars(percent: 0, width: 6)
        #expect(filled.isEmpty)
        #expect(empty.count == 6)
    }

    @Test("Сто процентов заполняет всё")
    func hundredIsFull() {
        let (filled, empty) = Gauge.bars(percent: 100, width: 6)
        #expect(filled.count == 6)
        #expect(empty.isEmpty)
    }

    /// Один процент не должен округлиться в ноль: пользователь видит, что окно
    /// уже началось.
    @Test("Один процент даёт минимум один блок")
    func onePercentShowsSomething() {
        for width in [3, 6, 10, 20] {
            let (filled, _) = Gauge.bars(percent: 1, width: width)
            #expect(filled.count >= 1, "ширина \(width)")
        }
    }

    /// Симметрично: 99% не должно выглядеть как полный гейдж.
    @Test("Девяносто девять процентов оставляет пустой блок")
    func ninetyNineLeavesGap() {
        for width in [3, 6, 10, 20] {
            let (_, empty) = Gauge.bars(percent: 99, width: width)
            #expect(empty.count >= 1, "ширина \(width)")
        }
    }

    @Test("Значения вне диапазона зажимаются, а не роняют приложение")
    func clampsOutOfRange() {
        let below = Gauge.bars(percent: -42, width: 6)
        #expect(below.filled.isEmpty)
        #expect(below.empty.count == 6)

        let above = Gauge.bars(percent: 1000, width: 6)
        #expect(above.filled.count == 6)
        #expect(above.empty.isEmpty)
    }

    @Test("Строка статуса: гейдж фиксированной ширины плюс процент")
    func statusText() {
        #expect(Gauge.statusText(percent: nil) == "-- %")

        // Общая длина строки меняется от числа цифр, это нормально. Важно, что
        // сама полоска всегда ровно width символов.
        for (percent, width) in [(0, 6), (42, 6), (100, 6), (7, 3), (99, 10)] {
            let text = Gauge.statusText(percent: percent, width: width)
            #expect(text.hasSuffix(" \(percent)%"), "процент \(percent)")
            #expect(text.prefix(width).allSatisfy { $0 == "█" }, "процент \(percent)")
            #expect(text.count == width + " \(percent)%".count, "процент \(percent)")
        }
    }
}

// MARK: - Форматирование времени

@Suite("Форматирование остатка времени")
struct FmtTests {

    @Test("Меньше часа")
    func subHour() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(Fmt.until(now.addingTimeInterval(12 * 60), from: now) == "12m")
        #expect(Fmt.until(now.addingTimeInterval(59 * 60), from: now) == "59m")
    }

    @Test("Часы и минуты")
    func hours() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(Fmt.until(now.addingTimeInterval(3600 + 47 * 60), from: now) == "1h 47m")
        #expect(Fmt.until(now.addingTimeInterval(5 * 3600), from: now) == "5h 0m")
    }

    @Test("Несколько суток")
    func days() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(Fmt.until(now.addingTimeInterval(4 * 86400 + 6 * 3600), from: now) == "4d 6h")
        #expect(Fmt.until(now.addingTimeInterval(86400), from: now) == "1d 0h")
    }

    @Test("Прошедшая дата это now")
    func past() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(Fmt.until(now.addingTimeInterval(-3600), from: now) == "now")
        #expect(Fmt.until(now, from: now) == "now")
    }
}

// MARK: - Severity

@Suite("Severity из ответа сервера")
struct SeverityTests {

    @Test("Известные значения")
    func known() {
        #expect(Severity(api: "normal") == .normal)
        #expect(Severity(api: "warning") == .warning)
        #expect(Severity(api: "critical") == .critical)
        #expect(Severity(api: "severe") == .critical)
    }

    @Test("Регистр не важен")
    func caseInsensitive() {
        #expect(Severity(api: "WARNING") == .warning)
        #expect(Severity(api: "Critical") == .critical)
    }

    @Test("Незнакомое и nil дают unknown")
    func unknown() {
        #expect(Severity(api: nil) == .unknown)
        #expect(Severity(api: "") == .unknown)
        #expect(Severity(api: "апокалипсис") == .unknown)
    }
}

// MARK: - Разбор ответа API

/// Записанный живьём вывод `claude -p "/usage"`. Эталон, менять можно только
/// после нового реального запуска.
let realOutput = """
You are currently using your subscription to power your Claude Code usage

Current session: 26% used · resets Jul 22 at 10:10pm (Europe/Riga)
Current week (all models): 83% used · resets Jul 24 at 9pm (Europe/Riga)
Current week (Fable): 88% used · resets Jul 24 at 9pm (Europe/Riga)

What's contributing to your limits usage?
Approximate, based on local sessions on this machine

Last 24h · 1258 requests · 11 sessions
  95% of your usage came from subagent-heavy sessions
"""

@Suite("Разбор вывода claude -p /usage")
struct ParseTests {

    /// Момент незадолго до сброса сессии из эталона.
    private let now = utc(2026, 7, 22, 12, 0)

    @Test("Эталонный вывод: три окна в порядке появления")
    func realRows() throws {
        let snap = try #require(UsageClient.parse(realOutput, now: now))
        #expect(snap.rows.count == 3)
        #expect(snap.rows.map(\.percent) == [26, 83, 88])
        #expect(snap.rows.map(\.isSession) == [true, false, false])
        #expect(snap.rows.map(\.kind) == ["session", "weekly_all", "weekly_scoped"])
        #expect(snap.rows.map(\.label) == ["5h", "Weekly", "Fable weekly"])
        // id уходит в ForEach, дубликаты ломают отрисовку.
        #expect(Set(snap.rows.map(\.id)).count == 3)
    }

    /// Строки с процентами тут нет вовсе. Так выглядит превышение частоты
    /// опроса: команда отработала успешно, а лимиты не отдала.
    @Test("Вывод без лимитов даёт nil, а не пустой снимок")
    func noLimitsBlock() {
        let text = """
        You are currently using your subscription to power your Claude Code usage

        What's contributing to your limits usage?
        Last 24h · 12 requests · 2 sessions
        """
        #expect(UsageClient.parse(text, now: now) == nil)
        #expect(UsageClient.parse("", now: now) == nil)
        #expect(UsageClient.parse("совершенно посторонний текст", now: now) == nil)
    }

    @Test("Незнакомый скоуп всё равно разбирается")
    func unknownScope() throws {
        let text = "Current week (Omelette): 12% used · resets Jul 24 at 9pm (Europe/Riga)"
        let snap = try #require(UsageClient.parse(text, now: now))
        #expect(snap.rows.first?.label == "Omelette weekly")
        #expect(snap.rows.first?.kind == "weekly_scoped")
        #expect(snap.rows.first?.percent == 12)
    }

    @Test("Время сброса разбирается вместе с зоной")
    func resetParsed() throws {
        let snap = try #require(UsageClient.parse(realOutput, now: now))
        let session = try #require(snap.rows.first?.resetsAt)
        // 10:10pm в Europe/Riga это 19:10 UTC.
        #expect(abs(session.timeIntervalSince(utc(2026, 7, 22, 19, 10))) < 60)
        // Формат без минут, "9pm", тоже должен разобраться.
        let weekly = try #require(snap.rows[1].resetsAt)
        #expect(abs(weekly.timeIntervalSince(utc(2026, 7, 24, 18, 0))) < 60)
        #expect(snap.rows.allSatisfy { $0.resetsAt != nil })
    }

    @Test("Окно активно, пока сброс впереди")
    func windowActive() throws {
        let before = try #require(UsageClient.parse(realOutput, now: utc(2026, 7, 22, 12, 0)))
        #expect(before.sessionWindowActive)
        // После сброса окно уже не идёт.
        let after = try #require(UsageClient.parse(realOutput, now: utc(2026, 7, 22, 20, 0)))
        #expect(after.sessionWindowActive == false)
    }

    /// Регресс: ночной пинг не должен пропускаться по протухшему снапшоту.
    /// Снимок сделан в 12:00 (окно идёт, сброс в 19:10 UTC), а /usage потом
    /// перестал отвечать и снимок завис. Замороженный флаг так и остаётся true,
    /// но решение о пинге считается от текущего момента и после сброса даёт false.
    @Test("Протухший снапшот: окно закрыто, если сброс уже прошёл")
    func staleWindowByTime() throws {
        let stale = try #require(UsageClient.parse(realOutput, now: utc(2026, 7, 22, 12, 0)))
        #expect(stale.sessionWindowActive)                              // флаг заморожен на true
        #expect(stale.sessionRunning(at: utc(2026, 7, 22, 12, 0)))      // в момент замера окно идёт
        #expect(stale.sessionRunning(at: utc(2026, 7, 22, 20, 0)) == false) // за сбросом закрыто
    }

    /// Проценты бывают дробные, а порядок строк может поменяться.
    @Test("Дробные проценты и произвольный порядок")
    func lenient() throws {
        let text = """
        Current week (all models): 41.7% used · resets Jul 24 at 9pm (Europe/Riga)
        Current session: 0% used · resets Jul 22 at 10:10pm (Europe/Riga)
        """
        let snap = try #require(UsageClient.parse(text, now: now))
        #expect(snap.rows.map(\.percent) == [42, 0])
        #expect(snap.session?.percent == 0)
    }

    @Test("Ошибки различаются по смыслу")
    func errorKinds() {
        #expect(UsageError.noLimits("").isTransient)
        #expect(UsageError.timedOut.isTransient)
        #expect(UsageError.notLoggedIn.isTransient == false)
        #expect(UsageError.claudeNotFound.isTransient == false)
        // Текст про прошлые цифры важен: это не поломка, а неполные данные.
        // Язык берём явно, иначе тест зависел бы от локали машины.
        let was = L.lang
        defer { L.lang = was }
        L.lang = .ru
        #expect(UsageError.noLimits("").hint.contains("прошлые"))
        L.lang = .en
        #expect(UsageError.noLimits("").hint.contains("last numbers"))
    }

    @Test("Перевод есть у каждой подсказки, и он не совпадает с русским")
    func everyHintTranslated() {
        let was = L.lang
        defer { L.lang = was }
        let cases: [UsageError] = [.claudeNotFound, .notLoggedIn, .noLimits(""), .timedOut,
                                   .launchFailed("boom")]
        for e in cases {
            L.lang = .ru; let ru = e.hint
            L.lang = .en; let en = e.hint
            #expect(!ru.isEmpty && !en.isEmpty)
            #expect(ru != en, "подсказка без перевода: \(ru)")
            // Забытый перевод виден по кириллице в английской ветке.
            #expect(en.range(of: "\\p{Cyrillic}", options: .regularExpression) == nil,
                    "кириллица в английском тексте: \(en)")
        }
    }

    @Test("Разные формулировки logged out распознаются")
    func loggedOut() {
        #expect(UsageClient.looksLoggedOut("Not logged in"))
        #expect(UsageClient.looksLoggedOut("Please log in to continue"))
        #expect(UsageClient.looksLoggedOut("Please run /login"))
        #expect(UsageClient.looksLoggedOut("Invalid API key"))
        // Нормальный вывод лимитов за logged out не принимаем.
        #expect(UsageClient.looksLoggedOut(realOutput) == false)
    }

    @Test("Выжимка вывода: одна строка, без пустот, с ограничением длины")
    func outputSnippet() {
        let s = UsageClient.snippet("  first line \n\n  second  \n")
        #expect(s == "first line · second")
        #expect(UsageClient.snippet("").isEmpty)
        #expect(UsageClient.snippet(String(repeating: "x", count: 500)).count <= 201)
    }
}

// MARK: - Строка меню

@Suite("Строка меню 55/78/2h15")
struct StatusBarTests {

    @Test("Час и больше: часы плюс минуты с нулём")
    func hours() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(StatusBar.compact(now.addingTimeInterval(2 * 3600 + 15 * 60), from: now) == "2h15")
        // Ведущий ноль обязателен, иначе 2h5 читается как два с половиной часа.
        #expect(StatusBar.compact(now.addingTimeInterval(2 * 3600 + 5 * 60), from: now) == "2h05")
        #expect(StatusBar.compact(now.addingTimeInterval(3600), from: now) == "1h00")
    }

    @Test("Меньше часа: только минуты")
    func minutes() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(StatusBar.compact(now.addingTimeInterval(15 * 60), from: now) == "15m")
        #expect(StatusBar.compact(now.addingTimeInterval(59 * 60 + 59), from: now) == "59m")
        #expect(StatusBar.compact(now.addingTimeInterval(60), from: now) == "1m")
    }

    @Test("Нет даты, ноль и прошедшее время дают прочерк")
    func noTime() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(StatusBar.compact(nil, from: now) == "--")
        #expect(StatusBar.compact(now, from: now) == "--")
        #expect(StatusBar.compact(now.addingTimeInterval(-3600), from: now) == "--")
    }

    @Test("Эталонный ответ разбирается в куски строки меню")
    func partsFromRealPayload() throws {
        let snap = try #require(UsageClient.parse(realOutput, now: utc(2026, 7, 22, 12, 0)))
        let p = StatusBar.parts(from: snap, now: utc(2026, 7, 22, 12, 0))

        #expect(p.session == "26")
        // Берём общий недельный weekly_all, а не скоупный по модели.
        #expect(p.weekly == "83")
        #expect(p.weeklyLevel == Level.pink)
        #expect(p.sessionLevel == Level.calm)
        #expect(p.time == "7h10")
    }

    @Test("Без снимка всё прочерки")
    func noSnapshot() {
        let p = StatusBar.parts(from: nil, now: Date())
        #expect(p.session == "--")
        #expect(p.weekly == "--")
        #expect(p.time == "--")
    }

    /// Окна нет, значит и обратного отсчёта нет, а проценты всё равно есть.
    @Test("Окно неактивно: время прочерк, проценты остаются")
    func inactiveWindow() throws {
        let snap = try #require(UsageClient.parse(realOutput, now: utc(2026, 7, 22, 20, 0)))
        let p = StatusBar.parts(from: snap, now: utc(2026, 7, 22, 16, 0))
        #expect(p.time == "--")
        #expect(p.session == "26")
        #expect(p.weekly == "83")
    }
}

// MARK: - Пороги цвета

@Suite("Пороги цвета")
struct LevelTests {

    /// Границы заданы пользователем: 60 жёлтый, 79 розовый, 89 красный.
    /// Регрессия именно на граничные значения, они легко съезжают на единицу.
    @Test("Границы порогов")
    func boundaries() {
        #expect(Level(percent: 0) == .calm)
        #expect(Level(percent: 59) == .calm)
        #expect(Level(percent: 60) == .yellow)
        #expect(Level(percent: 78) == .yellow)
        #expect(Level(percent: 79) == .pink)
        #expect(Level(percent: 88) == .pink)
        #expect(Level(percent: 89) == .red)
        #expect(Level(percent: 100) == .red)
    }
}

// MARK: - Якорь keep-alive

@Suite("Математика якоря")
struct AnchorTests {

    private let cal = fixedCalendar()

    /// База это якорь минус 5 часов. Якорь 09:00, база 04:00.
    @Test("Якорь 09:00, сейчас полдень: пинг завтра в 04:00")
    func anchorNineFromNoon() {
        let ping = Anchor.nextPing(anchorHour: 9, anchorMinute: 0,
                                   from: local(2026, 7, 22, 12, 0), calendar: cal)
        #expect(ping == local(2026, 7, 23, 4, 0))
    }

    @Test("Якорь 09:00, сейчас 02:00: пинг сегодня в 04:00")
    func anchorNineFromNight() {
        let ping = Anchor.nextPing(anchorHour: 9, anchorMinute: 0,
                                   from: local(2026, 7, 22, 2, 0), calendar: cal)
        #expect(ping == local(2026, 7, 22, 4, 0))
    }

    /// Якорь 03:00 отматывается через полночь назад, база 22:00 предыдущих суток.
    @Test("Якорь 03:00: база 22:00, ближайший пинг сегодня вечером")
    func anchorThreeCrossesMidnight() {
        let ping = Anchor.nextPing(anchorHour: 3, anchorMinute: 0,
                                   from: local(2026, 7, 22, 12, 0), calendar: cal)
        #expect(ping == local(2026, 7, 22, 22, 0))
    }

    @Test("Якорь 03:00, сейчас 23:00: пинг завтра в 22:00")
    func anchorThreeAfterBase() {
        let ping = Anchor.nextPing(anchorHour: 3, anchorMinute: 0,
                                   from: local(2026, 7, 22, 23, 0), calendar: cal)
        #expect(ping == local(2026, 7, 23, 22, 0))
    }

    @Test("Якорь 00:00: база 19:00")
    func anchorMidnight() {
        #expect(Anchor.nextPing(anchorHour: 0, anchorMinute: 0,
                                from: local(2026, 7, 22, 12, 0), calendar: cal)
                == local(2026, 7, 22, 19, 0))
        #expect(Anchor.nextPing(anchorHour: 0, anchorMinute: 0,
                                from: local(2026, 7, 22, 20, 0), calendar: cal)
                == local(2026, 7, 23, 19, 0))
    }

    @Test("Сброс наступает ровно через 5 часов после пинга")
    func resetIsFiveHoursLater() {
        let ping = local(2026, 7, 22, 4, 0)
        #expect(Anchor.resetAfter(ping: ping) == ping.addingTimeInterval(5 * 3600))
    }

    /// Свойство, ради которого вся фича и существует: пингуем в nextPing,
    /// значит окно сбрасывается ровно в якорное время.
    @Test("Круговой прогон: пинг плюс окно попадает в якорь",
          arguments: [(0, 0), (3, 0), (4, 30), (9, 0), (12, 15), (23, 45)])
    func roundTrip(anchor: (hour: Int, minute: Int)) {
        for now in [local(2026, 7, 22, 0, 30),
                    local(2026, 7, 22, 12, 0),
                    local(2026, 7, 22, 23, 50)] {
            let ping = Anchor.nextPing(anchorHour: anchor.hour, anchorMinute: anchor.minute,
                                       from: now, calendar: cal)
            #expect(ping > now, "якорь \(anchor), сейчас \(now)")

            let reset = Anchor.resetAfter(ping: ping)
            let parts = cal.dateComponents([.hour, .minute], from: reset)
            #expect(parts.hour == anchor.hour, "якорь \(anchor), сейчас \(now)")
            #expect(parts.minute == anchor.minute, "якорь \(anchor), сейчас \(now)")
        }
    }

    /// Ближайший пинг всегда в пределах суток, иначе расписание разъехалось.
    @Test("Пинг не дальше суток вперёд", arguments: [(0, 0), (9, 0), (23, 45)])
    func pingWithinADay(anchor: (hour: Int, minute: Int)) {
        let now = local(2026, 7, 22, 12, 0)
        let ping = Anchor.nextPing(anchorHour: anchor.hour, anchorMinute: anchor.minute,
                                   from: now, calendar: cal)
        #expect(ping.timeIntervalSince(now) <= 24 * 3600 + 1, "якорь \(anchor)")
    }
}

// MARK: - Лог

@Suite("Лог пингов")
struct LogTests {

    /// Временная папка на один тест, чтоб параллельные тесты не мешали друг другу.
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("limitnotifier-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func read(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    @Test("Записи старше порога удаляются, свежие остаются")
    func trimKeepsRecent() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("limitnotifier.log")

        let now = utc(2026, 7, 22, 12, 0)
        Log.write("совсем старая запись", at: url, now: now.addingTimeInterval(-100 * 3600))
        Log.write("старая запись", at: url, now: now.addingTimeInterval(-80 * 3600))
        Log.write("свежая запись", at: url, now: now.addingTimeInterval(-3600))
        Log.write("только что", at: url, now: now)

        let before = read(url)
        #expect(before.contains("совсем старая запись"))
        #expect(before.contains("только что"))
        #expect(before.split(separator: "\n").count == 4)

        Log.trim(olderThanHours: 72, at: url, now: now)

        let after = read(url)
        #expect(after.contains("совсем старая запись") == false)
        #expect(after.contains("старая запись") == false)
        #expect(after.contains("свежая запись"))
        #expect(after.contains("только что"))
    }

    /// Строку, у которой не разобрать время, выбрасывать нельзя: скорее всего
    /// это многострочный вывод или чужой формат, и он ещё пригодится.
    @Test("Строка с неразбираемым временем сохраняется")
    func trimKeepsUnparseableLine() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("limitnotifier.log")

        let now = utc(2026, 7, 22, 12, 0)
        Log.write("древняя запись", at: url, now: now.addingTimeInterval(-200 * 3600))

        var text = read(url)
        text += "мусор без времени в начале строки\n"
        try text.write(to: url, atomically: true, encoding: .utf8)

        Log.trim(olderThanHours: 72, at: url, now: now)

        let after = read(url)
        #expect(after.contains("древняя запись") == false)
        #expect(after.contains("мусор без времени в начале строки"))
    }

    @Test("Подрезка пустого лога оставляет его пустым")
    func trimEmptyFile() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("limitnotifier.log")
        try "".write(to: url, atomically: true, encoding: .utf8)

        Log.trim(olderThanHours: 72, at: url, now: utc(2026, 7, 22, 12, 0))

        #expect(read(url).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test("Подрезка несуществующего файла ничего не ломает")
    func trimMissingFile() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("нет-такого.log")

        Log.trim(olderThanHours: 72, at: url, now: utc(2026, 7, 22, 12, 0))

        #expect(FileManager.default.fileExists(atPath: url.path) == false)
    }

    @Test("Запись создаёт файл, если его не было")
    func writeCreatesFile() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("новый.log")

        Log.write("первая строка", at: url, now: utc(2026, 7, 22, 12, 0))

        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(read(url).contains("первая строка"))
        #expect(read(url).hasSuffix("\n"))
    }
}

// MARK: - Деньги

@Suite("Стоимость по тарифам API")
struct CostTests {

    /// Эталон: реальный ответ claude -p на haiku, у которого Claude Code
    /// вернул total_cost_usd = 0.0212593. Если эта проверка упадёт, значит
    /// поехала либо формула, либо таблица цен.
    @Test("Формула сходится с total_cost_usd от Claude Code")
    func matchesClaudeCode() {
        let usage: [String: Any] = [
            "input_tokens": 10,
            "cache_creation_input_tokens": 9227,
            "cache_read_input_tokens": 18953,
            "output_tokens": 180,
            "cache_creation": [
                "ephemeral_1h_input_tokens": 9227,
                "ephemeral_5m_input_tokens": 0,
            ],
        ]
        let prices = try! #require(Pricing.forModel("claude-haiku-4-5-20251001"))
        let cost = CostScanner.price(usage: usage, prices: prices)
        #expect(abs(cost - 0.0212593) < 1e-9, "получилось \(cost)")
    }

    @Test("Ставки кэша выводятся из input")
    func cacheRates() {
        let p = Prices(input: 5, output: 25)
        #expect(p.cacheWrite1h == 10)    // час это 2x
        #expect(p.cacheWrite5m == 6.25)  // пять минут это 1.25x
        #expect(p.cacheRead == 0.5)      // чтение это 0.1x
    }

    @Test("Модели резолвятся по префиксу с датой")
    func modelPrefixes() {
        #expect(Pricing.forModel("claude-opus-4-8")?.input == 5)
        #expect(Pricing.forModel("claude-opus-4-8[1m]")?.input == 5)
        #expect(Pricing.forModel("claude-fable-5")?.output == 50)
        #expect(Pricing.forModel("claude-haiku-4-5-20251001")?.input == 1)
        // Незнакомая модель не должна тихо посчитаться в ноль.
        #expect(Pricing.forModel("claude-opus-4-1") == nil)
        #expect(Pricing.forModel("<synthetic>") == nil)
    }

    /// Opus 5 вышел 2026-07-24 и до этого попадал в список неизвестных моделей.
    /// Заодно страхуемся от порядка префиксов: opus-5 не должен ловиться
    /// записью opus-4-*, а sonnet-5 не должен путаться с sonnet-4-6.
    @Test("Opus 5 считается, префиксы не перехлёстываются")
    func opus5() {
        #expect(Pricing.forModel("claude-opus-5")?.input == 5)
        #expect(Pricing.forModel("claude-opus-5")?.output == 25)
        #expect(Pricing.forModel("claude-opus-5[1m]")?.input == 5)
        // Вводная цена Sonnet 5, действует по 31 августа 2026.
        #expect(Pricing.forModel("claude-sonnet-5")?.input == 2)
        #expect(Pricing.forModel("claude-sonnet-4-6")?.input == 3)
    }

    /// Без разбивки по TTL считаем как часовой кэш: так пишет Claude Code.
    @Test("Кэш без разбивки считается по часовому тарифу")
    func cacheWithoutBreakdown() {
        let usage: [String: Any] = [
            "input_tokens": 0, "output_tokens": 0,
            "cache_read_input_tokens": 0,
            "cache_creation_input_tokens": 1_000_000,
        ]
        let cost = CostScanner.price(usage: usage, prices: Prices(input: 5, output: 25))
        #expect(abs(cost - 10.0) < 1e-9)
    }

    @Test("Пустой usage стоит ноль")
    func emptyUsage() {
        #expect(CostScanner.price(usage: [:], prices: Prices(input: 5, output: 25)) == 0)
    }
}

@Suite("Нулевые записи usage")
struct EmptyUsageTests {
    /// Служебные записи вроде <synthetic> не должны попадать в список
    /// моделей без цены: считать там нечего, а в панели это выглядит как
    /// потерянные деньги.
    @Test("Запись без токенов не считается значимой")
    func zeroUsageIsNotCounted() {
        #expect(CostScanner.hasTokens([:]) == false)
        #expect(CostScanner.hasTokens([
            "input_tokens": 0, "output_tokens": 0,
            "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0,
        ]) == false)
        #expect(CostScanner.hasTokens(["output_tokens": 1]))
        #expect(CostScanner.hasTokens(["cache_read_input_tokens": 42]))
    }
}

@Suite("Проверка обновлений")
struct UpdateCheckTests {

    @Test("Версии сравниваются по числам, а не как строки")
    func compare() {
        #expect(UpdateCheck.isNewer("1.1.1", than: "1.1"))
        #expect(UpdateCheck.isNewer("1.2", than: "1.1.9"))
        // Строковое сравнение тут дало бы "1.10" < "1.9", человек не увидел бы
        // обновление. Поэтому и считаем по компонентам.
        #expect(UpdateCheck.isNewer("1.10", than: "1.9"))
        #expect(UpdateCheck.isNewer("2.0", than: "1.99.99"))
        // Своя же и более старая версия обновлением не считаются.
        #expect(UpdateCheck.isNewer("1.1.1", than: "1.1.1") == false)
        #expect(UpdateCheck.isNewer("1.0", than: "1.1") == false)
        #expect(UpdateCheck.isNewer("1.1", than: "1.1.1") == false)
    }

    @Test("Ведущая v и хвосты не мешают")
    func tags() {
        #expect(UpdateCheck.normalize("v1.1.1") == "1.1.1")
        #expect(UpdateCheck.normalize(" 1.1.1\n") == "1.1.1")
        #expect(UpdateCheck.isNewer("v1.2", than: "1.1"))
        #expect(UpdateCheck.isNewer("1.2-beta", than: "1.1"))
    }
}

@Suite("Частота опроса")
struct PollPlanTests {

    private func snap(percent: Int, active: Bool) -> UsageSnapshot {
        UsageSnapshot(
            rows: [LimitRow(id: "session", kind: "session", label: "5h",
                            percent: percent, severity: .normal, resetsAt: nil,
                            group: "session", isSession: true)],
            fetchedAt: Date(),
            sessionWindowActive: active
        )
    }

    /// Просьба сервера главнее любых наших расчётов.
    @Test("Retry-After перебивает всё остальное")
    func retryAfterWins() {
        let hot = snap(percent: 95, active: true)
        #expect(PollPlan.interval(snapshot: hot, failureStreak: 0, retryAfter: 300) == 300)
        #expect(PollPlan.interval(snapshot: hot, failureStreak: 9, retryAfter: 300) == 300)
        // Но чаще раза в минуту не ходим, даже если сервер разрешил.
        #expect(PollPlan.interval(snapshot: hot, failureStreak: 0, retryAfter: 1) == 60)
        #expect(PollPlan.interval(snapshot: hot, failureStreak: 0, retryAfter: 0) == 60)
    }

    @Test("Окна нет: спрашиваем редко, меняться нечему")
    func idleIsQuiet() {
        #expect(PollPlan.interval(snapshot: snap(percent: 0, active: false),
                                  failureStreak: 0, retryAfter: nil) == 900)
    }

    @Test("Окно горит: обычный темп, у лимита частый")
    func activeScales() {
        #expect(PollPlan.interval(snapshot: snap(percent: 10, active: true),
                                  failureStreak: 0, retryAfter: nil) == 600)
        #expect(PollPlan.interval(snapshot: snap(percent: 78, active: true),
                                  failureStreak: 0, retryAfter: nil) == 600)
        // С 79 начинается розовая зона, тут точность важнее экономии.
        #expect(PollPlan.interval(snapshot: snap(percent: 79, active: true),
                                  failureStreak: 0, retryAfter: nil) == 120)
        #expect(PollPlan.interval(snapshot: snap(percent: 99, active: true),
                                  failureStreak: 0, retryAfter: nil) == 120)
    }

    /// Регресс: раньше "лимиты не отданы" темп опроса не меняло вовсе, и при
    /// горящем окне мы спрашивали раз в 2 минуты, поддерживая ограничение
    /// частоты на стороне claude.
    @Test("Пустой ответ удлиняет паузу, пока не упрётся в час")
    func emptyAnswerBacksOff() {
        let first = PollPlan.backoff(previous: nil)
        #expect(first == 900)
        let second = PollPlan.backoff(previous: first)
        #expect(second == 1800)
        #expect(PollPlan.backoff(previous: second) == 3600)
        // Потолок: дальше не растём.
        #expect(PollPlan.backoff(previous: 3600) == 3600)
        // И эта пауза действительно перебивает частый опрос у лимита.
        #expect(PollPlan.interval(snapshot: snap(percent: 95, active: true),
                                  failureStreak: 0, retryAfter: first) == 900)
    }

    @Test("Сеть лежит: не долбим")
    func brokenNetworkBacksOff() {
        #expect(PollPlan.interval(snapshot: snap(percent: 95, active: true),
                                  failureStreak: 3, retryAfter: nil) == 900)
    }

    @Test("Ещё нет данных: умеренный темп")
    func noSnapshot() {
        #expect(PollPlan.interval(snapshot: nil, failureStreak: 0, retryAfter: nil) == 300)
    }

    /// Ни при каких входных не уходим чаще раза в минуту.
    @Test("Никогда не чаще минуты")
    func neverBelowMinimum() {
        for streak in [0, 1, 5] {
            for after in [nil, 0, 1, 30, 600] as [Int?] {
                for active in [true, false] {
                    for pct in [0, 50, 79, 100] {
                        let v = PollPlan.interval(snapshot: snap(percent: pct, active: active),
                                                  failureStreak: streak, retryAfter: after)
                        #expect(v >= PollPlan.minimum)
                    }
                }
            }
        }
    }
}


// MARK: - Статистика использования

@Suite("Статистика")
struct StatsTests {

    private func cal() -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 3 * 3600)!
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }

    /// Имена моделей идут в подписи графика, поэтому важно, чтоб из id
    /// вычищались дата и пометка контекста.
    @Test("Короткие имена моделей")
    func names() {
        #expect(StatsScanner.shortName("claude-opus-4-8") == "Opus 4.8")
        #expect(StatsScanner.shortName("claude-fable-5") == "Fable 5")
        #expect(StatsScanner.shortName("claude-haiku-4-5-20251001") == "Haiku 4.5")
        #expect(StatsScanner.shortName("claude-opus-5[1m]") == "Opus 5")
    }

    @Test("Стрик считается по подряд идущим дням")
    func streaks() {
        let now = StatsSlicer.isoDate("2026-07-24")!
        // Три дня подряд вплотную к сегодняшнему: стрик живой.
        let live = StatsScanner.streaks(["2026-07-22", "2026-07-23", "2026-07-24"],
                                        now: now, calendar: cal())
        #expect(live.best == 3)
        #expect(live.current == 3)
        // Разрыв в середине: лучший остаётся, текущий считается с разрыва.
        let broken = StatsScanner.streaks(["2026-07-01", "2026-07-02", "2026-07-03",
                                           "2026-07-23", "2026-07-24"],
                                          now: now, calendar: cal())
        #expect(broken.best == 3)
        #expect(broken.current == 2)
        // Давно не работали: текущий стрик обнуляется, а не висит вечно.
        let stale = StatsScanner.streaks(["2026-07-01", "2026-07-02"], now: now, calendar: cal())
        #expect(stale.best == 2)
        #expect(stale.current == 0)
        #expect(StatsScanner.streaks([], now: now, calendar: cal()) == (0, 0))
    }

    private func sample() -> UsageStats {
        var days: [String: [String: Int]] = [:]
        // 70 дней подряд, чтобы проверить свёртку в недели.
        for i in 0..<70 {
            let date = StatsSlicer.isoDate("2026-07-24")!.addingTimeInterval(-Double(i) * 86400)
            days[StatsSlicer.isoString(date)] = ["Opus 4.8": 1000 + i, "Fable 5": 10]
        }
        days["2026-07-24"] = ["Opus 4.8": 90_000]          // рекордный день
        return UsageStats(days: days, hours: ["21": ["Opus 5": 500], "07": ["Opus 4.8": 100]],
                          requests: ["2026-07-24": 42], transcripts: 7,
                          bestStreak: 70, currentStreak: 70,
                          scannedAt: StatsSlicer.isoDate("2026-07-24")!)
    }

    @Test("Периоды режут нужное число дней")
    func periods() {
        let stats = sample(), now = StatsSlicer.isoDate("2026-07-24")!
        let week = StatsSlicer.slice(stats, period: .week, now: now, calendar: cal())
        #expect(week.columns.count == 7)
        let month = StatsSlicer.slice(stats, period: .month, now: now, calendar: cal())
        #expect(month.columns.count == 30)
        // Сегодня рисуем по часам, иначе это один столбик на весь экран.
        let today = StatsSlicer.slice(stats, period: .today, now: now, calendar: cal())
        #expect(today.columns.count == 2)
        #expect(today.columns.map(\.id) == ["07", "21"])
        #expect(today.title.contains("ЧАС") || today.title.uppercased().contains("HOUR"))
    }

    /// 70 столбиков в панель не влезают, поэтому длинный период сворачивается.
    @Test("Длинный период сворачивается в недели")
    func folding() {
        let stats = sample(), now = StatsSlicer.isoDate("2026-07-24")!
        let all = StatsSlicer.slice(stats, period: .all, now: now, calendar: cal())
        #expect(stats.activeDays == 70)
        #expect(all.columns.count <= StatsSlicer.maxColumns)
        #expect(all.columns.count == 11)
        // Свёртка ничего не теряет: сумма та же, что по дням.
        let byDay = stats.days.values.flatMap { $0.values }.reduce(0, +)
        #expect(all.total == byDay)
    }

    @Test("Модели упорядочены по расходу, суммы сходятся")
    func models() {
        let stats = sample(), now = StatsSlicer.isoDate("2026-07-24")!
        let week = StatsSlicer.slice(stats, period: .week, now: now, calendar: cal())
        #expect(week.models.first == "Opus 4.8")
        #expect(week.models.last == "Fable 5")
        #expect(week.total == week.modelTotals.values.reduce(0, +))
    }

    @Test("Рекордный день находится по сумме за день")
    func busiest() {
        let stats = sample()
        #expect(stats.busiestDay == "2026-07-24")
        #expect(stats.total(of: "2026-07-24") == 90_000)
        #expect(UsageStats.empty.busiestDay == nil)
        #expect(UsageStats.empty.isEmpty)
    }

    @Test("Пустая статистика не роняет нарезку")
    func emptySlice() {
        let now = StatsSlicer.isoDate("2026-07-24")!
        for period in StatsPeriod.allCases {
            let s = StatsSlicer.slice(.empty, period: period, now: now, calendar: cal())
            #expect(s.columns.isEmpty)
            #expect(s.total == 0)
            #expect(s.models.isEmpty)
        }
    }
}

// MARK: - Попап у края экрана

@Suite("Попап не уезжает за экран")
struct PopoverFitTests {

    /// Экран 1440 точек шириной, развёрнутая панель 753.
    private let screen = (min: 0.0, max: 1440.0)

    /// Главный случай: иконка у правого края, развернули статистику,
    /// окно встало правым краем за экраном.
    @Test("Вылезающее окно прижимается к правому краю с отступом")
    func pullsBack() {
        let x = PopoverFit.fittedX(x: 1000, width: 753,
                                   screenMinX: screen.min, screenMaxX: screen.max, margin: 8)
        #expect(abs(x - (1440 - 8 - 753)) < 0.01)
        #expect(x + 753 <= screen.max - 8 + 0.01)
    }

    @Test("Помещается: координату не трогаем")
    func leavesFittingWindow() {
        #expect(PopoverFit.fittedX(x: 300, width: 753,
                                   screenMinX: screen.min, screenMaxX: screen.max) == 300)
        #expect(PopoverFit.fittedX(x: 100, width: 300,
                                   screenMinX: screen.min, screenMaxX: screen.max) == 100)
    }

    @Test("За левый край тоже не пускаем")
    func clampsLeft() {
        #expect(PopoverFit.fittedX(x: -120, width: 300,
                                   screenMinX: screen.min, screenMaxX: screen.max) == 8)
    }

    /// Внешний монитор слева даёт отрицательные координаты, это нормально.
    @Test("Экран с ненулевым началом")
    func offsetScreen() {
        let x = PopoverFit.fittedX(x: -400, width: 753,
                                   screenMinX: -1920, screenMaxX: 0, margin: 8)
        #expect(x + 753 <= -8 + 0.01)
        #expect(x >= -1920 + 8)
    }

    /// Окно шире экрана целиком не влезет: прижимаем к левому краю, чтоб было
    /// видно начало панели, а не её хвост.
    @Test("Окно шире экрана прижимается к левому краю")
    func widerThanScreen() {
        #expect(PopoverFit.fittedX(x: 50, width: 900, screenMinX: 0, screenMaxX: 800) == 8)
    }
}

// MARK: - Кэш статистики claude

@Suite("Чтение stats-cache.json")
struct StatsCacheTests {

    private func cal() -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 3 * 3600)!
        return c
    }

    private func write(_ json: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stats-cache-\(UUID().uuidString).json")
        try json.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Урезанный, но настоящий по форме кусок кэша Claude Code.
    private let sample = """
    {
      "version": 4,
      "lastComputedDate": "2026-07-23",
      "dailyActivity": [
        {"date": "2026-07-22", "messageCount": 2655, "sessionCount": 3},
        {"date": "2026-07-23", "messageCount": 763, "sessionCount": 2}
      ],
      "dailyModelTokens": [
        {"date": "2026-07-22", "tokensByModel": {"claude-opus-4-8": 2222947, "claude-fable-5": 589309}},
        {"date": "2026-07-23", "tokensByModel": {"claude-opus-4-8": 918535}}
      ],
      "modelUsage": {"claude-opus-4-8": {"tokens": 3141482}},
      "totalSessions": 44,
      "firstSessionDate": "2026-05-22T19:05:14.611Z"
    }
    """

    @Test("Кэш разбирается в дни и модели")
    func parses() throws {
        let url = try write(sample)
        defer { try? FileManager.default.removeItem(at: url) }
        let now = StatsSlicer.isoDate("2026-07-23")!
        let stats = try #require(StatsScanner.readCache(url, now: now, calendar: cal()))

        #expect(stats.activeDays == 2)
        #expect(stats.days["2026-07-22"]?["Opus 4.8"] == 2222947)
        #expect(stats.days["2026-07-22"]?["Fable 5"] == 589309)
        #expect(stats.busiestDay == "2026-07-22")
        // Сессии берём из кэша: он помнит и то, чьи транскрипты уже стёрты.
        #expect(stats.transcripts == 44)
        #expect(stats.requests["2026-07-22"] == 2655)
        #expect(stats.currentStreak == 2)
    }

    @Test("Чужой или битый файл не роняет, а отдаёт nil")
    func rejectsGarbage() throws {
        let now = Date()
        for text in ["{}", "не json вовсе", #"{"dailyModelTokens": []}"#,
                     #"{"dailyModelTokens": [{"date": "2026-07-22"}]}"#] {
            let url = try write(text)
            defer { try? FileManager.default.removeItem(at: url) }
            #expect(StatsScanner.readCache(url, now: now, calendar: cal()) == nil,
                    "не должен принять: \(text)")
        }
        // Файла нет вовсе.
        let missing = URL(fileURLWithPath: "/tmp/нет-такого-файла-\(UUID().uuidString).json")
        #expect(StatsScanner.readCache(missing, now: now, calendar: cal()) == nil)
    }

    /// Кэш считается раз в сутки, поэтому сегодняшний день приходит из свежих
    /// транскриптов и должен перекрывать кэшевый, а не складываться с ним.
    @Test("Свежий скан перекрывает кэш за тот же день")
    func freshWins() {
        let now = StatsSlicer.isoDate("2026-07-24")!
        let cached = UsageStats(days: ["2026-07-23": ["Opus 4.8": 100],
                                       "2026-07-24": ["Opus 4.8": 5]],
                                hours: [:], requests: ["2026-07-24": 1], transcripts: 44,
                                bestStreak: 2, currentStreak: 2, scannedAt: now)
        let fresh = UsageStats(days: ["2026-07-24": ["Opus 4.8": 900, "Opus 5": 50]],
                               hours: ["21": ["Opus 5": 50]], requests: ["2026-07-24": 42],
                               transcripts: 3, bestStreak: 1, currentStreak: 1, scannedAt: now)
        let merged = StatsScanner.merge(cached, fresh: fresh, now: now, calendar: cal())

        #expect(merged.days["2026-07-24"]?["Opus 4.8"] == 900)   // не 905
        #expect(merged.days["2026-07-24"]?["Opus 5"] == 50)
        #expect(merged.days["2026-07-23"]?["Opus 4.8"] == 100)   // старое не тронуто
        #expect(merged.requests["2026-07-24"] == 42)
        #expect(merged.hours["21"]?["Opus 5"] == 50)
        #expect(merged.transcripts == 44)
    }
}
