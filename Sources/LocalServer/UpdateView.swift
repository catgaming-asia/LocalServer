import SwiftUI

/// Local Server › Check for Updates…: check, show notes, download + install.
struct UpdateSheet: View {
    @EnvironmentObject private var updater: Updater
    @EnvironmentObject private var model: ServerModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Software Update").font(.title3.bold())
            content
        }
        .padding(20)
        .frame(width: 460)
        .interactiveDismissDisabled(busy)
        .onAppear { if updater.available == nil { updater.check() } }
    }

    private var busy: Bool {
        switch updater.phase {
        case .downloading, .verifying, .installing: true
        default: false
        }
    }

    @ViewBuilder
    private var content: some View {
        switch updater.phase {
        case .idle, .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking for updates…").foregroundStyle(.secondary)
            }
            buttons { Button("Cancel") { close() }.keyboardShortcut(.cancelAction) }
        case .upToDate:
            Text("Local Server \(updater.current) is up to date.")
            buttons { Button("OK") { close() }.keyboardShortcut(.defaultAction) }
        case .failed(let text):
            Text(text).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            buttons {
                Button("Close") { close() }.keyboardShortcut(.cancelAction)
                Button("Try Again") { updater.check() }.keyboardShortcut(.defaultAction)
            }
        case .available(let release):
            releaseInfo(release)
            if model.isRunning {
                Label("The server and tunnel stop while Local Server restarts.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            buttons {
                Button("Later") { close() }.keyboardShortcut(.cancelAction)
                Button("Install") { updater.install(release) }.keyboardShortcut(.defaultAction)
            }
        case .downloading(let release, let fraction):
            releaseInfo(release)
            if let fraction {
                ProgressView(value: fraction) { Text("Downloading… \(Int(fraction * 100))%").foregroundStyle(.secondary) }
            } else {
                ProgressView { Text("Downloading…").foregroundStyle(.secondary) }
            }
            buttons { Button("Cancel") { close() }.keyboardShortcut(.cancelAction) }
        case .verifying(let release):
            releaseInfo(release)
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Verifying and unpacking…").foregroundStyle(.secondary)
            }
        case .installing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Installing. Local Server will quit and reopen.").foregroundStyle(.secondary)
            }
        }
    }

    private func releaseInfo(_ release: UpdateManifest) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Local Server \(release.version) is available — you have \(updater.current).")
            Text(meta(release)).font(.caption).foregroundStyle(.secondary)
            if !release.notes.isEmpty {
                ScrollView {
                    Text(release.notes).font(.caption).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                }
                .frame(maxHeight: 200)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private func meta(_ release: UpdateManifest) -> String {
        let size = release.size.formatted(.byteCount(style: .file))
        guard let date = release.date else { return size }
        return "\(date.formatted(date: .long, time: .omitted)) · \(size)"
    }

    private func buttons(@ViewBuilder _ content: () -> some View) -> some View {
        HStack {
            Spacer()
            content()
        }
    }

    private func close() {
        updater.cancel()
        dismiss()
    }
}

/// Local Server › Settings…: where updates come from.
struct SettingsView: View {
    @EnvironmentObject private var updater: Updater

    var body: some View {
        Form {
            Section("Updates") {
                TextField("Update URL", text: $updater.urlText, prompt: Text(defaultUpdateURL))
                    .font(.body.monospaced())
                Text(hint).font(.caption).foregroundStyle(.secondary)
                Text("Current version: \(updater.current)").font(.caption).foregroundStyle(.secondary)
                Button("Reset to Default") { updater.urlText = defaultUpdateURL }.disabled(updater.urlText == defaultUpdateURL)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
    }

    private var hint: String {
        switch updateBaseURL(updater.urlText) {
        case .failure(let error): error.localizedDescription
        case .success(let url): "Checks \(url.absoluteString)latest.json (public, no token)."
        }
    }
}
