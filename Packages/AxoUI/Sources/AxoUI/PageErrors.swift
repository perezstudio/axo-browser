import AxoCore
import AxoWeb
import SwiftUI

/// Axo's own pages for a load that failed and for warnings (#178), over the engine's, as the
/// error pages board draws them: Can't Connect with a surprised Axo (the only one with the
/// character), and plain warnings for certificates and dangerous sites, where Go Back is the
/// default (Return never goes on) and visiting anyway is a deliberate second step.
extension BrowserModel {
    /// Why the tab's last load failed, while its error page shows.
    public func tabLoadError(_ id: AxoCore.Tab.ID) -> PageLoadError? {
        pool.liveness(for: id).state?.loadError
    }

    /// The warning the tab's page shows, if any.
    public func tabWarning(_ id: AxoCore.Tab.ID) -> PageWarning? {
        pool.liveness(for: id).state?.warning
    }

    /// Tries the failed load again, the engine's way (Chromium reloads its error page's entry,
    /// which repeats the original request): Try Again.
    public func retryLoad(_ id: AxoCore.Tab.ID) {
        guard tabLoadError(id) != nil else { return }
        pool.livePage(for: id)?.retryFailedLoad()
    }

    /// Tells VoiceOver when a page on screen is replaced by Axo's error page or warning, and takes
    /// keyboard focus off the engine's page under it, which would otherwise still take keys
    /// (Chrome's warning page has its own way on, typed blind) and Return.
    func pageErrorChanged(_ tabID: AxoCore.Tab.ID) {
        let title = tabWarning(tabID)?.title ?? tabLoadError(tabID)?.title
        guard let title, isOnScreen(tabID) else { return }
        announce(title)
        resignPageFocus(tabID)
    }

    /// Whether there's a page to go back to from a failed load: the history's page before, or
    /// the page that was showing (WebKit keeps it, under another address).
    public func canLeaveLoadError(_ id: AxoCore.Tab.ID) -> Bool {
        guard let state = pool.liveness(for: id).state, let error = state.loadError else { return false }
        return state.canGoBack || (state.url != nil && state.url != error.url)
    }

    /// Leaves a failed load for the page before it: Go Back on the Can't Connect page.
    public func leaveLoadError(_ id: AxoCore.Tab.ID) {
        pool.livePage(for: id)?.leaveLoadError()
    }

    /// Leaves the warning for the page before: Go Back, the default. With nothing before it,
    /// the start page, since Chromium's own answer is its new tab page.
    public func leaveWarning(_ id: AxoCore.Tab.ID) {
        guard tabWarning(id) != nil else { return }
        if pool.state(for: id)?.canGoBack == true {
            pool.livePage(for: id)?.leaveWarning()
        } else {
            pool.load(URL(string: "about:blank")!, in: id)
        }
    }

    /// Goes on to the site despite the warning, once the person confirmed it.
    public func visitDespiteWarning(_ id: AxoCore.Tab.ID) {
        guard tabWarning(id)?.allowsVisiting == true else { return }
        pool.livePage(for: id)?.visitDespiteWarning()
    }
}

extension PageLoadError {
    /// The page's heading, as the board words it.
    var title: String {
        switch kind {
        case .offline: "You’re Not Connected to the Internet"
        case .serverNotFound: "Axo Can’t Find This Site"
        case .timedOut: "This Site Took Too Long to Answer"
        case .cantConnect: "Axo Can’t Connect to This Site"
        case .other: "Axo Can’t Open This Page"
        }
    }

    /// What happened and what to do, plainly.
    func message(host: String) -> String {
        switch kind {
        case .offline:
            "Axo can’t open \(host) because this Mac is offline. Check Wi-Fi or your network cable, then try again."
        case .serverNotFound:
            "There’s no server at \(host). Check the address for typos. If it’s right, the site may be down."
        case .timedOut:
            "\(host) didn’t respond in time. It may be busy or down. Try again in a moment."
        case .cantConnect:
            "\(host) didn’t accept the connection. It may be down, or not running on this address."
        case .other:
            "Something went wrong opening \(host). Try again in a moment."
        }
    }
}

extension PageWarning {
    var title: String {
        switch kind {
        case .certificate: "This Connection Isn’t Private"
        case .deceptiveSite: "Deceptive Website"
        case .harmfulSite: "Harmful Website"
        case .other: "Axo Stopped Before Opening This Page"
        }
    }

    func message(host: String) -> String {
        switch kind {
        case .certificate where code?.contains("DATE_INVALID") == true:
            "\(host)’s certificate has expired, or isn’t valid yet, or this Mac’s clock is wrong. Axo stopped before sending it anything."
        case .certificate:
            "\(host) may be pretending to be another site to steal your passwords or card numbers. Its certificate isn’t trusted. Axo stopped before sending it anything."
        case .deceptiveSite:
            "\(host) tries to trick people into giving away passwords, card numbers, or other personal information. It may look like a site you trust."
        case .harmfulSite:
            "\(host) may try to install software that harms your Mac, steals your information, or shows unwanted ads."
        case .other:
            "Opening \(host) as it is could put what you send it at risk."
        }
    }

    /// What Show Details adds.
    func details(host: String) -> String {
        let code = code.map { " (\($0))" } ?? ""
        switch kind {
        case .certificate:
            return "The certificate \(host) sent isn’t one Axo can trust. That can mean someone is in between you and the site, or the site is set up wrong.\(code)"
        case .deceptiveSite, .harmfulSite:
            return "This address is on Google Safe Browsing’s list of dangerous sites, checked on this Mac.\(code)"
        case .other:
            return "The page couldn’t be opened safely.\(code)"
        }
    }

    /// The label of the second step, after Show Details.
    var visitTitle: String {
        kind == .certificate ? "Visit This Website" : "Visit This Unsafe Website"
    }
}

/// The page's host, as the address bar names it.
private func pageHost(_ url: URL?) -> String {
    AddressDisplay.shown(for: url)?.text ?? "This page"
}

/// Can't Connect: the surprised Axo, the reason, Try Again, and Go Back when there's a page
/// before.
struct PageLoadErrorView: View {
    let error: PageLoadError
    let tint: Color
    let canGoBack: Bool
    let retry: () -> Void
    let goBack: () -> Void
    @State private var showsDetails = false

    var body: some View {
        VStack(spacing: 12) {
            SurprisedAxo(tint: tint)
            Text(error.title)
                .font(.system(size: 24, weight: .bold))
                .multilineTextAlignment(.center)
                .padding(.top, 10)
                .accessibilityAddTraits(.isHeader)
            Text(error.message(host: pageHost(error.url)))
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            HStack(spacing: 8) {
                Button("Try Again", action: retry)
                    .buttonStyle(.glassProminent)
                    .tint(tint)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("pageErrorRetry")
                if canGoBack {
                    Button("Go Back", action: goBack)
                        .buttonStyle(.glass)
                        .accessibilityIdentifier("pageErrorGoBack")
                }
                DetailsToggle(showsDetails: $showsDetails)
            }
            .controlSize(.large)
            .padding(.top, 8)
            if showsDetails {
                Text(error.code)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 40)
        .padding(.bottom, 60)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pageLoadError")
        .onChange(of: error) { showsDetails = false }
    }
}

/// A warning: plain and direct, no character, Go Back as the default; Show Details reveals why,
/// and only then the way on, which asks once more.
struct PageWarningView: View {
    let warning: PageWarning
    let goBack: () -> Void
    let visit: () -> Void
    @State private var showsDetails = false
    @State private var isConfirming = false

    private var host: String { pageHost(warning.url) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: warning.kind == .certificate ? "lock.trianglebadge.exclamationmark" : "exclamationmark.shield")
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 44))
                .foregroundStyle(.red)
                .accessibilityHidden(true)
            Text(warning.title)
                .font(.system(size: 24, weight: .bold))
                .accessibilityAddTraits(.isHeader)
            Text(warning.message(host: host))
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                // The system accent, as default buttons in alerts are: never the way on.
                Button("Go Back", action: goBack)
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("pageWarningGoBack")
                DetailsToggle(showsDetails: $showsDetails)
            }
            .controlSize(.large)
            .padding(.top, 8)
            if showsDetails {
                Text(warning.details(host: host))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if warning.allowsVisiting {
                    Button(warning.visitTitle) { isConfirming = true }
                        #if os(macOS)
                        .buttonStyle(.link)
                        #else
                        .buttonStyle(.plain)
                        #endif
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("pageWarningVisit")
                    Text("Only if you know why this happens.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: 520, alignment: .leading)
        .padding(.horizontal, 40)
        .padding(.bottom, 60)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pageWarning")
        .onChange(of: warning) {
            showsDetails = false
            isConfirming = false
        }
        // Cancel is the default, so Return never goes on.
        .alert("Visit “\(host)” anyway?", isPresented: $isConfirming) {
            Button("Cancel", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
            Button("Visit Website", role: .destructive, action: visit)
        } message: {
            Text(warning.kind == .certificate
                 ? "Its connection isn’t private. Passwords, card numbers, and anything else you send it could be read or changed on the way."
                 : "It’s on a list of dangerous sites. It could steal your information or harm your Mac.")
        }
    }
}

/// Show Details and Hide Details.
private struct DetailsToggle: View {
    @Binding var showsDetails: Bool

    var body: some View {
        Button {
            withAnimation(.snappy) { showsDetails.toggle() }
        } label: {
            Label(showsDetails ? "Hide Details" : "Show Details",
                  systemImage: showsDetails ? "chevron.up" : "chevron.down")
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(.glass)
        .accessibilityIdentifier("pageDetailsToggle")
    }
}
