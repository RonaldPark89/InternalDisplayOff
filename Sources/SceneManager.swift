import Foundation
import Combine

struct DisplayScene: Identifiable, Codable {
    let id: String
    var name: String
    var state: [String: Bool]  // DisplayState.persistenceKey -> isEnabled
    var isBuiltIn: Bool

    func targetEnabled(for display: DisplayState) -> Bool? {
        state[display.persistenceKey] ?? state[String(display.id)]
    }
}

@MainActor
final class SceneManager: ObservableObject {
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
        let allState = Dictionary(uniqueKeysWithValues: displays.map { ($0.persistenceKey, true) })
        scenes.append(DisplayScene(id: "builtin-all", name: "All Displays", state: allState, isBuiltIn: true))

        let externals = displays.filter { !$0.isBuiltin }
            .sorted { $0.physicalSizeInches > $1.physicalSizeInches }
        let internalKey = displays.first(where: { $0.isBuiltin }).map(\.persistenceKey)

        for (index, external) in externals.enumerated() {
            let sizeLabel = external.physicalSizeInches > 0
                ? "\(Int(external.physicalSizeInches.rounded()))\""
                : external.name
            // If two or more externals share the same size, disambiguate with a number.
            let sameSize = externals.filter {
                Int($0.physicalSizeInches.rounded()) == Int(external.physicalSizeInches.rounded())
            }.count
            let label = sameSize > 1 ? "\(sizeLabel) (\(index + 1))" : sizeLabel
            var state = Dictionary(uniqueKeysWithValues: displays.map { ($0.persistenceKey, false) })
            state[external.persistenceKey] = true
            scenes.append(DisplayScene(
                id: "builtin-focus-\(external.id)",
                name: "Focus on \(label)",
                state: state,
                isBuiltIn: true
            ))
        }

        if !externals.isEmpty, let iKey = internalKey {
            var internalState = Dictionary(uniqueKeysWithValues: displays.map { ($0.persistenceKey, false) })
            internalState[iKey] = true
            scenes.append(DisplayScene(id: "builtin-internal-only", name: "Internal Only",
                                       state: internalState, isBuiltIn: true))

            var externalState = Dictionary(uniqueKeysWithValues: displays.map { ($0.persistenceKey, true) })
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
            displays.allSatisfy { display in
                scene.targetEnabled(for: display) == display.isEnabled
            }
        }
    }

    /// Converts legacy numeric scene keys when their original session IDs are
    /// still present. New and already-migrated keys are left untouched.
    func migrateLegacyScenes(using displays: [DisplayState]) {
        var changed = false
        for sceneIndex in userScenes.indices {
            for display in displays {
                let legacyKey = String(display.id)
                guard userScenes[sceneIndex].state[display.persistenceKey] == nil,
                      let value = userScenes[sceneIndex].state.removeValue(forKey: legacyKey) else {
                    continue
                }
                userScenes[sceneIndex].state[display.persistenceKey] = value
                changed = true
            }
        }
        if changed {
            saveToUserDefaults()
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
