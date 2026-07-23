import AppKit

/// Основная функция приложения: гачи-борд. Разрешение на семплы дал их автор.
///
/// Звуки лежат в бандле, в Contents/Resources/sounds, названия в index.json.
/// Играем через NSSound: он проигрывает один раз и сам не зацикливается.
@MainActor
final class SoundBoard {
    struct Clip: Identifiable, Sendable {
        let id: String   // имя файла, уникальное
        let title: String
        let url: URL
    }

    let clips: [Clip]
    /// Держим ссылку на играющий звук, иначе его приберёт ARC на середине.
    private var current: NSSound?
    private var currentID: String?
    private var holder: Holder?
    private var lastRandom = -1

    init() {
        let dir = Bundle.main.resourceURL?.appendingPathComponent("sounds")
        let files = (dir.flatMap {
            try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)
        } ?? []).filter { $0.pathExtension.lowercased() == "mp3" }

        let titles = Self.loadTitles(dir: dir)
        clips = files
            .map { Clip(id: $0.lastPathComponent,
                        title: titles[$0.lastPathComponent] ?? $0.deletingPathExtension().lastPathComponent,
                        url: $0) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    var isEmpty: Bool { clips.isEmpty }
    var isPlaying: Bool { current != nil }

    /// Играет конкретный клип. Если этот же уже играет, обрывает (тумблер).
    /// Иначе останавливает предыдущий и играет новый: звук всегда один.
    func play(_ clip: Clip) {
        if currentID == clip.id { stop(); return }
        start(clip)
    }

    /// Кошка: случайный клип, не повторяя предыдущий. Если что-то играет,
    /// нажатие обрывает. Возвращает true, если звук запущен, false если оборван,
    /// чтобы кошка росла на запуск и сжималась на обрыв.
    @discardableResult
    func tapRandom() -> Bool {
        if isPlaying { stop(); return false }
        guard !clips.isEmpty else { return false }
        var i = Int.random(in: 0..<clips.count)
        if clips.count > 1, i == lastRandom { i = (i + 1) % clips.count }
        lastRandom = i
        start(clips[i])
        return true
    }

    // MARK: - Проигрывание

    private func start(_ clip: Clip) {
        stop()
        guard let sound = NSSound(contentsOf: clip.url, byReference: true) else { return }
        sound.volume = 0.58   // минус 42 процента от системной громкости
        let h = Holder(board: self)
        sound.delegate = h
        current = sound
        currentID = clip.id
        holder = h
        sound.play()
    }

    private func stop() {
        current?.stop()
        current = nil
        currentID = nil
        holder = nil
    }

    private func finished() {
        current = nil
        currentID = nil
        holder = nil
    }

    /// NSSoundDelegate требует NSObject, а SoundBoard это @MainActor класс.
    private final class Holder: NSObject, NSSoundDelegate {
        weak var board: SoundBoard?
        init(board: SoundBoard) { self.board = board }
        func sound(_ sound: NSSound, didFinishPlaying flag: Bool) {
            Task { @MainActor in self.board?.finished() }
        }
    }

    // MARK: - Названия

    private static func loadTitles(dir: URL?) -> [String: String] {
        guard let url = dir?.appendingPathComponent("index.json"),
              let data = try? Data(contentsOf: url),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [:] }
        var map: [String: String] = [:]
        for item in arr {
            if let f = item["file"] as? String, let t = item["title"] as? String { map[f] = t }
        }
        return map
    }
}
