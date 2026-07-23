import Foundation

/// Настройки. UserDefaults, без файлов и без базы: тут четыре значения.
public final class Settings: ObservableObject {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Keys.anchorHour: 9,
            Keys.anchorMinute: 0,
            Keys.keepAlive: false,
            Keys.wakeMac: false,
        ])
    }

    private enum Keys {
        static let anchorHour = "anchorHour"
        static let anchorMinute = "anchorMinute"
        static let keepAlive = "keepAliveEnabled"
        static let wakeMac = "wakeMacEnabled"
        static let visitedLimits = "visitedLimits"
    }

    @Published public var version = 0
    private func bump() { version &+= 1 }

    public var keepAliveEnabled: Bool {
        get { defaults.bool(forKey: Keys.keepAlive) }
        set { defaults.set(newValue, forKey: Keys.keepAlive); bump() }
    }

    /// Утренний якорь: время, к которому 5-часовое окно должно быть уже сброшено.
    public var anchorHour: Int {
        get { defaults.integer(forKey: Keys.anchorHour) }
        set { defaults.set(min(max(newValue, 0), 23), forKey: Keys.anchorHour); bump() }
    }

    public var anchorMinute: Int {
        get { defaults.integer(forKey: Keys.anchorMinute) }
        set { defaults.set(min(max(newValue, 0), 59), forKey: Keys.anchorMinute); bump() }
    }

    /// Будить мак ради ночного пинга. По умолчанию выключено: спящий мак не
    /// может иметь активного окна к утру, так что свежесть и так гарантирована.
    /// Заходил ли пользователь хоть раз на экран лимитов. Если да, панель
    /// открывается сразу на лимитах, а гачи-борд становится вторым экраном.
    public var visitedLimits: Bool {
        get { defaults.bool(forKey: Keys.visitedLimits) }
        set { defaults.set(newValue, forKey: Keys.visitedLimits); bump() }
    }

    public var wakeMacEnabled: Bool {
        get { defaults.bool(forKey: Keys.wakeMac) }
        set { defaults.set(newValue, forKey: Keys.wakeMac); bump() }
    }

    public var anchorText: String {
        String(format: "%02d:%02d", anchorHour, anchorMinute)
    }
}
