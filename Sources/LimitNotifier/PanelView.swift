import SwiftUI
import LimitNotifierCore

// Панель по варианту 14 "Quiet Meters" из previews3.html.
// Только текст и плоские заливки: ни градиентов, ни свечения, ни анимации.
// Все размеры сняты с макета один в один, поэтому числа тут магические
// намеренно, это перенос дизайна, а не расчёт.

// MARK: - Палитра

private enum Palette {
    static let bg = Color(red: 11 / 255, green: 11 / 255, blue: 13 / 255)        // #0b0b0d
    static let key = Color(red: 107 / 255, green: 107 / 255, blue: 115 / 255)    // #6b6b73
    static let value = Color(red: 233 / 255, green: 233 / 255, blue: 238 / 255)  // #e9e9ee
    static let accent = Color(red: 94 / 255, green: 231 / 255, blue: 208 / 255)  // #5ee7d0
    static let empty = Color(red: 43 / 255, green: 43 / 255, blue: 49 / 255)     // #2b2b31
    static let dim = Color(red: 138 / 255, green: 138 / 255, blue: 147 / 255)    // #8a8a93
    static let faint = Color(red: 87 / 255, green: 87 / 255, blue: 95 / 255)     // #57575f
    static let hover = Color(red: 154 / 255, green: 154 / 255, blue: 163 / 255)  // #9a9aa3
    static let amber = Color(red: 232 / 255, green: 177 / 255, blue: 58 / 255)   // #e8b13a
    static let red = Color(red: 232 / 255, green: 87 / 255, blue: 74 / 255)      // #e8574a
    static let line = Color.white.opacity(0.09)
    static let fieldLine = Color.white.opacity(0.16)
    static let fieldBg = Color.white.opacity(0.04)

    /// Цвет заполненной части гейджа. Единственное исключение из "только циан".
    /// Пороги те же, что и в строке меню: 60 жёлтый, 79 розовый, 89 красный.
    static func accent(for level: Level) -> Color {
        switch level {
        case .calm:   return accent
        case .yellow: return yellow
        case .pink:   return pink
        case .red:    return red
        }
    }

    static let yellow = Color(red: 0.99, green: 0.80, blue: 0.20)
    static let pink   = Color(red: 1.00, green: 0.35, blue: 0.55)
}

private enum Metrics {
    static let font = Font.system(size: 11, design: .monospaced)
    static let keyColumn: CGFloat = 58
    static let percentColumn: CGFloat = 32
    static let gaugeWidth = 22
    /// letter-spacing из макета: 0.08em и 0.09em при 11pt.
    static let trackKey: CGFloat = 0.88
    static let trackTitle: CGFloat = 0.99
    static let trackFoot: CGFloat = 0.66
}

// MARK: - Чистая математика полей ввода

enum AnchorInput {
    /// Сдвиг якоря на delta минут с корректным заворотом через полночь.
    static func shifted(hour: Int, minute: Int, byMinutes delta: Int) -> (hour: Int, minute: Int) {
        var total = (hour * 60 + minute + delta) % 1440
        if total < 0 { total += 1440 }
        return (total / 60, total % 60)
    }

    /// Разбор "HH:mm". Возвращает nil на любом мусоре, чтоб поле откатилось.
    static func parse(_ text: String) -> (hour: Int, minute: Int)? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":", maxSplits: 1)
        guard parts.count == 2,
              let h = Int(parts[0]), let m = Int(parts[1]),
              (0...23).contains(h), (0...59).contains(m) else { return nil }
        return (h, m)
    }
}

/// Часы и минуты даты без DateFormatter: календарь передаём параметром.
/// Центы важны на мелких суммах, на крупных только шум.
private func fmtMoney(_ v: Double) -> String {
    v >= 100 ? String(format: "$%.0f", v) : String(format: "$%.2f", v)
}

private func hhmm(_ date: Date, calendar: Calendar = .current) -> String {
    let c = calendar.dateComponents([.hour, .minute], from: date)
    return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
}

// MARK: - Панель

struct PanelView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Group {
            switch model.screen {
            case .board:  boardScreen()
            case .limits: limitsScreen(now: Date())
            }
        }
        .frame(width: 300, alignment: .leading)
        .background(Palette.bg)
    }

    // MARK: - Экран гачи-борда (основной)

    @ViewBuilder
    private func boardScreen() -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("GACHI BOARD")
                    .font(Metrics.font).tracking(Metrics.trackTitle)
                    .foregroundStyle(Palette.value)
                Spacer(minLength: 8)
                LimitsChip(model: model)   // живой чип с процентом -> экран лимитов
            }
            .padding(.bottom, 12)

            CatButton(board: model.board)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 12)

            // Сетка без прокрутки: все звуки видны сразу.
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3),
                      spacing: 6) {
                ForEach(model.board.clips) { clip in
                    PadButton(clip: clip, board: model.board)
                }
            }

            Spacer(minLength: 12)
            HStack {
                Spacer()
                FootButton(title: "QUIT", muted: false, action: { model.quit() })
            }
            .padding(.top, 10)
        }
        .padding(EdgeInsets(top: 13, leading: 14, bottom: 12, trailing: 14))
    }

    // MARK: - Экран лимитов (второстепенный, как раньше)

    @ViewBuilder
    private func limitsScreen(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header(now: now)

            // Ошибку показываем строкой сверху, но старый снапшот не стираем:
            // протухшие цифры полезнее пустой панели.
            if let error = model.lastError {
                Text(error.hint)
                    .font(Metrics.font)
                    .lineSpacing(3)
                    .foregroundStyle(Palette.amber)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 8)
            }

            if let snapshot = model.snapshot {
                gauges(snapshot)
                Sep()
                facts(snapshot, now: now)
            } else if model.lastError == nil {
                ConfigRow(key: "Status", value: "loading", dim: true)
            }

            Sep()

            SettingsBlock(
                settings: model.settings,
                nextPingText: model.nextPingText,
                onKeepAlive: { model.setKeepAlive($0) },
                onWakeMac: { model.setWakeMac($0) },
                onAnchor: { model.setAnchor(hour: $0, minute: $1) }
            )

            Sep()

            moneySection()

            Sep()

            loginRow()

            footer()
        }
        .padding(EdgeInsets(top: 13, leading: 14, bottom: 12, trailing: 14))
    }

    // MARK: Шапка лимитов (с кнопкой назад на борд)

    private func header(now: Date) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button(action: { model.showBoard() }) {
                Text("‹ BOARD")
                    .font(Metrics.font).tracking(Metrics.trackFoot)
                    .foregroundStyle(Palette.accent)
            }
            .buttonStyle(.plain)
            Spacer(minLength: 8)
            headerReset(now: now)
                .font(Metrics.font)
                .monospacedDigit()
                .lineLimit(1)
        }
        .padding(.bottom, 10)
    }

    private func headerReset(now: Date) -> Text {
        guard let at = model.snapshot?.session?.resetsAt else {
            return Text("no active window").foregroundStyle(Palette.faint)
        }
        return Text("resets in ").foregroundStyle(Palette.faint)
            + Text(Fmt.until(at, from: now)).foregroundStyle(Palette.value)
    }

    // MARK: Гейджи

    private func gauges(_ snapshot: UsageSnapshot) -> some View {
        // Ряды строго из snapshot.rows: их количество и состав задаёт сервер.
        // Незнакомый kind обязан отрисоваться, а не потеряться.
        VStack(alignment: .leading, spacing: 0) {
            ForEach(snapshot.rows) { row in
                GaugeRow(key: row.label, percent: row.percent, level: Level(percent: row.percent))
            }
        }
        .padding(.bottom, 3)
    }

    // MARK: Вторичные факты

    private func facts(_ snapshot: UsageSnapshot, now: Date) -> some View {
        // В ответе API нет ни burn rate, ни длительности сессии, ни имени
        // модели верхнего уровня, поэтому эти строки из макета выброшены,
        // а не заполнены выдуманными числами. Показываем только то, что
        // реально приходит: время сброса по окнам и метку обновления.
        // История за 8 окон тоже убрана: сервер её не отдаёт.
        VStack(alignment: .leading, spacing: 0) {
            // Сброс сессии уже стоит в шапке, тут только остальные окна.
            ForEach(snapshot.rows.filter { !$0.isSession }) { row in
                if let at = row.resetsAt {
                    ConfigRow(key: "\(row.label) resets", value: Fmt.until(at, from: now))
                }
            }
            ConfigRow(key: "Updated", value: hhmm(snapshot.fetchedAt), dim: true)
        }
    }

    // MARK: Деньги

    /// Считается локально из транскриптов: в ответе API денег нет, поля
    /// limit_dollars и used_dollars на подписке всегда null.
    private func moneySection() -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ConfigRow(key: "Today", value: fmtMoney(model.spend.today))
            ConfigRow(key: "Last 7 days", value: fmtMoney(model.spend.week))
            Note("Клауде хочет чтоб вы думали что тратите именно столько")
            if !model.spend.unknownModels.isEmpty {
                Note("Нет цены: \(model.spend.unknownModels.joined(separator: ", "))")
            }
        }
    }

    // MARK: Автозапуск

    private func loginRow() -> some View {
        // SMAppService регистрирует только приложение из /Applications.
        // Пока оно лежит в папке сборки, переключатель просто не защёлкнется.
        RowShell {
            RowKey("Start at login")
            Spacer(minLength: 8)
            Switch(isOn: Binding(
                get: { model.startAtLogin },
                set: { model.setStartAtLogin($0) }
            ))
        }
    }

    // MARK: Футер

    private func footer() -> some View {
        HStack(spacing: 12) {
            FootButton(
                title: model.isRefreshing ? "REFRESHING" : "REFRESH",
                muted: model.isRefreshing,
                action: { model.refresh() }
            )
            .disabled(model.isRefreshing)
            Spacer(minLength: 8)
            FootButton(title: "QUIT", muted: false, action: { model.quit() })
        }
        .padding(.top, 2)
    }
}

/// Кошка на борде. Клик играет случайный звук и кошка подскакивает. Если звук
/// обрывается, кошка наоборот сжимается.
private struct CatButton: View {
    let board: SoundBoard
    @State private var scale: CGFloat = 1.0
    // Грузим прямо из бандла: Image("cat") ищет ассет-каталог, а у нас
    // просто файл в Resources, и он его не находит.
    private static let cat: NSImage? = Bundle.main.url(forResource: "cat", withExtension: "png")
        .flatMap { NSImage(contentsOf: $0) }

    var body: some View {
        VStack(spacing: 6) {
            if let cat = Self.cat {
                Button {
                    let played = board.tapRandom()
                    scale = played ? 1.4 : 0.6
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { scale = 1.0 }
                } label: {
                    Image(nsImage: cat)
                        .resizable().scaledToFit()
                        .frame(width: 68, height: 68)
                        .scaleEffect(scale)
                        .animation(.spring(response: 0.28, dampingFraction: 0.45), value: scale)
                }
                .buttonStyle(.plain)
                .help("случайный звук")
            }
            Text("RANDOM")
                .font(.system(size: 10, design: .monospaced))
                .tracking(0.18 * 10)
                .foregroundStyle(Palette.pink)
        }
    }
}

/// Пэд одного звука. Клик играет его, повторный клик обрывает.
private struct PadButton: View {
    let clip: SoundBoard.Clip
    let board: SoundBoard
    @State private var hover = false

    var body: some View {
        Button { board.play(clip) } label: {
            Text(clip.title)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(hover ? Color.white : Palette.value)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 34)
                .padding(.horizontal, 4).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 8).fill(Palette.fieldBg))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .stroke(hover ? Palette.pink : Palette.line, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// Живой чип на борде: процент недельного лимита, клик уводит на экран лимитов.
private struct LimitsChip: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let parts = StatusBar.parts(from: model.snapshot)
        Button { model.showLimits() } label: {
            HStack(spacing: 5) {
                Text(parts.weekly + "%")
                    .foregroundStyle(color(parts.weeklyLevel))
                    .monospacedDigit()
                Text("LIMITS ›").foregroundStyle(Palette.dim)
            }
            .font(.system(size: 10.5, design: .monospaced))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Palette.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("лимиты Клауде")
    }

    private func color(_ level: Level) -> Color {
        switch level {
        case .calm:   return Palette.value
        case .yellow: return Palette.yellow
        case .pink:   return Palette.pink
        case .red:    return Palette.red
        }
    }
}

// MARK: - Блок настроек

/// Вынесен отдельно ради подписки на Settings: галочки и время живут там,
/// и без своего @ObservedObject панель не перерисовывалась бы по их смене.
private struct SettingsBlock: View {
    // Квалифицируем модуль: в SwiftUI есть свой Settings, имя иначе неоднозначно.
    @ObservedObject var settings: LimitNotifierCore.Settings
    let nextPingText: String
    let onKeepAlive: (Bool) -> Void
    let onWakeMac: (Bool) -> Void
    let onAnchor: (Int, Int) -> Void


    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RowShell {
                RowKey("KEEP-ALIVE")
                Spacer(minLength: 8)
                Switch(isOn: Binding(get: { settings.keepAliveEnabled }, set: onKeepAlive))
            }
            Note("Утром к нужному часу будет окно с 99% лимита. Работаете с 8, ставьте 9")

            Spacer().frame(height: 9)

            RowShell {
                RowKey("FRESH WINDOW BY")
                Spacer(minLength: 8)
                timeField
            }
            Note(nextPingText)

            Spacer().frame(height: 9)

            RowShell {
                RowKey("WAKE MAC", muted: !settings.keepAliveEnabled)
                Spacer(minLength: 8)
                Switch(isOn: Binding(get: { settings.wakeMacEnabled }, set: onWakeMac))
            }
            // Будилка без keep-alive бессмысленна: будить некого.
            .disabled(!settings.keepAliveEnabled)
            .opacity(settings.keepAliveEnabled ? 1 : 0.45)
            Note("Нужна, если закрываете мак на ночь")
        }
    }

    // MARK: Поле времени со степпером

    private var timeField: some View {
        // Не TextField намеренно. Системное поле при открытии панели само
        // хватает фокус и выделяет текст системным акцентом, а цвет выделения
        // приложением не задаётся. Значение меняется шевронами по 15 минут,
        // этого для якоря достаточно, а чужой синевы в панели больше нет.
        HStack(spacing: 0) {
            Text(settings.anchorText)
                .font(Metrics.font)
                .monospacedDigit()
                .foregroundStyle(Palette.value)
                .frame(width: 44, alignment: .leading)
                .padding(.horizontal, 6)

            Rectangle().fill(Palette.fieldLine).frame(width: 1)

            VStack(spacing: 0) {
                StepButton(systemName: "chevron.up") { shift(by: 15) }
                Rectangle().fill(Color.white.opacity(0.14)).frame(height: 1)
                StepButton(systemName: "chevron.down") { shift(by: -15) }
            }
            .frame(width: 13)
        }
        .frame(height: 18)
        .background(Palette.fieldBg)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Palette.fieldLine, lineWidth: 1))
    }

    private func shift(by minutes: Int) {
        let next = AnchorInput.shifted(
            hour: settings.anchorHour,
            minute: settings.anchorMinute,
            byMinutes: minutes
        )
        onAnchor(next.hour, next.minute)
    }
}

// MARK: - Мелкие элементы

/// Тонкий разделитель с воздухом сверху и снизу.
private struct Sep: View {
    var body: some View {
        Rectangle()
            .fill(Palette.line)
            .frame(height: 1)
            .padding(.vertical, 8)
    }
}

/// Ряд гейджа: ключ, блочная шкала, процент справа.
private struct GaugeRow: View {
    let key: String
    let percent: Int
    let level: Level

    var body: some View {
        HStack(spacing: 10) {
            Text(key.uppercased())
                .font(Metrics.font)
                .tracking(Metrics.trackKey)
                .foregroundStyle(Palette.key)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .truncationMode(.tail)
                .frame(width: Metrics.keyColumn, alignment: .leading)

            bar
                .font(Metrics.font)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text("\(percent)%")
                .font(Metrics.font)
                .monospacedDigit()
                .foregroundStyle(Palette.value)
                .lineLimit(1)
                .frame(width: Metrics.percentColumn, alignment: .trailing)
        }
        .padding(.vertical, 2)
        .frame(minHeight: 20)
    }

    private var bar: Text {
        let g = Gauge.bars(percent: percent, width: Metrics.gaugeWidth)
        return Text(g.filled).foregroundStyle(Palette.accent(for: level))
            + Text(g.empty).foregroundStyle(Palette.empty)
    }
}

/// Ряд "ключ слева, значение справа".
private struct ConfigRow: View {
    let key: String
    let value: String
    var dim: Bool = false

    var body: some View {
        RowShell {
            RowKey(key.uppercased())
            Spacer(minLength: 8)
            Text(value)
                .font(Metrics.font)
                .monospacedDigit()
                .foregroundStyle(dim ? Palette.dim : Palette.value)
                .lineLimit(1)
                .multilineTextAlignment(.trailing)
        }
    }
}

/// Геометрия ряда, общая для текстовых строк и строк с контролом.
private struct RowShell<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 12) { content }
            .padding(.vertical, 3)
            .frame(minHeight: 22)
    }
}

private struct RowKey: View {
    let title: String
    var muted: Bool = false

    init(_ title: String, muted: Bool = false) {
        self.title = title
        self.muted = muted
    }

    var body: some View {
        Text(title.uppercased())
            .font(Metrics.font)
            .tracking(Metrics.trackKey)
            .foregroundStyle(muted ? Palette.faint : Palette.key)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .truncationMode(.tail)
    }
}

/// Пояснение под строкой настройки.
private struct Note: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(Metrics.font)
            .lineSpacing(3)
            .foregroundStyle(Palette.faint)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 2)
    }
}

private struct Switch: View {
    @Binding var isOn: Bool

    var body: some View {
        Toggle("", isOn: $isOn)
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .tint(Palette.accent)
    }
}

private struct StepButton: View {
    let systemName: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 5, weight: .semibold))
                .foregroundStyle(Palette.value.opacity(0.8))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.white.opacity(hovering ? 0.16 : 0.07))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct FootButton: View {
    let title: String
    let muted: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Metrics.font)
                .tracking(Metrics.trackFoot)
                .foregroundStyle(muted ? Palette.line : (hovering ? Palette.hover : Palette.faint))
                .lineLimit(1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
