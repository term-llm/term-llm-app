import Foundation

public enum DiagnosticLevel: String, Sendable, Equatable {
    case ok
    case info
    case warning
    case failed
}

public struct DiagnosticCheck: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let level: DiagnosticLevel
    public let detail: String

    public init(id: String, title: String, level: DiagnosticLevel, detail: String) {
        self.id = id
        self.title = title
        self.level = level
        self.detail = detail
    }
}

public struct DiagnosticsReport: Equatable, Sendable {
    public var generatedAt: Date
    public var checks: [DiagnosticCheck]

    public init(generatedAt: Date = Date(), checks: [DiagnosticCheck]) {
        self.generatedAt = generatedAt
        self.checks = checks
    }

    public var hasFailure: Bool { checks.contains { $0.level == .failed } }

    /// Copyable text for a bug report. Values are redacted before display; the
    /// report never includes the service token.
    public func redactedText(appVersion: String, home: URL) -> String {
        var lines = [
            "term-llm macOS companion diagnostics",
            "app: \(appVersion)",
            "generated: \(ISO8601DateFormatter().string(from: generatedAt))",
            "",
        ]
        for check in checks {
            lines.append("[\(check.level.rawValue.uppercased())] \(check.title): \(DiagnosticsReport.redact(check.detail, home: home))")
        }
        return lines.joined(separator: "\n")
    }

    static func redact(_ text: String, home: URL) -> String {
        var value = text
        if !home.path.isEmpty, home.path != "/" {
            value = value.replacingOccurrences(of: home.path, with: "~")
        }
        value = value.replacingOccurrences(of: #"(?i)(token\s*[:=]\s*)\S+"#,
                                           with: "$1<redacted>",
                                           options: .regularExpression)
        value = value.replacingOccurrences(of: #"term_llm_token=[^;\s]+"#,
                                           with: "term_llm_token=<redacted>",
                                           options: .regularExpression)
        value = value.replacingOccurrences(of: #"\btok_[A-Za-z0-9_-]{12,}\b"#,
                                           with: "<redacted>",
                                           options: .regularExpression)
        return value
    }
}

public enum CompanionDiagnostics {
    /// Builds the diagnostics shown in the app and copied into reports. Inputs
    /// are observed state rather than independently re-queried, so the panel
    /// matches what the user sees in the menu bar.
    public static func build(appVersion: String,
                             payloadPresent: Bool,
                             selection: CLISelection?,
                             selectionError: String?,
                             problems: [CLIProblem],
                             pathLink: PATHLinkStatus?,
                             status: ServiceStatus?,
                             endpoint: ManagedLoopbackEndpoint?,
                             tokenAvailable: Bool,
                             loginItemEnabled: Bool,
                             managedMarkerPresent: Bool,
                             payloadChecksumPresent: Bool) -> DiagnosticsReport {
        var checks: [DiagnosticCheck] = []
        checks.append(DiagnosticCheck(id: "app", title: "Companion app",
                                      level: .ok, detail: "Running \(appVersion) natively on macOS."))
        checks.append(DiagnosticCheck(id: "payload", title: "Bundled CLI payload",
                                      level: payloadPresent ? .ok : .warning,
                                      detail: payloadPresent
                                        ? "The app bundle contains a term-llm payload."
                                        : "No CLI payload is bundled in this build; select an existing installation instead."))

        if let selectionError {
            checks.append(DiagnosticCheck(id: "cli", title: "CLI selection",
                                          level: .failed, detail: selectionError))
        } else if let selection {
            let integrity = problems.isEmpty ? "integrity verified" : problems.map(\.description).joined(separator: " ")
            checks.append(DiagnosticCheck(id: "cli", title: "term-llm CLI",
                                          level: problems.isEmpty ? .ok : .failed,
                                          detail: "\(selection.source.rawValue) \(selection.version.isEmpty ? "(version unknown)" : selection.version) at \(selection.binaryPath) — \(integrity)"))
        } else {
            checks.append(DiagnosticCheck(id: "cli", title: "term-llm CLI",
                                          level: .warning,
                                          detail: "No CLI selected yet. Install the bundled CLI or use an existing installation."))
        }

        if payloadPresent {
            checks.append(DiagnosticCheck(id: "payload-checksum", title: "Payload provenance",
                                          level: payloadChecksumPresent ? .ok : .warning,
                                          detail: payloadChecksumPresent
                                            ? "The bundled payload carries a SHA-256 sidecar and is verified before installation."
                                            : "No SHA-256 sidecar was found for this development payload; installation cannot verify provenance."))
        }

        if let selection, selection.source == .bundled {
            checks.append(DiagnosticCheck(id: "ownership", title: "Upgrade ownership",
                                          level: managedMarkerPresent ? .ok : .warning,
                                          detail: managedMarkerPresent
                                            ? "Managed-install marker present; term-llm self-upgrade refuses to replace this verified payload."
                                            : "The managed-install marker is missing; the app recreates it on launch and while running. Until then `term-llm upgrade` could replace the app-managed binary."))
        }

        if let pathLink {
            switch pathLink {
            case .linked(let path):
                checks.append(DiagnosticCheck(id: "path", title: "Terminal command",
                                              level: .ok, detail: "Linked \(path) to the managed CLI."))
            case .alreadyLinked(let path):
                checks.append(DiagnosticCheck(id: "path", title: "Terminal command",
                                              level: .ok, detail: "\(path) already points at the managed CLI."))
            case .notLinked(let path):
                checks.append(DiagnosticCheck(id: "path", title: "Terminal command",
                                              level: .info,
                                              detail: "\(path) is not linked yet. The managed binary is still usable by absolute path; installing the bundled CLI creates the link."))
            case .skippedExternal:
                checks.append(DiagnosticCheck(id: "path", title: "Terminal command",
                                              level: .info, detail: "Using the external installation's own command."))
            case .collision(let path):
                checks.append(DiagnosticCheck(id: "path", title: "Terminal command",
                                              level: .warning,
                                              detail: "\(path) belongs to something else and was not changed. Run the managed binary directly or resolve the collision."))
            case .failed(let reason):
                checks.append(DiagnosticCheck(id: "path", title: "Terminal command",
                                              level: .warning, detail: "Could not link the command: \(reason)"))
            }
        }

        if let status {
            let serviceLevel: DiagnosticLevel
            switch status.state {
            case .ready: serviceLevel = .ok
            case .stopped, .notInstalled, .notRegistered: serviceLevel = .warning
            case .unmanaged, .error, .unhealthy: serviceLevel = .failed
            }
            var detail = "state=\(status.state.rawValue) running=\(status.running) autostart=\(status.autostart)"
            if let pid = status.pid { detail += " pid=\(pid)" }
            if let auth = status.auth { detail += " auth=\(auth)" }
            detail += " enrollment=\(status.enrollment.rawValue)"
            if let healthError = status.healthError, !healthError.isEmpty { detail += " health: \(healthError)" }
            if let error = status.error, !error.isEmpty { detail += " error: \(error)" }
            checks.append(DiagnosticCheck(id: "service", title: "Local web service",
                                          level: serviceLevel, detail: detail))
            if let binary = status.binary {
                checks.append(DiagnosticCheck(id: "service-binary", title: "Service executable",
                                              level: .info, detail: binary))
            }
            if let specPath = status.specPath {
                checks.append(DiagnosticCheck(id: "service-spec", title: "Owned service spec",
                                              level: .info, detail: specPath))
            }
        } else {
            checks.append(DiagnosticCheck(id: "service", title: "Local web service",
                                          level: .warning, detail: "No service status was available."))
        }

        if let endpoint {
            checks.append(DiagnosticCheck(id: "endpoint", title: "Managed loopback trust",
                                          level: .ok,
                                          detail: "Plain HTTP is allowed only for the owned service at \(endpoint.baseURL.absoluteString); all other connections keep normal HTTPS validation."))
        } else {
            checks.append(DiagnosticCheck(id: "endpoint", title: "Managed loopback trust",
                                          level: .info,
                                          detail: "No owned loopback endpoint is available yet."))
        }

        checks.append(DiagnosticCheck(id: "token", title: "Local authentication",
                                      level: tokenAvailable ? .ok : .warning,
                                      detail: tokenAvailable
                                        ? "Bearer credential read from the core's managed store; held in memory and injected only into the embedded chat."
                                        : "The local credential could not be read. Open the chat again after the service is ready."))
        checks.append(DiagnosticCheck(id: "login-item", title: "Open app at login",
                                      level: loginItemEnabled ? .ok : .info,
                                      detail: loginItemEnabled
                                        ? "Owned launch agent \(AppLoginItem.label) is installed."
                                        : "The app will not open automatically at login."))
        return DiagnosticsReport(checks: checks)
    }
}
