import SwiftUI
import AppKit

struct PopoverView: View {
    @ObservedObject var displayManager: DisplayManager
    @ObservedObject var sceneManager: SceneManager
    @ObservedObject var launchManager = LaunchManager.shared
    var onQuit: () -> Void

    @State private var isHoveringQuit = false
    @State private var pulseAnimation = false
    @AppStorage("ShowStatusNotifications") private var showNotifications = true

    // Draft state: user toggles monitors here before hitting Apply.
    // nil entry means "no override — use the display's actual current state."
    @State private var draftEnabled: [CGDirectDisplayID: Bool] = [:]

    private var displays: [DisplayState] { displayManager.displays }
    private var onCount: Int { displays.filter(\.isEnabled).count }

    private var allScenes: [DisplayScene] { sceneManager.allScenes(for: displays) }
    private var activeScene: DisplayScene? { sceneManager.matchedScene(displays: displays, among: allScenes) }
    private var canSaveScene: Bool {
        activeScene == nil && displays.count > 1 && onCount < displays.count
    }

    // MARK: - Draft helpers

    private func isDraftOn(_ id: CGDirectDisplayID) -> Bool {
        draftEnabled[id] ?? (displays.first(where: { $0.id == id })?.isEnabled ?? false)
    }
    private var draftOnCount: Int { displays.filter { isDraftOn($0.id) }.count }
    private var isDirty: Bool {
        displays.contains { draftEnabled[$0.id] != nil && draftEnabled[$0.id] != $0.isEnabled }
    }
    private func toggleDraft(_ id: CGDirectDisplayID) {
        let on = isDraftOn(id)
        guard !on || draftOnCount > 1 else { return }
        draftEnabled[id] = !on
    }
    private func resetDraft() { draftEnabled.removeAll() }
    private func applyDraft() {
        let state = Dictionary(uniqueKeysWithValues: displays.map { (String($0.id), isDraftOn($0.id)) })
        displayManager.applySceneState(state, sceneName: "Custom")
    }

    var body: some View {
        VStack(spacing: 0) {
            headerView
            Divider().padding(.horizontal, 12)
            spatialMapSection
            Divider().padding(.horizontal, 12)
            quickActionsSection
            Divider().padding(.horizontal, 12)
            savedScenesSection
            Divider().padding(.horizontal, 12)
            settingsSection
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

            if let error = displayManager.lastError {
                errorView(error)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
            }

            Divider().padding(.horizontal, 12)
            footerView
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
        }
        .frame(width: 380)
        .onAppear { resetDraft() }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color.accentColor.opacity(0.15))
                    .frame(width: 28, height: 28)
                Image(systemName: iconSymbol)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.accentColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Displays")
                    .font(.system(size: 13, weight: .semibold))
                Text(activeScene != nil ? activeScene!.name : "Tap to toggle on/off · Apply to confirm")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            HStack(spacing: 4) {
                Circle()
                    .fill(onCount < displays.count ? Color.orange : Color.green)
                    .frame(width: 6, height: 6)
                    .opacity(pulseAnimation ? 0.6 : 1.0)
                    .animation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true), value: pulseAnimation)
                Text("\(onCount)/\(displays.count)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(Color.primary.opacity(0.06))
            )
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .onAppear  { pulseAnimation = true  }
        .onDisappear { pulseAnimation = false }
    }

    private var iconSymbol: String {
        if onCount == displays.count { return "display" }
        if onCount == 1 {
            let soloDisplay = displays.first(where: { $0.isEnabled })
            if let d = soloDisplay, !d.isBuiltin, d.physicalSizeInches >= 27 {
                return "play.display"
            }
            return "display"
        }
        if let internal_ = displays.first(where: { $0.isBuiltin }), !internal_.isEnabled,
           displays.filter({ !$0.isBuiltin }).allSatisfy({ $0.isEnabled }) {
            return "display.trianglebadge.exclamationmark"
        }
        return "display"
    }

    // MARK: - Spatial Map

    private var spatialMapSection: some View {
        VStack(spacing: 8) {
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    // Background
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.black.opacity(0.3))

                    // Center dashed divider line
                    Rectangle()
                        .fill(Color.clear)
                        .overlay(
                            GeometryReader { inner in
                                Path { path in
                                    path.move(to: CGPoint(x: inner.size.width / 2, y: 0))
                                    path.addLine(to: CGPoint(x: inner.size.width / 2, y: inner.size.height))
                                }
                                .stroke(Color.white.opacity(0.06), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                            }
                        )

                    // Display thumbnails
                    ForEach(displays) { display in
                        let rect = thumbnailRect(for: display, containerSize: geo.size)
                        let draftOn = isDraftOn(display.id)
                        let willChange = draftEnabled[display.id] != nil
                            && draftEnabled[display.id] != display.isEnabled
                        DisplayThumbnail(
                            display: display,
                            draftOn: draftOn,
                            willChange: willChange,
                            isSolo: draftOn && draftOnCount == 1
                        )
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                toggleDraft(display.id)
                            }
                        }
                        .animation(.easeInOut(duration: 0.22), value: draftOn)
                        .animation(.easeInOut(duration: 0.22), value: willChange)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.primary.opacity(0.07), lineWidth: 1)
                )
            }
            .frame(height: 170)

            Group {
                if isDirty {
                    HStack(spacing: 8) {
                        Button("Reset") {
                            withAnimation(.easeInOut(duration: 0.15)) { resetDraft() }
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        .frame(maxWidth: .infinity)

                        Button("Apply") { applyDraft() }
                            .buttonStyle(PrimaryButtonStyle())
                            .frame(maxWidth: .infinity)
                    }
                } else {
                    Text("Tap to toggle on/off · Apply to confirm")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary.opacity(0.5))
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .animation(.easeInOut(duration: 0.18), value: isDirty)
        }
        .padding(16)
        .padding(.bottom, 0)
    }

    // Compute each display's rect in the spatial map container, preserving real-world arrangement.
    private func thumbnailRect(for display: DisplayState, containerSize: CGSize) -> CGRect {
        let frames = displays.map { d -> CGRect in
            // Fallback for disabled displays that have no cached frame
            d.frame == .zero ? CGRect(x: 0, y: 0, width: 200, height: 125) : d.frame
        }
        guard !frames.isEmpty else {
            return CGRect(x: containerSize.width / 2 - 40, y: containerSize.height / 2 - 25, width: 80, height: 50)
        }

        let bounds = frames.reduce(CGRect.null) { $0.union($1) }
        guard bounds.width > 0, bounds.height > 0 else {
            return CGRect(x: containerSize.width / 2 - 40, y: containerSize.height / 2 - 25, width: 80, height: 50)
        }

        let padding: CGFloat = 14
        let availW = containerSize.width - padding * 2
        let availH = containerSize.height - padding * 2
        let scale = min(availW / bounds.width, availH / bounds.height) * 0.9

        let scaledW = bounds.width * scale
        let scaledH = bounds.height * scale
        let offsetX = padding + (availW - scaledW) / 2
        let offsetY_base = padding + (availH - scaledH) / 2

        // Use this display's effective frame
        let df = display.frame == .zero ? CGRect(x: 0, y: 0, width: 200, height: 125) : display.frame

        let x = (df.minX - bounds.minX) * scale + offsetX
        // AppKit y-up → SwiftUI y-down
        let y = scaledH - (df.minY - bounds.minY) * scale - df.height * scale + offsetY_base
        let w = max(df.width * scale, 24)
        let h = max(df.height * scale, 16)

        return CGRect(x: x, y: y, width: w, height: h)
    }

    // MARK: - Quick Actions

    private var quickActionsSection: some View {
        HStack(spacing: 8) {
            Button {
                displayManager.enableAll()
            } label: {
                Text("All On")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle())

            Button {
                presentSaveSceneDialog()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .bold))
                    Text("Save Scene")
                        .font(.system(size: 12))
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(!canSaveScene)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: - Saved Scenes

    private var savedScenesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SAVED SCENES")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary.opacity(0.6))
                .kerning(0.6)
                .padding(.horizontal, 14)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(allScenes) { scene in
                        SceneChip(
                            scene: scene,
                            isActive: activeScene?.id == scene.id,
                            displays: displays
                        ) {
                            displayManager.applySceneState(scene.state, sceneName: scene.name)
                        } onDelete: {
                            sceneManager.delete(scene.id)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 2)
            }
        }
        .padding(.vertical, 10)
    }

    // MARK: - Settings

    private var settingsSection: some View {
        VStack(spacing: 8) {
            settingsRow(
                icon: "arrow.right.to.line.alt",
                title: "Launch at Login",
                subtitle: "Start app automatically",
                isOn: $launchManager.isLaunchAtLoginEnabled
            )
            Divider().padding(.vertical, 2)
            settingsRow(
                icon: "bell.badge",
                title: "Status Notifications",
                subtitle: "Show toast messages on change",
                isOn: $showNotifications
            )
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.03)))
    }

    private func settingsRow(icon: String, title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(subtitle).font(.system(size: 10)).foregroundColor(.secondary)
            }
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(SwitchToggleStyle(tint: .accentColor))
        }
    }

    // MARK: - Error View

    private func errorView(_ error: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10)).foregroundColor(.yellow)
            Text(error).font(.system(size: 10)).foregroundColor(.secondary).lineLimit(2)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.yellow.opacity(0.1)))
    }

    // MARK: - Footer

    private var footerView: some View {
        HStack {
            Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
                .font(.system(size: 10))
                .foregroundColor(.secondary.opacity(0.5))
            Spacer()
            Text("Vibe coded with Claude Code")
                .font(.system(size: 9))
                .foregroundColor(.secondary.opacity(0.35))
            Spacer()
            Button(action: onQuit) {
                HStack(spacing: 4) {
                    Image(systemName: "power").font(.system(size: 9))
                    Text("Quit").font(.system(size: 11))
                }
                .foregroundColor(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isHoveringQuit ? Color.primary.opacity(0.08) : Color.clear)
                )
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.15)) { isHoveringQuit = hovering }
            }
        }
    }

    // MARK: - Save Scene Dialog

    private func presentSaveSceneDialog() {
        let alert = NSAlert()
        alert.messageText = "Save Scene"
        alert.informativeText = "Name this display arrangement."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        textField.stringValue = "Custom \(sceneManager.userScenes.count + 1)"
        textField.placeholderString = "Scene name"
        alert.accessoryView = textField
        alert.window.initialFirstResponder = textField

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let name = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }
            let state = Dictionary(uniqueKeysWithValues: displays.map { (String($0.id), $0.isEnabled) })
            let scene = DisplayScene(
                id: "user-\(Int(Date().timeIntervalSince1970))",
                name: name, state: state, isBuiltIn: false
            )
            sceneManager.save(scene)
            ToastManager.shared.showToast(message: "Saved as scene")
        }
    }
}

// MARK: - DisplayThumbnail

private struct DisplayThumbnail: View {
    let display: DisplayState
    let draftOn: Bool       // draft (intended) state — may differ from display.isEnabled
    let willChange: Bool    // draftOn differs from current display.isEnabled
    let isSolo: Bool        // draft results in exactly one display on

    var body: some View {
        ZStack {
            // Outer frame + border
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.black.opacity(0.5))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(borderColor, lineWidth: borderWidth)
                        .shadow(color: borderShadow, radius: 6)
                )

            // Inner screen area
            RoundedRectangle(cornerRadius: 3)
                .fill(screenFill)
                .padding(3)
                .overlay(
                    VStack(spacing: 2) {
                        Text(display.name)
                            .font(.system(size: 7, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(statusLabel)
                            .font(.system(size: 8, weight: .semibold))
                    }
                    .foregroundColor(draftOn ? .white : .white.opacity(0.3))
                    .padding(3)
                )
        }
        .opacity(draftOn ? 1.0 : (willChange ? 0.65 : 0.45))
        .animation(.easeInOut(duration: 0.22), value: draftOn)
        .animation(.easeInOut(duration: 0.22), value: willChange)
        .animation(.easeInOut(duration: 0.22), value: isSolo)
    }

    // Label reflects the draft (intended) state, with an arrow when changing
    private var statusLabel: String {
        if willChange { return draftOn ? "→ ON" : "→ OFF" }
        return draftOn ? (display.isBuiltin ? "built-in" : "on") : "OFF"
    }

    private var borderColor: Color {
        if willChange { return draftOn ? .teal : .orange }
        if isSolo { return .accentColor }
        return .white.opacity(0.08)
    }
    private var borderWidth: CGFloat { (willChange || isSolo) ? 2 : 1 }
    private var borderShadow: Color {
        if willChange && draftOn { return .teal.opacity(0.35) }
        if isSolo { return .accentColor.opacity(0.3) }
        return .clear
    }

    private var screenFill: some ShapeStyle {
        // Will be turned OFF (currently on, draft off)
        if !draftOn && willChange {
            return AnyShapeStyle(LinearGradient(
                stops: [
                    .init(color: Color.orange.opacity(0.55), location: 0),
                    .init(color: Color.orange.opacity(0.55), location: 0.5),
                    .init(color: Color.orange.opacity(0.35), location: 0.5),
                    .init(color: Color.orange.opacity(0.35), location: 1),
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing
            ))
        }
        // Stays OFF / disabled
        if !draftOn { return AnyShapeStyle(Color(white: 0.08)) }
        // Will be turned ON (currently off, draft on)
        if willChange {
            return AnyShapeStyle(LinearGradient(
                stops: [
                    .init(color: Color.teal.opacity(0.65), location: 0),
                    .init(color: Color.teal.opacity(0.65), location: 0.5),
                    .init(color: Color.teal.opacity(0.45), location: 0.5),
                    .init(color: Color.teal.opacity(0.45), location: 1),
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing
            ))
        }
        // Stays ON — use original colors
        if display.isBuiltin {
            return AnyShapeStyle(LinearGradient(
                stops: [
                    .init(color: Color.green.opacity(0.55), location: 0),
                    .init(color: Color.green.opacity(0.55), location: 0.5),
                    .init(color: Color.green.opacity(0.4), location: 0.5),
                    .init(color: Color.green.opacity(0.4), location: 1),
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing
            ))
        }
        return AnyShapeStyle(LinearGradient(
            stops: [
                .init(color: Color.blue.opacity(0.5), location: 0),
                .init(color: Color.blue.opacity(0.5), location: 0.5),
                .init(color: Color.blue.opacity(0.35), location: 0.5),
                .init(color: Color.blue.opacity(0.35), location: 1),
            ],
            startPoint: .topLeading, endPoint: .bottomTrailing
        ))
    }
}

// MARK: - SceneChip

private struct SceneChip: View {
    let scene: DisplayScene
    let isActive: Bool
    let displays: [DisplayState]
    let onApply: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 4) {
            // Mini display-state icon
            HStack(spacing: 2) {
                ForEach(displays) { d in
                    let isOnInScene = scene.state[String(d.id)] ?? false
                    RoundedRectangle(cornerRadius: 1)
                        .fill(isOnInScene ? Color.primary.opacity(isActive ? 1.0 : 0.7) : Color.clear)
                        .overlay(
                            RoundedRectangle(cornerRadius: 1)
                                .stroke(isOnInScene ? Color.clear : Color.primary.opacity(0.3), lineWidth: 0.5)
                        )
                        .frame(width: 4, height: 4)
                }
            }

            Text(scene.name)
                .font(.system(size: 11))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(isActive ? Color.accentColor.opacity(0.2) : Color.primary.opacity(isHovering ? 0.1 : 0.06))
                .overlay(
                    Capsule()
                        .stroke(isActive ? Color.accentColor.opacity(0.5) : Color.clear, lineWidth: 1)
                )
        )
        .foregroundColor(isActive ? .accentColor : .primary.opacity(0.78))
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) { isHovering = hovering }
        }
        .onTapGesture { onApply() }
        .contextMenu {
            if !scene.isBuiltIn {
                Button("Delete", role: .destructive) { onDelete() }
            }
        }
    }
}

// MARK: - Button Styles

private struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.accentColor.opacity(configuration.isPressed ? 0.8 : 1.0))
            )
            .foregroundColor(.white)
    }
}

private struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.1 : 0.07))
            )
            .foregroundColor(isEnabled ? .primary : .secondary)
            .opacity(isEnabled ? 1 : 0.5)
    }
}
