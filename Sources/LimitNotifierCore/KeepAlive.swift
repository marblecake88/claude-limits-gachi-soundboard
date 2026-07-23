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
