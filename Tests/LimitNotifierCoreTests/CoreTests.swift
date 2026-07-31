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

// MARK: - Вытеснение из строки меню

@Suite("Вытеснение из строки меню")
struct SqueezeWatchTests {

    @Test("Пока рисуют, плашка не нужна")
    func drawnStaysQuiet() {
        var watch = SqueezeWatch()
        #expect(watch.update(drawn: true) == false)
        #expect(watch.update(drawn: true) == false)
    }

    /// Один промах ничего не значит: опрос мог попасть в момент, когда строка
    /// меню ещё перекладывается после смены активного приложения.
    @Test("Одного промаха недостаточно")
    func singleMissIgnored() {
        var watch = SqueezeWatch()
        #expect(watch.update(drawn: false) == false)
    }

    @Test("Два промаха подряд это вытеснение")
    func twoMissesTrigger() {
        var watch = SqueezeWatch()
        #expect(watch.update(drawn: false) == false)
        #expect(watch.update(drawn: false) == true)
    }

    @Test("Удача сбрасывает счётчик")
    func drawnResets() {
        var watch = SqueezeWatch()
        #expect(watch.update(drawn: false) == false)
        #expect(watch.update(drawn: true) == false)
        // Счёт начинается заново, значит одного промаха снова мало.
        #expect(watch.update(drawn: false) == false)
        #expect(watch.update(drawn: false) == true)
    }

    @Test("Порог настраивается")
    func customThreshold() {
        var watch = SqueezeWatch(needed: 1)
        #expect(watch.update(drawn: false) == true)
    }

    /// Полный экран и кино прячут строку меню целиком. Наш элемент там тоже не
    /// нарисован, но это не вытеснение, и лезть поверх фильма не надо.
    @Test("Строку меню спрятали целиком: плашки нет")
    func hiddenBarStaysQuiet() {
        var asked = false
        let wanted = PlaquePlan.wanted(always: false, barShowing: false) {
            asked = true
            return true
        }
        #expect(wanted == false)
        // И счётчик промахов при этом не трогаем: иначе за время фильма он
        // накрутит промахов, и на выходе плашка выскочит на ровном месте.
        #expect(asked == false)
    }

    @Test("Строка меню видна, нас выкинули: плашка нужна")
    func squeezedWithVisibleBar() {
        #expect(PlaquePlan.wanted(always: false, barShowing: true) { true })
        #expect(PlaquePlan.wanted(always: false, barShowing: true) { false } == false)
    }

    /// Ручной режим сильнее всего: человек включил, значит хочет видеть, в том
    /// числе и в полном экране.
    @Test("Включённая руками плашка висит всегда")
    func alwaysWins() {
        var asked = false
        #expect(PlaquePlan.wanted(always: true, barShowing: false) { asked = true; return false })
        #expect(asked == false)
    }

    /// Вытеснение не разовое событие, а состояние: пока места нет, плашка висит.
    @Test("Пока места нет, состояние держится")
    func staysSqueezed() {
        var watch = SqueezeWatch()
        _ = watch.update(drawn: false)
        #expect(watch.update(drawn: false) == true)
        #expect(watch.update(drawn: false) == true)
        #expect(watch.update(drawn: true) == false)
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

// MARK: - Полный объём и склейка с кэшем

@Suite("Токены с кэшем")
struct LifetimeTokensTests {

    private func cal() -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 3 * 3600)!
        return c
    }

    /// Кэш claude отдаёт дневные цифры без кэш-токенов, а в modelUsage лежит
    /// полный объём. Разница на живых данных была 8.0b против 36.9m.
    @Test("Полный объём берётся из modelUsage, включая кэшевые токены")
    func lifetime() throws {
        let json = """
        {
          "lastComputedDate": "2026-07-23",
          "dailyModelTokens": [
            {"date": "2026-07-23", "tokensByModel": {"claude-opus-4-8": 1000}}
          ],
          "modelUsage": {
            "claude-opus-4-8": {"inputTokens": 100, "outputTokens": 900,
                                "cacheReadInputTokens": 500000, "cacheCreationInputTokens": 9000},
            "claude-fable-5": {"inputTokens": 0, "outputTokens": 0,
                               "cacheReadInputTokens": 90000, "cacheCreationInputTokens": 0}
          },
          "totalSessions": 7
        }
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lt-\(UUID().uuidString).json")
        try json.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let now = StatsSlicer.isoDate("2026-07-24")!
        let stats = try #require(StatsScanner.readCache(url, now: now, calendar: cal()))
        #expect(stats.lifetimeTokens == 100 + 900 + 500_000 + 9_000 + 90_000)
        // Дневная цифра осталась без кэша, как у claude.
        #expect(stats.days["2026-07-23"]?["Opus 4.8"] == 1000)
        #expect(stats.cacheUpTo == "2026-07-23")
    }

    /// Регресс: свежий скан читает только недавно менявшиеся файлы, поэтому за
    /// уже посчитанный кэшем день видит лишь часть работы. Затирать им кэш
    /// нельзя, иначе цифра за этот день падает.
    @Test("Свежий скан не затирает дни, которые кэш уже посчитал")
    func freshDoesNotClobberCountedDays() {
        let now = StatsSlicer.isoDate("2026-07-24")!
        let cached = UsageStats(days: ["2026-07-23": ["Opus 4.8": 5_000_000]],
                                hours: [:], requests: [:], transcripts: 44,
                                bestStreak: 1, currentStreak: 1, scannedAt: now,
                                lifetimeTokens: 8_000_000_000, cacheUpTo: "2026-07-23")
        // Скан увидел лишь остаток работы за 23-е плюс полный день 24-го.
        let fresh = UsageStats(days: ["2026-07-23": ["Opus 4.8": 12_000],
                                      "2026-07-24": ["Opus 5": 300_000]],
                               hours: ["21": ["Opus 5": 300_000]], requests: ["2026-07-24": 42],
                               transcripts: 3, bestStreak: 1, currentStreak: 1, scannedAt: now)
        let merged = StatsScanner.merge(cached, fresh: fresh, now: now, calendar: cal())

        #expect(merged.days["2026-07-23"]?["Opus 4.8"] == 5_000_000)   // кэш не тронут
        #expect(merged.days["2026-07-24"]?["Opus 5"] == 300_000)       // новый день добавлен
        #expect(merged.lifetimeTokens == 8_000_000_000)
        #expect(merged.cacheUpTo == "2026-07-23")
        #expect(merged.currentStreak == 2)
    }

    /// Регресс: "за всё время" неделю показывало одну и ту же сумму.
    ///
    /// Кэш claude пересчитывается не по расписанию, а когда он сам считает свою
    /// статистику. Пока человек туда не заходит, кэш стоит, и итоги за всё время
    /// брались из него как есть. На живых данных за неделю простоя потерялось
    /// 3400 долларов и четыре миллиарда токенов.
    @Test("Дни после кэша досчитываются в итоги за всё время")
    func tailAddsToLifetime() {
        let now = StatsSlicer.isoDate("2026-07-31")!
        let cached = UsageStats(days: ["2026-07-23": ["Opus 4.8": 5_000_000]],
                                hours: [:], requests: [:], transcripts: 44,
                                bestStreak: 1, currentStreak: 1, scannedAt: now,
                                lifetimeTokens: 8_000_000_000, cacheUpTo: "2026-07-23",
                                lifetimeCost: ["Opus 4.8": 8000])
        let fresh = UsageStats(
            days: ["2026-07-24": ["Opus 5": 300_000]],
            hours: [:], requests: [:], transcripts: 3,
            bestStreak: 1, currentStreak: 1, scannedAt: now,
            totalsByDay: [
                // День, который кэш уже посчитал: брать нельзя, удвоится.
                "2026-07-23": .init(cost: ["Opus 4.8": 999], tokens: 777_000_000),
                "2026-07-24": .init(cost: ["Opus 5": 100, "Opus 4.8": 50], tokens: 2_000_000_000),
            ])
        let merged = StatsScanner.merge(cached, fresh: fresh, now: now, calendar: cal())

        #expect(merged.lifetimeTokens == 8_000_000_000 + 2_000_000_000)
        #expect(merged.lifetimeCost["Opus 4.8"] == 8050)   // 8000 из кэша плюс 50 за хвост
        #expect(merged.lifetimeCost["Opus 5"] == 100)      // модели, которой в кэше не было
        #expect(merged.lifetimeCostTotal == 8150)
    }

    /// Регресс: свой счёт транскриптов раздут субагентами, у каждого файл свой.
    /// На живых данных выходило 211 против 79 у claude.
    @Test("Сессии показываем те же, что claude")
    func sessionsComeFromCache() {
        let now = StatsSlicer.isoDate("2026-07-31")!
        let cached = UsageStats(days: [:], hours: [:], requests: [:], transcripts: 79,
                                bestStreak: 0, currentStreak: 0, scannedAt: now,
                                cacheUpTo: "2026-07-23")
        let fresh = UsageStats(days: [:], hours: [:], requests: [:], transcripts: 211,
                               bestStreak: 0, currentStreak: 0, scannedAt: now)
        #expect(StatsScanner.merge(cached, fresh: fresh, now: now, calendar: cal())
                    .transcripts == 79)

        // Кэша нет, значит показывать нечего кроме своего счёта.
        let empty = UsageStats(days: [:], hours: [:], requests: [:], transcripts: 0,
                               bestStreak: 0, currentStreak: 0, scannedAt: now, cacheUpTo: nil)
        #expect(StatsScanner.merge(empty, fresh: fresh, now: now, calendar: cal())
                    .transcripts == 211)
    }

    /// Без кэша считаем всё сами, и деньги в том числе: иначе запасной путь
    /// показывал бы нули.
    @Test("Полный скан сам считает итоги за всё время")
    func scanFillsLifetime() {
        let now = StatsSlicer.isoDate("2026-07-31")!
        let cached = UsageStats(days: [:], hours: [:], requests: [:], transcripts: 0,
                                bestStreak: 0, currentStreak: 0, scannedAt: now,
                                cacheUpTo: nil)
        let fresh = UsageStats(days: ["2026-07-30": ["Opus 5": 10]],
                               hours: [:], requests: [:], transcripts: 1,
                               bestStreak: 1, currentStreak: 1, scannedAt: now,
                               totalsByDay: ["2026-07-30": .init(cost: ["Opus 5": 12], tokens: 90)])
        let merged = StatsScanner.merge(cached, fresh: fresh, now: now, calendar: cal())
        #expect(merged.lifetimeTokens == 90)
        #expect(merged.lifetimeCostTotal == 12)
    }

    @Test("Без даты в кэше свежие данные применяются ко всем дням")
    func noCacheDateMergesAll() {
        let now = StatsSlicer.isoDate("2026-07-24")!
        let cached = UsageStats(days: ["2026-07-23": ["Opus 4.8": 10]], hours: [:], requests: [:],
                               transcripts: 1, bestStreak: 1, currentStreak: 1, scannedAt: now,
                               lifetimeTokens: 0, cacheUpTo: nil)
        let fresh = UsageStats(days: ["2026-07-23": ["Opus 4.8": 999]], hours: [:], requests: [:],
                              transcripts: 1, bestStreak: 1, currentStreak: 1, scannedAt: now)
        let merged = StatsScanner.merge(cached, fresh: fresh, now: now, calendar: cal())
        #expect(merged.days["2026-07-23"]?["Opus 4.8"] == 999)
    }

    @Test("Форматирование больших чисел")
    func formatting() {
        #expect(Fmt.tokens(8_021_000_000) == "8.0b")
        #expect(Fmt.tokens(999_999_999) == "1000.0m")
        #expect(Fmt.tokens(36_900_000) == "36.9m")
        #expect(Fmt.tokens(1500) == "2k")
        #expect(Fmt.tokens(42) == "42")
    }
}

// MARK: - Будильник мака

@Suite("Расписание пробуждения")
struct WakeScheduleTests {

    /// Регресс: команду считали от якоря как есть, и мак будился к концу окна.
    /// Якорь 08:45 значит "к 8:45 окно уже закрылось", пинг за пять часов до,
    /// то есть 03:45, а будить надо на две минуты раньше пинга.
    @Test("Команда считается от якоря минус окно минус две минуты")
    func command() {
        #expect(WakeSchedule.command(anchorHour: 8, anchorMinute: 45)
                == "sudo pmset repeat wakeorpoweron MTWRFSU 03:43:00")
        #expect(WakeSchedule.command(anchorHour: 9, anchorMinute: 0)
                == "sudo pmset repeat wakeorpoweron MTWRFSU 03:58:00")
        // Через полночь уезжаем на прошлые сутки, а не в отрицательное время.
        #expect(WakeSchedule.command(anchorHour: 3, anchorMinute: 0)
                == "sudo pmset repeat wakeorpoweron MTWRFSU 21:58:00")
        #expect(WakeSchedule.command(anchorHour: 0, anchorMinute: 0)
                == "sudo pmset repeat wakeorpoweron MTWRFSU 18:58:00")
    }

    /// Настоящий вывод pmset -g sched с этой машины.
    @Test("Разбор pmset -g sched")
    func parse() {
        let real = """
        Repeating power events:
          wakepoweron at 3:28AM every day
        Scheduled power events:
         [0]  wake at 07/24/2026 12:41:36 by 'com.apple.alarm.user-invisible'
        """
        #expect(WakeSchedule.scheduled(in: real) == "03:28")
        #expect(WakeSchedule.scheduled(in: "wakepoweron at 3:43PM every day") == "15:43")
        #expect(WakeSchedule.scheduled(in: "wakepoweron at 12:05AM every day") == "00:05")
        #expect(WakeSchedule.scheduled(in: "wakepoweron at 12:05PM every day") == "12:05")
        // Расписания нет: только разовые события или пусто.
        #expect(WakeSchedule.scheduled(in: "Scheduled power events:\n [0]  wake at 07/24") == nil)
        #expect(WakeSchedule.scheduled(in: "") == nil)
    }
}

// MARK: - Недельный остаток в строке меню

@Suite("Остаток недельного лимита")
struct WeeklyTimeTests {

    private let now = utc(2026, 7, 25, 12, 0)

    /// От суток и выше только дни, ниже только часы: на недельном горизонте
    /// минуты в строке меню только мельтешат.
    @Test("Крупные единицы: дни или часы")
    func coarse() {
        #expect(StatusBar.coarse(now.addingTimeInterval(4 * 86400 + 6 * 3600), from: now) == "4d")
        #expect(StatusBar.coarse(now.addingTimeInterval(86400), from: now) == "1d")
        // Чуть меньше суток это уже часы, а не "0d".
        #expect(StatusBar.coarse(now.addingTimeInterval(86400 - 60), from: now) == "23h")
        #expect(StatusBar.coarse(now.addingTimeInterval(11 * 3600 + 40 * 60), from: now) == "11h")
        #expect(StatusBar.coarse(now.addingTimeInterval(30 * 60), from: now) == "0h")
        // Прошедшее и пустое дают прочерк, а не отрицательное время.
        #expect(StatusBar.coarse(now.addingTimeInterval(-3600), from: now) == "--")
        #expect(StatusBar.coarse(nil, from: now) == "--")
    }

    /// Недельный остаток берётся у общего недельного лимита, не у скоупного.
    @Test("В строке меню появляется недельный остаток")
    func inStatusLine() throws {
        let snap = try #require(UsageClient.parse(realOutput, now: utc(2026, 7, 22, 12, 0)))
        let parts = StatusBar.parts(from: snap, now: utc(2026, 7, 22, 12, 0))
        // Эталон: недельный сбрасывается 24 июля в 9pm Рига, это через 2 суток.
        #expect(parts.weeklyTime == "2d")
        #expect(parts.time == "7h10")
        #expect(parts.session == "26")
        #expect(parts.weekly == "83")
    }

    @Test("Без снимка недельный остаток тоже прочерк")
    func noSnapshot() {
        #expect(StatusBar.parts(from: nil, now: now).weeklyTime == "--")
    }
}

// MARK: - Лента в строке меню

@Suite("Движение ленты")
struct MarqueeTests {

    private let m = Marquee()   // 90 точек в секунду, разгон 0.7 с, два проезда

    /// Профиль трапеция: разгон, ровный ход, торможение. Путь и время должны
    /// сходиться, иначе на стыках будет видна ступенька скорости.
    @Test("Края пути: ноль в начале, полный путь в конце")
    func endpoints() {
        let period = 200.0
        let total = m.distance(period: period)
        #expect(total == 400)
        #expect(m.offset(at: 0, period: period) == 0)
        #expect(m.offset(at: -1, period: period) == 0)
        let full = m.duration(period: period)
        #expect(abs(m.offset(at: full, period: period) - total) < 0.001)
        #expect(abs(m.offset(at: full + 5, period: period) - total) < 0.001)
    }

    @Test("Лента едет только вперёд и без рывков")
    func monotonicAndSmooth() {
        let period = 240.0
        let full = m.duration(period: period)
        var previous = 0.0
        var maxJump = 0.0
        // Шаг мельче кадра, чтобы поймать разрыв на стыке участков.
        for i in 1...2000 {
            let t = full * Double(i) / 2000
            let x = m.offset(at: t, period: period)
            #expect(x >= previous - 0.0001, "лента поехала назад в \(t)")
            maxJump = max(maxJump, x - previous)
            previous = x
        }
        // За такой шаг лента не может пройти больше, чем скорость помножить на шаг.
        #expect(maxJump < m.speed * (full / 2000) * 1.05)
    }

    /// В середине прогона лента должна идти ровно на рабочей скорости.
    @Test("На ровном участке скорость та самая")
    func cruiseSpeed() {
        let period = 300.0
        let full = m.duration(period: period)
        let mid = full / 2, dt = 0.05
        let v = (m.offset(at: mid + dt, period: period)
                 - m.offset(at: mid - dt, period: period)) / (dt * 2)
        #expect(abs(v - m.speed) < 0.5)
    }

    /// А на старте и на финише заметно медленнее: это и есть доводчик.
    @Test("Старт и финиш мягкие")
    func softEnds() {
        let period = 300.0
        let full = m.duration(period: period)
        let dt = 0.05
        let vStart = m.offset(at: dt, period: period) / dt
        let vEnd = (m.offset(at: full, period: period)
                    - m.offset(at: full - dt, period: period)) / dt
        #expect(vStart < m.speed * 0.25, "старт слишком резкий")
        #expect(vEnd < m.speed * 0.25, "финиш слишком резкий")
    }

    /// Разгон занимает ровно speed*ramp/2 точек, иначе стык не сойдётся.
    @Test("Длительность складывается из разгона, ровного хода и торможения")
    func durationMath() {
        let period = 500.0
        let total = m.distance(period: period)
        let cruise = total - m.rampDistance * 2
        #expect(abs(m.duration(period: period) - (m.ramp * 2 + cruise / m.speed)) < 0.001)
        // Пауза считается по одному проезду, а не по всей поездке.
        #expect(abs(m.hold(period: period)
                    - m.duration(period: period) / 2 * 4) < 0.001)
    }

    /// Короткая лента: разогнаться не успеваем, профиль треугольный.
    @Test("Очень короткий путь не ломает математику")
    func triangularProfile() {
        let period = 8.0
        let full = m.duration(period: period)
        #expect(full > 0)
        #expect(abs(m.offset(at: full, period: period) - m.distance(period: period)) < 0.001)
        #expect(m.offset(at: full / 2, period: period) > 0)
    }

    @Test("Нулевой период не роняет")
    func zeroPeriod() {
        #expect(m.duration(period: 0) == 0)
        #expect(m.offset(at: 1, period: 0) == 0)
    }
}

// MARK: - События от хука

@Suite("События готовности")
struct ReadyLogTests {

    private let now = utc(2026, 7, 27, 12, 0)

    @Test("Разбор того, что пишет хук")
    func parse() {
        let text = """
        {"hook_event_name":"Stop","session_id":"abc","cwd":"/Users/k/PycharmProjects/drpmonitor"}
        {"hook_event_name":"Stop","session_id":"def","cwd":"/Users/k/PycharmProjects/auratg"}
        """
        let events = ReadyLog.parse(text, now: now)
        #expect(events.count == 2)
        #expect(events.map(\.project) == ["drpmonitor", "auratg"])
        #expect(events[0].sessionId == "abc")
    }

    /// Приложение опрашивает лимиты через сам claude, и это тоже даёт Stop.
    /// Если не отфильтровать, оно будет звать само себя каждые десять минут.
    @Test("Свой собственный опрос лимитов не считается событием")
    func ignoresOwnProbe() {
        let text = #"{"cwd":"/Users/k/Library/Application Support/LimitNotifier/probe"}"#
        #expect(ReadyLog.parse(text, now: now).isEmpty)
        #expect(ReadyLog.isOurProbe(cwd: "/Users/k/Library/Application Support/LimitNotifier/probe"))
        #expect(ReadyLog.isOurProbe(cwd: "/Users/k/PycharmProjects/drpmonitor") == false)
    }

    @Test("Мусор в файле пропускается, а не роняет разбор")
    func skipsGarbage() {
        let text = """
        не json совсем
        {"cwd":""}
        {"нет":"cwd"}
        {"cwd":"/tmp/real"}
        """
        let events = ReadyLog.parse(text, now: now)
        #expect(events.map(\.project) == ["real"])
    }

    @Test("Чтение опустошает файл, чтобы он не рос")
    func drainEmptiesFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ready-\(UUID().uuidString).jsonl")
        try #"{"cwd":"/tmp/one"}"#.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(ReadyLog.drain(at: url, now: now).map(\.project) == ["one"])
        // Второй заход уже ничего не находит.
        #expect(ReadyLog.drain(at: url, now: now).isEmpty)
    }
}

// MARK: - Установка хука в чужой файл настроек

@Suite("Дочитывание транскриптов")
struct ScanStateTests {

    private func cal() -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 3 * 3600)!
        return c
    }

    /// Одна строка транскрипта: столько-то токенов в такой-то день.
    private func line(day: String, tokens: Int, cacheRead: Int = 0) -> String {
        """
        {"timestamp":"\(day)T12:00:00.000Z","message":{"model":"claude-opus-4-8",\
        "usage":{"input_tokens":\(tokens),"output_tokens":0,\
        "cache_read_input_tokens":\(cacheRead),"cache_creation_input_tokens":0}}}
        """
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("scan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Главное свойство: дописали файл, прочли только дописанное, а посчиталось
    /// всё. Ради этого всё и затевалось, иначе каждое обновление перечитывает
    /// сотни мегабайт.
    @Test("Дописанное дочитывается, прежнее не считается заново")
    func appendReadsOnlyTail() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("a.jsonl")
        let now = StatsSlicer.isoDate("2026-07-31")!

        try (line(day: "2026-07-30", tokens: 100) + "\n").write(to: file, atomically: true,
                                                                encoding: .utf8)
        var state = ScanState()
        state.advance(root: root, now: now, calendar: cal())
        #expect(state.days["2026-07-30"]?["Opus 4.8"] == 100)
        let after = state.offsets["a.jsonl"]

        // Дописываем вторую строку и просим дочитать.
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line(day: "2026-07-30", tokens: 7) + "\n").utf8))
        try handle.close()

        state.advance(root: root, now: now, calendar: cal())
        #expect(state.days["2026-07-30"]?["Opus 4.8"] == 107)      // сложилось, а не удвоилось
        #expect((state.offsets["a.jsonl"] ?? 0) > (after ?? 0))     // позиция сдвинулась
    }

    /// Повторный проход без изменений не должен ничего менять: это и есть
    /// защита от двойного счёта.
    @Test("Проход по неизменившемуся файлу ничего не добавляет")
    func idempotent() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try (line(day: "2026-07-30", tokens: 50) + "\n")
            .write(to: root.appendingPathComponent("a.jsonl"), atomically: true, encoding: .utf8)
        let now = StatsSlicer.isoDate("2026-07-31")!

        var state = ScanState()
        state.advance(root: root, now: now, calendar: cal())
        state.advance(root: root, now: now, calendar: cal())
        state.advance(root: root, now: now, calendar: cal())
        #expect(state.days["2026-07-30"]?["Opus 4.8"] == 50)
        #expect(state.files == 1)
    }

    /// Недописанная строка в счёт не идёт: файл могут дописывать прямо сейчас.
    /// В следующий раз она прочитается целиком.
    @Test("Обрывок строки ждёт своего перевода строки")
    func partialLineWaits() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("a.jsonl")
        let full = line(day: "2026-07-30", tokens: 100)
        let now = StatsSlicer.isoDate("2026-07-31")!

        // Половина строки, без перевода строки в конце.
        try String(full.prefix(full.count / 2)).write(to: file, atomically: true, encoding: .utf8)
        var state = ScanState()
        state.advance(root: root, now: now, calendar: cal())
        #expect(state.days.isEmpty)
        #expect(state.offsets["a.jsonl"] == 0)

        try (full + "\n").write(to: file, atomically: true, encoding: .utf8)
        state.advance(root: root, now: now, calendar: cal())
        #expect(state.days["2026-07-30"]?["Opus 4.8"] == 100)
    }

    /// Файл стал короче, значит его переписали, и накопленному по нему верить
    /// нельзя. Считаем всё заново.
    @Test("Подрезанный файл заставляет пересчитать всё")
    func truncationRebuilds() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("a.jsonl")
        let now = StatsSlicer.isoDate("2026-07-31")!

        var text = ""
        for _ in 0..<5 { text += line(day: "2026-07-30", tokens: 100) + "\n" }
        try text.write(to: file, atomically: true, encoding: .utf8)
        var state = ScanState()
        state.advance(root: root, now: now, calendar: cal())
        #expect(state.days["2026-07-30"]?["Opus 4.8"] == 500)

        try (line(day: "2026-07-30", tokens: 100) + "\n").write(to: file, atomically: true,
                                                                encoding: .utf8)
        state.advance(root: root, now: now, calendar: cal())
        #expect(state.days["2026-07-30"]?["Opus 4.8"] == 100)   // а не 600
    }

    /// Удалённый транскрипт остаётся посчитанным: claude подчищает старые
    /// файлы, и терять вместе с ними историю нельзя.
    @Test("Удаление файла не стирает уже посчитанное")
    func deletedFileKeepsItsNumbers() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("a.jsonl")
        let now = StatsSlicer.isoDate("2026-07-31")!

        try (line(day: "2026-07-30", tokens: 100) + "\n").write(to: file, atomically: true,
                                                                encoding: .utf8)
        var state = ScanState()
        state.advance(root: root, now: now, calendar: cal())
        try FileManager.default.removeItem(at: file)
        state.advance(root: root, now: now, calendar: cal())

        #expect(state.days["2026-07-30"]?["Opus 4.8"] == 100)
        #expect(state.offsets.isEmpty)   // позиция ушла вместе с файлом
    }

    @Test("Деньги за сегодня и за неделю из накопленных дней")
    func spendFromTotals() {
        let now = StatsSlicer.isoDate("2026-07-31")!
        var state = ScanState()
        state.totals["2026-07-31"] = .init(cost: ["Opus 4.8": 10, "Opus 5": 5], tokens: 1)
        state.totals["2026-07-28"] = .init(cost: ["Opus 4.8": 100], tokens: 1)
        state.totals["2026-07-01"] = .init(cost: ["Opus 4.8": 999], tokens: 1)   // вне недели

        let spend = state.spend(now: now, calendar: cal())
        #expect(spend.today == 15)
        #expect(spend.week == 115)
    }

    @Test("Часы отдаются только сегодняшние")
    func hoursAreTodayOnly() {
        let now = StatsSlicer.isoDate("2026-07-31")!
        var state = ScanState()
        state.hours["2026-07-31 14"] = ["Opus 4.8": 10]
        state.hours["2026-07-30 14"] = ["Opus 4.8": 99]
        let stats = state.stats(now: now, calendar: cal())
        #expect(stats.hours["14"]?["Opus 4.8"] == 10)
        #expect(stats.hours.count == 1)
    }

    @Test("Состояние переживает запись и чтение")
    func roundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("state-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        var state = ScanState()
        state.offsets["/a.jsonl"] = 42
        state.days["2026-07-30"] = ["Opus 4.8": 7]
        state.totals["2026-07-30"] = .init(cost: ["Opus 4.8": 1.5], tokens: 9)
        state.files = 1
        state.write(to: url)

        let back = try #require(ScanState.read(url))
        #expect(back.offsets["/a.jsonl"] == 42)
        #expect(back.days["2026-07-30"]?["Opus 4.8"] == 7)
        #expect(back.totals["2026-07-30"]?.tokens == 9)
        #expect(back.files == 1)
    }
}

@Suite("Папка проекта и вложенность")
struct ProjectPathTests {

    @Test("Сама папка накрывает себя")
    func sameFolder() {
        #expect(ProjectPath.covers(folder: "/work/app", path: "/work/app"))
        // Хвостовой слэш в локах встречается, и он ничего не меняет.
        #expect(ProjectPath.covers(folder: "/work/app/", path: "/work/app"))
    }

    /// Ради этого всё и затевалось: claude запускают в подпапке, а редактор
    /// держит корень проекта.
    @Test("Родительская папка накрывает вложенную")
    func nested() {
        #expect(ProjectPath.covers(folder: "/Users/k/PycharmProjects/100memesbot",
                                   path: "/Users/k/PycharmProjects/100memesbot/Reps"))
        #expect(ProjectPath.covers(folder: "/work", path: "/work/a/b/c"))
    }

    /// Сравнение по границе сегмента, иначе соседний проект с похожим именем
    /// сойдёт за родителя, и мы поднимем чужое окно.
    @Test("Похожее имя рядом не считается")
    func neighbourNotCovered() {
        #expect(ProjectPath.covers(folder: "/work/app", path: "/work/app-old") == false)
        #expect(ProjectPath.covers(folder: "/work/app", path: "/work/application") == false)
    }

    @Test("Вложенная папка не накрывает родителя")
    func childDoesNotCoverParent() {
        #expect(ProjectPath.covers(folder: "/work/app/sub", path: "/work/app") == false)
    }

    @Test("Корень накрывает всё")
    func rootCoversEverything() {
        #expect(ProjectPath.covers(folder: "/", path: "/work/app"))
    }
}

@Suite("Хук в настройках claude")
struct HookInstallerTests {

    private let cmd = "/Users/k/Library/Application Support/LimitNotifier/on-stop.sh"

    /// Главное требование: чужие настройки и чужие хуки остаются целыми.
    @Test("Свой хук добавляется, чужое не трогается")
    func keepsOtherSettings() {
        let before: [String: Any] = [
            "model": "opus",
            "hooks": [
                "Stop": [["hooks": [["type": "command", "command": "/чужой/скрипт.sh"]]]],
                "PreToolUse": [["matcher": "Bash",
                                "hooks": [["type": "command", "command": "/чужой/bash.sh"]]]],
            ],
        ]
        let after = HookInstaller.settings(byInstallingInto: before, command: cmd)

        #expect(after["model"] as? String == "opus")
        let hooks = after["hooks"] as? [String: Any]
        #expect((hooks?["PreToolUse"] as? [[String: Any]])?.count == 1)
        let stop = hooks?["Stop"] as? [[String: Any]] ?? []
        #expect(stop.count == 2, "чужой хук Stop должен остаться рядом с нашим")
        #expect(HookInstaller.installed(in: after, command: cmd))
    }

    @Test("Повторная установка не дублирует хук")
    func idempotent() {
        var root: [String: Any] = [:]
        root = HookInstaller.settings(byInstallingInto: root, command: cmd)
        root = HookInstaller.settings(byInstallingInto: root, command: cmd)
        let stop = (root["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]] ?? []
        #expect(stop.count == 1)
    }

    @Test("Удаляется только свой хук")
    func removesOnlyOurs() {
        var root: [String: Any] = [
            "hooks": ["Stop": [["hooks": [["type": "command", "command": "/чужой/скрипт.sh"]]]]],
        ]
        root = HookInstaller.settings(byInstallingInto: root, command: cmd)
        root = HookInstaller.settings(byRemovingFrom: root, command: cmd)

        let stop = (root["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]] ?? []
        #expect(stop.count == 1)
        #expect(HookInstaller.installed(in: root, command: cmd) == false)
        let handlers = stop[0]["hooks"] as? [[String: Any]] ?? []
        #expect(handlers.first?["command"] as? String == "/чужой/скрипт.sh")
    }

    /// Если своих хуков больше нет, пустых разделов оставлять не надо.
    @Test("После удаления пустые разделы подчищаются")
    func cleansUpEmpty() {
        var root: [String: Any] = ["model": "opus"]
        root = HookInstaller.settings(byInstallingInto: root, command: cmd)
        root = HookInstaller.settings(byRemovingFrom: root, command: cmd)
        #expect(root["hooks"] == nil)
        #expect(root["model"] as? String == "opus")
    }

    @Test("Скрипт не блокирует claude и дописывает в наш файл")
    func scriptShape() {
        let s = HookInstaller.script(logPath: "/tmp/ready.jsonl")
        #expect(s.hasPrefix("#!/bin/bash"))
        #expect(s.contains(">> \"/tmp/ready.jsonl\""))
        #expect(s.contains("exit 0"))
    }
}

// MARK: - Ожидание тишины перед зовом

@Suite("Тишина перед зовом")
struct QuietTests {

    private let at = utc(2026, 7, 27, 12, 0)
    private func event(_ transcript: String = "/tmp/t.jsonl") -> ReadyEvent {
        ReadyEvent(cwd: "/Users/k/PycharmProjects/drpmonitor", sessionId: "s",
                   transcript: transcript, at: at)
    }

    /// Главный случай: claude отчитался о конце ответа, но его разбудила
    /// фоновая задача и он продолжил. Такой Stop звать не должен.
    @Test("Работа продолжилась: не зовём")
    func resumed() {
        let v = Quiet.verdict(event: event(), now: at.addingTimeInterval(30),
                             transcriptChangedAt: at.addingTimeInterval(10))
        #expect(v == .resumed)
    }

    @Test("Тишины мало: ждём дальше")
    func waiting() {
        let v = Quiet.verdict(event: event(), now: at.addingTimeInterval(5),
                             transcriptChangedAt: at)
        #expect(v == .waiting)
    }

    @Test("Тишина выдержана: зовём")
    func call() {
        let v = Quiet.verdict(event: event(), now: at.addingTimeInterval(Quiet.delay),
                             transcriptChangedAt: at)
        #expect(v == .call)
    }

    /// Сам Stop тоже попадает в транскрипт, и запись оказывается на доли
    /// секунды позже события. Это не повод считать, что работа продолжилась.
    @Test("Запись самого Stop не считается продолжением")
    func ownRecordIgnored() {
        let v = Quiet.verdict(event: event(), now: at.addingTimeInterval(Quiet.delay),
                             transcriptChangedAt: at.addingTimeInterval(0.4))
        #expect(v == .call)
    }

    @Test("Без транскрипта решаем только по времени")
    func noTranscript() {
        #expect(Quiet.verdict(event: event(""), now: at.addingTimeInterval(1),
                              transcriptChangedAt: nil) == .waiting)
        #expect(Quiet.verdict(event: event(""), now: at.addingTimeInterval(Quiet.delay + 1),
                              transcriptChangedAt: nil) == .call)
    }

    @Test("Транскрипт в событии разбирается")
    func parsesTranscript() {
        let text = #"{"cwd":"/tmp/proj","session_id":"a","transcript_path":"/tmp/a.jsonl"}"#
        let events = ReadyLog.parse(text, now: at)
        #expect(events.first?.transcript == "/tmp/a.jsonl")
    }
}

// MARK: - Свои же запуски claude

@Suite("Не зовём сами себя")
struct OwnRunsTests {

    /// Ночной keep-alive запускался без рабочей папки, и хук присылал событие
    /// с проектом "/". Строка меню звала на собственный будильник в четыре утра.
    @Test("Запуск из корня не считается проектом")
    func rootIsNotProject() {
        #expect(ReadyLog.isOurProbe(cwd: "/"))
        #expect(ReadyLog.parse(#"{"cwd":"/"}"#).isEmpty)
        // Настоящие проекты по-прежнему проходят.
        #expect(ReadyLog.isOurProbe(cwd: "/Users/k/PycharmProjects/drpmonitor") == false)
    }

    @Test("Опрос лимитов тоже не считается")
    func probeIsNotProject() {
        #expect(ReadyLog.isOurProbe(
            cwd: "/Users/k/Library/Application Support/LimitNotifier/probe"))
    }
}
