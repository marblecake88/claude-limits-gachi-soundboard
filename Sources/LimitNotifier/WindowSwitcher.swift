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

        if let path, let holder = ideHolding(path: path),
           openInEditor(project: project, path: holder.folder, ide: holder.ide) {
            return true
        }
        if focusViaAccessibility(project: project) { return true }
        return false
    }

    /// В каком редакторе открыта папка и какую именно папку он держит.
    ///
    /// Claude Code держит по файлу на каждое подключённое окно и пишет туда и
    /// список папок, и имя редактора, так что угадывать не нужно.
    ///
    /// Совпадение ищем не точное, а по вложенности: claude часто запускают в
    /// подпапке проекта, тогда как редактор открыл корень. Открывать надо
    /// именно корень, иначе редактор заведёт новое окно на подпапку вместо
    /// того, чтобы поднять уже открытое.
    private static func ideHolding(path: String) -> (ide: String, folder: String)? {
        let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/ide")
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil) else { return nil }

        var best: (ide: String, folder: String)?
        for file in files where file.pathExtension == "lock" {
            guard let data = try? Data(contentsOf: file),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let folders = json["workspaceFolders"] as? [String],
                  let ide = json["ideName"] as? String
            else { continue }
            for folder in folders where ProjectPath.covers(folder: folder, path: path) {
                // Из подходящих берём самую глубокую: если открыты и корень, и
                // подпапка, ближе к цели вторая.
                if best == nil || folder.count > best!.folder.count {
                    best = (ide, folder)
                }
            }
        }
        return best
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
        // Папку пишем всегда: если проект вложенный, открывали не его, а корень,
        // и без этого непонятно, почему подняли соседнее на вид окно.
        Log.write("перешёл к \(project) в \(ide) · папка \(path)")
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
