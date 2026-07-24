import Foundation

/// Проверка новой версии через публичный GitHub API.
///
/// Sparkle и прочие автообновлялки сюда не тащим: приложение раздаётся зипом и
/// через brew, а самообновление подписанного бандла это отдельная морока с
/// ключами. Наша задача скромнее: заметить, что вышла новая версия, и показать
/// это в углу панели. Обновляется человек сам, кнопкой или `brew upgrade`.
public enum UpdateCheck {
    public static let repo = "marblecake88/claude-limits-gachi-soundboard"

    /// Куда вести человека по клику.
    public static var releasesURL: URL {
        URL(string: "https://github.com/\(repo)/releases/latest")!
    }

    /// Тег последнего релиза без ведущей v, например "1.1.1".
    /// Молча возвращает nil на любой проблеме: нет сети, лимит API, мусор в
    /// ответе. Обновление это приятный бонус, а не повод показывать ошибку.
    public static func latestTag(timeout: TimeInterval = 10) async -> String? {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        request.timeoutInterval = timeout
        // Без этого GitHub иногда отдаёт другую форму ответа.
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String
        else { return nil }
        return normalize(tag)
    }

    static func normalize(_ tag: String) -> String {
        var t = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("v") || t.hasPrefix("V") { t.removeFirst() }
        return t
    }

    /// Сравниваем по числовым компонентам, а не строками: иначе "1.10"
    /// оказалось бы старше "1.9", и человек не увидел бы обновление.
    /// Нечисловой хвост (1.2-beta) отбрасываем, для нашей нумерации хватает.
    public static func isNewer(_ latest: String, than current: String) -> Bool {
        let a = parts(latest), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let l = i < a.count ? a[i] : 0
            let c = i < b.count ? b[i] : 0
            if l != c { return l > c }
        }
        return false
    }

    private static func parts(_ version: String) -> [Int] {
        normalize(version).split(separator: ".").map {
            Int($0.prefix { $0.isNumber }) ?? 0
        }
    }
}
