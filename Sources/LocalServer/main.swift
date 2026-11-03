import Foundation

// `LocalServer --serve [--project <path>] [--port 8080] [--clr-dir <path>] [--addressables-dir <path>]
//               [--tunnel quick|<hostname>] [--tunnel-name <name>]` runs without UI (scripts, CI, ssh).
// --tunnel quick publishes a random https://….trycloudflare.com; --tunnel cdn.example.com a fixed domain (cloudflared tunnel login first).
// Anything else opens the app.
if CommandLine.arguments.contains("--serve") {
    Headless.run(arguments: CommandLine.arguments)
} else {
    LocalServerApp.main()
}

enum Headless {
    static func run(arguments: [String]) -> Never {
        func value(_ name: String) -> String? {
            guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }

        let project = URL(fileURLWithPath: value("--project") ?? FileManager.default.currentDirectoryPath)
        let port = UInt16(value("--port") ?? "") ?? 8080
        let clrRoot = value("--clr-dir").map { URL(fileURLWithPath: $0) } ?? project.appendingPathComponent("Export/CLR/deuegambit")
        let addressablesRoot = value("--addressables-dir").map { URL(fileURLWithPath: $0) } ?? project.appendingPathComponent("ServerData")
        let format = DateFormatter()
        format.dateFormat = "HH:mm:ss"

        let tunnel = CloudflareTunnel { event in
            switch event {
            case .log(let line): print("tunnel: \(line)")
            case .ready(let url): print("Tunnel up: \(url)  clr → \(url)/clr/  addressables → \(url)/addressables/")
            case .exited(let failure):
                print("Tunnel stopped: \(failure ?? "")")
                exit(1)
            }
            fflush(stdout)
        }
        // Ctrl-C: take cloudflared down with us.
        signal(SIGINT, SIG_IGN)
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        interrupt.setEventHandler {
            tunnel.stop()
            exit(0)
        }
        interrupt.resume()

        let server = HTTPServer(router: Router(clrRoot: clrRoot, addressablesRoot: addressablesRoot), onLog: { entry in
            print("\(format.string(from: Date())) \(entry.method) \(entry.path) \(entry.status) \(entry.bytes)")
            fflush(stdout)
        }, onState: { failure in
            if let failure {
                print("Listener failed: \(failure)")
                exit(1)
            }
            print("Listening on 0.0.0.0:\(port)  clr → \(clrRoot.path)  addressables → \(addressablesRoot.path)")
            fflush(stdout)
            if let target = value("--tunnel") {
                tunnel.start(CloudflareTunnel.Config(mode: target == "quick" ? .quick : .domain, port: Int(port),
                                                     tunnelName: value("--tunnel-name") ?? "deuegambit-localserver",
                                                     hostname: target.lowercased()))
            }
        })
        do {
            try server.start(port: port)
        } catch {
            print("Cannot start: \(error)")
            exit(1)
        }
        dispatchMain()
    }
}
