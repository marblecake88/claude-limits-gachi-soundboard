import AppKit
import LimitNotifierCore

/// Плавающая плашка: те же цифры и та же бегущая строка, что в строке меню, но
/// своим окном.
///
/// Нужна потому, что место в строке меню раздаёт система, а не мы. Приложениям с
/// длинным меню (JetBrains, Xcode) её хватает целиком, и наш элемент просто
/// перестают рисовать; в полноэкранном режиме строки меню нет вообще. Своё окно
/// уровня строки меню не вытесняет никто, и живёт оно на всех рабочих столах и
/// поверх полноэкранных окон.
@MainActor
final class Plaque {
    private let panel: NSPanel
    private let tape: TapeView
    private let settings: Settings

    /// К чему цеплять попап: тот же вид, что рисует ленту.
    var anchor: NSView { tape }
    var isVisible: Bool { panel.isVisible }

    init(settings: Settings, onClick: @escaping () -> Void) {
        self.settings = settings
        tape = TapeView(frame: NSRect(x: 0, y: 0, width: 120, height: TapeView.height))
        // Фон плашки свой и тёмный, поэтому и цвета цифр берём тёмной темы:
        // адаптивные оттенки резолвятся по внешнему виду того, кто их рисует.
        tape.appearance = NSAppearance(named: .darkAqua)

        panel = NSPanel(contentRect: tape.frame,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.contentView = tape
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true

        tape.onClick = {
            Log.write("клик по плашке")
            onClick()
        }
        tape.onMoved = { [weak self] in self?.savePosition() }
    }

    func show() {
        place()
        panel.orderFrontRegardless()
    }

    func hide() { panel.orderOut(nil) }

    /// Кадр ленты: тот же текст и то же смещение, что уходят в строку меню.
    func render(line: NSAttributedString, width: CGFloat, offset: Double) {
        tape.line = line
        tape.offset = offset
        if abs(tape.tapeWidth - width) > 0.5 {
            tape.tapeWidth = width
            resize()
        }
        tape.needsDisplay = true
    }

    private func resize() {
        var frame = panel.frame
        frame.size = NSSize(width: tape.tapeWidth + TapeView.padX * 2, height: TapeView.height)
        panel.setFrame(frame, display: true)
    }

    /// Ставит плашку туда, где её оставили. Границы проверяем каждый раз: экран
    /// мог отвалиться или сменить разрешение, и сохранённая точка оказаться вне его.
    private func place() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let saved = settings.plaqueOrigin
            ?? CGPoint(x: visible.maxX - size.width - 12, y: visible.maxY - size.height - 6)
        panel.setFrameOrigin(NSPoint(
            x: min(max(saved.x, visible.minX), visible.maxX - size.width),
            y: min(max(saved.y, visible.minY), visible.maxY - size.height)))
    }

    private func savePosition() {
        settings.plaqueOrigin = panel.frame.origin
        Log.write("плашка переставлена в \(Int(panel.frame.origin.x)),\(Int(panel.frame.origin.y))")
    }
}

/// Рисует ли система наше окно в строке меню.
///
/// Единственный честный способ это узнать: спросить у системы список окон,
/// которые реально на экране. Координаты самого элемента не годятся, AppKit
/// раскладывает их как будто места бесконечно и уводит вытесненные в минус, а
/// occlusionState у элементов строки меню врёт даже про видимые. Разрешений
/// запрос не требует: имена и рамки окон отдаются без записи экрана.
///
/// То, что список отражает именно нарисованное, документацией не обещано.
/// Проверено опытом на Sequoia; если отвалится, останется ручной режим
/// "плашка всегда".
enum MenuBar {
    static func isDrawn(_ number: Int) -> Bool {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return list.contains { ($0[kCGWindowNumber as String] as? Int) == number }
    }
}

/// Вид плашки: тёмная пилюля с лентой внутри. Окно ленты такой же ширины, как
/// строка лимитов, поэтому имена проектов проезжают ровно так же, как в строке
/// меню, тем же кодом движения.
private final class TapeView: NSView {
    static let height: CGFloat = 22
    static let padX: CGFloat = 9

    var line: NSAttributedString?
    /// Ширина окна ленты: сколько её видно за раз.
    var tapeWidth: CGFloat = 0
    var offset: Double = 0
    var onClick: () -> Void = {}
    var onMoved: () -> Void = {}

    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6)
        NSColor.black.withAlphaComponent(0.62).setFill()
        shape.fill()
        NSColor.white.withAlphaComponent(0.10).setStroke()
        shape.lineWidth = 1
        shape.stroke()

        guard let line else { return }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: NSRect(x: Self.padX, y: 0,
                                  width: tapeWidth, height: bounds.height)).setClip()
        // Как и в строке меню: draw(at:) берёт левый низ блока, поэтому просто
        // центрируем блок по его собственной высоте.
        line.draw(at: NSPoint(x: Self.padX - offset,
                              y: ((bounds.height - line.size().height) / 2).rounded()))
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Где стояло окно и где была мышь в момент нажатия.
    private var grabbedAt: (window: NSPoint, mouse: NSPoint)?

    /// Перетаскиваем сами, а не через performDrag: тот на безрамочной панели
    /// молча ничего не делает, и до сохранения позиции дело не доходило.
    ///
    /// Клик от переноса отличаем по пройденному пути: порог в три точки затем,
    /// что мышь под пальцем всегда чуть дрожит.
    override func mouseDown(with event: NSEvent) {
        guard let panel = window else { return }
        grabbedAt = (panel.frame.origin, NSEvent.mouseLocation)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let grabbed = grabbedAt, let panel = window else { return }
        let mouse = NSEvent.mouseLocation
        panel.setFrameOrigin(NSPoint(x: grabbed.window.x + mouse.x - grabbed.mouse.x,
                                     y: grabbed.window.y + mouse.y - grabbed.mouse.y))
    }

    override func mouseUp(with event: NSEvent) {
        guard let grabbed = grabbedAt, let panel = window else { return }
        grabbedAt = nil
        let moved = hypot(panel.frame.origin.x - grabbed.window.x,
                          panel.frame.origin.y - grabbed.window.y)
        if moved < 3 {
            onClick()
        } else {
            onMoved()
        }
    }
}
