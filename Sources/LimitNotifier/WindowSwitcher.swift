import AppKit
import ApplicationServices
import LimitNotifierCore

/// Переход к окну проекта по клику на его имени.
///
/// Ищем среди окон запущенных приложений то, в заголовке которого стоит имя
/// папки: редакторы пишут его сами ("App.swift — limitnotifier"). Поднимаем
/// найденное окно и активируем приложение, а рабочий стол macOS переключает
/// сама, когда окно оказывается на другом.
///
/// Работает через Accessibility, тот же доступ, что и для проверки фокуса. Без
/// него не сработает, и это не страшно: клик просто уберёт строку из списка.
enum WindowSwitcher {

    /// Приложения, которые не могут держать проект: искать в них незачем, а
    /// перебор окон через Accessibility не бесплатный.
    private static let skip: Set<String> = [
        "com.apple.finder", "com.apple.systempreferences", "com.koteng.limitnotifier",
    ]

    /// Окна приложения с заголовками, либо код ошибки.
    ///
    /// Код нужен затем, что у приложений на Electron список окон отдаётся не
    /// всегда, и без него непонятно, окон правда нет или доступ не сработал.
    private struct Found {
        let items: [(window: AXUIElement, title: String)]
        let error: AXError?

        var titles: [String] { items.map(\.title) }

        func match(_ project: String) -> AXUIElement? {
            items.first { $0.title.localizedCaseInsensitiveContains(project) }?.window
        }
    }

    /// Редакторы на Electron не отдают список своих окон через Accessibility:
    /// focused-окно публикуют, а kAXWindows пустой. Поэтому просим само
    /// приложение открыть папку, а оно поднимает нужное окно.
    ///
    /// Именно open, а не CLI редактора: `code <папка>` это node-скрипт, он
    /// занимает 2.7 секунды, тогда как open отвечает за 0.08.
    private static let opener = "/usr/bin/open"

    /// Переходит к окну проекта.
    ///
    /// Порядок важен для скорости. Если папка открыта в редакторе (об этом знает
    /// сам claude, он держит по файлу на окно в ~/.claude/ide), сразу зовём его
    /// CLI: перебор окон через Accessibility для Electron всё равно бесполезен,
    /// а стоит сотни миллисекунд на десятках синхронных запросов.
    @discardableResult
    static func focus(project: String, path: String? = nil) -> Bool {
        let started = Date()
        defer {
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            if ms > 400 { Log.write("переход к \(project) занял \(ms)мс") }
        }

        if let path, let ide = ideHolding(path: path),
           openInEditor(project: project, path: path, ide: ide) {
            return true
        }
        if focusViaAccessibility(project: project) { return true }
        return false
    }

    /// В каком редакторе открыта папка. Claude Code держит по файлу на каждое
    /// подключённое окно и пишет туда и список папок, и имя редактора, так что
    /// угадывать не нужно.
    private static func ideHolding(path: String) -> String? {
        let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/ide")
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil) else { return nil }

        for file in files where file.pathExtension == "lock" {
            guard let data = try? Data(contentsOf: file),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let folders = json["workspaceFolders"] as? [String], folders.contains(path)
            else { continue }
            return json["ideName"] as? String
        }
        return nil
    }

    /// Просим редактор открыть папку: он поднимает окно, где она уже открыта,
    /// а рабочий стол macOS переключает сам.
    private static func openInEditor(project: String, path: String, ide: String) -> Bool {
        guard FileManager.default.fileExists(atPath: path) else { return false }
        guard case .finished(let status, _, let stderr) =
                Proc.run(opener, ["-a", ide, path], timeout: 10), status == 0
        else {
            Log.write("не смог открыть \(project) в \(ide)")
            return false
        }
        if !stderr.isEmpty { Log.write("open: \(stderr.prefix(120))") }
        Log.write("перешёл к \(project) в \(ide)")
        return true
    }

    private static func focusViaAccessibility(project: String) -> Bool {
        guard FocusProbe.isTrusted, !project.isEmpty else { return false }

        var seen: [String] = []
        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular,
                  let bundleId = app.bundleIdentifier, !skip.contains(bundleId)
            else { continue }

            let name = app.localizedName ?? bundleId
            let found = windows(of: app)
            guard let window = found.match(project) else {
                // Заголовки собираем только для лога неудачи, и только короткие.
                if !found.titles.isEmpty {
                    seen.append("\(name): " + found.titles.prefix(3)
                        .map { "«\($0.prefix(40))»" }.joined(separator: " "))
                }
                continue
            }
            // Порядок важен: сначала поднимаем окно внутри приложения, потом
            // выводим приложение вперёд. Иначе активируется его прежнее окно.
            AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            app.activate()
            Log.write("перешёл к окну \(project) в \(name)")
            return true
        }

        Log.write("окно \(project) через accessibility не нашлось · видно: "
                  + (seen.isEmpty ? "ни одного окна" : seen.joined(separator: " | ")))
        return false
    }

    private static func windows(of app: NSRunningApplication) -> Found {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value)
        guard status == .success, let list = value as? [AXUIElement] else {
            return Found(items: [], error: status == .success ? nil : status)
        }
        let items: [(AXUIElement, String)] = list.compactMap { window in
            var title: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString,
                                                &title) == .success,
                  let text = title as? String, !text.isEmpty
            else { return nil }
            return (window, text)
        }
        return Found(items: items, error: nil)
    }
}
