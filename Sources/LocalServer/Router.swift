import Foundation

/// Maps request paths to files (the layout ClrBootstrap and Addressables download from):
///   /clr/<version>/<platform>/<file>  -> <clrRoot>/<version>/<platform>/Upload/<file>
///   /addressables/<path>              -> <addressablesRoot>/<path>
/// Dot segments, backslashes and anything resolving outside a root are rejected.
struct Router {
    let clrRoot: URL
    let addressablesRoot: URL

    func file(for requestPath: String) -> URL? {
        let pathOnly = requestPath.split(separator: "?", maxSplits: 1).first.map(String.init) ?? ""
        let decoded = pathOnly.removingPercentEncoding ?? pathOnly
        var parts = decoded.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let route = parts.first,
              !parts.contains(where: { $0 == "." || $0 == ".." || $0.contains("\\") }) else { return nil }
        parts.removeFirst()

        let base: URL
        switch route {
        case "clr":
            base = clrRoot
            if parts.count >= 3 && parts[2] != "Upload" { parts.insert("Upload", at: 2) }
        case "addressables":
            base = addressablesRoot
        default:
            return nil
        }

        let root = base.standardizedFileURL.resolvingSymlinksInPath()
        let target = parts.reduce(root) { $0.appendingPathComponent($1) }.standardizedFileURL.resolvingSymlinksInPath()
        guard target.path.hasPrefix(root.path + "/") else { return nil }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory), !isDirectory.boolValue else { return nil }
        return target
    }

    static func contentType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "json": return "application/json"
        case "hash", "txt": return "text/plain; charset=utf-8"
        default: return "application/octet-stream"
        }
    }
}
