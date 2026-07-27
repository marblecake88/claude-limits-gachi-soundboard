import Foundation

/// Ошибка пинга это просто готовая строка для лога и панели, свой тип тут лишний.
/// Нужно только чтоб String пролез в Result.
extension String: @retroactive Error {}

// MARK: - Математика якоря

/// Дневная цепочка пингов (base + 5h, base + 10h, ...) сознательно не сделана.
/// Смысл есть только у утреннего пинга: пинг не перезапускает уже идущее окно,
/// а если окно не идёт, значит ты сейчас и не работаешь, и выравнивать нечего.
/// Если цепочка когда-нибудь понадобится, она сводится к перебору base + k*5h
/// до следующего base, форма для этого уже готова: base считается отдельно,
/// а resetAfter даёт конец окна для любого момента пинга.
public enum Anchor {
    /// Длина окна. Одна на весь файл, чтоб не разъезжалась.
    public static let window: TimeInterval = 5 * 3600

    /// Момент следующего пинга: ближайший в будущем (anchor - 5 часов).
    ///
    /// Якорь 09:00 даёт пинг в 04:00. Якорь 03:00 даёт 22:00, то есть время
    /// предыдущих суток, и тогда ближайшее вхождение может быть ещё сегодня.
    /// Считаем по компонентам календаря, а не прибавлением 86400 секунд, иначе
    /// переход на летнее время сдвинет время по стенным часам.
    public static func nextPing(anchorHour: Int, anchorMinute: Int,
                                from now: Date, calendar: Calendar = .current) -> Date {
        // Отматываем пять часов назад по циферблату, с переходом через полночь.
        let baseHour = ((anchorHour - 5) % 24 + 24) % 24
        var match = DateComponents()
        match.hour = baseHour
        match.minute = ((anchorMinute % 60) + 60) % 60
        match.second = 0
        // .nextTime: если ровно этого времени в сутках нет (весенний перевод
        // часов), берём ближайшее следующее, а не пропускаем день целиком.
        let next = calendar.nextDate(after: now, matching: match, matchingPolicy: .nextTime)
        // Страховка. На валидных компонентах nextDate не возвращает nil.
        return next ?? now.addingTimeInterval(24 * 3600)
    }

    /// Во сколько сбросится окно, если пингануть в pingTime.
    public static func resetAfter(ping pingTime: Date) -> Date {
        pingTime.addingTimeInterval(window)
    }
}

// MARK: - Пинг через claude CLI

public enum Pinger {
    /// Дёргает claude -p дешёвой моделью. Возвращает текст или текст ошибки.
    ///
    /// Haiku потому что 5-часовое окно общее для всех моделей, платить по
    /// ставкам Opus только ради открытия окна незачем.
    public static func ping(claudePath: String, timeout: TimeInterval = 60) -> Result<String, String> {
        // Настоящий запрос к модели, а не /usage: тот стоит ноль токенов и
        // именно поэтому окна НЕ открывает. Нам нужно окно, значит нужен
        // реальный вызов, и haiku тут самый дешёвый.
        //
        // Пока идём, держим мак бодрым: после пробуждения по pmset система
        // норовит уснуть обратно, а пинг занимает несколько секунд.
        let awake = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "keep-alive ping")
        defer { ProcessInfo.processInfo.endActivity(awake) }

        let result = Proc.run(claudePath, ["-p", "2+2", "--model", "haiku"], timeout: timeout)
        switch result {
        case .launchFailed(let message):
            return .failure("не смог запустить \(claudePath): \(message)")
        case .timedOut:
            return .failure("пинг не уложился в \(Int(timeout)) с, процесс убит")
        case .finished(let status, let out, let err):
            let text = out.trimmingCharacters(in: .whitespacesAndNewlines)
            guard status == 0 else {
                let detail = err.trimmingCharacters(in: .whitespacesAndNewlines)
                return .failure("claude вернул код \(status): \(detail.isEmpty ? text : detail)")
            }
            return .success(text)
        }
    }

}

// MARK: - Будильник мака

/// Пробуждение мака к пингу настраивается через `pmset repeat`, а он требует
/// рута.
///
/// Раньше приложение звало `osascript` с `do shell script ... with
/// administrator privileges`: всплывал системный запрос пароля, и команда
/// выполнялась от рута. Ровно так работает почти вся macOS-малварь, крадущая
/// пароли, поэтому поведенческий XProtect в Sequoia на это и срабатывает: у
/// одного пользователя система показала попап про вредоносное ПО и снесла
/// приложение из /Applications, хотя подпись и нотаризация были в порядке.
///
/// Поэтому прав больше не просим совсем. Приложение показывает готовую команду,
/// человек выполняет её в терминале сам, а мы только читаем состояние: чтение
/// `pmset -g sched` рута не требует.
public enum WakeSchedule {
    /// Команда, которую пользователь вставляет в терминал.
    ///
    /// Считаем от якоря, а не от времени пинга: якорь это час, к которому окно
    /// должно закончиться, а пинг случается за пять часов до него. Плюс две
    /// минуты запаса, маку нужно время подняться. Якорь 08:45 даёт 03:43.
    ///
    /// Раньше сюда передавали сам якорь, и команда будила мак в 08:43, то есть
    /// к концу окна вместо его начала. Поэтому вход теперь называется явно.
    public static func command(anchorHour: Int, anchorMinute: Int) -> String {
        let minutes = anchorHour * 60 + anchorMinute - Int(Anchor.window / 60) - 2
        let shifted = ((minutes % 1440) + 1440) % 1440
        return String(format: "sudo pmset repeat wakeorpoweron MTWRFSU %02d:%02d:00",
                      shifted / 60, shifted % 60)
    }

    public static let cancelCommand = "sudo pmset repeat cancel"

    /// Разбирает `pmset -g sched`. Возвращает время повторяющегося пробуждения
    /// в виде "03:43:00", если оно настроено.
    ///
    /// Вывод выглядит так:
    ///     Repeating power events:
    ///       wakepoweron at 3:43AM every day
    public static func scheduled(in output: String) -> String? {
        for raw in output.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces).lowercased()
            guard line.contains("wakepoweron") || line.contains("wakeorpoweron") else { continue }
            guard let at = line.range(of: #"\d{1,2}:\d{2}(:\d{2})?\s*(am|pm)?"#,
                                      options: .regularExpression) else { continue }
            return normalize(String(line[at]))
        }
        return nil
    }

    /// "3:43am" -> "03:43", "15:43:00" -> "15:43".
    static func normalize(_ text: String) -> String {
        let t = text.replacingOccurrences(of: " ", with: "")
        let pm = t.hasSuffix("pm"), am = t.hasSuffix("am")
        let digits = t.replacingOccurrences(of: "am", with: "").replacingOccurrences(of: "pm", with: "")
        let parts = digits.split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2 else { return text }
        var hour = parts[0]
        if pm, hour < 12 { hour += 12 }
        if am, hour == 12 { hour = 0 }
        return String(format: "%02d:%02d", hour % 24, parts[1])
    }

    /// Читает текущее расписание. Без рута, поэтому дёргать безопасно.
    public static func current(timeout: TimeInterval = 10) -> String? {
        guard case .finished(let status, let out, _) =
                Proc.run("/usr/bin/pmset", ["-g", "sched"], timeout: timeout), status == 0
        else { return nil }
        return scheduled(in: out)
    }
}
