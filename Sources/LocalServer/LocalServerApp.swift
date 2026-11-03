import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

struct LocalServerApp: App {
    @StateObject private var model = ServerModel()
    @StateObject private var updater = Updater()
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        Window("Local Server", id: "main") {
            ContentView()
                .environmentObject(model)
                .environmentObject(updater)
                .frame(minWidth: 620, minHeight: 680)
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.showSheet = true }
            }
        }

        Settings {
            SettingsView().environmentObject(updater)
        }

        MenuBarExtra {
            MenuBarContent().environmentObject(model).environmentObject(updater)
        } label: {
            Image(systemName: model.isRunning ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
        }
    }
}

/// `swift run` starts a plain executable; make it a regular app with a Dock icon and focus.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

struct MenuBarContent: View {
    @EnvironmentObject private var model: ServerModel
    @EnvironmentObject private var updater: Updater
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.isRunning ? "Running  \(model.deviceURL)" : "Stopped")
        Button(model.isRunning ? "Stop" : "Start") { model.isRunning ? model.stop() : model.start() }
        Button("Copy CLR URL") { model.copy(model.shareURL + "/clr/") }
        if let url = model.tunnelStatus.url { Text("Tunnel  \(url)") }
        Button(model.tunnelStatus == .stopped ? "Start Tunnel" : "Stop Tunnel") {
            model.tunnelStatus == .stopped ? model.startTunnel() : model.stopTunnel()
        }
        Divider()
        Button(updater.available.map { "Update to \($0.version)…" } ?? "Check for Updates…") {
            updater.showSheet = true
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Open Window") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Quit") { NSApp.terminate(nil) }
    }
}

struct ContentView: View {
    @EnvironmentObject private var model: ServerModel
    @EnvironmentObject private var updater: Updater

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let release = updater.available, !updater.showSheet {
                HStack {
                    Label("Local Server \(release.version) is available (you have \(updater.current)).", systemImage: "arrow.down.circle.fill")
                        .foregroundStyle(.blue)
                    Spacer()
                    Button("Update…") { updater.showSheet = true }
                }
            }
            serverBox
            tunnelBox
            HStack {
                Text("Available on this server").font(.headline)
                Spacer()
                Button("Refresh") { model.refresh() }
            }
            payloadBox(title: "CLR", url: model.shareURL + "/clr/", payloads: model.clrPayloads,
                       hint: "Run GENERATE ALL CLR in the Unity Build Tool.")
            payloadBox(title: "Addressables", url: model.shareURL + "/addressables/", payloads: model.addressablePayloads,
                       hint: "Run BUILD/UPDATE ADDRESSABLE in the Unity Build Tool.")
            Text("LAN: phone and Mac must share the same Wi-Fi. Tunnel: any network, https. Point the app at this server from Unity: TOOL › Local Server › Use on device, then Apply and build.")
                .font(.caption).foregroundStyle(.secondary)
            logBox
        }
        .padding(16)
        .sheet(isPresented: $updater.showSheet) { UpdateSheet() }
        // Quiet check on launch: only shows the banner when a newer release exists.
        .task { updater.check(quiet: true) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refresh() }
    }

    private var serverBox: some View {
        GroupBox {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label(model.isRunning ? "Running  \(model.deviceURL)" : "Stopped",
                              systemImage: model.isRunning ? "circle.fill" : "circle")
                            .foregroundStyle(model.isRunning ? .green : .secondary)
                            .font(.headline)
                        Spacer()
                        Button("Start") { model.start() }.disabled(model.isRunning)
                        Button("Stop") { model.stop() }.disabled(!model.isRunning)
                    }
                    HStack {
                        Text("Project").frame(width: 80, alignment: .leading)
                        Text(model.projectPath.isEmpty ? "Not set" : model.projectPath)
                            .lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(model.isProjectValid ? .primary : Color.red)
                        Spacer()
                        Button("Choose…") { model.chooseProject() }.disabled(model.isRunning)
                    }
                    folderRow("Addressables", path: model.addressablesRoot.path, isValid: model.isAddressablesRootValid,
                              isDefault: model.addressablesFolder.isEmpty,
                              choose: model.chooseAddressablesFolder, reset: { model.addressablesFolder = "" })
                    folderRow("CLR", path: model.clrRoot.path, isValid: model.isClrRootValid,
                              isDefault: model.clrFolder.isEmpty,
                              choose: model.chooseClrFolder, reset: { model.clrFolder = "" })
                    HStack {
                        Text("Port").frame(width: 80, alignment: .leading)
                        TextField("8080", value: $model.port, format: .number.grouping(.never)).frame(width: 70).disabled(model.isRunning)
                    }
                    HStack {
                        Text("LAN IP").frame(width: 80, alignment: .leading)
                        Picker("", selection: $model.host) {
                            ForEach(model.addresses) { Text("\($0.address)  (\($0.interface))").tag($0.address) }
                            if model.addresses.isEmpty { Text("localhost").tag("localhost") }
                        }
                        .labelsHidden().frame(width: 240)
                        Button("Copy URL") { model.copy(model.deviceURL) }
                    }
                    if let error = model.error {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                }
                QRCodeView(text: model.shareURL + "/clr/")
                    .frame(width: 110, height: 110)
                    .help("CLR URL for the phone")
            }
            .padding(4)
        }
    }

    private var tunnelBox: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(tunnelTitle, systemImage: model.tunnelStatus.url != nil ? "lock.fill" : "cloud")
                        .foregroundStyle(model.tunnelStatus.url != nil ? .green : .secondary)
                        .font(.headline)
                    if model.tunnelStatus == .starting { ProgressView().controlSize(.small) }
                    Spacer()
                    Picker("", selection: $model.tunnelMode) {
                        Text("Quick").tag(CloudflareTunnel.Mode.quick)
                        Text("Custom domain").tag(CloudflareTunnel.Mode.domain)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 220)
                    .disabled(model.tunnelStatus != .stopped)
                    Button("Start Tunnel") { model.startTunnel() }
                        .disabled(model.tunnelStatus != .stopped || !model.hasCloudflared)
                    Button("Stop Tunnel") { model.stopTunnel() }.disabled(model.tunnelStatus == .stopped)
                }
                if model.tunnelMode == .domain {
                    HStack {
                        Text("Domain").frame(width: 80, alignment: .leading)
                        TextField("cdn.example.com", text: $model.tunnelHostname).frame(width: 240)
                        Text("Tunnel")
                        TextField("name", text: $model.tunnelName).frame(width: 180)
                        Spacer()
                    }
                    .disabled(model.tunnelStatus != .stopped)
                    HStack {
                        Text("Cloudflare").frame(width: 80, alignment: .leading)
                        if model.isCloudflareLoggedIn {
                            Label("Logged in (~/.cloudflared/cert.pem)", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else {
                            Text("Not logged in").foregroundStyle(.secondary)
                        }
                        Spacer()
                        if model.isLoggingIn {
                            ProgressView().controlSize(.small)
                            Button("Open Page") { model.openLoginPage() }.disabled(model.loginURL == nil)
                            Button("Cancel") { model.cancelLogin() }
                        } else {
                            Button("Login…") { model.loginCloudflare() }
                                .disabled(model.isCloudflareLoggedIn || !model.hasCloudflared)
                        }
                    }
                    if model.isLoggingIn, let url = model.loginURL {
                        HStack {
                            Text("Login link").frame(width: 80, alignment: .leading)
                            Text(url.absoluteString).font(.caption.monospaced())
                                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                                .help(url.absoluteString)
                            Spacer()
                            Button("Copy") { model.copy(url.absoluteString) }
                        }
                    }
                    if model.isLoggingIn {
                        Text("Signing in is not enough: on the “Authorize Cloudflare Tunnel” page pick the zone of your domain (e.g. example.com for cdn.example.com) and click Authorize. No zone listed = the domain is not on this Cloudflare account.")
                            .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let url = model.tunnelStatus.url {
                    HStack {
                        Text("Public URL").frame(width: 80, alignment: .leading)
                        Text(url).font(.body.monospaced()).textSelection(.enabled)
                        Spacer()
                        Button("Copy") { model.copy(url) }
                        Button("Open") { if let link = URL(string: url + "/clr/") { NSWorkspace.shared.open(link) } }
                    }
                }
                Text(tunnelHint).font(.caption).foregroundStyle(.secondary)
                if let error = model.tunnelError {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
            }
            .padding(4)
        }
    }

    private var tunnelTitle: String {
        switch model.tunnelStatus {
        case .stopped: "Cloudflare Tunnel (HTTPS)"
        case .starting: "Tunnel starting…"
        case .running: "Tunnel running"
        }
    }

    private var tunnelHint: String {
        if !model.hasCloudflared { return "cloudflared not found. Install it: brew install cloudflared, then reopen the app." }
        switch model.tunnelMode {
        case .quick:
            return "Random https://….trycloudflare.com, no account needed. The URL changes every start, so the build must be updated each time."
        case .domain:
            return "Fixed https://<domain>; the domain must be a zone on your Cloudflare account. Login once, then Start creates the tunnel and DNS record. Anyone with the URL can download the files."
        }
    }

    /// Folder served for a route; empty setting = default inside the project, Reset returns to it.
    private func folderRow(_ title: String, path: String, isValid: Bool, isDefault: Bool,
                           choose: @escaping () -> Void, reset: @escaping () -> Void) -> some View {
        HStack {
            Text(title).frame(width: 80, alignment: .leading)
            Text(path).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(isValid ? Color.primary : Color.red)
                .help(isValid ? path : "Folder does not exist: \(path)")
            if isDefault { Text("default").font(.caption).foregroundStyle(.secondary) }
            Spacer()
            Button("Choose…", action: choose).disabled(model.isRunning)
            Button("Reset", action: reset).disabled(model.isRunning || isDefault)
        }
    }

    private func payloadBox(title: String, url: String, payloads: [Payload], hint: String) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(title).font(.headline).frame(width: 110, alignment: .leading)
                    Text(url).font(.caption.monospaced()).textSelection(.enabled)
                    Spacer()
                    Button("Copy") { model.copy(url) }
                }
                if payloads.isEmpty {
                    Text("Nothing to serve. \(hint)").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(payloads) { payload in
                    HStack {
                        Image(systemName: payload.testPath != nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(payload.testPath != nil ? .green : .orange)
                        Text(payload.label).frame(width: 180, alignment: .leading)
                        Text(payload.detail).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Test") { model.test(payload) }.disabled(!model.isRunning || payload.testPath == nil)
                    }
                }
            }
            .padding(4)
        }
    }

    private var logBox: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Request log").font(.headline)
                Spacer()
                Button("Clear") { model.clearLog() }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(model.log.enumerated()), id: \.offset) { index, line in
                            Text(line).font(.caption.monospaced()).textSelection(.enabled).id(index)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .onChange(of: model.log.count) { _, count in
                    if count > 0 { proxy.scrollTo(count - 1, anchor: .bottom) }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }
}

struct QRCodeView: View {
    let text: String

    var body: some View {
        if let image = Self.render(text) {
            Image(nsImage: image).interpolation(.none).resizable().scaledToFit()
        } else {
            Color.clear
        }
    }

    private static func render(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
