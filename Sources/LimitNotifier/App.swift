import SwiftUI
import AppKit
import Combine
import ServiceManagement
import LimitNotifierCore

@main
struct LimitNotifierApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    // Сцены нет: MenuBarExtra рисует свой лейбл как шаблонное изображение и
    // схлопывает цвет в монохром. Поэтому статус-элемент делаем на AppKit,
    // где NSAttributedString красится как надо.
    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var observer: AnyCancellable?

    private let marquee = Marquee()          // 90 точек в секунду, разгон 0.7 с, два проезда
    private var marqueeTimer: Timer?
    private var marqueeTape: NSAttributedString?
    private var marqueeWindow: CGFloat = 0
    private var marqueePeriod: Double = 0
    private var runStart: Date?
    private var holdUntil = Date.distantFuture

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(togglePanel)
        statusItem = item

        let pop = NSPopover()
        pop.behavior = .transient
        pop.contentViewController = NSHostingController(rootView: PanelView(model: model))
        popover = pop
        watchPopoverResize()

        observer = model.objectWillChange.sink { [weak self] _ in
            // objectWillChange приходит до записи значения, поэтому
            // перерисовываем на следующем витке цикла.
            DispatchQueue.main.async { self?.redraw() }
        }
        redraw()
    }

    /// Не даём развёрнутой панели уехать за правый край экрана.
    ///
    /// Попап центрируется по иконке в строке меню, а она у правого края: узкая
    /// панель влезает, а со статистикой вылезает наружу. Двигаем само окно.
    ///
    /// Ловим именно ресайз окна, а не таймер: по таймеру панель успевала
    /// заехать за край и потом дёрганно выезжала обратно. Уведомление приходит
    /// в том же цикле, что и смена размера, поэтому наружу она уже не попадает.
    private func watchPopoverResize() {
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self,
                      let window = note.object as? NSWindow,
                      window === self.popover?.contentViewController?.view.window else { return }
                self.fitOnScreen()
            }
        }
    }

    /// Считаем позицию от иконки каждый раз, а не двигаем от текущей: иначе
    /// после сворачивания статистики узкая панель так и оставалась слева, там,
    /// куда её отодвинули ради широкой.
    private func fitOnScreen() {
        guard let popover, popover.isShown,
              let button = statusItem?.button, let anchorWindow = button.window,
              let window = popover.contentViewController?.view.window,
              let screen = window.screen ?? NSScreen.main else { return }

        let anchor = anchorWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let visible = screen.visibleFrame
        var frame = window.frame
        // Как ставит сам попап: по центру иконки. Дальше зажимаем в экран.
        let wanted = PopoverFit.fittedX(x: anchor.midX - frame.width / 2, width: frame.width,
                                        screenMinX: visible.minX, screenMaxX: visible.maxX)
        guard abs(wanted - frame.origin.x) > 0.5 else { return }
        frame.origin.x = wanted
        window.setFrame(frame, display: true)
    }

    /// Строка вида 55/78/2h15/4d, каждое число своим цветом.
    private func redraw() {
        guard let button = statusItem?.button else { return }
        let limits = limitsLine()

        guard !model.ready.isEmpty else {
            // Спокойное состояние. Рисуем той же картинкой, что и во время
            // движения: если в покое отдать строку системе как текст, а в
            // движении подменять картинкой, текст прыгает на пару точек по
            // вертикали. Один путь отрисовки на оба состояния, никаких стыков.
            stopMarquee()
            marqueeTape = limits
            marqueeWindow = ceil(limits.size().width)
            drawTape(offset: 0)
            return
        }
        // Есть кого позвать: строка превращается в ленту, где лимиты первый
        // элемент. Обрезку по окну и смещение тексту в кнопке не задать, поэтому
        // и в покое, и в движении рисуем сами.
        startMarquee(limits: limits)
    }

    private func limitsLine() -> NSAttributedString {
        let p = StatusBar.parts(from: model.snapshot, now: model.tick)
        let line = NSMutableAttributedString()
        func add(_ text: String, _ color: NSColor) {
            line.append(NSAttributedString(string: text,
                                           attributes: [.font: Self.font, .foregroundColor: color]))
        }
        add(p.session, Self.color(p.sessionLevel))
        add("/", Self.separator)
        add(p.weekly, Self.color(p.weeklyLevel))
        add("/", Self.separator)
        add(p.time, Self.timeColor)
        add("/", Self.separator)
        add(p.weeklyTime, Self.timeColor)
        return line
    }

    /// Размер берём у самой строки меню, чтобы совпадать с часами и прочими
    /// системными надписями: там 13 точек, а не 12. Цифры моноширинные, иначе
    /// строка дёргалась бы при каждой смене процента.
    private static let font: NSFont = {
        let size = NSFont.menuBarFont(ofSize: 0).pointSize
        return NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular)
    }()

    /// Цвета имён: три ступени синего. Холодная гамма намеренно, чтобы имена не
    /// читались как продолжение шкалы лимитов, где зелёный, жёлтый и розовый
    /// уже значат "насколько всё плохо".
    private static let projectColors: [NSColor] = [
        NSColor(srgbRed: 0xa8/255, green: 0xd8/255, blue: 1.0, alpha: 1),
        NSColor(srgbRed: 0x6a/255, green: 0xa9/255, blue: 0xe8/255, alpha: 1),
        NSColor(srgbRed: 0x4a/255, green: 0x7f/255, blue: 0xc0/255, alpha: 1),
    ]

    // MARK: - Лента

    private func startMarquee(limits: NSAttributedString) {
        // Один период: лимиты, разделитель, имена, разделитель.
        let tape = NSMutableAttributedString(attributedString: limits)
        tape.append(separatorPiece())
        for (index, name) in model.ready.enumerated() {
            let color = Self.projectColors[index % Self.projectColors.count]
            tape.append(NSAttributedString(string: "✓ " + name,
                                           attributes: [.font: Self.font, .foregroundColor: color]))
            tape.append(separatorPiece())
        }
        marqueeWindow = ceil(limits.size().width)
        marqueePeriod = ceil(tape.size().width)

        // Рисуем три периода: пока второй уезжает, третий уже входит в окно,
        // поэтому в конце пути в окне снова лимиты и возврат на ноль не виден.
        let full = NSMutableAttributedString()
        for _ in 0..<(marquee.passes + 1) { full.append(tape) }
        marqueeTape = full

        guard marqueeTimer == nil else { return }
        holdUntil = Date().addingTimeInterval(1)   // секунда на то, чтоб заметить появление
        runStart = nil
        marqueeTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickMarquee() }
        }
        drawTape(offset: 0)
    }

    private func separatorPiece() -> NSAttributedString {
        NSAttributedString(string: "   ·   ",
                           attributes: [.font: Self.font, .foregroundColor: Self.separator])
    }

    private func stopMarquee() {
        marqueeTimer?.invalidate()
        marqueeTimer = nil
        marqueeTape = nil
        runStart = nil
    }

    private func tickMarquee() {
        guard marqueeTape != nil else { stopMarquee(); return }
        let now = Date()
        if let start = runStart {
            let t = now.timeIntervalSince(start)
            let full = marquee.duration(period: marqueePeriod)
            if t >= full {
                runStart = nil
                holdUntil = now.addingTimeInterval(marquee.hold(period: marqueePeriod))
                drawTape(offset: 0)
            } else {
                drawTape(offset: marquee.offset(at: t, period: marqueePeriod))
            }
        } else if now >= holdUntil {
            runStart = now
        }
    }

    /// Кадр ленты: окно шириной ровно как строка лимитов, текст сдвинут влево.
    ///
    /// Рисуем через drawingHandler, а не lockFocus. Так система сама зовёт нас в
    /// нужном разрешении (на ретине иначе выходит мыло) и в том же внешнем виде,
    /// что у кнопки: адаптивные цвета вне этого контекста резолвятся для светлой
    /// темы и на тёмном меню-баре смотрятся грязно.
    private func drawTape(offset: Double) {
        guard let tape = marqueeTape, let button = statusItem?.button else { return }
        // Высота как у строки меню: если картинка ниже, кнопка её центрирует
        // сама и текст уезжает относительно соседних иконок.
        let height = NSStatusBar.system.thickness
        let size = NSSize(width: marqueeWindow, height: height)
        // draw(at:) принимает левый НИЗ блока текста, а не базовую линию. Если
        // прибавить к нему ещё и descender, текст уезжает вверх почти на три
        // точки: именно так он и разъезжался с тем, что рисует система.
        // Поэтому просто центрируем блок по его же высоте.
        let top = ((height - tape.size().height) / 2).rounded()

        let image = NSImage(size: size, flipped: false) { _ in
            tape.draw(at: NSPoint(x: -offset, y: top))
            return true
        }
        image.isTemplate = false   // иначе macOS перекрасит всё в монохром

        button.attributedTitle = NSAttributedString(string: "")
        button.image = image
        button.imagePosition = .imageOnly
    }

    /// Пороги: до 60 зелёный как гейджи в панели, 60 жёлтый, 79 розовый, 89 красный.
    private static func color(_ level: Level) -> NSColor {
        switch level {
        case .calm:   return calm
        case .yellow: return adaptive(dark: rgb(1.00, 0.85, 0.35), light: rgb(0.72, 0.50, 0.00))
        case .pink:   return adaptive(dark: rgb(1.00, 0.53, 0.68), light: rgb(0.84, 0.13, 0.35))
        case .red:    return adaptive(dark: rgb(1.00, 0.46, 0.42), light: rgb(0.78, 0.11, 0.07))
        }
    }

    /// Спокойная зона: тот же мятный, что у гейджей в панели, но посветлее,
    /// чтоб цифры не тонули в тёмном меню-баре. На светлом фоне светлый мятный
    /// выцветает, поэтому там зелёный поплотнее.
    private static let calm = adaptive(dark: rgb(0.52, 0.96, 0.87),
                                       light: rgb(0.03, 0.55, 0.45))

    /// Время до сброса: заметно тише цифр, но непрозрачное. Полупрозрачные
    /// оттенки на светлом таскбаре сливались с обоями и счётчик пропадал.
    private static let timeColor = adaptive(dark: rgb(0.62, 0.62, 0.66),
                                            light: rgb(0.38, 0.38, 0.42))

    /// Разделители ещё тише времени: это просто риски между числами.
    private static let separator = adaptive(dark: rgb(0.44, 0.44, 0.48),
                                            light: rgb(0.56, 0.56, 0.60))

    /// Цвет, свой для светлой и тёмной темы. Считается в момент отрисовки, так
    /// что переключение темы подхватывается само.
    private static func adaptive(dark: NSColor, light: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }

    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
        NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }

    @objc private func togglePanel() {
        guard let button = statusItem?.button, let popover else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            model.prepareForOpen()
            model.refresh()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
            popover.contentViewController?.view.window?.makeKey()
            fitOnScreen()
        }
    }
}

/// Два экрана панели: гачи-борд (основной) и лимиты (второстепенный).
enum Screen { case board, limits }

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var lastError: UsageError?
    @Published private(set) var isRefreshing = false
    @Published private(set) var nextPingText = L.s("выключено", "off")
    /// Версия из последнего релиза, если она новее нашей. Иначе nil.
    @Published private(set) var updateVersion: String?
    /// Во сколько мак разбудит сам себя, если это настроено. Читаем из pmset.
    @Published private(set) var wakeAt: String?

    // MARK: - Уведомления об окончании

    /// Проекты, где claude закончил работу и ждёт человека. Порядок сохраняем:
    /// цвет в строке меню закреплён за местом в очереди.
    @Published private(set) var ready: [String] = []
    /// То же, но не гаснет по клику: чтобы в панели было видно, кто закончил,
    /// даже если зов в строке меню уже погашен.
    @Published private(set) var recent: [Finished] = []

    struct Finished: Identifiable, Equatable {
        let name: String
        let at: Date
        var id: String { name }
    }
    @Published private(set) var notifyOn = HookInstaller.isInstalled
    /// События, которые ждут тишины: claude мог отчитаться о конце ответа и
    /// тут же продолжить, если его разбудила фоновая задача.
    private var pending: [ReadyEvent] = []
    /// Транскрипт и время каждого уже прозвучавшего зова: если сессия снова
    /// ожила, зов пора снимать, даже если нового Stop не было.
    private var called: [String: (transcript: String, at: Date)] = [:]
    private var readyTask: Task<Void, Never>?

    /// Раз в две секунды дочитываем, что написал хук, и разбираем ожидающих.
    /// Опрос, а не слежение за файлом: события редкие, а FSEvents на
    /// перезаписываемый файл капризны.
    private func watchReady() {
        readyTask?.cancel()
        guard notifyOn else { ready = []; pending = []; return }
        readyTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pickUpReady()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func pickUpReady() {
        // Новое событие вытесняет прежнее ожидание по тому же проекту: отсчёт
        // тишины начинается заново.
        for event in ReadyLog.drain() {
            pending.removeAll { $0.project == event.project }
            pending.append(event)
            // Работа пошла снова, значит прежний зов больше не актуален.
            ready.removeAll { $0 == event.project }
        }
        // Человек вернулся в окно проекта: зов свою работу сделал. Проверяем на
        // каждом тике, а не только в момент появления, иначе зов висит и крутит
        // строку, пока по ней не щёлкнут.
        if !ready.isEmpty {
            let seen = ready.filter { FocusProbe.looksFocused(project: $0) }
            if !seen.isEmpty {
                ready.removeAll { seen.contains($0) }
                seen.forEach { called.removeValue(forKey: $0) }
                Log.write("зов снят, окно открыто: \(seen.joined(separator: ", "))")
            }
            // Работа возобновилась: claude закрыл ответ, ждал не человека, а
            // фоновую задачу, и снова взялся за дело. Звать больше не о чем.
            let alive = ready.filter { name in
                guard let mark = called[name], !mark.transcript.isEmpty,
                      let changed = modifiedAt(mark.transcript) else { return false }
                return changed > mark.at.addingTimeInterval(1)
            }
            if !alive.isEmpty {
                ready.removeAll { alive.contains($0) }
                alive.forEach { called.removeValue(forKey: $0) }
                Log.write("зов снят, работа продолжилась: \(alive.joined(separator: ", "))")
            }
        }
        guard !pending.isEmpty else { return }

        let now = Date()
        var stillWaiting: [ReadyEvent] = []
        for event in pending {
            let changed = event.transcript.isEmpty ? nil : modifiedAt(event.transcript)
            switch Quiet.verdict(event: event, now: now, transcriptChangedAt: changed) {
            case .resumed:
                Log.write("\(event.project): работа продолжилась, не зову")
            case .waiting:
                stillWaiting.append(event)
            case .call:
                call(event)
            }
        }
        pending = stillWaiting
    }

    private func call(_ event: ReadyEvent) {
        let name = event.project
        // Если человек уже смотрит в это окно, звать незачем.
        if FocusProbe.looksFocused(project: name) {
            Log.write("готово \(name), но окно в фокусе, не зову")
            return
        }
        if !ready.contains(name) { ready.append(name) }
        called[name] = (transcript: event.transcript, at: Date())
        recent.removeAll { $0.name == name }
        recent.insert(Finished(name: name, at: event.at), at: 0)
        if recent.count > 5 { recent.removeLast(recent.count - 5) }
        Log.write("готово: \(name) · \(FocusProbe.describe())")
    }

    private func modifiedAt(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    /// Гасим зов: человек открыл панель, значит увидел.
    func clearReady() {
        guard !ready.isEmpty else { return }
        ready = []
        called = [:]
    }

    func setNotify(_ on: Bool) {
        let error = on ? HookInstaller.install() : HookInstaller.remove()
        if let error {
            Log.write("хук не установился: \(error)")
            return
        }
        notifyOn = HookInstaller.isInstalled
        Log.write("уведомления об окончании \(notifyOn ? "включены" : "выключены")")
        if !notifyOn { ready = []; pending = [] }
        watchReady()
    }


    /// Какой экран показан. По умолчанию борд, но если пользователь хоть раз
    /// заходил в лимиты, панель открывается сразу на них.
    @Published var screen: Screen = .board

    /// Вызывается при каждом открытии панели: выбирает стартовый экран.
    func prepareForOpen() {
        screen = settings.visitedLimits ? .limits : .board
        refreshWakeState()
        clearReady()
    }

    func showLimits() {
        screen = .limits
        // Запоминаем навсегда: дальше открываемся на лимитах.
        if !settings.visitedLimits { settings.visitedLimits = true }
    }

    func showBoard() { screen = .board }

    /// Один борд на всё приложение: звук всегда один, кошка и пэды делят его.
    let board = SoundBoard()

    let settings = Settings()

    private let client = UsageClient()
    private var pollTask: Task<Void, Never>?
    private var keepAliveTask: Task<Void, Never>?
    private var failureStreak = 0
    /// Пауза, которую сами себе назначили, когда claude не отдал лимиты.
    /// Сбрасывается первым же удачным ответом.
    private var retryAfter: Int?
    private var lastDigest = ""
    private var lastWakeSpec = ""

    @Published private(set) var spend = Spend.empty
    private var scanning = false

    // MARK: - Статистика

    @Published private(set) var stats = UsageStats.empty
    @Published private(set) var statsScanning = false
    @Published private(set) var statsOpen = false
    @Published private(set) var statsPeriod: StatsPeriod = .all

    func toggleStats() {
        statsOpen.toggle()
        if statsOpen { rescanStats() }
    }

    func setStatsPeriod(_ period: StatsPeriod) { statsPeriod = period }

    /// Кнопка пересчёта в панели статистики: считаем сразу, без выдержки.
    func refreshStats() { rescanStats(force: true) }

    /// Переключение языка на лету. Строки собираются при отрисовке, поэтому
    /// достаточно дёрнуть перерисовку, а вот уже посчитанный текст следующего
    /// пинга приходится пересобрать руками.
    func setLanguage(_ lang: L.Lang) {
        guard L.lang != lang else { return }
        L.lang = lang
        settings.language = lang
        objectWillChange.send()
        rescheduleKeepAlive()
    }

    /// Полный проход по транскриптам заметно дороже скана трат: тот берёт
    /// только неделю, а этому нужна вся история. Поэтому считаем лениво, при
    /// открытии статистики, и не чаще раза в 10 минут.
    private func rescanStats(force: Bool = false) {
        guard !statsScanning else { return }
        guard force || Date().timeIntervalSince(stats.scannedAt) > 600 else { return }
        statsScanning = true
        Task.detached(priority: .utility) {
            let started = Date()
            let result = StatsScanner.load()
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.stats = result
                self.statsScanning = false
                Log.write("stats: \(result.activeDays) дней, \(result.transcripts) сессий, \(ms)ms")
            }
        }
    }

    /// Скан транскриптов на фоне. Не чаще раза в 5 минут: он читает диск, а
    /// цифра за сутки от лишней точности не выигрывает.
    func rescanSpend(force: Bool = false) {
        guard !scanning else { return }
        guard force || Date().timeIntervalSince(spend.scannedAt) > 300 else { return }
        scanning = true
        Task.detached(priority: .utility) {
            let started = Date()
            let result = CostScanner.scan()
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.spend = result
                self.scanning = false
                var line = String(format: "cost scan: today $%.2f, week $%.2f, %dms",
                                  result.today, result.week, ms)
                if !result.unknownModels.isEmpty {
                    line += ", без цены: " + result.unknownModels.joined(separator: " ")
                }
                Log.write(line)
            }
        }
    }

    /// Тикает раз в 30 секунд, чтоб остаток в строке меню отсчитывался сам,
    /// не дожидаясь следующего запроса к серверу.
    @Published private(set) var tick = Date()
    private var tickTask: Task<Void, Never>?
    private var updateTask: Task<Void, Never>?


    init() {
        // Язык применяем до первой отрисовки: иначе панель успеет собраться
        // на системном, а сохранённый выбор подхватится только со второго раза.
        if let saved = settings.language { L.lang = saved }
        Log.trim()
        Log.write("app started")
        startPolling()
        rescheduleKeepAlive()
        rescanSpend(force: true)
        refreshWakeState()
        watchReady()

        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                self?.tick = Date()
            }
        }

        // Раз в сутки смотрим, не вышла ли новая версия. Чаще незачем, релизы
        // не каждый час, а GitHub API анонимно ограничен по частоте.
        updateTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkForUpdate()
                try? await Task.sleep(for: .seconds(24 * 3600))
            }
        }

        // После пробуждения мака расписание надо пересчитать: пока он спал,
        // запланированный момент мог пройти.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                Log.write("mac woke up, rescheduling")
                self?.refresh()
                self?.rescheduleKeepAlive()
            }
        }
    }

    // MARK: - Опрос

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.fetchOnce()
                guard let self else { return }
                try? await Task.sleep(for: self.nextDelay)
            }
        }
    }

    /// Сколько ждать до следующего опроса. Правила в PollPlan, там же тесты.
    private var nextDelay: Duration {
        .seconds(PollPlan.interval(snapshot: snapshot, failureStreak: failureStreak,
                                   retryAfter: retryAfter))
    }

    func refresh(force: Bool = false) {
        // Панель открывают часто, а за минуту цифры почти не меняются.
        // Запрос на каждое открытие это прямой путь в 429.
        if !force, let at = snapshot?.fetchedAt, Date().timeIntervalSince(at) < 60 {
            rescanSpend()
            return
        }
        Task { await fetchOnce() }
        rescanSpend()
    }

    private func fetchOnce() async {
        guard !isRefreshing else { return }
        isRefreshing = true

        defer { isRefreshing = false }
        do {
            let fresh = try await Task.detached(priority: .utility) { [client] in
                try client.fetch()
            }.value
            // Логируем только когда картина изменилась, иначе за сутки набежит
            // 720 одинаковых строк и в логе ничего не найдёшь.
            let digest = fresh.rows.map { "\($0.label) \($0.percent)%" }.joined(separator: ", ")
            if digest != lastDigest {
                Log.write("fetch ok: \(digest)\(fresh.sessionWindowActive ? "" : " (окна нет)")")
                lastDigest = digest
            }
            snapshot = fresh
            lastError = nil
            retryAfter = nil
            if failureStreak > 0 {
                Log.write("fetch recovered after \(failureStreak) failures")
                failureStreak = 0
            }
        } catch let e as UsageError {
            lastError = e
            if case .noLimits(let raw) = e {
                // Не поломка: команда отработала, а процентов не отдала.
                // Счётчик ошибок не трогаем, чтоб не считать это сбоем, но паузу
                // удлиняем: у того, кому usage режут по частоте, прежний опрос
                // раз в 2-10 минут это ограничение только поддерживал.
                retryAfter = PollPlan.backoff(previous: retryAfter)
                Log.write("лимиты не отданы, показываю прошлые, следующий опрос через \(retryAfter! / 60)м"
                          + (raw.isEmpty ? "" : " · claude: \(raw)"))
            } else {
                failureStreak += 1
                Log.write("fetch failed (\(failureStreak)): \(e)")
            }
        } catch {
            lastError = .launchFailed(error.localizedDescription)
            failureStreak += 1
            Log.write("fetch failed (\(failureStreak)): \(error.localizedDescription)")
        }
    }

    // MARK: - Обновления

    /// Текущая версия из бандла. При запуске из swift run её нет, тогда "0".
    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    private func checkForUpdate() async {
        guard let latest = await UpdateCheck.latestTag() else { return }
        let newer = UpdateCheck.isNewer(latest, than: currentVersion)
        updateVersion = newer ? latest : nil
        if newer { Log.write("новая версия \(latest), у нас \(currentVersion)") }
    }

    func openReleases() {
        NSWorkspace.shared.open(UpdateCheck.releasesURL)
    }

    /// Окно с объяснением, что даёт эта штука и что для неё нужно.
    ///
    /// Два согласия в одном месте: правка ~/.claude/settings.json (туда идёт
    /// хук) и доступ к Accessibility (без него не узнать, смотришь ли ты уже в
    /// то окно). Ни то, ни другое не делаем молча.
    func showNotifyHelp() {
        let alert = NSAlert()
        alert.messageText = L.s("Уведомления об окончании задачи",
                                "Notify when a task finishes")
        let ru = [
            "Когда claude в другом окне закончит работу и будет ждать вас, строка меню",
            "прокрутит имя проекта. Никаких звуков и всплывающих окон.",
            "",
            "Для этого нужно два разрешения:",
            "",
            "1. Хук в ~/.claude/settings.json. Claude Code сам сообщит нам, что закончил;",
            "   ваши остальные настройки и хуки останутся на месте.",
            "2. Доступ к Accessibility. Нужен ровно для одного: понять, смотрите ли вы",
            "   прямо сейчас в то окно, и не звать вас, если и так смотрите.",
            "",
            "Без второго тоже работает, просто зовёт всегда. Выключить можно в любой",
            "момент этой же кнопкой, хук удалится.",
        ].joined(separator: "\n")
        let en = [
            "When claude finishes in another window and waits for you, the menu bar",
            "scrolls the project name past. No sounds, no popups.",
            "",
            "This needs two permissions:",
            "",
            "1. A hook in ~/.claude/settings.json, so Claude Code tells us it finished.",
            "   Your other settings and hooks are left untouched.",
            "2. Accessibility access, for exactly one thing: to tell whether you are",
            "   already looking at that window, and stay quiet if you are.",
            "",
            "It works without the second one too, it just always calls you. You can turn",
            "this off any time with the same button, and the hook gets removed.",
        ].joined(separator: "\n")

        let width: CGFloat = 500
        let body = NSTextField(wrappingLabelWithString: L.s(ru, en))
        body.alignment = .left
        body.font = .systemFont(ofSize: 12)
        body.preferredMaxLayoutWidth = width
        let height = body.sizeThatFits(NSSize(width: width,
                                              height: .greatestFiniteMagnitude)).height
        let box = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        body.frame = NSRect(x: 0, y: 0, width: width, height: height)
        box.addSubview(body)
        alert.accessoryView = box

        alert.addButton(withTitle: L.s("Включить", "Turn on"))
        alert.addButton(withTitle: L.s("Отмена", "Cancel"))

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        setNotify(true)
        // Диалог доступа показываем после установки хука: если человек откажет,
        // уведомления всё равно будут работать, просто без проверки фокуса.
        if !FocusProbe.isTrusted { FocusProbe.requestAccess() }
    }

    // MARK: - Настройки

    func setAnchor(hour: Int, minute: Int) {
        settings.anchorHour = hour
        settings.anchorMinute = minute
        Log.write("anchor set to \(settings.anchorText)")
        rescheduleKeepAlive()
    }

    func setKeepAlive(_ on: Bool) {
        settings.keepAliveEnabled = on
        Log.write("keep-alive \(on ? "on" : "off")")
        rescheduleKeepAlive()
    }

    /// Окно с объяснением, зачем нужен будильник и что для него сделать.
    ///
    /// Прав приложение не просит вообще: pmset требует рута, а запрос пароля
    /// из приложения macOS считает поведением малвари и однажды за это снесла
    /// приложение из /Applications. Поэтому команду выполняет человек.
    func showWakeHelp() {
        let cmd = WakeSchedule.command(anchorHour: settings.anchorHour,
                                       anchorMinute: settings.anchorMinute)
        let alert = NSAlert()
        alert.messageText = L.s("Разбудить мак к ночному пингу",
                                "Wake the mac for the nightly ping")
        // Собираем построчно: у многострочного литерала с переносами по бэкслешу
        // отступ следующей строки попадает прямо в текст.
        let ru = [
            "Если мак спит, keep-alive не сработает: будить claude некому.",
            "Штатный способ разбудить мак по расписанию это pmset, ему нужен root.",
            "",
            "Приложение прав не просит специально: запрос пароля из приложения macOS",
            "считает поведением вредоносного ПО и однажды за это удалила приложение,",
            "хотя подпись и нотаризация были в порядке.",
            "",
            "Поэтому вставьте команду в терминал сами, один раз. Она разбудит мак",
            "к \(settings.anchorText) минус пять часов, то есть к началу окна.",
            "",
            "Проверить: pmset -g sched",
            "Отменить: \(WakeSchedule.cancelCommand)",
            "",
            "Слот повтора в системе один: своё расписание, если было, команда заменит.",
        ].joined(separator: "\n")
        let en = [
            "If the mac is asleep, keep-alive can't run: nobody wakes claude.",
            "The standard way to wake a mac on schedule is pmset, and it needs root.",
            "",
            "The app deliberately never asks for privileges: a password prompt coming",
            "from an app is what macOS treats as malware behaviour, and it once deleted",
            "this app over exactly that, signature and notarization notwithstanding.",
            "",
            "So paste the command in a terminal yourself, once. It wakes the mac five",
            "hours before \(settings.anchorText), which is when the window starts.",
            "",
            "Check with: pmset -g sched",
            "Cancel with: \(WakeSchedule.cancelCommand)",
            "",
            "The system has one repeat slot: this replaces your own schedule if you had one.",
        ].joined(separator: "\n")
        // informativeText NSAlert центрирует, и абзацы разъезжаются лестницей.
        // Поэтому весь текст держим своим полем с выравниванием по левому краю.
        let width: CGFloat = 470
        let body = NSTextField(wrappingLabelWithString: L.s(ru, en))
        body.alignment = .left
        body.font = .systemFont(ofSize: 12)
        body.preferredMaxLayoutWidth = width
        let bodyHeight = body.sizeThatFits(
            NSSize(width: width, height: .greatestFiniteMagnitude)).height

        // Команду кладём в отдельное поле: её можно выделить мышкой и скопировать
        // руками, а не только кнопкой.
        let field = NSTextField(labelWithString: cmd)
        field.isSelectable = true
        field.allowsEditingTextAttributes = false
        field.alignment = .left
        field.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        field.lineBreakMode = .byTruncatingTail

        let gap: CGFloat = 12, fieldHeight: CGFloat = 22
        let box = NSView(frame: NSRect(x: 0, y: 0, width: width,
                                       height: bodyHeight + gap + fieldHeight))
        field.frame = NSRect(x: 0, y: 0, width: width, height: fieldHeight)
        body.frame = NSRect(x: 0, y: fieldHeight + gap, width: width, height: bodyHeight)
        box.addSubview(body)
        box.addSubview(field)
        alert.accessoryView = box

        alert.addButton(withTitle: L.s("Скопировать команду", "Copy command"))
        alert.addButton(withTitle: L.s("Закрыть", "Close"))

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(cmd, forType: .string)
            Log.write("wake command скопирована: \(cmd)")
        }
        refreshWakeState()
    }

    /// Читает, стоит ли будильник. Без прав, поэтому можно дёргать свободно.
    func refreshWakeState() {
        Task.detached(priority: .utility) {
            let at = WakeSchedule.current()
            await MainActor.run { [weak self] in self?.wakeAt = at }
        }
    }

    func quit() {
        Log.write("app quit")
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Автозапуск

    /// Работает только когда приложение лежит в /Applications. Из папки
    /// сборки система его зарегистрировать откажется, и это не наша ошибка.
    @Published private(set) var startAtLogin = SMAppService.mainApp.status == .enabled

    func setStartAtLogin(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            Log.write("start at login \(on ? "on" : "off")")
        } catch {
            Log.write("start at login failed: \(error.localizedDescription)")
        }
        startAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: - Keep-alive

    private func rescheduleKeepAlive() {
        keepAliveTask?.cancel()
        guard settings.keepAliveEnabled else {
            nextPingText = L.s("выключено", "off")
            return
        }
        let ping = Anchor.nextPing(anchorHour: settings.anchorHour,
                                   anchorMinute: settings.anchorMinute,
                                   from: Date())
        let hhmm = DateFormatter()
        hhmm.dateFormat = "HH:mm"
        nextPingText = hhmm.string(from: ping) + L.s(", через ", ", in ") + Fmt.until(ping)

        keepAliveTask = Task { [weak self] in
            let delay = ping.timeIntervalSinceNow
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
            }
            guard !Task.isCancelled else { return }
            await self?.firePing()
            self?.rescheduleKeepAlive()
        }
    }

    private func firePing() async {
        // Пингуем только если окно сейчас не идёт: запущенное окно пинг всё
        // равно не перезапустит, так что вызов был бы холостым.
        await fetchOnce()
        // Считаем от текущего момента, а не по флагу снапшота: протухший снапшот
        // (когда /usage молчит) держит старый флаг true и после закрытия окна,
        // из-за чего нужный пинг терялся. Лишний пинг по идущему окну безвреден,
        // он его не перезапускает, а вот пропуск нужного пинга ломает всё утро.
        if snapshot?.sessionRunning(at: Date()) == true {
            Log.write("ping skipped, window already running")
            return
        }
        guard let claude = Proc.findClaude() else {
            Log.write("ping skipped, claude cli not found")
            return
        }
        let result = Pinger.ping(claudePath: claude)
        switch result {
        case .success:
            // Верим не коду возврата, а серверу: окно либо открылось, либо нет.
            // Иначе в логе будет бодрое "ok" при том, что ничего не произошло.
            await fetchOnce()
            if snapshot?.sessionRunning(at: Date()) == true {
                Log.write("ping ok, окно открыто, сбросится в якорное время")
            } else {
                Log.write("ping отработал, но окна на сервере не видно")
            }
        case .failure(let msg):
            Log.write("ping failed: \(msg)")
            await fetchOnce()
        }
    }
}
