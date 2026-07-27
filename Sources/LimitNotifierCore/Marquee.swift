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
