import Foundation

/// Движение ленты в строке меню: лимиты уезжают влево, за ними имена проектов.
///
/// Профиль скорости трапецеидальный, как у доводчика двери: лента разгоняется с
/// постоянным ускорением до рабочей скорости, идёт ровно, потом так же плавно
/// замирает. Поэтому easing не подбирается на глаз, а следует из физики:
/// путь разгона это speed * ramp / 2, иначе на стыке разгона и ровного хода
/// была бы видна ступенька скорости.
public struct Marquee: Sendable {
    /// Точек в секунду на ровном ходу.
    public let speed: Double
    /// Сколько длится разгон и, симметрично, торможение.
    public let ramp: Double
    /// Сколько раз лента проезжает период за один прогон: первый зовёт, второй читают.
    public let passes: Int

    public init(speed: Double = 90, ramp: Double = 0.7, passes: Int = 2) {
        precondition(speed > 0 && ramp > 0 && passes > 0)
        self.speed = speed
        self.ramp = ramp
        self.passes = passes
    }

    /// Ускорение, с которым набирается рабочая скорость.
    var acceleration: Double { speed / ramp }
    /// Путь, который лента проходит за разгон.
    var rampDistance: Double { speed * ramp / 2 }

    /// Полный путь прогона: период ленты, помноженный на число проходов.
    public func distance(period: Double) -> Double { period * Double(passes) }

    /// Сколько длится прогон целиком.
    public func duration(period: Double) -> Double {
        let total = distance(period: period)
        guard total > 0 else { return 0 }
        // Короткая лента: разогнаться до рабочей скорости не успеваем, профиль
        // становится треугольным, вершина ниже speed.
        guard total >= rampDistance * 2 else {
            return 2 * (total / acceleration).squareRoot()
        }
        let cruise = total - rampDistance * 2
        return ramp * 2 + cruise / speed
    }

    /// Пауза на лимитах между прогонами.
    ///
    /// Считаем от одного проезда, а не от всей поездки: два проезда это уже сам
    /// сигнал, и растягивать тишину вдвое незачем.
    public func hold(period: Double, ratio: Double = 4) -> Double {
        duration(period: period) / Double(passes) * ratio
    }

    /// Смещение ленты влево в момент t от начала прогона, в точках.
    /// Вне интервала прогона возвращает края: 0 и полный путь.
    public func offset(at t: Double, period: Double) -> Double {
        let total = distance(period: period)
        let full = duration(period: period)
        guard total > 0, full > 0 else { return 0 }
        if t <= 0 { return 0 }
        if t >= full { return total }

        guard total >= rampDistance * 2 else {
            // Треугольный профиль: половину времени разгон, половину торможение.
            let half = full / 2
            if t <= half { return acceleration * t * t / 2 }
            let left = full - t
            return total - acceleration * left * left / 2
        }
        if t <= ramp { return acceleration * t * t / 2 }
        let cruiseEnd = full - ramp
        if t <= cruiseEnd { return rampDistance + speed * (t - ramp) }
        let left = full - t
        return total - acceleration * left * left / 2
    }
}

/// Цвета имён проектов: три ступени синего.
///
/// Живут в ядре, потому что нужны обоим слоям сразу: строке меню, где имена
/// едут лентой, и панели, где висит список закончивших. Если держать по копии
/// в каждом, они рано или поздно разъедутся.
///
/// Гамма холодная намеренно. Тёплая половина занята шкалой лимитов, где зелёный
/// значит спокойно, а розовый и красный жарко: покрась имена так же, и глаз
/// станет читать их как продолжение шкалы.
public enum ProjectPalette {
    public static let steps: [(red: Double, green: Double, blue: Double)] = [
        (0xa8 / 255, 0xd8 / 255, 1.0),
        (0x6a / 255, 0xa9 / 255, 0xe8 / 255),
        (0x4a / 255, 0x7f / 255, 0xc0 / 255),
    ]

    /// Цвет по месту в очереди. Дальше третьего по кругу: столько проектов
    /// одновременно всё равно не заканчивается.
    public static func step(_ index: Int) -> (red: Double, green: Double, blue: Double) {
        steps[((index % steps.count) + steps.count) % steps.count]
    }
}
