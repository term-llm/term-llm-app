import SwiftUI
import UIKit
import WebKit
import CryptoKit

/// One authorized peer connection plus its owned chat bridge and WebKit
/// data store.  The data store is non-persistent and private to this link:
/// it holds only the bridge's HttpOnly capability cookie and the remote
/// chat's own storage, never the app's default (production) cookies.
@MainActor
final class PeerActiveConnection: Identifiable {
    let id = UUID()
    let link: PeerHubLink
    let endpoint: PeerLoopbackEndpoint
    let dataStore: WKWebsiteDataStore
    let relayOnly: Bool
    /// The peer ingress serves the Hub at "/" (core `contain pair` BasePath
    /// "/").  The native Hub uses the bridge origin as its identity so
    /// Hub-supplied paths map onto owned loopback URLs; Hub API requests
    /// themselves go over WebRTCHubTransport, not the bridge.
    var hubURL: URL { endpoint.baseURL }

    init(link: PeerHubLink, endpoint: PeerLoopbackEndpoint, dataStore: WKWebsiteDataStore, relayOnly: Bool) {
        self.link = link
        self.endpoint = endpoint
        self.dataStore = dataStore
        self.relayOnly = relayOnly
    }

    func hubTransport() -> WebRTCHubTransport { link.hubTransport(hubBaseURL: hubURL) }
}

/// What the device-side confirmation shows: never the secret, capability or
/// full link.
struct PeerPairingReview: Equatable {
    let hostName: String
    let hostFingerprint: String
    let deviceFingerprint: String?
    let signallingHost: String
    let expiresAt: Date
}

@MainActor
final class PeerConnectionModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case review
        case connecting
        case connected
        case failed(String)
        case disconnected(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var review: PeerPairingReview?
    @Published private(set) var active: PeerActiveConnection?
    @Published private(set) var showingHub = true
    @Published private(set) var chatRootURL: URL?
    @Published private(set) var chatDestination: HubBrowserDestination?
    @Published private(set) var captureStatus: String?
    @Published private(set) var exported = false

    let capture: PeerCaptureConfiguration?
    private let recorder: PeerCaptureRecorder?
    private let store = PeerIdentityStore()
    private var pendingLink: PeerPairingLink?
    private var connectTask: Task<Void, Never>?
    private var beforeChat: PeerSessionStats?
    private var hubReturned = false

    init(capture: PeerCaptureConfiguration? = PeerCaptureConfiguration.fromEnvironment()) {
        self.capture = capture
        self.recorder = capture == nil ? nil : PeerCaptureRecorder()
        if let capture {
            do { try PeerCaptureEvidence.writeReady(capture) } catch { captureStatus = "Ready marker not written" }
        }
    }

    var isPresenting: Bool { phase != .idle }

    // MARK: URL entry (real OS URL handler)

    /// True when `url` is a pairing link (handled or refused here).
    func handle(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == PeerPairingWire.linkScheme else { return false }
        switch phase {
        case .idle, .failed, .disconnected: break
        default: return true  // one pairing at a time
        }
        let link: PeerPairingLink
        do {
            link = try PeerPairingLink.parse(url.absoluteString)
        } catch {
            phase = .failed("This pairing link is not valid.")
            return true
        }
        guard !link.isExpired() else {
            phase = .failed(PeerPairingError.expired.localizedDescription)
            return true
        }
        pendingLink = link
        let host = link.broker.host ?? "-"
        review = PeerPairingReview(
            hostName: link.name ?? "Unnamed host",
            hostFingerprint: PeerBase64URL.encode(Data(SHA256.hash(data: link.hostKey).prefix(9))),
            deviceFingerprint: try? store.deviceIdentity().fingerprint,
            signallingHost: link.broker.port.map { "\(host):\($0)" } ?? host,
            expiresAt: link.expiresAt)
        phase = .review
        return true
    }

    // MARK: Device-side confirmation

    func reject() {
        pendingLink = nil
        review = nil
        phase = .idle
    }

    func approve() {
        guard phase == .review, let link = pendingLink else { return }
        pendingLink = nil
        phase = .connecting
        let options = Self.options(capture)
        connectTask = Task { [weak self] in
            guard let self else { return }
            do {
                let connection = try await self.connect(link: link, options: options)
                guard !Task.isCancelled, self.phase == .connecting else {
                    connection.link.revoke()
                    return
                }
                self.adopt(connection)
            } catch {
                guard self.phase == .connecting else { return }
                self.phase = .failed((error as? LocalizedError)?.errorDescription ?? "Pairing failed.")
            }
        }
    }

    func cancelConnecting() {
        connectTask?.cancel()
        connectTask = nil
        review = nil
        phase = .idle
    }

    func dismiss() {
        review = nil
        phase = .idle
    }

    func disconnect() {
        let connection = active
        active = nil
        chatRootURL = nil
        chatDestination = nil
        review = nil
        phase = .idle
        connection?.link.revoke()
    }

    private static func options(_ capture: PeerCaptureConfiguration?) -> PeerHubConnector.Options {
        guard let capture else { return PeerHubConnector.Options() }
        return PeerHubConnector.Options(iceServers: capture.iceServers, relayOnly: capture.forceRelay)
    }

    private func connect(link: PeerPairingLink, options: PeerHubConnector.Options) async throws -> PeerActiveConnection {
        let hub = try await PeerHubConnector.pair(link: link, deviceName: Self.deviceName(), store: store, options: options)
        do {
            let forwarder = recorder.map { $0.wrap(hub.multiplexer) }
            let bridge = try hub.makeChatBridge(listener: PeerNWLoopbackListener(), forwarder: forwarder)
            let endpoint = try await bridge.start()
            let dataStore = WKWebsiteDataStore.nonPersistent()
            await endpoint.installCapability(in: dataStore.httpCookieStore)
            return PeerActiveConnection(link: hub, endpoint: endpoint, dataStore: dataStore,
                                        relayOnly: options.relayOnly)
        } catch {
            hub.revoke()
            throw error
        }
    }

    private func adopt(_ connection: PeerActiveConnection) {
        active = connection
        review = nil
        chatRootURL = nil
        chatDestination = nil
        showingHub = true
        phase = .connected
        let id = connection.id
        connection.link.onTeardown = { [weak self] _ in
            Task { @MainActor in self?.tornDown(id) }
        }
        // Teardown may have raced the handler installation.
        if !connection.link.isActive { tornDown(id) }
    }

    private func tornDown(_ id: UUID) {
        guard let connection = active, connection.id == id else { return }
        active = nil
        chatRootURL = nil
        chatDestination = nil
        let endpoint = connection.endpoint
        let cookies = connection.dataStore.httpCookieStore
        Task { @MainActor in await endpoint.removeCapability(from: cookies) }
        // Reconnect is pilot-limited to a live broker mailbox and is not
        // offered here.  The stored pairing record is kept; a scope 403 never
        // reaches this path (it is a route error in WebRTCHubTransport).
        phase = .disconnected("The peer connection closed. Create a new pairing code on the host to connect again.")
    }

    private static func deviceName() -> String {
        let name = UIDevice.current.name
        return (try? PeerPairingValidation.deviceName(name)) != nil ? name : "iPhone"
    }

    // MARK: Workspace navigation

    func openChat(_ url: URL) {
        guard let connection = active, connection.endpoint.owns(url) else { return }
        if chatRootURL == nil {
            chatRootURL = url  // BrowserView's initial load; no second native load
        } else {
            chatDestination = HubBrowserDestination(url: url)
        }
        showingHub = false
    }

    func showHub() {
        if recorder?.hasCompletedResponse == true { hubReturned = true }
        showingHub = true
    }

    func showChat() {
        guard chatRootURL != nil else { return }
        showingHub = false
    }

    // MARK: DEBUG capture actions (only reachable when `capture` != nil)

    /// Opens the private link through the real OS URL handler.
    func openCapturePairLink() {
        guard let url = capture?.pairingLink else { return }
        UIApplication.shared.open(url)
    }

    func sampleBeforeChat() {
        guard capture != nil else { return }
        guard let connection = active else { captureStatus = "Not connected"; return }
        Task { @MainActor in
            beforeChat = await connection.link.stats()
            captureStatus = "Stats sampled"
        }
    }

    func exportEvidence() {
        guard let capture else { return }
        exported = false
        let connection = active
        Task { @MainActor in
            let after = await connection?.link.stats()
            let document = PeerCaptureEvidence.document(
                config: capture, chat: recorder?.latestExchange()?.evidence(),
                before: beforeChat, after: after, hubReturned: hubReturned)
            do {
                try PeerCaptureEvidence.write(document, name: PeerCaptureConfiguration.evidenceFileName)
                exported = true
                captureStatus = nil
            } catch {
                captureStatus = "Export failed"
            }
        }
    }
}

// MARK: - Views

struct PeerRootView: View {
    @ObservedObject var model: PeerConnectionModel

    var body: some View {
        switch model.phase {
        case .connected:
            if let connection = model.active {
                PeerWorkspaceView(model: model, connection: connection)
            } else {
                ProgressView()
            }
        case .disconnected(let message):
            PeerMessageView(title: "Disconnected", symbol: "bolt.horizontal.circle", message: message) {
                Button("Done") { model.dismiss() }.buttonStyle(.borderedProminent)
            }
        default:
            PeerApprovalView(model: model)
        }
    }
}

struct PeerMessageView<Actions: View>: View {
    let title: String
    let symbol: String
    let message: String
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(spacing: 20) {
            ContentUnavailableView(title, systemImage: symbol, description: Text(message))
            VStack(spacing: 12, content: actions)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Visible device-side confirmation.  The host terminal must ALSO approve.
struct PeerApprovalView: View {
    @ObservedObject var model: PeerConnectionModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Label("Pair with a computer", systemImage: "link.badge.plus")
                    .font(.title2.bold())
                if let review = model.review {
                    LabeledContent("Host", value: review.hostName)
                    LabeledContent("Host key", value: review.hostFingerprint)
                        .font(.body.monospaced())
                    if let device = review.deviceFingerprint {
                        LabeledContent("This device", value: device)
                            .font(.body.monospaced())
                    }
                    LabeledContent("Signalling", value: review.signallingHost)
                    LabeledContent("Code expires") { Text(review.expiresAt, style: .relative) }
                }
                Text("Approving sends a signed request. You must also confirm on the host's terminal. The host grants chat and Hub access for this device only; security and registration settings are excluded.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                switch model.phase {
                case .review:
                    HStack {
                        Button("Reject", role: .cancel) { model.reject() }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("peer.reject")
                        Spacer()
                        Button("Approve") { model.approve() }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("peer.approve")
                    }
                case .connecting:
                    ProgressView("Waiting for approval on the host terminal…")
                    Button("Cancel", role: .cancel) { model.cancelConnecting() }
                        .buttonStyle(.bordered)
                case .failed(let message):
                    Text(message)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("peer.error")
                    Button("Done") { model.dismiss() }
                        .buttonStyle(.borderedProminent)
                default:
                    EmptyView()
                }
            }
            .padding(24)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("peer.approval")
    }
}

/// Native Hub over WebRTCHubTransport + upstream chat in the existing
/// BrowserView, loaded from the owned localhost bridge with its own store.
struct PeerWorkspaceView: View {
    @ObservedObject var model: PeerConnectionModel
    let connection: PeerActiveConnection
    @State private var loading = false
    @State private var canGoBack = false
    @State private var loadError: String?
    @State private var loginRequired = false
    @State private var reloadCount = 0
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { model.showHub() } label: { Label("Hub", systemImage: "square.grid.2x2") }
                    .accessibilityIdentifier("hub.open")
                Spacer()
                Button { model.showChat() } label: { Label("Chat", systemImage: "bubble.left.and.bubble.right") }
                    .disabled(model.chatRootURL == nil)
                    .accessibilityIdentifier("hub.chat")
                Spacer()
                Button("Disconnect", systemImage: "xmark.circle") { model.disconnect() }
                    .accessibilityIdentifier("peer.disconnect")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal)
            .frame(minHeight: 44)
            .background(.bar)
            statusBar
            ZStack {
                if let root = model.chatRootURL {
                    BrowserView(url: root, loading: $loading, canGoBack: $canGoBack,
                                loadError: $loadError, loginRequired: $loginRequired,
                                reloadCount: reloadCount, backCount: 0, authenticatedCount: 0,
                                scenePhase: model.showingHub ? .inactive : scenePhase,
                                onLoginRequired: {}, onRevealControls: {},
                                nativeDestination: model.chatDestination,
                                isContentVisible: !model.showingHub,
                                websiteDataStore: connection.dataStore,
                                allowsMediaCapture: false)
                        .opacity(model.showingHub ? 0 : 1)
                        .allowsHitTesting(!model.showingHub)
                        .accessibilityHidden(model.showingHub)
                    if let loadError, !model.showingHub {
                        PeerMessageView(title: "Chat unavailable", symbol: "wifi.exclamationmark", message: loadError) {
                            Button("Retry") { self.loadError = nil; reloadCount += 1 }.buttonStyle(.borderedProminent)
                            Button("Back to Hub") { model.showHub() }.buttonStyle(.bordered)
                        }
                        .background(.regularMaterial)
                    }
                }
                if model.showingHub {
                    HubView(server: connection.hubURL, onOpenChat: { model.openChat($0) }, onSettings: {},
                            onAuthorizationRevoked: { model.disconnect() },
                            transport: connection.hubTransport())
                        .id(connection.id)
                }
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            Text(connection.relayOnly ? "Connected · WebRTC relay" : "Connected · WebRTC")
                .font(.caption.bold())
                .accessibilityIdentifier("peer.connected")
            if let relay = model.capture?.relayLabel {
                Text(relay).font(.caption2.bold()).accessibilityIdentifier("peer.relayLabel")
            }
            Spacer()
            if model.capture != nil {
                Button("Stats") { model.sampleBeforeChat() }
                    .font(.caption)
                    .accessibilityIdentifier("peer.capture.beforeChat")
                Button("Export") { model.exportEvidence() }
                    .font(.caption)
                    .accessibilityIdentifier("peer.diagnostics.export")
                if model.exported {
                    Text("Exported").font(.caption2).accessibilityIdentifier("peer.diagnostics.exported")
                } else if let status = model.captureStatus {
                    Text(status).font(.caption2)
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
        .background(.green.opacity(0.15))
    }
}
