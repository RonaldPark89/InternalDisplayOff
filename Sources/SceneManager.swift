import Foundation
import Combine

struct DisplayScene: Identifiable, Codable {
    let id: String
    var name: String
    var state: [String: Bool]  // String(CGDirectDisplayID) -> isEnabled
    var isBuiltIn: Bool
}

class SceneManager: ObservableObject {
    static let shared = SceneManager()

    @Published var userScenes: [DisplayScene] = []

    private let defaultsKey = "SavedUserScenes"

    private init() {
        loadFromUserDefaults()
    }

    // Built-in scenes are computed from the current display set so they stay
    // accurate after hot-plug/unplug without needing to be re-saved.
    func builtInScenes(for displays: [DisplayState]) -> [DisplayScene] {
        guard !displays.isEmpty else { return [] }

        var scenes: [DisplayScene] = []
        let allState = Dictionary(uniqueKeysWithValues: displays.map { (String($0.id), true) })
        scenes.append(DisplayScene(id: "builtin-all", name: "All Displays", state: allState, isBuiltIn: true))

        let externals = displays.filter { !$0.isBuiltin }
            .sorted { $0.physicalSizeInches > $1.physicalSizeInches }
        let internalKey = displays.first(where: { $0.isBuiltin }).map { String($0.id) }

        for external in externals {
            let label = external.physicalSizeInches > 0
                ? "\(Int(external.physicalSizeInches.rounded()))\""
                : external.name
            var state = Dictionary(uniqueKeysWithValues: displays.map { (String($0.id), false) })
            state[String(external.id)] = true
            scenes.append(DisplayScene(
                id: "builtin-focus-\(external.id)",
                name: "Focus on \(label)",
                state: state,
                isBuiltIn: true
            ))
        }

        if !externals.isEmpty, let iKey = internalKey {
            var internalState = Dictionary(uniqueKeysWithValues: displays.map { (String($0.id), false) })
            internalState[iKey] = true
            scenes.append(DisplayScene(id: "builtin-internal-only", name: "Internal Only",
                                       state: internalState, isBuiltIn: true))

            var externalState = Dictionary(uniqueKeysWithValues: displays.map { (String($0.id), true) })
            externalState[iKey] = false
            scenes.append(DisplayScene(id: "builtin-externals-only", name: "Externals Only",
                                       state: externalState, isBuiltIn: true))
        }

        return scenes
    }

    func allScenes(for displays: [DisplayState]) -> [DisplayScene] {
        builtInScenes(for: displays) + userScenes
    }

    // Returns the scene whose on/off state exactly matches all current displays.
    func matchedScene(displays: [DisplayState], among scenes: [DisplayScene]) -> DisplayScene? {
        scenes.first { scene in
            displays.allSatisfy { d in scene.state[String(d.id)] == d.isEnabled }
        }
    }

    func save(_ scene: DisplayScene) {
        userScenes.append(scene)
        saveToUserDefaults()
    }

    func rename(_ id: String, to name: String) {
        if let idx = userScenes.firstIndex(where: { $0.id == id }) {
            userScenes[idx].name = name
            saveToUserDefaults()
        }
    }

    func delete(_ id: String) {
        userScenes.removeAll { $0.id == id && !$0.isBuiltIn }
        saveToUserDefaults()
    }

    private func loadFromUserDefaults() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([DisplayScene].self, from: data) else { return }
        userScenes = decoded.filter { !$0.isBuiltIn }
    }

    private func saveToUserDefaults() {
        guard let data = try? JSONEncoder().encode(userScenes) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}
