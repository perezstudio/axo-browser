# Axo: Interface 1.0 plan

This plan brings the app in line with the design canvas made in November 2026 (the "Axo" design canvas artifact, private to the project owner). The canvas has one board per area, each with a note describing how it behaves; this document turns those boards into work, in order, mapped to GitHub issues.

`docs/PLAN.md` stays the project plan. This document is the plan for one slice of it: the interface for 1.0, on the Mac first and then on iPhone and iPad (Milestone 7). Departures from either still need approval first (see `CLAUDE.md`, "Hard rules").

## How to use this plan

- Work goes in the order of the phases below. Inside a phase, items can go in any order unless one says it needs another.
- Each item is one pull request, as with the UI issues so far. An item names its board, its issue, and what done means.
- Each PR follows `CLAUDE.md`: tests in the same change (UI tests for flows, run remotely with `scripts/run-ui-tests-remotely.sh`), docs kept current, new screens added to `AccessibilityAuditTests`, and a red-team review once CI passes.
- When the app and a board disagree, the board's note is the spec, but the app's constraints win: a board that can't be built as drawn gets a change to the board first, agreed with the owner, rather than a silent difference.
- Check an item off here, and in `docs/PLAN.md` where it maps to a milestone item, in the PR that finishes it.

## What the boards agree on

These hold across every board, and new work should follow them even where a board doesn't show the case.

- **The page is only the page.** Controls live in the sidebar, or, with the navigation bar above the page, in a control bar inside the page's area, on the page's layer. Nothing spans the sidebar's top edge: the sidebar keeps the Space's theme from top to bottom, and the toolbar tint (#107) colors only the control bar over the page.
- **Layered page (#67).** The page runs edge to edge and meets the sidebar along one straight edge with a shadow. Back and forward share a glass capsule; reload is its own glass circle.
- **Accents.** In-app accents use the Space's color. Raspberry, Blush, and Axolotl Pink are for branding only (first run's welcome, the app icon, marketing). Default buttons in system alerts and panels use the person's system accent color.
- **Icons.** The boards draw stand-ins for SF Symbols: a 24-point grid, a light stroke, rounded ends, and a soft fill on the main closed shape. In the app that is SF Symbols with hierarchical rendering at the matching weight; draw custom symbols only where no SF Symbol fits, in the same style.
- **Motion.** Rows, sheets, popovers, and menus move with short, purposeful animations (the Sidebar interactions board shows the timings), respect Reduce Motion, and never move the page itself except to give or take width.
- **Voice.** Warm in empty and status states, plain and direct in errors, privacy, and permissions. The Axo character appears only in empty and status states (a surprised Axo on Can't Connect), never in security warnings, prompts, or Settings.
- **Defaults that protect.** Every question that grants access (files, external apps, certificates, dangerous sites, permissions) has Cancel or Go Back as its default button, so Return never grants.
- **Native first.** Chrome's own Views UI never shows; where Chromium would show a dialog, Axo draws its own (see `docs/chromium-engine.md`). Apple's system UI (Screen Time, passkeys, Spotlight, share sheets) stays Apple's.

## Decisions

Decided on November 14, 2026. The phases below follow them.

1. **Favorites sync through iCloud**, with profiles, Spaces (themes included once #137 lands), folders, and pinned tabs. AxoSync already syncs them (migration `v14-favorites`); what's left is saying so: the iCloud pane's switch still reads "Sync Spaces, folders, and pinned tabs". Search engines stay with #132. The Settings board's iCloud row, which also lists search engines, changes to match.
2. **A Space arriving through sync gets no notice.** It appears in the sidebar (its dot pops in) and VoiceOver announces it, as with other changes the person didn't make in Axo. The Sync board's notice comes out. The Focus filter's notice (Apple integrations board) wasn't part of this decision; until it is, it follows the same rule: announced, no notice.
3. **Extensions on iPhone and iPad install the way Safari's do**: web extensions the person gets from the App Store, which Axo loads through `WKWebExtension`. Axo has no store or file install of its own on iOS, so the iOS Settings board's Install from Files… comes out. First step of that item: confirm that a third-party browser can find and load App Store–installed Safari web extensions with `WKWebExtension` on iOS 27; if it can't, say so here and in `docs/webkit-gaps.md` before building the rest.
4. **Sparkle is approved, for the Mac only** (MIT, listed in `CLAUDE.md`'s dependencies). The iOS app updates through the App Store and never links it. The Updates board's custom user driver (Axo's own error wording and the update-ready notice) is part of the work.
5. **The boards' proposals are accepted**: the update-ready notice and Restart to Update Axo menu item; picture in picture's View menu item, page menu item, and tab-row mark; the iPhone's Address bar setting (bottom or top); Downloads at the end of the top tab bar; and Include beta versions in Settings. Reader, which only appears as an item in the iPhone menu, gets its own design before it's built.
6. **Google is the default search engine**, with Bing and DuckDuckGo as the alternatives. It replaces the DuckDuckGo placeholder in `AddressInput`, and the Search pane (#132) offers the three.

## Phase 1: the window

The boards: Axo today, Proposed 1.0 window, Tab row states, Space themes (in Axo today).

- [x] **Space themes (#137).** PR #169: a color or gradient, translucency, and grain behind the sidebar, edited from the Space's Theme… popover and Settings › Spaces.
- [ ] **Layered page (#67).** The page as a layer beside the sidebar along one straight edge with a shadow, the back and forward capsule, and the reload circle. Done: the window matches the board in light and dark, with the sidebar shown and hidden, and the page's own loading bar and hovered-link label still sit on the page.
- [ ] **Navigation bar above the page, inside the page's area (#170).** Today the toolbar spans the window and its tint covers the strip above the sidebar (#107). Change it so the control bar sits inside the page's area and the sidebar keeps its theme to the top (the Mac board's "Address bar above the page"). Done: `testNavigationBarPlacement` and `testToolbarTakesThePagesThemeColor` updated, and the tint reaches only the control bar.
- [ ] **Top tab bar (#136).** The "Tabs on top" layout: favorites with the Space's name, Pinned, folders, today's tabs, New Tab, with the control bar inside the page under it; hiding the tab bar keeps the control bar. Needs the item above.
- [ ] **Space name row (#171).** The Space's name between the favorites and Pinned, styled like a tab row, as on the window board.
- [ ] **Tab rows.** One PR per issue, each matching the Tab row states board (close on hover, the loading spinner, and dimmed tabs are built, from PR #158): audio and mute (#71), a pinned tab away from its page (#73), camera, microphone, screen, and location in use (#74), crashed and unresponsive pages (#75, shared with Phase 6), hover preview card (#76), and the rest of #82.
- [ ] **Notices.** Check `NoticeView` against the boards (capsule at the page column's bottom, Undo, held while hovered); adjust spacing and motion to match. Small; no issue needed unless it changes behavior.

## Phase 2: sidebar interactions

The board: Sidebar interactions. Each demo is a behavior to build, with the board's timings.

- [ ] **Drag to reorder, into folders, and to Pinned (#77).** The lifted row, rows sliding out of the way, a closed folder highlighting and springing open, the Pinned section's outline.
- [ ] **Drag to another Space (#78).** The dot grows and names the Space, the tab shrinks into it, and a notice says where it went, with Undo. The rest of #78 (into a split, a new window, another app) can follow.
- [ ] **Close and Undo.** The row slides away and the gap closes; the notice's Undo brings it back to the same place. Mostly built; match the motion.
- [ ] **Swiping between Spaces.** Built (`SidebarSwipeState`); check the theme blend and the springs against the board once themes land.
- [ ] **Select several tabs (#79), rename (#80), more context menu actions (#81), Undo and Redo for organization changes (#118).** Not drawn on a board beyond the context menu; build to the existing issues.

## Phase 3: command bar and address

The boards: Floating command bar, Proposed 1.0 window.

- [ ] **Narrow results while typing (#122), ranking (#121), menu commands (#123).** In the order set earlier (#122, #121, #123).
- [ ] **Command bar as a native floating panel (#87).** The board's floating bar, in browser and mini windows.
- [ ] **History menus on Back and Forward (#112).**
- [ ] **Google as the default search engine (#172).** Replace the DuckDuckGo placeholder in `AddressInput` with Google, keeping Bing and DuckDuckGo for the Search pane (#132) to offer (decision 6). Small; can go any time.

## Phase 4: page tools, menus, and prompts

The boards: Page tools, Page context menu, Prompts and extensions toolbar, Split view and Peek, Extension side panels, DevTools.

- [ ] **Site Settings as one panel for the current site (#110).** From the address pill, or the top of the page when the pill isn't on screen.
- [ ] **Page context menu (#173).** Built on Chromium (`PageMenu.entries`); check its items and order against the board for page, link, image, selected text, and text field, and add what's missing (Open in Peek and in Split View for links, Summarize Page).
- [ ] **Prompts.** Built; check permission prompts, JavaScript dialogs, external-app questions, and extension prompts against the board's layout and wording.
- [ ] **Split view and Peek, side panels, DevTools.** Built; check each against its board (Peek's card, the split's focused pane and resize handle, the side panel's header and divider, DevTools docked in the page's area, which follows from the layered page). Fix differences in one PR per board.
- [ ] **Connection security and certificate details (#96).** The pill's Not Secure mark and the certificate details; shared with Phase 6's warnings.

## Phase 5: Settings and the Extensions window

The boards: Settings, Extensions window, iCloud sync.

- [ ] **Settings in a sidebar layout like System Settings (#85).** The board's panes, order, and sections: General, Profiles, Spaces, Search, Link Routing, Site Customizations, iCloud.
- [ ] **Website Permissions pane (#133).** Each permission's default and the sites that asked, per profile.
- [ ] **Search (#132).** Engines, keywords, and a default per profile: Google by default, with Bing and DuckDuckGo offered (decision 6).
- [ ] **Extensions window per profile (#131).** The board's list and details: the state in a word, attention dots, Pin to toolbar, shortcuts with clashes struck through, site access (#54), user scripts, Developer mode, About, and Remove….
- [ ] **Asking before an update adds permissions (#130).** The board's Review… sheet with Keep It Off and Allow.
- [ ] **iCloud pane states (#174).** Off, Setting Up, Up to Date, Paused (signed out, storage full), and Couldn't Sync, with what syncs (profiles, Spaces, folders, pinned tabs, and favorites, which already sync; the switch's wording still leaves favorites out) and what stays on the Mac. A Space that arrives shows in the sidebar with no notice, announced to VoiceOver (decision 2). Waits on Milestone 7's real-device check.

## Phase 6: lists, flows, and states

The boards: Downloads and empty states, History and mini windows, First run, New Space and profile, Import from another browser, Error pages and warnings, Page full screen, File panels, Screen Time limits, Picture in Picture.

- [ ] **Downloads and empty states, History and mini windows.** Check the built lists and mini windows against their boards; build the empty states with the Axo character in the Space's color. One PR per board.
- [ ] **First run (#175).** New: the welcome on Blush, Import (Arc found or nothing to import), Set up a Space, and one persistent glass card whose tint takes the Space's color, with the board's animations. No profile step; people start in Default.
- [ ] **New Space and New Profile (#176).** The + by the Space dots, File › New Space…, and Settings › Profiles, with the theme picker and the New Profile slide-in.
- [ ] **Import later (#177).** From Settings › General or File › Import from Browser…, as a sheet over the open window, with add as new Spaces or merge into a folder. Safari import isn't built (only Arc and Chrome); either build it or drop it from the board.
- [ ] **Error pages (#178).** Can't Connect, Not Secure, certificate warnings, dangerous sites, and Page Stopped (#75, #96). Chromium shows its own error pages today; Axo's replace them through the engine. #75 and #96 cover the rest.
- [ ] **Page full screen.** Built; match the hint and the exit behavior on the board.
- [ ] **File panels.** Built (#48); check the questions' wording and icons against the board.
- [ ] **Screen Time (#179).** Built; add the proposed blocked-tab mark on the row and its VoiceOver text.
- [ ] **Picture in picture started by Axo (#83) and on Chromium (#46).** The menu items, the tab-row mark, and a native window for it, as accepted in decision 5.

## Phase 7: system integration and updates

The boards: Apple integrations, Software updates.

- [ ] **Apple integrations.** Handoff, Spotlight, App Intents, and Focus filters are built (Milestone 6); keep the Focus switch to an announcement with no notice (decision 2), and check Handoff opening in the Space you're in. Passkeys stay blocked on Apple's entitlement (Milestone 4).
- [ ] **Software updates (#180).** Sparkle's flow, Settings › General › Software Update, and the update-ready notice. Sparkle is approved for the Mac only (decision 4), with a custom user driver for Axo's wording; waits on packaging (#61).

## Phase 8: consistency pass on the canvas

Before iOS starts, bring the older boards in line with what was decided later, so the canvas tells one story: the shared icon set on every board, one list of what syncs (decision 1, with favorites), no notice for a synced Space on the Sync board and none for the Focus switch on the Apple integrations board (decision 2), extensions on iOS installed the Safari way everywhere and Install from Files… removed (decision 3), Google as the default engine wherever a board shows one (decision 6), and the Mac window board's notes matching what Phases 1 to 7 built. This is canvas work, not app work, and can start now.

## Phase 9: iPhone and iPad (Milestone 7)

The boards: iPhone and iPad, iOS first run, Settings, and sharing. Builds on the first iOS slice (`AxoiOS`, `MobileBrowserView`).

- [ ] **iPhone bar and menu (#181).** The bottom bar (••• menu, the address with the Space's dots, the tabs button), and the menu growing from the button with Back, Forward, Reload, and Share nearest the thumb.
- [ ] **iPhone motion (#182).** The command bar rising with the keyboard, the page zooming into its card in the tabs view, swiping the bar between Spaces with the themes blending, the bar shrinking on scroll, closing and opening tab cards, and the loading line.
- [ ] **iPad window (#183).** The Mac window's three layouts, sized for touch: the sidebar, controls above inside the page's area, and tabs on top; the sidebar and tab bar sliding in and out, the floating sidebar from the left edge, and the ≡ More menu with Downloads, History, Archive, Extensions, Import, and Settings.
- [ ] **iOS first run (#184).** Welcome, Spaces from iCloud or Set up your first Space, Open links in Axo (iOS's own Default Browser App setting), and Done.
- [ ] **iOS Settings (#185).** The Mac's panes and look: a pushed list on iPhone, a sheet with the Mac's sidebar on iPad, laid out the iOS way where the Mac's rows don't fit, and the Mac's theme picker (a sheet on iPhone, a popover on iPad).
- [ ] **Sharing (#186).** Axo's items first in iOS's share sheet, and a share extension that adds a link to a Space (a new target).
- [ ] **Extensions on iOS (#187).** Installed the way Safari's are, from the App Store, and loaded through `WKWebExtension` (decision 3): in the iPhone's menu and where the Mac shows them on iPad, managed in Settings per profile. Starts by confirming a third-party browser can load them on iOS 27.

## Issues

Every item above has an issue. The ones filed for this plan on November 14, 2026 are #170 to #187; existing issues were updated the same day to match the boards and the decisions, and #69, #70, and #72 were closed as done in #158.
