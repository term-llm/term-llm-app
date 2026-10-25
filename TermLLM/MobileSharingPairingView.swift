import SwiftUI
import UIKit

@MainActor
final class MobileSharingPairingModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case review
        case requesting
        case waitingForOwner(String)
        case connected(String)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var link: MobileSharingPairingLink?
    private var task: Task<Void, Never>?

    var isPresented: Bool { phase != .idle }
    var canDismiss: Bool {
        switch phase {
        case .requesting, .waitingForOwner: false
        default: true
        }
    }

    /// Returns true only for the reserved pairing authority. Invalid pair URLs
    /// are consumed and shown as errors; ordinary termllm://connect continues
    /// to the existing importer.
    func handle(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "termllm", url.host?.lowercased() == "pair" else { return false }
        task?.cancel()
        do {
            let parsed = try MobileSharingPairingLink.parse(url.absoluteString)
            guard !parsed.isExpired() else { throw MobileSharingProtocolError.expired }
            link = parsed
            phase = .review
        } catch {
            link = nil
            phase = .failed(error.localizedDescription)
        }
        return true
    }

    func begin(catalog: HubConnectionStore, runtime: MobileSharingRuntime) {
        guard let link, phase == .review else { return }
        phase = .requesting
        let deviceName = UIDevice.current.name
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let source = try await runtime.pair(link: link, deviceName: deviceName, catalog: catalog) { [weak self] sas in
                    Task { @MainActor [weak self] in
                        guard let self, self.phase == .requesting else { return }
                        self.phase = .waitingForOwner(sas)
                    }
                }
                guard !Task.isCancelled else { return }
                phase = .connected(source.name)
            } catch is CancellationError {
                phase = .idle
                self.link = nil
            } catch {
                guard !Task.isCancelled else { return }
                phase = .failed(error.localizedDescription)
            }
            task = nil
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        link = nil
        phase = .idle
    }

    func dismiss() {
        guard canDismiss else { return }
        link = nil
        phase = .idle
    }
}

struct MobileSharingPairingView: View {
    @ObservedObject var model: MobileSharingPairingModel
    @ObservedObject var catalog: HubConnectionStore
    @ObservedObject var runtime: MobileSharingRuntime

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                content
                Spacer(minLength: 0)
            }
            .padding(24)
            .navigationTitle("Mobile Sharing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if model.canDismiss {
                        Button("Close") { model.dismiss() }
                    } else {
                        Button("Cancel", role: .cancel) { model.cancel() }
                    }
                }
            }
        }
        .interactiveDismissDisabled(!model.canDismiss)
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .idle:
            EmptyView()
        case .review:
            Image(systemName: "iphone.and.arrow.forward").font(.system(size: 48)).foregroundStyle(.blue)
            Text("Connect to this host?").font(.title2.bold())
            if let link = model.link {
                detail("Host", link.hostLabel ?? "Unnamed host")
                detail("Host identity", link.hostFingerprint)
                detail("Rendezvous", link.broker.host ?? "Unknown")
                Text("Only continue if this is the host whose QR code you scanned. The host can show this app its conversations and run tools under its configured approval mode.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("Request access") { model.begin(catalog: catalog, runtime: runtime) }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("mobileSharing.request")
            }
        case .requesting:
            ProgressView()
            Text("Authenticating this iPhone…").font(.headline)
            Text("No host has been saved yet.").font(.footnote).foregroundStyle(.secondary)
        case .waitingForOwner(let sas):
            ProgressView()
            Text("Enter this code on the host").font(.headline)
            Text(sas)
                .font(.system(.largeTitle, design: .monospaced).weight(.bold))
                .tracking(6)
                .accessibilityLabel(sas.map(String.init).joined(separator: " "))
                .accessibilityIdentifier("mobileSharing.sas")
            Text("The code is derived from both device identities and this one-use invitation. Keep this screen open while the owner approves it in Mobile Sharing settings.")
                .font(.footnote).foregroundStyle(.secondary)
        case .connected(let name):
            Image(systemName: "checkmark.shield.fill").font(.system(size: 48)).foregroundStyle(.green)
            Text("Saved \(name)").font(.title2.bold())
            Text("The verified host is saved and will reconnect without another QR code if it is currently offline.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button("Done") { model.dismiss() }.buttonStyle(.borderedProminent)
                .accessibilityIdentifier("mobileSharing.done")
        case .failed(let message):
            Image(systemName: "exclamationmark.shield.fill").font(.system(size: 48)).foregroundStyle(.orange)
            Text("Couldn’t connect").font(.title2.bold())
            Text(message).multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button("Close") { model.dismiss() }.buttonStyle(.bordered)
        }
    }

    private func detail(_ label: String, _ value: String) -> some View {
        LabeledContent(label) { Text(value).font(.system(.body, design: .monospaced)).multilineTextAlignment(.trailing) }
            .frame(maxWidth: .infinity)
    }
}
