import AxoCore
import AxoWeb
import SwiftUI

/// What a tab's page plays and uses (#71, #74): sound, with a speaker that mutes it, and the
/// camera, microphone, screen, or location in use, as an orange dot, as macOS shows them. Rows
/// read it through the pool's per-tab liveness, so a row redraws only when its own tab changes.
extension BrowserModel {
    /// The sound and devices of the tab's page; nothing for a tab without a live page.
    public func tabMedia(_ id: AxoCore.Tab.ID) -> PageMedia {
        pool.liveness(for: id).state?.media ?? PageMedia()
    }

    /// The tabs a tab's Mute Tab acts on: its split's panes, as its row's speaker does, or the
    /// tab (a favorite too).
    public func muteTargets(for id: AxoCore.Tab.ID) -> [AxoCore.Tab.ID] {
        split(of: id).map { panes(of: $0.id).map(\.id) } ?? [id]
    }

    /// The sound and devices of the page showing (a favorite's too) and its split's other
    /// panes: the Tabs menu's Mute Tab, which acts as the shown row's speaker does.
    public var shownTabMedia: PageMedia {
        shownTab.map { tabMedia(muteTargets(for: $0.id)) } ?? PageMedia()
    }

    /// The sound and devices of several tabs (a split's panes) as one: playing if any plays,
    /// muted only if none plays unmuted, and every device any of them uses.
    public func tabMedia(_ ids: [AxoCore.Tab.ID]) -> PageMedia {
        PageMedia.combined(ids.map(tabMedia))
    }

    /// Mutes or unmutes tabs' sound, for as long as they're open, and tells VoiceOver.
    public func setMuted(_ muted: Bool, tabIDs: [AxoCore.Tab.ID]) {
        guard !tabIDs.isEmpty else { return }
        tabIDs.forEach { pool.setMuted(muted, tabID: $0) }
        announce(muted ? "Muted" : "Unmuted")
    }

    /// Mutes the tabs' sound if any plays unmuted, and otherwise unmutes them: the speaker's and
    /// the menus' Mute Tab and Unmute Tab. For a split, only its panes with sound.
    public func toggleMuted(_ ids: [AxoCore.Tab.ID]) {
        let media = ids.map { ($0, tabMedia($0)) }.filter { $0.1.hasSound }
        let mute = !PageMedia.combined(media.map(\.1)).isMuted
        setMuted(mute, tabIDs: media.map(\.0))
    }
}

extension PageMedia {
    /// Whether a row shows its speaker: it plays sound, or is muted (so it can be unmuted).
    public var hasSound: Bool { isPlayingAudio || isMuted }

    /// Several pages' sound and devices as one row shows them.
    static func combined(_ media: [PageMedia]) -> PageMedia {
        let sounding = media.filter(\.hasSound)
        return PageMedia(
            isPlayingAudio: sounding.contains(where: \.isPlayingAudio),
            isMuted: !sounding.isEmpty && !sounding.contains { $0.isPlayingAudio && !$0.isMuted },
            capture: media.reduce(into: []) { $0.formUnion($1.capture) }
        )
    }

    /// The speaker's action: "Mute Tab" or "Unmute Tab".
    var muteTitle: String { isMuted ? "Unmute Tab" : "Mute Tab" }

    /// For VoiceOver and the dot's tooltip: "Using the camera and microphone", "Sharing the
    /// screen", "Using your location", and so on; nil when it uses none.
    var captureDescription: String? {
        var devices: [String] = []
        if capture.contains(.camera) { devices.append("the camera") }
        if capture.contains(.microphone) { devices.append("the microphone") }
        if capture.contains(.location) { devices.append("your location") }
        let using = devices.isEmpty ? nil : "Using " + devices.formatted(.list(type: .and))
        let sharing = capture.contains(.screen) ? "Sharing the screen" : nil
        let parts = [using, sharing].compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// The row's sound and devices for VoiceOver: "Playing audio" or "Muted", then what it uses.
    var stateDescription: [String] {
        [isMuted ? "Muted" : (isPlayingAudio ? "Playing audio" : nil), captureDescription].compactMap(\.self)
    }
}

/// A row's speaker, which mutes and unmutes the tab, as the Tab row states board draws it.
struct TabMuteButton: View {
    let media: PageMedia
    let toggle: () -> Void

    var body: some View {
        // A borderless button in a List row gets its click without selecting the row first.
        Button(action: toggle) {
            Image(systemName: media.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 12))
                .frame(width: 20, height: 20)
                .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.primary)
        .help(media.muteTitle)
        .accessibilityLabel(media.muteTitle)
        .accessibilityIdentifier("tabMuteButton")
    }
}

/// The orange dot for a tab using the camera, microphone, screen, or location, as macOS shows
/// them in the menu bar. The row's accessibility value says what it uses.
struct TabCaptureDot: View {
    let media: PageMedia

    /// The board's orange, darker than the system's so it reads on light sidebars.
    static let color = Color(red: 0xC2 / 255, green: 0x5E / 255, blue: 0)

    var body: some View {
        Circle()
            .fill(Self.color)
            .frame(width: 8, height: 8)
            .frame(width: 20, height: 20)
            .help(media.captureDescription ?? "")
            .accessibilityHidden(true)
    }
}
