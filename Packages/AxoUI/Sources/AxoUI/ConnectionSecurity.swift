import AxoCore
import AxoWeb
import SwiftUI
#if os(macOS)
import SecurityInterface
#endif

/// What the address bar says about the shown page's connection (#96), as the error pages board
/// draws it: a lock for a secure page, a struck-through lock for one that isn't, and a red "Not
/// Private" chip for a certificate the engine doesn't trust. Each is a button that shows the
/// connection's details.
public enum ConnectionIndicator: Hashable, Sendable {
    case secure
    case notSecure
    case notPrivate

    /// The button's name for VoiceOver.
    var buttonLabel: String {
        switch self {
        case .secure: "Connection Secure"
        case .notSecure: "Connection Not Secure"
        case .notPrivate: "Connection Not Private"
        }
    }

    /// What the address's VoiceOver value starts with, so the state is heard with the address.
    var addressPrefix: String {
        switch self {
        case .secure: ""
        case .notSecure: "Not secure, "
        case .notPrivate: "Not private, "
        }
    }
}

extension BrowserModel {
    /// The shown page's connection security: its live page's, or for a tab that hasn't loaded,
    /// what its address says (plain http isn't secure; nothing else is known yet).
    public var shownPageSecurity: PageSecurity {
        if let page = selectedPage { return page.security }
        return Self.unloadedSecurity(of: shownTab?.url)
    }

    /// What a tab that hasn't loaded can say from its address alone: plain http (not this Mac)
    /// isn't secure; nothing else is known until its page reports.
    static func unloadedSecurity(of url: URL?) -> PageSecurity {
        PageSecurity(level: AddressDisplay.shown(for: url)?.kind == .notSecure ? .notSecure : .none)
    }

    /// What the address bar shows for the shown page's connection; nil for pages with nothing to
    /// say (not on the web, or this Mac).
    public var connectionIndicator: ConnectionIndicator? {
        let security = shownPageSecurity
        switch security.level {
        case .secure: return .secure
        case .notSecure: return .notSecure
        // A page that's broken only for running http content isn't secure; "Not Private" is for a
        // certificate that isn't trusted.
        case .broken: return security.hasCertificateError ? .notPrivate : .notSecure
        case .none: return nil
        }
    }

    /// Opens macOS's own certificate view for the shown page's certificates.
    public func showShownPageCertificates() {
        let certificates = shownPageSecurity.certificates
        guard !certificates.isEmpty else { return }
        isShowingConnectionInfo = false
        showCertificates(certificates)
    }
}

/// The lock (or chip) at the address's leading end; a click shows the connection's details.
struct ConnectionButton: View {
    let model: BrowserModel
    let indicator: ConnectionIndicator

    var body: some View {
        Button {
            model.isShowingConnectionInfo.toggle()
        } label: {
            switch indicator {
            case .secure:
                Image(systemName: "lock.fill")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
            case .notSecure:
                Image(systemName: "lock.slash")
                    .foregroundStyle(.secondary)
            case .notPrivate:
                Label("Not Private", systemImage: "exclamationmark.triangle.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.leading, 5)
                    .padding(.trailing, 7)
                    .frame(height: 20)
                    .background(Color(red: 0.898, green: 0.282, blue: 0.302), in: .rect(cornerRadius: 6))
            }
        }
        .buttonStyle(.borderless)
        .help(indicator.buttonLabel)
        .accessibilityLabel(indicator.buttonLabel)
        .accessibilityIdentifier("connectionButton")
        .popover(isPresented: Binding(get: { model.isShowingConnectionInfo }, set: { model.isShowingConnectionInfo = $0 }),
                 arrowEdge: .bottom) {
            let info = ConnectionInfoView(model: model, indicator: indicator, security: model.shownPageSecurity,
                                          url: model.shownPageURL)
            #if os(macOS)
            // The window's appearance, not the sidebar theme's.
            info.windowAppearance()
            #else
            info
            #endif
        }
    }
}

/// The connection's details: what it means, plainly, who the certificate was issued to and by,
/// Show Certificate, and Site Settings.
struct ConnectionInfoView: View {
    let model: BrowserModel
    let indicator: ConnectionIndicator
    let security: PageSecurity
    /// The page's address: its host named as the address bar names it.
    let url: URL?

    private var host: String {
        AddressDisplay.shown(for: url)?.text ?? "This site"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: indicator == .secure ? "lock.fill" : "exclamationmark.triangle")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(indicator == .secure ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                    .font(.system(size: 16))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(Self.title(for: indicator))
                        .font(.system(size: 13, weight: .bold))
                        .accessibilityAddTraits(.isHeader)
                    Text(Self.message(for: indicator, host: host, isHTTPS: url?.scheme?.lowercased() == "https"))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let issued = Self.issued(security.certificates) {
                        Text(issued)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            #if os(macOS)
            if !security.certificates.isEmpty {
                Button("Show Certificate…") { model.showShownPageCertificates() }
                    .padding(.top, 10)
                    .padding(.leading, 26)
                    .accessibilityIdentifier("showCertificateButton")
            }
            #endif
            if model.siteSettingsOrigin != nil {
                Divider().padding(.top, 12).padding(.bottom, 8)
                Button {
                    model.isShowingConnectionInfo = false
                    Task { await model.showSiteSettings() }
                } label: {
                    HStack {
                        Text("Site Settings…")
                        Spacer()
                        Text("Camera, location, pop-ups")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .font(.system(size: 13))
        .padding(14)
        .frame(width: 320, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("connectionInfo")
    }

    static func title(for indicator: ConnectionIndicator) -> String {
        switch indicator {
        case .secure: "Your connection to this site is secure"
        case .notSecure: "Your connection to this site isn’t secure"
        case .notPrivate: "Your connection to this site isn’t private"
        }
    }

    /// Plain and direct, as the board words it.
    static func message(for indicator: ConnectionIndicator, host: String, isHTTPS: Bool) -> String {
        switch indicator {
        case .secure:
            "\(host) has a valid certificate, so what you send it is encrypted on the way."
        case .notSecure where isHTTPS:
            "\(host) uses content loaded over plain http, which others on the network can see and change."
        case .notSecure:
            "\(host) uses plain http. Others on the network can see and change what you send it, so don’t enter passwords or card numbers here."
        case .notPrivate:
            "\(host)’s certificate isn’t trusted, so someone may be pretending to be this site. Don’t enter passwords or card numbers here."
        }
    }

    /// "Issued to example.com by Example CA", from the site's certificate and the one after it.
    static func issued(_ certificates: [SecCertificate]) -> String? {
        guard let site = certificates.first, let subject = SecCertificateCopySubjectSummary(site) as String? else { return nil }
        if certificates.count > 1, let issuer = SecCertificateCopySubjectSummary(certificates[1]) as String? {
            return "Issued to \(subject) by \(issuer)"
        }
        return "Issued to \(subject)"
    }
}

/// Shows certificates in macOS's own certificate view (SecurityInterface's `SFCertificatePanel`).
enum CertificateViewer {
    #if os(macOS)
    @MainActor private static var current: SFCertificatePanel?
    #endif

    /// On the browser window (the main window; the closing popover may still be key), once the
    /// popover has gone. Never modal, which would hold the run loop the engine shares.
    @MainActor
    static func show(_ certificates: [SecCertificate]) {
        #if os(macOS)
        Task { @MainActor in
            await Task.yield()
            guard let window = NSApp.mainWindow else { return }
            // Kept while its sheet shows; the next one replaces it.
            let panel = SFCertificatePanel()
            current = panel
            panel.beginSheet(for: window, modalDelegate: nil, didEnd: nil, contextInfo: nil,
                             certificates: certificates, showGroup: certificates.count > 1)
        }
        #endif
    }
}
