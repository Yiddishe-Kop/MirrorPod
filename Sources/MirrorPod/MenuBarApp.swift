#if MENUBAR_APP
import AppKit
import SwiftUI

private enum MirrorRunState: Equatable {
    case stopped
    case starting
    case waitingForAudio
    case running
    case stopping
    case needsPermission
    case chooseHomePod
    case failed(String)

    var title: String {
        switch self {
        case .stopped: "Ready"
        case .starting: "Starting…"
        case .waitingForAudio: "Waiting for audio"
        case .running: "Mirroring audio"
        case .stopping: "Stopping…"
        case .needsPermission: "Permission required"
        case .chooseHomePod: "Choose the HomePod"
        case .failed: "Needs attention"
        }
    }

    var symbol: String {
        switch self {
        case .running: "checkmark.circle.fill"
        case .starting, .waitingForAudio, .stopping: "clock.fill"
        case .needsPermission, .chooseHomePod, .failed: "exclamationmark.triangle.fill"
        case .stopped: "pause.circle"
        }
    }

    var isActive: Bool {
        switch self {
        case .starting, .waitingForAudio, .running, .stopping: true
        default: false
        }
    }

    var isBusy: Bool {
        self == .starting || self == .stopping
    }
}

@MainActor
private final class MirrorPodController: ObservableObject {
    @Published private(set) var state: MirrorRunState = .stopped
    @Published private(set) var normalOutputName = "Checking…"
    @Published private(set) var normalOutputVolume = 1.0
    @Published private(set) var normalOutputVolumeAvailable = false
    @Published var delayMilliseconds: Int {
        didSet {
            UserDefaults.standard.set(delayMilliseconds, forKey: Self.delayKey)
            mirror?.setDelayMilliseconds(delayMilliseconds)
        }
    }
    @Published var macSpeakerVolume: Double {
        didSet {
            UserDefaults.standard.set(macSpeakerVolume, forKey: Self.macVolumeKey)
            mirror?.setVolume(Float(macSpeakerVolume))
        }
    }

    private static let delayKey = "MirrorPodDelayMilliseconds"
    private static let macVolumeKey = "MirrorPodMacSpeakerVolume"
    private var mirror: AudioMirror?
    private var didAttemptAutomaticStart = false

    init() {
        if UserDefaults.standard.object(forKey: Self.delayKey) != nil {
            delayMilliseconds = UserDefaults.standard.integer(forKey: Self.delayKey)
        } else {
            delayMilliseconds = 2_000
        }
        if UserDefaults.standard.object(forKey: Self.macVolumeKey) != nil {
            macSpeakerVolume = UserDefaults.standard.double(forKey: Self.macVolumeKey)
        } else {
            macSpeakerVolume = 1
        }
        refreshOutput()
    }

    var menuBarSymbol: String {
        switch state {
        case .running: "hifispeaker.2.fill"
        case .needsPermission, .chooseHomePod, .failed: "exclamationmark.triangle.fill"
        default: "hifispeaker.2"
        }
    }

    var statusDetail: String? {
        switch state {
        case .needsPermission:
            "Allow Screen & System Audio Recording, then reopen MirrorPod."
        case .chooseHomePod:
            "Select Living Room as the normal Mac output before starting."
        case .failed(let message):
            message
        case .waitingForAudio:
            "Start playback in Spotify."
        default:
            nil
        }
    }

    func startAutomaticallyOnce() async {
        guard !didAttemptAutomaticStart else { return }
        didAttemptAutomaticStart = true
        await start()
    }

    func toggle() async {
        if state.isActive {
            await stop()
        } else {
            await start()
        }
    }

    func start() async {
        guard mirror == nil, !state.isBusy else { return }
        state = .starting

        do {
            let devices = try AudioHardware.outputDevices()
            guard let builtInOutput = devices.first(where: \AudioDevice.isBuiltInOutput) else {
                throw MirrorError.noBuiltInOutput
            }

            refreshOutput()
            guard normalOutputName != builtInOutput.name else {
                state = .chooseHomePod
                return
            }

            let newMirror = AudioMirror(
                outputDevice: builtInOutput,
                delayMilliseconds: delayMilliseconds,
                volume: Float(macSpeakerVolume)
            )
            newMirror.onPlaybackStarted = { [weak self] in
                Task { @MainActor in
                    self?.state = .running
                }
            }
            newMirror.onError = { [weak self] error in
                Task { @MainActor in
                    self?.state = .failed(error.localizedDescription)
                    self?.mirror = nil
                }
            }
            mirror = newMirror

            do {
                try await newMirror.start()
                if state == .starting {
                    state = .waitingForAudio
                }
            } catch MirrorError.permissionDenied {
                mirror = nil
                state = .needsPermission
            } catch {
                mirror = nil
                state = .failed(error.localizedDescription)
            }
        } catch {
            mirror = nil
            state = .failed(error.localizedDescription)
        }
    }

    func stop() async {
        guard let mirror else {
            state = .stopped
            return
        }
        state = .stopping
        await mirror.stop()
        self.mirror = nil
        state = .stopped
    }

    func refreshOutput() {
        normalOutputName = AudioHardware.defaultOutputName() ?? "Unavailable"
        if let volume = AudioHardware.defaultOutputVolume() {
            normalOutputVolume = Double(volume)
            normalOutputVolumeAvailable = true
        } else {
            normalOutputVolumeAvailable = false
        }
    }

    func setNormalOutputVolume(_ newValue: Double) {
        let clampedValue = min(max(newValue, 0), 1)
        do {
            try AudioHardware.setDefaultOutputVolume(Float(clampedValue))
            normalOutputVolume = clampedValue
            normalOutputVolumeAvailable = true
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func openSoundSettings() {
        openSettings("x-apple.systempreferences:com.apple.Sound-Settings.extension")
    }

    func openPrivacySettings() {
        openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    func quit() {
        Task {
            await stop()
            NSApplication.shared.terminate(nil)
        }
    }

    private func openSettings(_ value: String) {
        guard let url = URL(string: value) else { return }
        NSWorkspace.shared.open(url)
    }
}

private struct MirrorPodMenuView: View {
    @ObservedObject var controller: MirrorPodController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            topBar
            controls

            if let detail = controller.statusDetail {
                Label(detail, systemImage: controller.state.symbol)
                    .font(.caption)
                    .foregroundStyle(statusColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityElement(children: .combine)
            }

            footer
        }
        .padding(12)
        .frame(width: 310)
        .task {
            await controller.startAutomaticallyOnce()
        }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            controller.refreshOutput()
        }
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            routing
            Spacer(minLength: 4)
            primaryAction
        }
    }

    private var routing: some View {
        HStack(spacing: 7) {
            Image(systemName: "homepodmini.fill")
            Text(controller.normalOutputName == "AirPlay" ? "HomePod" : controller.normalOutputName)
                .lineLimit(1)
            Image(systemName: "arrow.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Image(systemName: "laptopcomputer")
            Text("MacBook")
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .glassEffect(.clear, in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Routing from \(controller.normalOutputName) to MacBook speakers")
    }

    private var controls: some View {
        VStack(spacing: 10) {
            volumes
            Divider()
                .opacity(0.45)
            delayControl
        }
        .padding(11)
        .glassEffect(
            .regular,
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
    }

    private var delayControl: some View {
        Stepper(
            value: $controller.delayMilliseconds,
            in: 0...4_000,
            step: 50
        ) {
            HStack {
                Text("Sync delay")
                Spacer()
                Text("\(controller.delayMilliseconds) ms")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .help("Adjust synchronization with the HomePod")
        .accessibilityLabel("Mac speaker synchronization delay")
        .accessibilityValue("\(controller.delayMilliseconds) milliseconds")
    }

    private var volumes: some View {
        VStack(spacing: 9) {
            volumeControl(
                title: "HomePod",
                value: Binding(
                    get: { controller.normalOutputVolume },
                    set: { controller.setNormalOutputVolume($0) }
                ),
                enabled: controller.normalOutputVolumeAvailable
            )
            volumeControl(
                title: "MacBook",
                value: $controller.macSpeakerVolume
            )
        }
    }

    private func volumeControl(
        title: String,
        value: Binding<Double>,
        enabled: Bool = true
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(value.wrappedValue, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(.callout)

            Slider(value: value, in: 0...1) {
                Text("\(title) volume")
            } minimumValueLabel: {
                Image(systemName: "speaker.fill")
                    .accessibilityHidden(true)
            } maximumValueLabel: {
                Image(systemName: "speaker.wave.3.fill")
                    .accessibilityHidden(true)
            }
            .labelsHidden()
            .disabled(!enabled)
            .accessibilityLabel("\(title) volume")
            .accessibilityValue("\(Int((value.wrappedValue * 100).rounded())) percent")
        }
    }

    private var primaryAction: some View {
        Button {
            Task { await controller.toggle() }
        } label: {
            Label(
                controller.state.isActive ? "Stop" : "Start",
                systemImage: controller.state.isActive ? "stop.fill" : "play.fill"
            )
        }
        .buttonStyle(.glass(.clear))
        .controlSize(.small)
        .disabled(controller.state.isBusy)
        .keyboardShortcut(.return, modifiers: [])
        .accessibilityLabel(controller.state.isActive ? "Stop mirroring" : "Start mirroring")
    }

    private var footer: some View {
        HStack {
            if controller.state == .needsPermission {
                Button {
                    controller.openPrivacySettings()
                } label: {
                    Label("Privacy", systemImage: "hand.raised")
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .accessibilityLabel("Open Privacy Settings")
                .help("Open Screen & System Audio Recording settings")
            } else {
                Button {
                    controller.openSoundSettings()
                } label: {
                    Label("Sound", systemImage: "speaker.wave.2")
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .accessibilityLabel("Open Sound Settings")
                .help("Choose the HomePod output")
            }

            Spacer()

            Button {
                controller.quit()
            } label: {
                Label("Quit", systemImage: "power")
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .accessibilityLabel("Quit MirrorPod")
            .keyboardShortcut("q", modifiers: .command)
        }
        .controlSize(.small)
        .foregroundStyle(.secondary)
    }

    private var statusColor: Color {
        switch controller.state {
        case .running: .green
        case .needsPermission, .chooseHomePod, .failed: .orange
        default: .secondary
        }
    }
}

@main
private struct MirrorPodMenuBarApp: App {
    @StateObject private var controller = MirrorPodController()

    var body: some Scene {
        MenuBarExtra {
            MirrorPodMenuView(controller: controller)
        } label: {
            Image(systemName: controller.menuBarSymbol)
                .accessibilityLabel("MirrorPod, \(controller.state.title)")
        }
        .menuBarExtraStyle(.window)
    }
}
#endif
