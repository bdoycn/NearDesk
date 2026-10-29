// Copyright 2026 NearDesk Contributors
// SPDX-License-Identifier: Apache-2.0

import AppKit
import NearDeskCore
import Network
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    let host = HostController()
    let viewer = ViewerController()
}

@MainActor
final class HostController: ObservableObject {
    @Published var name: String
    @Published var password = ""
    @Published var status = "Not sharing."
    @Published var port: UInt16 = 0
    @Published var sharing = false
    @Published var screenOK = false
    @Published var accessibilityOK = false
    @Published var fingerprint = ""

    private let session = HostSession()

    init() {
        name = Host.current().localizedName ?? "NearDesk Mac"
        session.onStatus = { [weak self] text in
            Task { @MainActor in self?.status = text }
        }
        session.onStartFailure = { [weak self] error in
            Task { @MainActor in
                self?.sharing = false
                self?.port = 0
                self?.status = "Could not start sharing: \(error.localizedDescription)"
            }
        }
        session.onPort = { [weak self] port in
            Task { @MainActor in self?.port = port }
        }
        session.onStreaming = { [weak self] streaming in
            Task { @MainActor in
                if streaming { self?.status = self?.status ?? "" }
            }
        }
        refresh()
        if let identity = try? SpikeIdentity.loadOrCreate() {
            fingerprint = SpikeIdentity.grouped(identity.fingerprintHex)
        }
    }

    func refresh() {
        screenOK = PermissionProbe.screenRecording
        accessibilityOK = PermissionProbe.accessibility
    }

    func allowScreen() {
        PermissionProbe.promptScreenRecording()
        refresh()
    }

    func allowAccessibility() {
        PermissionProbe.promptAccessibility()
        refresh()
    }

    func toggleSharing() {
        if sharing {
            session.stop()
            sharing = false
            port = 0
            status = "Not sharing."
            return
        }
        guard (1...128).contains(password.utf8.count) else {
            status = "Set a password of 1 to 128 bytes before sharing."
            return
        }
        if !screenOK {
            status = "Screen Recording is off. NearDesk will not show a stand-in picture."
        }
        if !accessibilityOK {
            status = "Accessibility is off. Keyboard and pointer injection will fail until it is allowed."
        }
        do {
            try session.start(name: name, password: password)
            sharing = true
        } catch {
            sharing = false
            port = 0
            status = "Could not start sharing: \(error.localizedDescription)"
        }
    }
}

@MainActor
final class ViewerController: ObservableObject {
    @Published var password = ""
    @Published var status = "Looking for NearDesk Macs."
    @Published var macs: [DiscoveredMac] = []
    @Published var displays: [RemoteDisplay] = []
    @Published var connected = false
    @Published var controlling = false
    @Published var hud = LatencySnapshot.empty
    @Published var trustPrompt: String?
    @Published var trustMismatch: String?
    @Published var selectedDisplay: UInt32 = 0

    let surface = VideoSurfaceModel()
    private let session = ViewerSession()
    private let browser = HostBrowser()
    private var trustContinuation: CheckedContinuation<Bool, Never>?
    private var hostKey = ""

    init() {
        surface.onInput = { [weak self] message in
            self?.session.send(message)
        }
        surface.onControlling = { [weak self] value in
            Task { @MainActor in self?.controlling = value }
        }
        session.onStatus = { [weak self] text in
            Task { @MainActor in self?.status = text }
        }
        session.onDisplays = { [weak self] displays in
            Task { @MainActor in
                self?.displays = displays
                self?.selectedDisplay = displays.first?.displayID ?? 0
                self?.connected = true
            }
        }
        session.onFrame = { [weak self] frame in
            self?.surface.present(frame)
        }
        session.confirmTrust = { [weak self] fingerprint in
            await self?.askTrust(fingerprint) ?? false
        }
        session.onTrustMismatch = { [weak self] fingerprint in
            Task { @MainActor in self?.trustMismatch = fingerprint }
        }
        browser.onMacs = { [weak self] macs in
            Task { @MainActor in self?.macs = macs }
        }
        browser.onState = { [weak self] text in
            Task { @MainActor in
                if self?.connected == false { self?.status = text }
            }
        }
        LatencyHub.shared.onSnapshot = { [weak self] snapshot in
            Task { @MainActor in
                self?.hud = snapshot
                self?.surface.hud = snapshot
            }
        }
    }

    private var browsing = false

    func startBrowsing() {
        guard !browsing else { return }
        browsing = true
        browser.start()
    }

    func connect(_ mac: DiscoveredMac) {
        hostKey = mac.name
        trustMismatch = nil
        session.connect(endpoint: mac.endpoint, hostKey: hostKey, password: password, name: Host.current().localizedName ?? "NearDesk")
        status = "Connecting to \(mac.name)…"
    }

    func connectLoopback(port: UInt16) {
        guard let portValue = NWEndpoint.Port(rawValue: port) else { return }
        hostKey = "loopback"
        trustMismatch = nil
        let endpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: portValue)
        session.connect(endpoint: endpoint, hostKey: hostKey, password: password, name: Host.current().localizedName ?? "NearDesk")
        status = "Connecting to this Mac…"
    }

    func disconnect() {
        session.disconnect()
        connected = false
        controlling = false
        displays = []
        status = "Disconnected."
    }

    func chooseDisplay(_ id: UInt32) {
        selectedDisplay = id
        session.choose(displayID: id)
    }

    func acceptTrust() { trustContinuation?.resume(returning: true); trustContinuation = nil; trustPrompt = nil }
    func rejectTrust() { trustContinuation?.resume(returning: false); trustContinuation = nil; trustPrompt = nil }

    func forgetTrust() {
        TofuStore.forget(host: hostKey)
        trustMismatch = nil
        status = "Saved fingerprint cleared. Connect again to review the certificate."
    }

    func revealCSV() {
        try? SpikePaths.ensure(SpikePaths.spike)
        NSWorkspace.shared.activateFileViewerSelecting([SpikePaths.videoCSV, SpikePaths.inputCSV])
    }

    private func askTrust(_ fingerprint: String) async -> Bool {
        await withCheckedContinuation { continuation in
            trustContinuation = continuation
            trustPrompt = fingerprint
        }
    }
}

struct RootView: View {
    @StateObject private var model = AppModel()
    @State private var mode = 0

    var body: some View {
        VStack(spacing: 0) {
            Picker("Mode", selection: $mode) {
                Text("Host").tag(0)
                Text("Viewer").tag(1)
            }
            .pickerStyle(.segmented)
            .padding()
            Divider()
            if mode == 0 {
                HostPane(host: model.host, viewer: model.viewer)
            } else {
                ViewerPane(host: model.host, viewer: model.viewer)
            }
        }
        .frame(minWidth: 880, minHeight: 640)
        .onChange(of: mode) { _, mode in
            if mode == 1 { model.viewer.startBrowsing() }
        }
        .onReceive(Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()) { _ in
            model.host.refresh()
        }
    }
}

private struct HostPane: View {
    @ObservedObject var host: HostController
    @ObservedObject var viewer: ViewerController

    var body: some View {
        Form {
            Section("This Mac") {
                TextField("Name", text: $host.name)
                SecureField("Password", text: $host.password)
                Text("The password stays on the control stream after QUIC. It is not published in Bonjour.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section("Permissions") {
                permissionRow("Screen Recording", ok: host.screenOK, settings: "Privacy_ScreenCapture", action: host.allowScreen)
                permissionRow("Accessibility", ok: host.accessibilityOK, settings: "Privacy_Accessibility", action: host.allowAccessibility)
                Text("After allowing Screen Recording or Accessibility, macOS often needs you to fully quit NearDesk.app (⌘Q) and relaunch it before the green check appears.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("Local Network is requested when sharing starts or you first select Viewer to find nearby Macs.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section("Share") {
                Button(host.sharing ? "Stop sharing" : "Start sharing") { host.toggleSharing() }
                Text(host.status)
                if host.port != 0 {
                    Text("UDP port \(host.port). A viewer on this Mac can use loopback.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if !host.fingerprint.isEmpty {
                    Text("Certificate SHA-256 \(host.fingerprint)")
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func permissionRow(_ title: String, ok: Bool, settings: String, action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? .green : .orange)
            Text(title)
            Spacer()
            if ok {
                Text("Allowed").foregroundStyle(.secondary)
            } else {
                Button("Allow") { action() }
                Button("Open Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(settings)") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }
}

private struct ViewerPane: View {
    @ObservedObject var host: HostController
    @ObservedObject var viewer: ViewerController

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 12) {
                SecureField("Password", text: $viewer.password)
                if host.port != 0 {
                    Button("Connect to this Mac") { viewer.connectLoopback(port: host.port) }
                        .disabled(viewer.password.isEmpty)
                }
                Text(viewer.status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                List(viewer.macs) { mac in
                    Button {
                        viewer.connect(mac)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(mac.name)
                            if !mac.version.isEmpty {
                                Text("protocol \(mac.version)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(viewer.password.isEmpty)
                }
                if viewer.displays.count > 1 {
                    Picker("Display", selection: $viewer.selectedDisplay) {
                        ForEach(viewer.displays, id: \.displayID) { display in
                            Text("\(display.widthPx)×\(display.heightPx)").tag(display.displayID)
                        }
                    }
                    .onChange(of: viewer.selectedDisplay) { _, id in
                        viewer.chooseDisplay(id)
                    }
                }
                HStack {
                    if viewer.connected {
                        Button("Disconnect") { viewer.disconnect() }
                    }
                    Button("Show latency CSV") { viewer.revealCSV() }
                }
                if viewer.trustMismatch != nil {
                    Text("The certificate no longer matches the one you accepted. The password was not sent.")
                        .font(.callout)
                    Button("Forget saved fingerprint") { viewer.forgetTrust() }
                }
                Spacer()
            }
            .padding()
            .frame(minWidth: 260, idealWidth: 300)

            ZStack(alignment: .topLeading) {
                VideoDesktop(surface: viewer.surface)
                VStack(alignment: .leading, spacing: 4) {
                    Text(hudText)
                        .font(.system(.caption, design: .monospaced))
                    Text(viewer.controlling ? "Controlling. Esc releases the pointer." : "Click the picture to control the desktop.")
                        .font(.caption)
                }
                .padding(8)
                .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
                .foregroundStyle(.white)
                .padding(12)
            }
        }
        .alert("Trust this Mac?", isPresented: trustPresented) {
            Button("Trust") { viewer.acceptTrust() }
            Button("Cancel", role: .cancel) { viewer.rejectTrust() }
        } message: {
            Text("First connection. NearDesk will remember this certificate SHA-256:\n\(viewer.trustPrompt ?? "")")
        }
    }

    private var trustPresented: Binding<Bool> {
        Binding(get: { viewer.trustPrompt != nil }, set: { shown in
            if !shown, viewer.trustPrompt != nil { viewer.rejectTrust() }
        })
    }

    private var hudText: String {
        let hud = viewer.hud
        let p50 = hud.videoP50ms.map { String(format: "%.1f ms", $0) } ?? "—"
        let p95 = hud.videoP95ms.map { String(format: "%.1f ms", $0) } ?? "—"
        let input = hud.inputP50ms.map { String(format: "%.1f ms", $0) } ?? "—"
        return "GG p50 \(p50)  p95 \(p95)  n=\(hud.videoCount)\nInput p50 \(input)  n=\(hud.inputCount)"
    }
}
