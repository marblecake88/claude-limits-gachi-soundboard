import SwiftUI
import LimitNotifierCore

/// Правое крыло панели: статистика использования по локальным транскриптам.
///
/// Появляется по кнопке STATS и живёт только рядом с экраном лимитов. Панель
/// лимитов при этом не меняется ни на пиксель, попап разъезжается вширь.
struct StatsPane: View {
    @ObservedObject var model: AppModel

    private var slice: StatsSlice {
        StatsSlicer.slice(model.stats, period: model.statsPeriod)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            head()

            if model.stats.isEmpty {
                Spacer()
                Text(model.statsScanning
                     ? L.s("считаю…", "counting…")
                     : L.s("данных пока нет", "no data yet"))
                    .font(StatsMetrics.font)
                    .foregroundStyle(StatsPalette.faint)
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer()
            } else {
                let s = slice
                kpis(s)
                chartBlock(s)
                Divider().overlay(StatsPalette.line).padding(.vertical, 11)
                bottom(s)
                Divider().overlay(StatsPalette.line).padding(.vertical, 10)
                money()
                Divider().overlay(StatsPalette.line).padding(.vertical, 10)
                record()
            }
        }
        .padding(EdgeInsets(top: 13, leading: 15, bottom: 12, trailing: 15))
    }

    // MARK: Шапка с переключателем периода

    private func head() -> some View {
        HStack(spacing: 6) {
            Text(L.s("СТАТИСТИКА", "STATISTICS"))
                .font(StatsMetrics.font).tracking(0.9)
                .foregroundStyle(StatsPalette.key)
            Button(action: { model.refreshStats() }) {
                Text(model.statsScanning ? "…" : "⟳")
                    .font(StatsMetrics.font)
                    .foregroundStyle(model.statsScanning
                                     ? StatsPalette.faint : StatsPalette.accent)
            }
            .buttonStyle(.plain)
            .disabled(model.statsScanning)
            // Обычное обновление идёт само и дочитывает только новое, поэтому
            // кнопка это именно полный пересчёт, и он не мгновенный.
            .help(L.s("перечитать всё заново, это небыстро",
                      "recount everything from scratch, takes a while"))
            Spacer(minLength: 8)
            ForEach(StatsPeriod.allCases, id: \.self) { period in
                Button(action: { model.setStatsPeriod(period) }) {
                    Text(period.title)
                        .font(StatsMetrics.small)
                        .foregroundStyle(period == model.statsPeriod
                                         ? StatsPalette.value : StatsPalette.key)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(period == model.statsPeriod
                                      ? StatsPalette.accentSoft : .clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(period == model.statsPeriod
                                        ? StatsPalette.accentLine : StatsPalette.line, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.bottom, 11)
    }

    // MARK: Плитки

    private func kpis(_ s: StatsSlice) -> some View {
        HStack(spacing: 1) {
            kpi(L.s("ТОКЕНОВ", "TOKENS"), Fmt.tokens(s.total))
            kpi(L.s("СЕССИЙ", "SESSIONS"), "\(model.stats.transcripts)")
            kpi(L.s("ДНЕЙ", "DAYS"), "\(s.dayCount)")
            kpi(L.s("СТРИК", "STREAK"), "\(model.stats.currentStreak)",
                accent: model.stats.currentStreak > 0)
        }
        .background(StatsPalette.line)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(StatsPalette.line, lineWidth: 1))
        .padding(.bottom, 12)
    }

    private func kpi(_ key: String, _ value: String, accent: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(key).font(StatsMetrics.small).tracking(0.8)
                .foregroundStyle(StatsPalette.key)
                .lineLimit(1).minimumScaleFactor(0.75)
            Text(value).font(StatsMetrics.big).monospacedDigit()
                .foregroundStyle(accent ? StatsPalette.accent : StatsPalette.value)
        }
        .padding(.horizontal, 9).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StatsPalette.card)
    }

    // MARK: График

    private func chartBlock(_ s: StatsSlice) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(s.title).font(StatsMetrics.font).tracking(0.9)
                    .foregroundStyle(StatsPalette.key)
                Text(L.s("без кэша", "no cache"))
                    .font(StatsMetrics.small).foregroundStyle(StatsPalette.faint)
                Spacer(minLength: 6)
                legend(s.models)
            }
            ColumnsChart(columns: s.columns, models: s.models)
                .frame(height: 104)   // включая подписи оси снизу
        }
    }

    private func legend(_ models: [String]) -> some View {
        HStack(spacing: 8) {
            ForEach(models.prefix(4), id: \.self) { model in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(StatsPalette.series(models.firstIndex(of: model) ?? 0))
                        .frame(width: 7, height: 7)
                    Text(model).font(StatsMetrics.small).foregroundStyle(StatsPalette.key)
                }
            }
        }
    }

    // MARK: Низ: хитмап и модели

    private func bottom(_ s: StatsSlice) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L.s("АКТИВНОСТЬ ЗА ВСЁ ВРЕМЯ", "ACTIVITY, ALL TIME"))
                    .font(StatsMetrics.small).tracking(0.8)
                    .foregroundStyle(StatsPalette.key)
                Heatmap(stats: model.stats)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(L.s("МОДЕЛИ", "MODELS"))
                    .font(StatsMetrics.small).tracking(0.8)
                    .foregroundStyle(StatsPalette.key)
                ForEach(Array(s.models.prefix(5).enumerated()), id: \.element) { index, name in
                    modelRow(name, value: s.modelTotals[name] ?? 0, total: s.total, index: index)
                }
            }
            .frame(width: 168, alignment: .leading)
        }
    }

    /// Полоска модели теми же блоками, что и гейджи лимитов: язык один.
    private func modelRow(_ name: String, value: Int, total: Int, index: Int) -> some View {
        let percent = total > 0 ? Int((Double(value) / Double(total) * 100).rounded()) : 0
        let bars = Gauge.bars(percent: percent, width: 10)
        return HStack(spacing: 6) {
            Text(name).font(StatsMetrics.small)
                .foregroundStyle(StatsPalette.key)
                .lineLimit(1).minimumScaleFactor(0.8)
                .frame(width: 58, alignment: .leading)
            (Text(bars.filled).foregroundStyle(StatsPalette.series(index))
             + Text(bars.empty).foregroundStyle(StatsPalette.empty))
                .font(StatsMetrics.small)
            Spacer(minLength: 2)
            Text("\(percent)%").font(StatsMetrics.small).monospacedDigit()
                .foregroundStyle(StatsPalette.value)
        }
    }

    // MARK: Деньги

    /// Во сколько обошёлся бы объём по тарифам API.
    ///
    /// Раньше жило в панели лимитов двумя строками, но там для этого мало
    /// места: тут помещается и разбивка по моделям, и честная сумма за всё
    /// время, посчитанная с кэшевыми токенами.
    private func money() -> some View {
        let lifetime = model.stats.lifetimeCost
        let total = model.stats.lifetimeCostTotal
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(L.s("ПО ТАРИФАМ API", "AT API RATES"))
                    .font(StatsMetrics.font).tracking(0.9)
                    .foregroundStyle(StatsPalette.key)
                Spacer(minLength: 6)
                Text(L.s("Клауде хочет чтоб вы думали что тратите именно столько",
                         "Claude wants you to think this is what you spend"))
                    .font(StatsMetrics.tiny).foregroundStyle(StatsPalette.faint)
                    .lineLimit(2).minimumScaleFactor(0.85)
            }
            HStack(spacing: 1) {
                kpi(L.s("СЕГОДНЯ", "TODAY"), money(model.spend.today))
                kpi(L.s("7 ДНЕЙ", "7 DAYS"), money(model.spend.week))
                kpi(L.s("ЗА ВСЁ ВРЕМЯ", "ALL TIME"), money(total), accent: true)
            }
            .background(StatsPalette.line)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(StatsPalette.line, lineWidth: 1))

            if total > 0 {
                // По моделям: видно, кто съедает бюджет. Считается с кэшем,
                // поэтому суммы сильно больше, чем кажется по токенам.
                let sorted = lifetime.sorted { $0.value > $1.value }.prefix(4)
                HStack(spacing: 12) {
                    ForEach(Array(sorted.enumerated()), id: \.element.key) { index, item in
                        HStack(spacing: 5) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(StatsPalette.series(index))
                                .frame(width: 7, height: 7)
                            Text(item.key).font(StatsMetrics.small)
                                .foregroundStyle(StatsPalette.key)
                            Text(money(item.value)).font(StatsMetrics.small).monospacedDigit()
                                .foregroundStyle(StatsPalette.value)
                        }
                    }
                }
            }
            if !model.spend.unknownModels.isEmpty {
                Text(L.s("без тарифа: ", "no rate: ")
                     + model.spend.unknownModels.joined(separator: ", "))
                    .font(StatsMetrics.tiny).foregroundStyle(StatsPalette.faint)
            }
        }
    }

    /// Центы важны на мелких суммах, на крупных это шум.
    private func money(_ value: Double) -> String {
        value >= 100 ? String(format: "$%.0f", value) : String(format: "$%.2f", value)
    }

    // MARK: Рекорд одной строкой

    private func record() -> some View {
        HStack(spacing: 8) {
            if let day = model.stats.busiestDay {
                Text(L.s("РЕКОРД", "BUSIEST")).font(StatsMetrics.small).tracking(0.8)
                    .foregroundStyle(StatsPalette.key)
                Text(Fmt.tokens(model.stats.total(of: day)))
                    .font(StatsMetrics.small).monospacedDigit()
                    .foregroundStyle(StatsPalette.value)
                Text(day + " · \(model.stats.requests[day] ?? 0) "
                     + L.s("сообщений", "messages"))
                    .font(StatsMetrics.small).foregroundStyle(StatsPalette.faint)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if model.stats.lifetimeTokens > 0 {
                Text(L.s("С КЭШЕМ ЗА ВСЁ ВРЕМЯ", "WITH CACHE, ALL TIME"))
                    .font(StatsMetrics.small).tracking(0.8)
                    .foregroundStyle(StatsPalette.key)
                Text(Fmt.tokens(model.stats.lifetimeTokens))
                    .font(StatsMetrics.small).monospacedDigit()
                    .foregroundStyle(StatsPalette.value)
            }
        }
    }
}

// MARK: - Столбцы

/// Стековые столбцы: по одному на день, час или неделю, с подписанной осью.
private struct ColumnsChart: View {
    let columns: [StatsColumn]
    let models: [String]

    /// Пик столбца: без него высота ни о чём не говорит.
    private var peak: Int { columns.map(\.total).max() ?? 0 }
    private var gap: CGFloat { columns.count > 40 ? 1 : 2 }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 5) {
                GeometryReader { geo in
                    let width = (geo.size.width - CGFloat(columns.count - 1) * gap)
                        / CGFloat(Swift.max(columns.count, 1))
                    HStack(alignment: .bottom, spacing: gap) {
                        ForEach(columns, id: \.id) { column in
                            bar(column, max: peak, height: geo.size.height)
                                .frame(width: Swift.max(width, 1))
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                }
                // Потолок шкалы сбоку, чтоб не спорил со столбцами за место.
                Text(Fmt.tokens(peak))
                    .font(StatsMetrics.tiny).monospacedDigit()
                    .foregroundStyle(StatsPalette.faint)
                    .frame(width: 34, alignment: .leading)
            }
            axis()
        }
    }

    /// Подписи под столбцами. Когда колонок мало, подписываем каждую, иначе
    /// только края и середину: иначе даты сливаются в кашу.
    @ViewBuilder
    private func axis() -> some View {
        if columns.count <= 12 {
            HStack(alignment: .top, spacing: gap) {
                ForEach(columns, id: \.id) { column in
                    Text(column.tick)
                        .font(StatsMetrics.tiny).monospacedDigit()
                        .foregroundStyle(StatsPalette.faint)
                        .lineLimit(1).minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.trailing, 39)   // столько занимает подпись потолка справа
        } else {
            HStack(spacing: 4) {
                Text(columns.first?.tick ?? "")
                Spacer(minLength: 2)
                Text(columns[columns.count / 2].tick)
                Spacer(minLength: 2)
                Text(columns.last?.tick ?? "")
            }
            .font(StatsMetrics.tiny).monospacedDigit()
            .foregroundStyle(StatsPalette.faint)
            .padding(.trailing, 39)
        }
    }

    private func bar(_ column: StatsColumn, max: Int, height: CGFloat) -> some View {
        // Сегменты сверху вниз в порядке моделей, между ними зазор в 1 точку,
        // иначе соседние цвета склеиваются в одно пятно.
        VStack(spacing: 1) {
            ForEach(Array(models.enumerated()), id: \.element) { index, name in
                if let value = column.parts[name], value > 0 {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(StatsPalette.series(index))
                        .frame(height: Swift.max(1, CGFloat(value) / CGFloat(Swift.max(max, 1)) * height))
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .bottom)
        .help("\(column.id) · \(Fmt.tokens(column.total))")
    }
}

// MARK: - Хитмап

/// Карта активности по дням: недели по столбцам, дни недели по строкам.
/// Всегда за всё время, период на неё не влияет: это карта, а не срез.
private struct Heatmap: View {
    let stats: UsageStats
    private let cell: CGFloat = 10
    private let gap: CGFloat = 2.5
    private let weeks = 13

    var body: some View {
        let max = stats.days.keys.map { stats.total(of: $0) }.max() ?? 1
        let last = stats.sortedDays.last.flatMap { StatsSlicer.isoDate($0) } ?? Date()
        HStack(spacing: gap) {
            ForEach(0..<weeks, id: \.self) { week in
                VStack(spacing: gap) {
                    ForEach(0..<7, id: \.self) { weekday in
                        cellView(week: week, weekday: weekday, last: last, max: max)
                    }
                }
            }
        }
    }

    private func cellView(week: Int, weekday: Int, last: Date, max: Int) -> some View {
        let calendar = Calendar.current
        let shift = (calendar.component(.weekday, from: last) + 5) % 7
        let offset = -( (weeks - 1 - week) * 7 ) - shift + weekday
        let date = calendar.date(byAdding: .day, value: offset, to: last) ?? last
        let key = StatsSlicer.isoString(date)
        let value = stats.total(of: key)
        let future = date > last
        return RoundedRectangle(cornerRadius: 2)
            .fill(future ? Color.clear : StatsPalette.heat(value: value, max: max))
            .frame(width: cell, height: cell)
            .help(future ? "" : "\(key) · \(Fmt.tokens(value))")
    }
}

// MARK: - Оформление статистики

enum StatsPalette {
    static let value = Color(red: 233/255, green: 233/255, blue: 238/255)
    static let key = Color(red: 138/255, green: 138/255, blue: 147/255)
    static let faint = Color(red: 87/255, green: 87/255, blue: 95/255)
    static let line = Color.white.opacity(0.07)
    static let card = Color(red: 19/255, green: 19/255, blue: 23/255)
    static let empty = Color(red: 43/255, green: 43/255, blue: 49/255)
    static let accent = Color(red: 94/255, green: 231/255, blue: 208/255)
    static let accentSoft = Color(red: 94/255, green: 231/255, blue: 208/255).opacity(0.10)
    static let accentLine = Color(red: 94/255, green: 231/255, blue: 208/255).opacity(0.45)

    /// Цвета серий проверены валидатором на этом фоне: различимы и при
    /// дальтонизме, и по контрасту. Пятая и дальше уходят в серый.
    private static let seriesColors: [Color] = [
        Color(red: 0x39/255, green: 0x87/255, blue: 0xe5/255),
        Color(red: 0xd9/255, green: 0x59/255, blue: 0x26/255),
        Color(red: 0x19/255, green: 0x9e/255, blue: 0x70/255),
        Color(red: 0xc9/255, green: 0x85/255, blue: 0x00/255),
    ]
    static func series(_ index: Int) -> Color {
        index < seriesColors.count ? seriesColors[index]
                                   : Color(red: 137/255, green: 135/255, blue: 129/255)
    }

    /// Одна тональная шкала: чем больше токенов, тем светлее клетка.
    static func heat(value: Int, max: Int) -> Color {
        guard value > 0, max > 0 else { return Color(red: 21/255, green: 22/255, blue: 27/255) }
        let ratio = Double(value) / Double(max)
        if ratio > 0.5  { return Color(red: 0x86/255, green: 0xb6/255, blue: 0xef/255) }
        if ratio > 0.2  { return Color(red: 0x39/255, green: 0x87/255, blue: 0xe5/255) }
        if ratio > 0.05 { return Color(red: 0x25/255, green: 0x6a/255, blue: 0xbf/255) }
        return Color(red: 0x18/255, green: 0x4f/255, blue: 0x95/255)
    }
}

enum StatsMetrics {
    static let font = Font.system(size: 11, design: .monospaced)
    static let small = Font.system(size: 10, design: .monospaced)
    /// Для подписей осей: они не должны спорить с данными за внимание.
    static let tiny = Font.system(size: 9, design: .monospaced)
    static let big = Font.system(size: 16, design: .monospaced)
}
