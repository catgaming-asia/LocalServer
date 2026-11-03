import AppKit
import Foundation

struct NetworkAddress: Hashable, Identifiable {
    let interface: String
    let address: String
    var id: String { address }
}

enum TunnelStatus: Equatable {
    case stopped, starting, running(String)

    var url: String? {
        if case .running(let url) = self { return url }
        return nil
    }
}

struct Payload: Identifiable {
    let id = UUID()
    let label: String
    let detail: String
    let testPath: String?
}

@MainActor
final class ServerModel: ObservableObject {
    // Persisted settings.
    @Published var projectPath: String { didSet { defaults.set(projectPath, forKey: "projectPath"); refresh() } }
    // Empty folder = the default inside the project (Export/CLR/deuegambit, ServerData).
    @Published var clrFolder: String { didSet { defaults.set(clrFolder, forKey: "clrFolder"); refresh() } }
    @Published var addressablesFolder: String { didSet { defaults.set(addressablesFolder, forKey: "addressablesFolder"); refresh() } }
    @Published var port: Int { didSet { defaults.set(port, forKey: "port") } }
    @Published var host: String { didSet { defaults.set(host, forKey: "host") } }
    @Published var tunnelMode: CloudflareTunnel.Mode { didSet { defaults.set(tunnelMode.rawValue, forKey: "tunnelMode") } }
    @Published var tunnelName: String { didSet { defaults.set(tunnelName, forKey: "tunnelName") } }
    @Published var tunnelHostname: String { didSet { defaults.set(tunnelHostname, forKey: "tunnelHostname") } }

    @Published private(set) var isRunning = false
    @Published private(set) var error: String?
    @Published private(set) var addresses: [NetworkAddress] = []
    @Published private(set) var clrPayloads: [Payload] = []
    @Published private(set) var addressablePayloads: [Payload] = []
    @Published private(set) var log: [String] = []
    @Published private(set) var tunnelStatus: TunnelStatus = .stopped
    @Published private(set) var tunnelError: String?
    @Published private(set) var isLoggingIn = false
    /// The Authorize page cloudflared opened, to open again if the browser tab got lost.
    @Published private(set) var loginURL: URL?
    @Published private(set) var isCloudflareLoggedIn = CloudflareTunnel.isLoggedIn
    let hasCloudflared = CloudflareTunnel.executable() != nil

    private let defaults = UserDefaults.standard
    private var server: HTTPServer?
    private var tunnel: CloudflareTunnel?
    private var loginProcess: Process?
    private static let timeFormat: DateFormatter = {
        let format = DateFormatter()
        format.dateFormat = "HH:mm:ss"
        return format
    }()

    var deviceURL: String { "http://\(host):\(port)" }
    /// The tunnel's https URL while it is up, otherwise the LAN URL.
    var shareURL: String { tunnelStatus.url ?? deviceURL }
    var projectURL: URL { URL(fileURLWithPath: projectPath) }
    var defaultClrRoot: URL { projectURL.appendingPathComponent("Export/CLR/deuegambit") }
    var defaultAddressablesRoot: URL { projectURL.appendingPathComponent("ServerData") }
    var clrRoot: URL { clrFolder.isEmpty ? defaultClrRoot : URL(fileURLWithPath: clrFolder) }
    var addressablesRoot: URL { addressablesFolder.isEmpty ? defaultAddressablesRoot : URL(fileURLWithPath: addressablesFolder) }
    var isProjectValid: Bool { FileManager.default.fileExists(atPath: projectURL.appendingPathComponent("Assets").path) }
    var isClrRootValid: Bool { Self.isDirectory(clrRoot) }
    var isAddressablesRootValid: Bool { Self.isDirectory(addressablesRoot) }

    init() {
        projectPath = defaults.string(forKey: "projectPath") ?? Self.guessProjectPath()
        clrFolder = defaults.string(forKey: "clrFolder") ?? ""
        addressablesFolder = defaults.string(forKey: "addressablesFolder") ?? ""
        let savedPort = defaults.integer(forKey: "port")
        port = savedPort > 0 ? savedPort : 8080
        host = defaults.string(forKey: "host") ?? ""
        tunnelMode = CloudflareTunnel.Mode(rawValue: defaults.string(forKey: "tunnelMode") ?? "") ?? .quick
        tunnelName = defaults.string(forKey: "tunnelName") ?? "deuegambit-localserver"
        tunnelHostname = defaults.string(forKey: "tunnelHostname") ?? ""
        refresh()
        // Do not leave cloudflared running after the app quits.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tunnel?.stop()
                self?.loginProcess?.terminate()
            }
        }
    }

    /// When launched from <project>/Localserver (swift run / the bundled app next to it), the project is the parent.
    private static func guessProjectPath() -> String {
        let candidates = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
            Bundle.main.bundleURL.deletingLastPathComponent()
        ]
        for start in candidates {
            var url = start
            for _ in 0..<4 {
                if FileManager.default.fileExists(atPath: url.appendingPathComponent("Assets").path) { return url.path }
                url.deleteLastPathComponent()
            }
        }
        return ""
    }

    func refresh() {
        isCloudflareLoggedIn = CloudflareTunnel.isLoggedIn
        addresses = Self.lanAddresses()
        if !addresses.contains(where: { $0.address == host }) { host = addresses.first?.address ?? "localhost" }
        scanPayloads()
    }

    func chooseProject() {
        if let url = Self.chooseFolder(message: "Choose the Unity project folder (the one containing Assets, Export and ServerData).",
                                       start: projectURL) { projectPath = url.path }
    }

    func chooseClrFolder() {
        if let url = Self.chooseFolder(message: "Choose the CLR export folder (contains <version>/<platform>/Upload).",
                                       start: clrRoot) { clrFolder = url.path }
    }

    func chooseAddressablesFolder() {
        if let url = Self.chooseFolder(message: "Choose the Addressables folder (contains <version>/<Target>/...).",
                                       start: addressablesRoot) { addressablesFolder = url.path }
    }

    private static func chooseFolder(message: String, start: URL) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Choose"
        panel.message = message
        if isDirectory(start) { panel.directoryURL = start }
        return panel.runModal() == .OK ? panel.url : nil
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    func start() {
        guard !isRunning, let port = UInt16(exactly: port) else { return }
        guard isClrRootValid && isAddressablesRootValid else { error = "CLR Folder and Addressables Folder must both exist."; return }
        let router = Router(clrRoot: clrRoot, addressablesRoot: addressablesRoot)
        let server = HTTPServer(router: router, onLog: { [weak self] entry in
            Task { @MainActor in self?.append(entry) }
        }, onState: { [weak self] failure in
            Task { @MainActor in
                guard let self else { return }
                self.error = failure
                if failure != nil { self.stop() }
            }
        })
        do {
            try server.start(port: port)
            self.server = server
            isRunning = true
            error = nil
            appendLine("Listening on \(deviceURL)  clr → \(clrRoot.path)/<version>/<platform>/Upload  addressables → \(addressablesRoot.path)")
        } catch {
            self.error = error.localizedDescription
        }
    }

    func stop() {
        stopTunnel()
        server?.stop()
        server = nil
        if isRunning { appendLine("Stopped") }
        isRunning = false
    }

    // MARK: - Cloudflare Tunnel

    func startTunnel() {
        guard tunnel == nil else { return }
        if !isRunning { start() }
        guard isRunning else { return }
        let config = CloudflareTunnel.Config(mode: tunnelMode, port: port,
                                             tunnelName: tunnelName.trimmingCharacters(in: .whitespaces),
                                             hostname: tunnelHostname.trimmingCharacters(in: .whitespaces).lowercased())
        let tunnel = CloudflareTunnel { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        self.tunnel = tunnel
        tunnelStatus = .starting
        tunnelError = nil
        tunnel.start(config)
    }

    func stopTunnel() {
        tunnel?.stop()
    }

    func loginCloudflare() {
        guard !isLoggingIn else { return }
        isLoggingIn = true
        loginURL = nil
        tunnelError = nil
        appendLine("tunnel: cloudflared tunnel login — in the browser pick the domain's zone, then click Authorize")
        loginProcess = CloudflareTunnel.login(onLog: { [weak self] line in
            Task { @MainActor in self?.appendLine("tunnel: \(line)") }
        }, onURL: { [weak self] url in
            Task { @MainActor in self?.loginURL = url }
        }, completion: { [weak self] failure in
            Task { @MainActor in
                guard let self else { return }
                self.loginProcess = nil
                self.isLoggingIn = false
                self.loginURL = nil
                self.tunnelError = failure
                self.isCloudflareLoggedIn = CloudflareTunnel.isLoggedIn
                self.appendLine(self.isCloudflareLoggedIn ? "tunnel: logged in, ~/.cloudflared/cert.pem saved" : "tunnel: login not finished")
            }
        })
    }

    func cancelLogin() {
        loginProcess?.terminate()
    }

    func openLoginPage() {
        if let loginURL { NSWorkspace.shared.open(loginURL) }
    }

    private func handle(_ event: CloudflareTunnel.Event) {
        switch event {
        case .log(let line):
            appendLine("tunnel: \(line)")
        case .ready(let url):
            tunnelStatus = .running(url)
            appendLine("Tunnel up: \(url)")
        case .exited(let failure):
            tunnel = nil
            tunnelStatus = .stopped
            tunnelError = failure
            appendLine(failure.map { "Tunnel stopped: \($0)" } ?? "Tunnel stopped")
        }
    }

    func clearLog() { log.removeAll() }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func test(_ payload: Payload) {
        guard let path = payload.testPath, let url = URL(string: "http://localhost:\(port)\(path)") else { return }
        NSWorkspace.shared.open(url)
    }

    private func append(_ entry: HTTPServer.LogEntry) {
        let size = entry.bytes > 0 ? "  \(ByteCountFormatter.string(fromByteCount: Int64(entry.bytes), countStyle: .file))" : ""
        appendLine("\(entry.method) \(entry.path) \(entry.status)\(size)")
    }

    private func appendLine(_ text: String) {
        log.append("\(Self.timeFormat.string(from: Date())) \(text)")
        if log.count > 500 { log.removeFirst(log.count - 500) }
    }

    // MARK: - Scanning

    /// CLR: <clrRoot>/<version>/<platform>/Upload/hotupdate.hash.
    /// Addressables: <ServerData>/<version>/<Target>/<audience>/catalog_*.hash.
    private func scanPayloads() {
        var clr: [Payload] = []
        for version in Self.subdirectories(clrRoot) {
            for platform in Self.subdirectories(version) {
                let upload = platform.appendingPathComponent("Upload")
                let ready = FileManager.default.fileExists(atPath: upload.appendingPathComponent("hotupdate.hash").path)
                let relative = "\(version.lastPathComponent)/\(platform.lastPathComponent)"
                clr.append(Payload(label: relative.replacingOccurrences(of: "/", with: " / "),
                                   detail: ready ? Self.describe(upload) : "no Upload/hotupdate.hash",
                                   testPath: ready ? "/clr/\(relative)/hotupdate.hash" : nil))
            }
        }

        var addressables: [Payload] = []
        for version in Self.subdirectories(addressablesRoot) {
            for target in Self.subdirectories(version) {
                for audience in Self.subdirectories(target) {
                    let files = (try? FileManager.default.contentsOfDirectory(atPath: audience.path)) ?? []
                    guard let catalog = files.sorted().first(where: { $0.hasPrefix("catalog_") && $0.hasSuffix(".hash") }) else { continue }
                    let relative = "\(version.lastPathComponent)/\(target.lastPathComponent)/\(audience.lastPathComponent)"
                    addressables.append(Payload(label: relative.replacingOccurrences(of: "/", with: " / "),
                                                detail: Self.describe(audience),
                                                testPath: "/addressables/\(relative)/\(catalog)"))
                }
            }
        }

        clrPayloads = clr
        addressablePayloads = addressables
    }

    private static func subdirectories(_ url: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey],
                                                                  options: [.skipsHiddenFiles])) ?? []
        return items.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func describe(_ folder: URL) -> String {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                                   options: [.skipsHiddenFiles])) ?? [])
            .compactMap { try? $0.resourceValues(forKeys: Set(keys)) }
            .filter { $0.isRegularFile == true }
        guard !files.isEmpty else { return "empty" }
        let size = ByteCountFormatter.string(fromByteCount: Int64(files.reduce(0) { $0 + ($1.fileSize ?? 0) }), countStyle: .file)
        let modified = files.compactMap(\.contentModificationDate).max().map {
            let format = DateFormatter()
            format.dateFormat = "dd/MM HH:mm"
            return format.string(from: $0)
        } ?? "-"
        return "\(files.count) files, \(size), \(modified)"
    }

    // MARK: - Network

    static func lanAddresses() -> [NetworkAddress] {
        var result: [NetworkAddress] = []
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return result }
        defer { freeifaddrs(pointer) }
        for item in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(item.pointee.ifa_flags)
            guard let address = item.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            var name = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &name, socklen_t(name.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            result.append(NetworkAddress(interface: String(cString: item.pointee.ifa_name), address: String(cString: name)))
        }
        // en0/en1 (Wi-Fi / Ethernet) first.
        return result.sorted { ($0.interface.hasPrefix("en") ? 0 : 1, $0.interface) < ($1.interface.hasPrefix("en") ? 0 : 1, $1.interface) }
    }
}
