import Foundation

/// Настройки. UserDefaults, без файлов и без базы: значений тут горстка.
public final class Settings: ObservableObject {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private enum Keys {
        static let visitedLimits = "visitedLimits"
        static let language = "language"
        static let plaqueAlways = "plaqueAlways"
        static let plaqueMode = "plaqueMode"
        static let percentOnly = "percentOnly"
        static let plaqueX = "plaqueX"
        static let plaqueY = "plaqueY"
    }

    @Published public var version = 0
    private func bump() { version &+= 1 }

    /// Выбранный язык интерфейса. nil значит "как в системе": пока человек сам
    /// не переключил, слушаемся системного языка, а не запоминаем его навсегда.
    public var language: L.Lang? {
        get {
            switch defaults.string(forKey: Keys.language) {
            case "ru": return .ru
            case "en": return .en
            default: return nil
            }
        }
        set {
            switch newValue {
            case .ru: defaults.set("ru", forKey: Keys.language)
            case .en: defaults.set("en", forKey: Keys.language)
            case nil: defaults.removeObject(forKey: Keys.language)
            }
            bump()
        }
    }

    /// Заходил ли пользователь хоть раз на экран лимитов. Если да, панель
    /// открывается сразу на лимитах, а гачи-борд становится вторым экраном.
    public var visitedLimits: Bool {
        get { defaults.bool(forKey: Keys.visitedLimits) }
        set { defaults.set(newValue, forKey: Keys.visitedLimits); bump() }
    }

    /// Режим плавающей плашки. По умолчанию авто: появляется, когда нас
    /// вытеснили из строки меню, и уходит, когда место вернулось.
    ///
    /// Прежний тумблер "всегда" переносим как есть: у кого он был включён, тот
    /// и получит always, остальные авто.
    public var plaqueMode: PlaqueMode {
        get {
            if let raw = defaults.string(forKey: Keys.plaqueMode),
               let mode = PlaqueMode(rawValue: raw) { return mode }
            return defaults.bool(forKey: Keys.plaqueAlways) ? .always : .auto
        }
        set { defaults.set(newValue.rawValue, forKey: Keys.plaqueMode); bump() }
    }

    /// В строке меню только два процента, без времени до сброса: 84/34 вместо
    /// 84/34/1h07/4d. Для тех, кому важна сама нагрузка, а не часы, и у кого
    /// строка меню и так забита.
    public var percentOnly: Bool {
        get { defaults.bool(forKey: Keys.percentOnly) }
        set { defaults.set(newValue, forKey: Keys.percentOnly); bump() }
    }

    /// Куда её перетащили. nil, пока не двигали: тогда встаёт в правый верхний
    /// угол под строкой меню.
    ///
    /// bump тут не зовём: позиция это не состояние интерфейса панели, а
    /// перерисовывать её на каждый пиксель перетаскивания незачем.
    public var plaqueOrigin: CGPoint? {
        get {
            guard let x = defaults.object(forKey: Keys.plaqueX) as? Double,
                  let y = defaults.object(forKey: Keys.plaqueY) as? Double else { return nil }
            return CGPoint(x: x, y: y)
        }
        set {
            guard let newValue else {
                defaults.removeObject(forKey: Keys.plaqueX)
                defaults.removeObject(forKey: Keys.plaqueY)
                return
            }
            defaults.set(newValue.x, forKey: Keys.plaqueX)
            defaults.set(newValue.y, forKey: Keys.plaqueY)
        }
    }
}
