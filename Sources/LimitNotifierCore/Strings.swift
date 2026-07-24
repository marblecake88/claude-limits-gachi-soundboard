import Foundation

/// Локализация без .lproj и Localizable.strings.
///
/// Строк в приложении полтора десятка, а ради .strings пришлось бы городить
/// папки в бандле, копировать их из make-app.sh и следить за кодировкой. Проще
/// держать оба варианта рядом в коде: видно сразу, что и на что переводится,
/// и невозможно забыть перевод, потому что второй аргумент обязателен.
///
/// Язык берём системный: русская система получает русский, все остальные
/// английский. Отдельной настройки нет намеренно, у macOS уже есть язык.
public enum L {
    public enum Lang: Sendable { case ru, en }

    /// var, а не let: тестам нужно проверять обе ветки, а системная локаль в CI
    /// какая угодно. Обычный код это значение не трогает.
    public nonisolated(unsafe) static var lang: Lang = detect()

    static func detect() -> Lang {
        Locale.preferredLanguages.first?.hasPrefix("ru") == true ? .ru : .en
    }

    /// Пара переводов. Порядок всегда один: сначала русский, потом английский.
    public static func s(_ ru: String, _ en: String) -> String {
        lang == .ru ? ru : en
    }
}
