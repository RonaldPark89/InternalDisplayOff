import SwiftUI

struct PopoverView: View {
    @ObservedObject var displayManager: DisplayManager
    @ObservedObject var launchManager = LaunchManager.shared
    var onQuit: () -> Void

    @State private var isHoveringToggle = false
    @State private var isHoveringQuit = false
    @State private var pulseAnimation = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 8)

            Divider()
                .padding(.horizontal, 12)

            // Status Section
            statusSection
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

            // Settings Section
            settingsSection
                .padding(.horizontal, 16)
                .padding(.bottom, 10)

            // Error Message
            if let error = displayManager.lastError {
                errorView(error)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
            }

            Divider()
                .padding(.horizontal, 12)

            // Toggle Button
            toggleButton
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

            Divider()
                .padding(.horizontal, 12)

            // Footer
            footerView
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
        }
        .frame(width: 260)
        .onAppear {
            displayManager.refreshDisplayInfo()
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(spacing: 10) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 20, weight: .medium))
                .foregroundColor(.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text("Display Control")
                    .font(.system(size: 14, weight: .semibold))
                Text("Toggle internal display")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            Spacer()

            // Status indicator dot
            Circle()
                .fill(displayManager.isInternalDisplayOff ? Color.orange : Color.green)
                .frame(width: 8, height: 8)
                .shadow(color: displayManager.isInternalDisplayOff ? .orange.opacity(0.5) : .green.opacity(0.5), radius: 4)
                .opacity(pulseAnimation ? 0.6 : 1.0)
                .animation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true), value: pulseAnimation)
                .onAppear { pulseAnimation = true }
        }
    }

    // MARK: - Status Section

    private var statusSection: some View {
        VStack(spacing: 10) {
            HStack {
                Label {
                    Text("Internal Display")
                        .font(.system(size: 12))
                } icon: {
                    Image(systemName: "laptopcomputer")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                Spacer()

                Text(displayManager.isInternalDisplayOff ? "Disabled" : "Active")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(displayManager.isInternalDisplayOff ? .orange : .green)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(displayManager.isInternalDisplayOff
                                ? Color.orange.opacity(0.15)
                                : Color.green.opacity(0.15))
                    )
            }

            HStack {
                Label {
                    Text("External Displays")
                        .font(.system(size: 12))
                } icon: {
                    Image(systemName: "display")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                Spacer()

                Text("\(displayManager.externalDisplayCount) connected")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Settings Section

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $launchManager.isLaunchAtLoginEnabled) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.right.to.line.alt")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Launch at Login")
                            .font(.system(size: 12, weight: .medium))
                        Text("Start app automatically")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
            }
            .toggleStyle(SwitchToggleStyle(tint: .accentColor))
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.03))
        )
    }

    // MARK: - Error View

    private func errorView(_ error: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundColor(.yellow)

            Text(error)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .lineLimit(2)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.yellow.opacity(0.1))
        )
    }

    // MARK: - Toggle Button

    private var toggleButton: some View {
        Button(action: {
            withAnimation(.easeInOut(duration: 0.3)) {
                displayManager.toggleInternalDisplay()
            }
        }) {
            HStack(spacing: 10) {
                Image(systemName: displayManager.isInternalDisplayOff
                    ? "power.circle.fill"
                    : "power.circle")
                    .font(.system(size: 18))
                    .foregroundColor(displayManager.isInternalDisplayOff ? .green : .orange)

                VStack(alignment: .leading, spacing: 1) {
                    Text(displayManager.isInternalDisplayOff
                        ? "Enable Internal Display"
                        : "Disable Internal Display")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.primary)

                    Text(displayManager.isInternalDisplayOff
                        ? "Turn the built-in screen back on"
                        : "Turn off the built-in screen")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                    .opacity(isHoveringToggle ? 1.0 : 0.5)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHoveringToggle
                        ? Color.primary.opacity(0.08)
                        : Color.primary.opacity(0.03))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHoveringToggle = hovering
            }
        }
    }

    // MARK: - Footer

    private var footerView: some View {
        HStack {
            Text("v1.0")
                .font(.system(size: 10))
                .foregroundColor(.secondary.opacity(0.5))

            Spacer()

            Button(action: {
                // Re-enable display before quitting for safety
                if displayManager.isInternalDisplayOff {
                    displayManager.enableInternalDisplay()
                }
                onQuit()
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "power")
                        .font(.system(size: 9))
                    Text("Quit")
                        .font(.system(size: 11))
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
                withAnimation(.easeInOut(duration: 0.15)) {
                    isHoveringQuit = hovering
                }
            }
        }
    }
}
