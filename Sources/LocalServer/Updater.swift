import AppKit
import CryptoKit
import Foundation

// Self-update from a public folder (Cloudflare R2): <Update URL>latest.json + the zip next to it. No token.
// build/release.command writes both files; upload them by hand (zip first, latest.json last).
// Ported from My Connector (Termus/swift/Sources/Termus/Updater.swift).

let updateURLDefaultsKey = "updateBaseURL"
let defaultUpdateURL = "https://data.catgaming.asia/LocalServer/release/"
let updateBundleID = "asia.catgaming.deuegambit.localserver"

/// CFBundleShortVersionString; `swift run` has no Info.plist → "0.0.0".
func currentAppVersion() -> String {
    (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
}

/// "x.y.z" (leading "v" allowed). Unreadable text never counts as newer.
func isNewerVersion(_ latest: String, than current: String) -> Bool {
    func numbers(_ text: String) -> [Int]? {
        var core = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if core.hasPrefix("v") { core.removeFirst() }
        let parts = core.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard (1...3).contains(parts.count), parts.allSatisfy({ ($0 ?? -1) >= 0 }) else { return nil }
        return parts.compactMap { $0 } + Array(repeating: 0, count: 3 - parts.count)
    }
    guard let latest = numbers(latest), let current = numbers(current) else { return false }
    return current.lexicographicallyPrecedes(latest)
}

struct UpdateFailure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

/// https only, no login/query/fragment, always ends with "/".
func updateBaseURL(_ text: String) -> Result<URL, UpdateFailure> {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard var parts = URLComponents(string: trimmed), parts.scheme?.lowercased() == "https",
          parts.host?.isEmpty == false, parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil else {
        return .failure(UpdateFailure("The Update URL must be a plain https:// folder address."))
    }
    if !parts.path.hasSuffix("/") { parts.path += "/" }
    guard let url = parts.url else { return .failure(UpdateFailure("The Update URL is not a valid address.")) }
    return .success(url)
}

/// latest.json: {"version","build","date","notes","file","size","sha256"}; `file` sits in the same folder.
struct UpdateManifest: Equatable {
    let version: String
    let date: Date?
    let notes: String
    let file: String
    let size: Int64
    let sha256: String
    let fileURL: URL

    static func parse(_ data: Data, base: URL) -> Result<UpdateManifest, UpdateFailure> {
        let bad: (String) -> Result<UpdateManifest, UpdateFailure> = { .failure(UpdateFailure("latest.json is not valid: \($0).")) }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return bad("not a JSON object") }
        guard let version = object["version"] as? String, isNewerVersion(version, than: "0.0.0") || version == "0.0.0" else {
            return bad("missing or wrong \"version\"")
        }
        guard let file = object["file"] as? String, file.lowercased().hasSuffix(".zip"), !file.hasPrefix("."),
              !file.contains("/"), !file.contains("\\"), !file.contains("?"), !file.contains("#") else {
            return bad("\"file\" must be a .zip name in the same folder")
        }
        guard let size = (object["size"] as? NSNumber)?.int64Value, size > 0 else { return bad("missing or wrong \"size\"") }
        let hex = ((object["sha256"] as? String) ?? "").lowercased()
        guard hex.count == 64, hex.allSatisfy(\.isHexDigit) else { return bad("\"sha256\" must be 64 hex characters") }
        return .success(UpdateManifest(version: version, date: (object["date"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) },
                                       notes: ((object["notes"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                                       file: file, size: size, sha256: hex, fileURL: base.appendingPathComponent(file)))
    }
}

/// Waits for the app to quit, swaps in the new bundle (restoring the old one on failure), reopens it.
/// $1 PID, $2 new app, $3 target app, $4 temp folder to delete.
private let installScript = """
#!/bin/sh
pid="$1"; new="$2"; target="$3"; work="$4"
old="$target.old"
i=0
while kill -0 "$pid" 2>/dev/null; do
  i=$((i + 1))
  [ "$i" -gt 600 ] && exit 1
  sleep 0.1
done
rm -rf "$old"
if mv "$target" "$old"; then
  if mv "$new" "$target"; then
    rm -rf "$old"
  else
    rm -rf "$target"
    mv "$old" "$target"
  fi
fi
open "$target"
rm -rf "$work"
"""

enum UpdatePhase: Equatable {
    case idle
    case checking
    case upToDate
    case failed(String)
    case available(UpdateManifest)
    /// fraction nil = size unknown yet.
    case downloading(UpdateManifest, fraction: Double?)
    case verifying(UpdateManifest)
    case installing
}

@MainActor
final class Updater: ObservableObject {
    @Published private(set) var phase: UpdatePhase = .idle
    @Published var showSheet = false
    @Published var urlText: String { didSet { UserDefaults.standard.set(urlText, forKey: updateURLDefaultsKey) } }
    let current = currentAppVersion()
    private var work: Task<Void, Never>?

    init() {
        urlText = UserDefaults.standard.string(forKey: updateURLDefaultsKey) ?? defaultUpdateURL
    }

    var available: UpdateManifest? {
        if case .available(let manifest) = phase { return manifest }
        return nil
    }

    /// quiet: launch check, failures leave the phase idle instead of showing an error.
    func check(quiet: Bool = false) {
        let base: URL
        switch updateBaseURL(urlText) {
        case .failure(let error):
            phase = quiet ? .idle : .failed(error.localizedDescription)
            return
        case .success(let url): base = url
        }
        phase = .checking
        work?.cancel()
        work = Task { [weak self] in
            let result = await Self.fetchManifest(base)
            guard let self, !Task.isCancelled else { return }
            switch result {
            case .failure(let error): self.phase = quiet ? .idle : .failed(error.localizedDescription)
            case .success(let manifest): self.phase = isNewerVersion(manifest.version, than: self.current) ? .available(manifest) : .upToDate
            }
        }
    }

    func cancel() {
        work?.cancel()
        work = nil
        if case .installing = phase { return }
        phase = .idle
    }

    /// Download, check size + SHA-256, unpack, check bundle id + version, then run the install script and quit.
    func install(_ manifest: UpdateManifest) {
        let target = Bundle.main.bundleURL
        let parent = target.deletingLastPathComponent()
        guard target.pathExtension == "app", FileManager.default.isWritableFile(atPath: parent.path) else {
            phase = .failed("Local Server can't replace itself in “\(parent.path)”. Run it from LocalServer.app in a folder you can write to.")
            return
        }
        phase = .downloading(manifest, fraction: nil)
        work?.cancel()
        work = Task { [weak self] in
            guard let self else { return }
            let result = await self.prepare(manifest, target: target)
            guard !Task.isCancelled else { return }
            switch result {
            case .failure(let error): self.phase = .failed(error.localizedDescription)
            case .success(let process):
                self.phase = .installing
                guard (try? process.run()) != nil else { return self.phase = .failed("Could not start the installer script.") }
                // terminate is ignored while a sheet is attached.
                for window in NSApp.windows {
                    while let sheet = window.attachedSheet { window.endSheet(sheet) }
                }
                DispatchQueue.main.async { NSApp.terminate(nil) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { exit(0) }
            }
        }
    }

    private func prepare(_ manifest: UpdateManifest, target: URL) async -> Result<Process, UpdateFailure> {
        let fm = FileManager.default
        let workDir = fm.temporaryDirectory.appendingPathComponent("LocalServerUpdate-\(UUID().uuidString)", isDirectory: true)
        let fail: (String) -> Result<Process, UpdateFailure> = {
            try? fm.removeItem(at: workDir)
            return .failure(UpdateFailure($0))
        }
        guard (try? fm.createDirectory(at: workDir, withIntermediateDirectories: true)) != nil else {
            return fail("Could not create a temporary folder for the update.")
        }

        let zip = workDir.appendingPathComponent(manifest.file)
        if let error = await download(manifest, to: zip) { return fail(error) }
        guard !Task.isCancelled else { return fail("Cancelled.") }

        phase = .verifying(manifest)
        let size = ((try? fm.attributesOfItem(atPath: zip.path))?[.size] as? NSNumber)?.int64Value ?? -1
        guard size == manifest.size else { return fail("Downloaded \(size) bytes but latest.json says \(manifest.size). Update cancelled.") }
        let hash = await Task.detached { Self.sha256(zip) }.value
        guard hash == manifest.sha256 else { return fail("The download's SHA-256 doesn't match latest.json. Update cancelled.") }

        let unpacked = workDir.appendingPathComponent("app", isDirectory: true)
        guard await Self.runTool("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path]) == 0 else { return fail("Could not unpack \(manifest.file).") }
        let apps = ((try? fm.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "app" }
        guard apps.count == 1, let newApp = apps.first else { return fail("\(manifest.file) should contain exactly one app.") }
        let info = NSDictionary(contentsOf: newApp.appendingPathComponent("Contents/Info.plist")) as? [String: Any]
        guard info?["CFBundleIdentifier"] as? String == updateBundleID else { return fail("The downloaded app is not Local Server (bundle identifier mismatch).") }
        guard info?["CFBundleShortVersionString"] as? String == manifest.version else { return fail("The downloaded app's version doesn't match \(manifest.version).") }

        let script = workDir.appendingPathComponent("install.sh")
        guard (try? Data(installScript.utf8).write(to: script)) != nil else { return fail("Could not write the installer script.") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path, String(ProcessInfo.processInfo.processIdentifier), newApp.path, target.path, workDir.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return .success(process)
    }

    /// nil on success, otherwise the reason.
    private func download(_ manifest: UpdateManifest, to destination: URL) async -> String? {
        let session = URLSession(configuration: Self.sessionConfig())
        defer { session.finishTasksAndInvalidate() }
        do {
            let (bytes, response) = try await session.bytes(for: Self.request(manifest.fileURL))
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else { return "Download of \(manifest.file) failed (HTTP \(status))." }
            FileManager.default.createFile(atPath: destination.path, contents: nil)
            let handle = try FileHandle(forWritingTo: destination)
            defer { try? handle.close() }
            var buffer = Data()
            var written: Int64 = 0
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count >= 1 << 20 {
                    try handle.write(contentsOf: buffer)
                    written += Int64(buffer.count)
                    buffer.removeAll(keepingCapacity: true)
                    phase = .downloading(manifest, fraction: min(1, Double(written) / Double(manifest.size)))
                }
            }
            try handle.write(contentsOf: buffer)
            return nil
        } catch is CancellationError {
            return "Cancelled."
        } catch {
            return "Download failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Helpers

    private static func fetchManifest(_ base: URL) async -> Result<UpdateManifest, UpdateFailure> {
        // ?t= changes every time so the CDN never answers from cache.
        var parts = URLComponents(url: base.appendingPathComponent("latest.json"), resolvingAgainstBaseURL: false)
        parts?.queryItems = [URLQueryItem(name: "t", value: String(Int(Date().timeIntervalSince1970)))]
        guard let url = parts?.url else { return .failure(UpdateFailure("The Update URL is not a valid address.")) }
        let session = URLSession(configuration: sessionConfig())
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, response) = try await session.data(for: request(url))
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                return .failure(UpdateFailure(status == 404 ? "HTTP 404: no latest.json at \(base.absoluteString)." : "HTTP \(status) reading latest.json."))
            }
            return UpdateManifest.parse(data, base: base)
        } catch {
            return .failure(UpdateFailure("Could not reach \(base.host ?? "the update server"): \(error.localizedDescription)"))
        }
    }

    private static func sessionConfig() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        return config
    }

    private static func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("LocalServer/\(currentAppVersion())", forHTTPHeaderField: "User-Agent")
        return request
    }

    private nonisolated static func sha256(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func runTool(_ path: String, _ arguments: [String]) async -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        return await withCheckedContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            if (try? process.run()) == nil {
                process.terminationHandler = nil
                continuation.resume(returning: -1)
            }
        }
    }
}
