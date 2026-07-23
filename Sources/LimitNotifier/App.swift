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

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(togglePanel)
        statusItem = item

        let pop = NSPopover()
        pop.behavior = .transient
        pop.contentViewController = NSHostingController(rootView: PanelView(model: model))
        popover = pop

        observer = model.objectWillChange.sink { [weak self] _ in
            // objectWillChange приходит до записи значения, поэтому
            // перерисовываем на следующем витке цикла.
            DispatchQueue.main.async { self?.redraw() }
        }
        redraw()
    }

    /// Строка вида 55/78/2h15, каждое число своим цветом.
    private func redraw() {
        let p = StatusBar.parts(from: model.snapshot, now: model.tick)
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let line = NSMutableAttributedString()

        func add(_ text: String, _ color: NSColor) {
            line.append(NSAttributedString(string: text,
                                           attributes: [.font: font, .foregroundColor: color]))
        }
        add(p.session, Self.color(p.sessionLevel))
        add("/", .tertiaryLabelColor)
        add(p.weekly, Self.color(p.weeklyLevel))
        add("/", .tertiaryLabelColor)
        add(p.time, .secondaryLabelColor)

        statusItem?.button?.attributedTitle = line
    }

    /// Пороги: до 60 обычный цвет, 60 жёлтый, 79 розовый, 89 красный.
    private static func color(_ level: Level) -> NSColor {
        switch level {
        case .calm:   return .labelColor
        case .yellow: return .systemYellow
        case .pink:   return .systemPink
        case .red:    return .systemRed
        }
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
    @Published private(set) var nextPingText = "выключено"

    /// Какой экран показан. По умолчанию борд, но если пользователь хоть раз
    /// заходил в лимиты, панель открывается сразу на них.
    @Published var screen: Screen = .board

    /// Вызывается при каждом открытии панели: выбирает стартовый экран.
    func prepareForOpen() {
        screen = settings.visitedLimits ? .limits : .board
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
    private var lastDigest = ""
    private var lastWakeSpec = ""

    @Published private(set) var spend = Spend.empty
    private var scanning = false

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
                    line += ", без цены: \(result.unknownModels.joined(separator: " "))"
                }
                Log.write(line)
            }
        }
    }

    /// Тикает раз в 30 секунд, чтоб остаток в строке меню отсчитывался сам,
    /// не дожидаясь следующего запроса к серверу.
    @Published private(set) var tick = Date()
    private var tickTask: Task<Void, Never>?


    init() {
        Log.trim()
        Log.write("app started")
        startPolling()
        rescheduleKeepAlive()
        rescanSpend(force: true)

        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                self?.tick = Date()
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
        .seconds(PollPlan.interval(snapshot: snapshot, failureStreak: failureStreak))
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
            if failureStreak > 0 {
                Log.write("fetch recovered after \(failureStreak) failures")
                failureStreak = 0
            }
        } catch let e as UsageError {
            lastError = e
            if case .noLimits = e {
                // Не поломка: команда отработала, а процентов не отдала.
                // Счётчик ошибок не трогаем, чтоб не уехать в долгий бэкофф.
                Log.write("лимиты не отданы, показываю прошлые")
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
        if !on { setWakeMac(false) }
        rescheduleKeepAlive()
    }

    func setWakeMac(_ on: Bool) {
        let ping = Anchor.nextPing(anchorHour: settings.anchorHour,
                                   anchorMinute: settings.anchorMinute,
                                   from: Date())
        // Пароль спрашиваем только когда состояние реально меняется.
        // Раньше выключение keep-alive безусловно звало pmset, даже если
        // будильник и так не стоял, и это дёргало пароль на каждый клик.
        let spec = on ? "\(settings.anchorHour):\(settings.anchorMinute)" : ""
        guard on != settings.wakeMacEnabled || (on && spec != lastWakeSpec) else {
            rescheduleKeepAlive()
            return
        }
        lastWakeSpec = on ? spec : ""

        // pmset требует прав, поэтому спрашиваем пароль через osascript.
        // Слот repeat в системе один на всех, об этом написано в панели.
        let cal = Calendar.current
        let h = cal.component(.hour, from: ping)
        let m = cal.component(.minute, from: ping)
        // Будим на две минуты раньше: маку нужно время подняться.
        let wakeAt = String(format: "%02d:%02d:00", (h * 60 + m - 2 + 1440) / 60 % 24,
                            (h * 60 + m - 2 + 1440) % 60)
        let cmd = on
            ? "pmset repeat wakeorpoweron MTWRFSU \(wakeAt)"
            : "pmset repeat cancel"

        Task.detached {
            let script = "do shell script \"\(cmd)\" with administrator privileges"
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", script]
            do {
                try p.run()
                p.waitUntilExit()
                let ok = p.terminationStatus == 0
                await MainActor.run {
                    self.settings.wakeMacEnabled = on && ok
                    Log.write("pmset \(on ? "set \(wakeAt)" : "cancelled"): \(ok ? "ok" : "отказ")")
                    self.rescheduleKeepAlive()
                }
            } catch {
                await MainActor.run {
                    self.settings.wakeMacEnabled = false
                    Log.write("pmset failed: \(error.localizedDescription)")
                }
            }
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
            nextPingText = "выключено"
            return
        }
        let ping = Anchor.nextPing(anchorHour: settings.anchorHour,
                                   anchorMinute: settings.anchorMinute,
                                   from: Date())
        let hhmm = DateFormatter()
        hhmm.dateFormat = "HH:mm"
        nextPingText = "\(hhmm.string(from: ping)), через \(Fmt.until(ping))"

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
        if snapshot?.sessionWindowActive == true {
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
            if snapshot?.sessionWindowActive == true {
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
