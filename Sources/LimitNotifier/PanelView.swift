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

    /// Имена закончивших проектов. Палитра общая со строкой меню, лежит в ядре.
    static func project(_ index: Int) -> Color {
        let step = ProjectPalette.step(index)
        return Color(red: step.red, green: step.green, blue: step.blue)
    }
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

/// Часы и минуты даты без DateFormatter: календарь передаём параметром.
/// Центы важны на мелких суммах, на крупных только шум.
private func fmtMoney(_ v: Double) -> String {
    v >= 100 ? String(format: "$%.0f", v) : String(format: "$%.2f", v)
}

private func hhmm(_ date: Date, calendar: Calendar = .current) -> String {
    let c = calendar.dateComponents([.hour, .minute], from: date)
    return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
}

// MARK: - Размеры панели

/// Ширины в одном месте: их знает и вёрстка, и код, который держит попап
/// в пределах экрана.
enum PanelSize {
    static let limits: CGFloat = 300
    static let stats: CGFloat = 452

    static func total(statsOpen: Bool) -> CGFloat {
        statsOpen ? limits + 1 + stats : limits   // +1 это разделитель
    }
}

// MARK: - Панель

struct PanelView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Group {
            switch model.screen {
            case .board:
                boardScreen().frame(width: PanelSize.limits, alignment: .leading)
            case .limits:
                // Разъезжаемся только вширь: панель лимитов слева остаётся
                // ровно такой же, статистика пристраивается справа.
                HStack(alignment: .top, spacing: 0) {
                    limitsScreen(now: Date())
                        .frame(width: PanelSize.limits, alignment: .leading)
                    if model.statsOpen {
                        Divider().overlay(Palette.line)
                        StatsPane(model: model)
                            .frame(width: PanelSize.stats, alignment: .leading)
                    }
                }
            }
        }
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

            readyBlock()

            Sep()

            percentRow()
            plaqueRow()
            loginRow()
            languageRow()

            footer()
        }
        .padding(EdgeInsets(top: 13, leading: 14, bottom: 12, trailing: 14))
    }

    // MARK: Шапка лимитов (с кнопкой назад на борд)

    /// Назад слева, остаток по центру, разворот статистики справа.
    /// Крайние колонки равной ширины, иначе центр уезжает вслед за длиной кнопки.
    private func header(now: Date) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Button(action: { model.showBoard() }) {
                Text("‹ BOARD")
                    .font(Metrics.font).tracking(Metrics.trackFoot)
                    .foregroundStyle(Palette.accent)
            }
            .buttonStyle(.plain)
            .frame(width: 62, alignment: .leading)

            headerReset(now: now)
                .font(Metrics.font)
                .monospacedDigit()
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .center)

            Button(action: { model.toggleStats() }) {
                Text(model.statsOpen ? "STATS ‹" : "STATS ⤢")
                    .font(Metrics.font).tracking(Metrics.trackFoot)
                    .foregroundStyle(Palette.accent)
            }
            .buttonStyle(.plain)
            .frame(width: 62, alignment: .trailing)
        }
        .padding(.bottom, 10)
    }

    private func headerReset(now: Date) -> Text {
        guard let at = model.snapshot?.main?.resetsAt else {
            return Text("no data yet").foregroundStyle(Palette.faint)
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
            // Сброс недельного стоит в шапке, скоупные окна (fable и прочие)
            // сбрасываются вместе с ним: отдельная строка повторяла бы шапку.
            ConfigRow(key: "Updated", value: hhmm(snapshot.fetchedAt), dim: true)
        }
    }

    // MARK: Деньги

    // MARK: Уведомления об окончании

    /// Стоит выше keep-alive: это то, ради чего в панель заглядывают чаще всего.
    private func readyBlock() -> some View {
        VStack(alignment: .leading, spacing: 0) {
            RowShell {
                RowKey("READY ALERTS")
                Spacer(minLength: 8)
                Button(action: { model.notifyOn ? model.setNotify(false) : model.showNotifyHelp() }) {
                    Text(model.notifyOn ? L.s("ВКЛ", "ON") : L.s("НАСТРОИТЬ", "SET UP"))
                        .font(.system(size: 10, design: .monospaced))
                        .tracking(Metrics.trackFoot)
                        .foregroundStyle(model.notifyOn ? Palette.accent : Palette.dim)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .overlay(RoundedRectangle(cornerRadius: 7)
                            .stroke(model.notifyOn ? Palette.accent.opacity(0.5) : Palette.line,
                                    lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            if model.recent.isEmpty {
                Note(L.s("Строка меню прокрутит имя проекта, когда claude в другом окне закончит",
                         "The menu bar scrolls the project name when claude finishes in another window"))
            } else {
                ForEach(model.recent) { item in
                    ReadyRow(item: item,
                             onOpen: { model.openProject(item) },
                             onDismiss: { model.dismiss(item.name) })
                }
            }
        }
    }

    // MARK: Только проценты

    private func percentRow() -> some View {
        RowShell {
            RowKey(L.s("Только проценты", "Percent only"))
            Spacer(minLength: 8)
            Switch(isOn: Binding(
                get: { model.percentOnly },
                set: { model.setPercentOnly($0) }
            ))
        }
    }

    // MARK: Плавающая плашка

    /// Место в строке меню раздаёт система, и приложениям с длинным меню её не
    /// хватает: наш элемент выкидывают. В авто плашка появляется сама, когда
    /// это случилось, и уходит, когда место вернулось.
    ///
    /// Выключить надо давать явно: определение вытеснения опирается на список
    /// окон системы, а он недокументирован, и если он где-то соврёт, человек
    /// должен просто выключить, а не бороться с догадками приложения.
    private func plaqueRow() -> some View {
        VStack(alignment: .leading, spacing: 0) {
            RowShell {
                RowKey(L.s("Плашка", "Plaque"))
                Spacer(minLength: 8)
                HStack(spacing: 5) {
                    ForEach(PlaqueMode.allCases, id: \.self) { mode in
                        Button(action: { model.setPlaqueMode(mode) }) {
                            Text(Self.plaqueTitle(mode))
                                .font(Metrics.font).tracking(Metrics.trackFoot)
                                .foregroundStyle(model.plaqueMode == mode
                                                 ? Palette.value : Palette.faint)
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(RoundedRectangle(cornerRadius: 6)
                                    .fill(model.plaqueMode == mode ? Palette.fieldBg : .clear))
                                .overlay(RoundedRectangle(cornerRadius: 6)
                                    .stroke(model.plaqueMode == mode
                                            ? Palette.fieldLine : Palette.line, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Note(Self.plaqueNote(model.plaqueMode))
        }
    }

    private static func plaqueTitle(_ mode: PlaqueMode) -> String {
        switch mode {
        case .off:    return L.s("ВЫКЛ", "OFF")
        case .auto:   return L.s("АВТО", "AUTO")
        case .always: return L.s("ВСЕГДА", "ALWAYS")
        }
    }

    private static func plaqueNote(_ mode: PlaqueMode) -> String {
        switch mode {
        case .off:
            return L.s("Только строка меню, что бы ни случилось",
                       "Menu bar only, whatever happens")
        case .auto:
            return L.s("Появится сама, если нас вытеснят из строки меню",
                       "Shows up on its own if we get squeezed out of the menu bar")
        case .always:
            return L.s("Висит поверх всего, включая полный экран",
                       "Floats above everything, fullscreen included")
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

    // MARK: Язык

    /// По умолчанию берём язык системы, но оставляем переключатель: у людей
    /// система бывает английская, а привычка читать по-русски остаётся.
    private func languageRow() -> some View {
        RowShell {
            RowKey(L.s("Язык", "Language"))
            Spacer(minLength: 8)
            HStack(spacing: 5) {
                ForEach([L.Lang.ru, L.Lang.en], id: \.self) { lang in
                    Button(action: { model.setLanguage(lang) }) {
                        Text(lang == .ru ? "RU" : "EN")
                            .font(Metrics.font).tracking(Metrics.trackFoot)
                            .foregroundStyle(L.lang == lang ? Palette.value : Palette.faint)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 6)
                                .fill(L.lang == lang ? Palette.fieldBg : .clear))
                            .overlay(RoundedRectangle(cornerRadius: 6)
                                .stroke(L.lang == lang ? Palette.fieldLine : Palette.line,
                                        lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
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
            if let update = model.updateVersion {
                // Обновление важнее самой версии, поэтому вместо неё и заметным
                // цветом. Клик ведёт на страницу релизов.
                Button(action: { model.openReleases() }) {
                    Text("UPDATE \(update) ↗")
                        .font(Metrics.font).tracking(Metrics.trackFoot)
                        .foregroundStyle(Palette.accent)
                }
                .buttonStyle(.plain)
            } else {
                Text(Self.buildLabel)
                    .font(Metrics.font).tracking(Metrics.trackFoot)
                    .foregroundStyle(Palette.faint)
            }
            Spacer(minLength: 8)
            FootButton(title: "QUIT", muted: false, action: { model.quit() })
        }
        .padding(.top, 2)
    }

    /// Версия и билд для угла панели. Билд это короткий git-хэш из BuildSHA,
    /// который проставляет make-app.sh, чтоб по скриншоту было видно что за код.
    private static var buildLabel: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let sha = info?["BuildSHA"] as? String
        return sha.map { "v\(version) · \($0)" } ?? "v\(version)"
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
                .help(L.s("случайный звук", "random sound"))
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
        .help(L.s("лимиты Клауде", "Claude limits"))
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


/// Строка "кто закончил": по имени переходим к окну проекта, крестик просто
/// убирает запись. Разведено намеренно: клик по всей строке был удобнее, но
/// теперь у имени есть своё дело, и промахиваться мимо него нельзя.
private struct ReadyRow: View {
    let item: AppModel.Finished
    let onOpen: () -> Void
    let onDismiss: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onOpen) {
                Text(item.name.uppercased())
                    .font(Metrics.font).tracking(Metrics.trackKey)
                    .foregroundStyle(Palette.project(item.colorIndex))
                    .lineLimit(1).truncationMode(.tail)
                    .underline(hovering)
            }
            .buttonStyle(.plain)
            .help(L.s("перейти к окну проекта", "go to the project window"))

            Spacer(minLength: 8)
            Text(hhmm(item.at))
                .font(Metrics.font).monospacedDigit()
                .foregroundStyle(Palette.faint)
            // Крестик появляется под курсором, чтобы в покое не рябить.
            Button(action: onDismiss) {
                Text("×")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(hovering ? Palette.hover : .clear)
                    .frame(width: 10)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L.s("убрать из списка", "remove from the list"))
        }
        .padding(.vertical, 3)
        .onHover { hovering = $0 }
    }
}
