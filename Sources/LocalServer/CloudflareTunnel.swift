import Foundation

/// Runs `cloudflared` to publish the local server over HTTPS.
/// Quick: random https://<words>.trycloudflare.com, no account, changes every start.
/// Domain: fixed https://<hostname> on a zone of your Cloudflare account, after `cloudflared tunnel login` once on this Mac;
/// Start creates the named tunnel and its DNS record when missing.
final class CloudflareTunnel {
    enum Mode: String, CaseIterable, Identifiable {
        case quick, domain
        var id: String { rawValue }
    }

    struct Config {
        let mode: Mode
        let port: Int
        let tunnelName: String
        let hostname: String
    }

    enum Event {
        case log(String)
        /// Public https URL, once cloudflared has a connection to the edge.
        case ready(String)
        /// nil when stopped on purpose, otherwise the reason.
        case exited(String?)
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    private let queue = DispatchQueue(label: "LocalServer.tunnel")
    private let onEvent: (Event) -> Void
    private var process: Process?
    private var stopped = false
    private var isReady = false
    private var pending = ""

    init(onEvent: @escaping (Event) -> Void) {
        self.onEvent = onEvent
    }

    // MARK: - cloudflared

    /// Apps opened from Finder get a minimal PATH, so check the Homebrew locations first.
    static func executable() -> URL? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let candidates = ["/opt/homebrew/bin/cloudflared", "/usr/local/bin/cloudflared"]
            + path.split(separator: ":").map { "\($0)/cloudflared" }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    static var configFolder: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cloudflared") }
    static var isLoggedIn: Bool { FileManager.default.fileExists(atPath: configFolder.appendingPathComponent("cert.pem").path) }

    /// `cloudflared tunnel login`: opens the browser to pick a zone, writes ~/.cloudflared/cert.pem.
    static func login(onLog: @escaping (String) -> Void, completion: @escaping (String?) -> Void) {
        DispatchQueue.global().async {
            guard let exe = executable() else { return completion(Failure.missing.errorDescription) }
            let result = run(exe, ["tunnel", "login"], onLine: onLog)
            completion(result.status == 0 && isLoggedIn ? nil : lastLine(result.output) ?? "cloudflared tunnel login failed")
        }
    }

    // MARK: - Run

    func start(_ config: Config) {
        stopped = false
        isReady = false
        queue.async { [self] in
            do {
                guard let exe = Self.executable() else { throw Failure.missing }
                let origin = "http://127.0.0.1:\(config.port)"
                switch config.mode {
                case .quick:
                    try launch(exe, ["tunnel", "--no-autoupdate", "--url", origin], fixedURL: nil)
                case .domain:
                    try prepareNamedTunnel(exe, config)
                    guard !stopped else { return onEvent(.exited(nil)) }
                    try launch(exe, ["tunnel", "--no-autoupdate", "--url", origin, "run", config.tunnelName],
                               fixedURL: "https://\(config.hostname)")
                }
            } catch {
                onEvent(.exited(error.localizedDescription))
            }
        }
    }

    func stop() {
        stopped = true
        process?.terminate()
    }

    /// Create the tunnel when this account has none by that name, then point the hostname at it (replacing an old record).
    private func prepareNamedTunnel(_ exe: URL, _ config: Config) throws {
        guard Self.isLoggedIn else { throw Failure("Not logged in to Cloudflare. Press Login first.") }
        guard !config.hostname.isEmpty, config.hostname.contains(".") else { throw Failure("Enter the domain, e.g. cdn.example.com.") }
        guard !config.tunnelName.isEmpty else { throw Failure("Enter a tunnel name.") }

        let log: (String) -> Void = { [onEvent] in onEvent(.log($0)) }
        let list = Self.run(exe, ["tunnel", "list", "--output", "json", "--name", config.tunnelName])
        let tunnels = (try? JSONSerialization.jsonObject(with: Data(list.stdout.utf8))) as? [[String: Any]] ?? []
        if let id = tunnels.first?["id"] as? String {
            let credentials = Self.configFolder.appendingPathComponent("\(id).json")
            guard FileManager.default.fileExists(atPath: credentials.path) else {
                throw Failure("Tunnel '\(config.tunnelName)' exists on the account but \(credentials.path) is missing on this Mac. Use another tunnel name.")
            }
        } else {
            onEvent(.log("Creating tunnel \(config.tunnelName)"))
            let create = Self.run(exe, ["tunnel", "create", config.tunnelName], onLine: log)
            guard create.status == 0 else { throw Failure(Self.lastLine(create.output) ?? "cloudflared tunnel create failed") }
        }

        onEvent(.log("Routing \(config.hostname) → \(config.tunnelName)"))
        let route = Self.run(exe, ["tunnel", "route", "dns", "--overwrite-dns", config.tunnelName, config.hostname], onLine: log)
        guard route.status == 0 else { throw Failure(Self.lastLine(route.output) ?? "cloudflared tunnel route dns failed") }
    }

    private func launch(_ exe: URL, _ arguments: [String], fixedURL: String?) throws {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = exe
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        pending = ""
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            self.queue.async { self.consume(String(decoding: data, as: UTF8.self), fixedURL: fixedURL) }
        }
        process.terminationHandler = { [weak self] process in
            pipe.fileHandleForReading.readabilityHandler = nil
            guard let self else { return }
            self.queue.async {
                self.process = nil
                self.onEvent(.exited(self.stopped ? nil : "cloudflared exited (code \(process.terminationStatus))"))
            }
        }
        onEvent(.log("cloudflared \(arguments.joined(separator: " "))"))
        try process.run()
        self.process = process
        if stopped { process.terminate() }
    }

    /// cloudflared logs everything to stderr; pass on warnings/errors and watch for the moment the tunnel is up.
    private func consume(_ text: String, fixedURL: String?) {
        pending += text
        var lines = pending.components(separatedBy: "\n")
        pending = lines.removeLast()
        for line in lines where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            if line.contains(" ERR ") || line.contains(" WRN ") { onEvent(.log(line)) }
            guard !isReady else { continue }
            if let fixedURL, line.contains("Registered tunnel connection") {
                isReady = true
                onEvent(.ready(fixedURL))
            } else if fixedURL == nil, let range = line.range(of: #"https://[a-z0-9-]+\.trycloudflare\.com"#, options: .regularExpression),
                      !line[range].hasPrefix("https://api.") {
                isReady = true
                onEvent(.ready(String(line[range])))
            }
        }
    }

    // MARK: - Helpers

    private static func run(_ exe: URL, _ arguments: [String], onLine: ((String) -> Void)? = nil) -> (status: Int32, stdout: String, output: String) {
        let process = Process()
        let out = Pipe()
        let err = Pipe()
        process.executableURL = exe
        process.arguments = arguments
        process.standardOutput = out
        process.standardError = err
        var errText = ""
        let lock = NSLock()
        err.fileHandleForReading.readabilityHandler = { handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            lock.withLock { errText += text }
            text.split(separator: "\n").forEach { onLine?(String($0)) }
        }
        do { try process.run() } catch { return (-1, "", error.localizedDescription) }
        let stdout = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        err.fileHandleForReading.readabilityHandler = nil
        errText += String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        if onLine != nil { stdout.split(separator: "\n").forEach { onLine?(String($0)) } }
        return (process.terminationStatus, stdout, lock.withLock { errText } + stdout)
    }

    private static func lastLine(_ text: String) -> String? {
        text.split(separator: "\n").last.map(String.init)
    }
}

private extension CloudflareTunnel.Failure {
    static let missing = Self("cloudflared not found. Install it with: brew install cloudflared")
}
