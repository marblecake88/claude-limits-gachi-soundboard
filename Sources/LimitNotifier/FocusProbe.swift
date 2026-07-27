import AppKit
import ApplicationServices

/// Смотрит ли человек прямо сейчас на окно с этим проектом.
///
/// Нужно, чтобы не звать в строке меню, когда ты и так сидишь в этом окне и
/// читаешь ответ. Определить активное окно можно только через Accessibility:
/// заголовки окон другим способом не отдаются, а окна VS Code снаружи все
/// выглядят одним процессом с одним pid.
///
/// Разрешение спрашиваем явно и только по кнопке. Без него всё работает, просто
/// зовём всегда: лучше лишний сигнал, чем пропущенный.
enum FocusProbe {

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Открывает системный диалог с предложением выдать доступ. Дальше человек
    /// уходит в настройки сам, вернуть результат синхронно macOS не даёт.
    static func requestAccess() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Заголовок активного окна фронтального приложения.
    static func frontWindowTitle() -> String? {
        guard isTrusted, let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)

        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString,
                                            &window) == .success,
              let focused = window as! AXUIElement?
        else { return nil }

        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused, kAXTitleAttribute as CFString,
                                            &title) == .success
        else { return nil }
        return title as? String
    }

    /// Похоже ли, что в активном окне открыт именно этот проект.
    ///
    /// Редакторы пишут в заголовок имя папки: "App.swift — limitnotifier".
    /// Сравниваем по имени папки, потому что полный путь в заголовок не попадает.
    static func looksFocused(project: String) -> Bool {
        guard !project.isEmpty, let title = frontWindowTitle() else { return false }
        return title.localizedCaseInsensitiveContains(project)
    }

    /// Строка для лога: что именно приложение видит в активном окне.
    /// Нужна, потому что доступ может быть выдан, а заголовок всё равно пустой:
    /// приложения на Electron публикуют его в AX не всегда.
    static func describe() -> String {
        guard isTrusted else { return "доступа к Accessibility нет" }
        let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        guard let title = frontWindowTitle() else { return "фронт \(app), заголовка не отдаёт" }
        return "фронт \(app), заголовок «\(title)»"
    }
}
