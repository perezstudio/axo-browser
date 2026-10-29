// AxoEngine's stable API, as Objective-C protocols.
//
// Axo never links AxoEngine: it loads the framework at runtime (it's large, and only machines
// that build Chromium have it), finds the classes by name, and talks to them through these
// protocols. Axo keeps an identical copy of this file (Packages/AxoChromium); the two must
// match, and AXO_ENGINE_API_VERSION says which version a framework implements.
//
// Classes: AXOApplication (an NSApplication subclass), AXOEngine, AXOEngineConfiguration,
// AXOProfile, AXOWindow, AXOPage, AXODownload, AXOExtension, AXOExtensionAction, and
// AXOExtensionPopup, each adopting the protocol of the same name. Every class
// is main-thread only, like AppKit, and completion handlers run on the main thread.
//
// Every protocol is NS_SWIFT_UI_ACTOR, so Swift treats the API as main-actor isolated, which it
// is. Raise AXO_ENGINE_API_VERSION whenever anything in this file changes.

#import <AppKit/AppKit.h>

#define AXO_ENGINE_API_VERSION 22

NS_ASSUME_NONNULL_BEGIN

@protocol AXOPage;
@protocol AXOPageDelegate;
@protocol AXOWindow;
@protocol AXOWindowDelegate;
@protocol AXOExtension;
@protocol AXOExtensionAction;
@protocol AXOExtensionPopup;
@protocol AXOExtensionCommand;
@protocol AXOExtensionPrompt;
@protocol AXOContextMenu;
@protocol AXOContextMenuItem;
@protocol AXOExtensionSidePanel;
@protocol AXOBookmarkNode;
@protocol AXOBookmarkChange;
@protocol AXOHistoryChange;

typedef NS_ENUM(NSInteger, AXOExtensionPromptKind) {
  /// More permissions (`chrome.permissions.request`, or turning on an extension that asked for
  /// more in an update). `details` lists them.
  AXOExtensionPromptKindPermissions,
  /// Installing an extension. `details` lists its permissions.
  AXOExtensionPromptKindInstall,
  /// Removing an extension, maybe at another's request (`requestingExtensionName`).
  AXOExtensionPromptKindUninstall,
  /// Recording the screen: answer Screen or Window (`allowsScreen`, `allowsWindow`), or Cancel.
  AXOExtensionPromptKindScreenCapture,
};

typedef NS_ENUM(NSInteger, AXOExtensionPromptAnswer) {
  AXOExtensionPromptAnswerCancel,
  AXOExtensionPromptAnswerAccept,
  AXOExtensionPromptAnswerScreen,
  AXOExtensionPromptAnswerWindow,
};
@protocol AXODownload;

/// The domain of errors the engine reports.
#define AXOEngineErrorDomain @"AXOEngineErrorDomain"

// MARK: - Engine

/// How to start the engine. Make one with `[[AXOEngineConfiguration alloc] init]`.
NS_SWIFT_UI_ACTOR
@protocol AXOEngineConfiguration <NSObject>
/// Where profiles keep their data, one folder per profile.
@property(nonatomic, copy) NSURL* userDataDirectory;
/// For tests: when `YES`, the engine uses a stand-in keychain (never the person's) and makes no
/// background requests of its own (component updates and the like).
@property(nonatomic) BOOL ephemeral;
/// More Chromium switches, such as `--enable-logging=stderr`, for debugging. The engine never
/// reads them from the environment; the app decides (Axo only in debug builds).
@property(nonatomic, copy) NSArray<NSString*>* additionalArguments;
/// More folders to find native messaging hosts in (`<name>.json` manifests), after Chromium's
/// own. Apps like 1Password register their hosts for Google Chrome, not for Axo. Empty by
/// default.
@property(nonatomic, copy) NSArray<NSURL*>* nativeMessagingHostFolders;
@end

/// The Chromium browser process inside the app. The `AXOEngine` class adopts it.
NS_SWIFT_UI_ACTOR
@protocol AXOEngine <NSObject>
/// The API version the framework implements; compare with AXO_ENGINE_API_VERSION.
@property(class, readonly) NSInteger apiVersion;
/// The Chromium version the framework was built from, such as `156.0.8078.48`.
@property(class, readonly) NSString* chromiumVersion;

/// Runs Chromium's browser process inside the app's running event loop, and calls `ready` once
/// pages can be created, or with an error.
///
/// `NSApp` must be an `AXOApplication`. Chromium's loop runs nested in AppKit's, so this doesn't
/// return until the engine shuts down. Call it once, after the app finished launching, from a
/// run-loop callout (`RunLoop.main.perform`), never a main-queue block, which would stall the
/// main queue (and the main actor) for the rest of the session.
+ (void)runWithConfiguration:(id<AXOEngineConfiguration>)configuration
                       ready:(void (^)(id<AXOEngine> _Nullable engine, NSError* _Nullable error))ready;

/// Shuts Chromium down, after which `runWithConfiguration:ready:` returns. Quitting the app
/// does this for you.
- (void)shutdown;
@end

// MARK: - Profiles

/// One Axo profile's website data: a Chromium profile in its own folder.
NS_SWIFT_UI_ACTOR
@protocol AXOProfile <NSObject>
/// Axo's profile ID.
@property(nonatomic, readonly) NSUUID* identifier;

/// The profile for `identifier`, created on first use. The engine must be running.
+ (id<AXOProfile>)profileWithIdentifier:(NSUUID*)identifier
    NS_SWIFT_NAME(profile(withIdentifier:));

/// Removes cookies, caches, and other website data.
- (void)clearWebsiteDataWithCompletion:(void (^)(void))completion;

/// Loads an unpacked extension (a folder with a manifest.json) into the profile, as Chrome's
/// developer mode does. `completion` gets the extension's ID, or an error.
- (void)loadUnpackedExtensionAtURL:(NSURL*)url
                        completion:(void (^)(NSString* _Nullable extensionID, NSError* _Nullable error))completion
    NS_SWIFT_NAME(loadUnpackedExtension(at:completion:));

/// The profile's installed extensions, enabled or not.
@property(nonatomic, readonly) NSArray<id<AXOExtension>>* extensions;

/// Gives or takes away an extension's permission to run user scripts (`chrome.userScripts`),
/// as Chrome's "Allow User Scripts" switch does.
- (void)setUserScriptsAllowed:(BOOL)allowed forExtension:(NSString*)extensionID
    NS_SWIFT_NAME(setUserScriptsAllowed(_:forExtension:));

/// Turns an extension on or off.
- (void)setExtension:(NSString*)extensionID enabled:(BOOL)enabled
    NS_SWIFT_NAME(setExtension(_:enabled:));

/// Uninstalls an extension and deletes its data.
- (void)uninstallExtension:(NSString*)extensionID;

/// The toolbar buttons of the profile's enabled extensions, for `page`: what Chrome's toolbar
/// would show when that page is the active tab.
- (NSArray<id<AXOExtensionAction>>*)extensionActionsForPage:(id<AXOPage>)page
    NS_SWIFT_NAME(extensionActions(for:));

/// Clicks an extension's toolbar button with `page` as the active tab of `window`. If the
/// extension has a popup, `completion` gets it, open and loading; otherwise `nil`, and the
/// extension handled the click (`chrome.action.onClicked`).
- (void)performExtensionAction:(NSString*)extensionID
                        onPage:(id<AXOPage>)page
                        window:(id<AXOWindow>)window
                    completion:(void (^)(id<AXOExtensionPopup> _Nullable popup))completion
    NS_SWIFT_NAME(performExtensionAction(_:on:window:completion:));

/// Called when extensions are installed, removed, turned on or off, or change their toolbar
/// buttons (titles, badges, icons).
@property(nonatomic, copy, nullable) void (^onExtensionsChange)(void);

/// Called when an extension opens its own popup (`chrome.action.openPopup`), as some do when
/// their toolbar button is clicked. Show it under the extension's toolbar button, as for a popup
/// from `performExtensionAction`. Without a handler, the extension's call fails.
@property(nonatomic, copy, nullable) void (^onExtensionPopupRequest)(id<AXOExtensionPopup> popup);

/// The keyboard shortcuts of the profile's enabled extensions (`commands` in their manifests)
/// that have keys. Show them as menu items; they change with `onExtensionsChange`.
@property(nonatomic, readonly) NSArray<id<AXOExtensionCommand>>* extensionCommands;

/// Runs an extension's command with `page` as the active tab, as pressing its shortcut does:
/// `_execute_action` clicks the extension's toolbar button (`completion` gets its popup, or nil
/// when the extension handled the click), and other commands reach the extension's
/// `chrome.commands.onCommand` with access to the page (`completion` gets nil).
- (void)performExtensionCommand:(NSString*)name
                      extension:(NSString*)extensionID
                         onPage:(id<AXOPage>)page
                         window:(id<AXOWindow>)window
                     completion:(void (^)(id<AXOExtensionPopup> _Nullable popup))completion
    NS_SWIFT_NAME(performExtensionCommand(_:extension:on:window:completion:));

/// Called when something needs the person's answer that Chrome would ask in its own dialog:
/// an extension asking for more permissions (`chrome.permissions.request`) or being installed,
/// an extension being removed (`chrome.management.uninstall`), or, when a page or extension
/// wants to record the screen and may have a screen or a window, which of the two (macOS's own
/// picker then opens for that kind). Ask in the app's own UI and call `answer` once. Without a
/// handler, every prompt is answered Cancel.
@property(nonatomic, copy, nullable) void (^onExtensionPrompt)
    (id<AXOExtensionPrompt> prompt, void (^answer)(AXOExtensionPromptAnswer answer));

/// Sets the profile's bookmarks, as extensions see them (`chrome.bookmarks`): `bar` becomes the
/// bookmarks bar and `other` the other bookmarks, replacing what was there, matched node by node
/// by `identifier` (a UUID), so a bookmark keeps its extension-visible ID across launches. Call
/// it whenever the app's tree changes. Applied once the bookmark model has loaded.
- (void)setBookmarkBar:(NSArray<id<AXOBookmarkNode>>*)bar
                 other:(NSArray<id<AXOBookmarkNode>>*)other
    NS_SWIFT_NAME(setBookmarks(bar:other:));

/// Called with each change an extension makes to the bookmarks. Apply it to the app's data and
/// set the tree again; a change the app can't make is undone by that.
@property(nonatomic, copy, nullable) void (^onBookmarkChange)(id<AXOBookmarkChange> change);

/// Called when history changes other than by a page visit: an extension added a visit
/// (`chrome.history.addUrl`) or deleted history (`chrome.history` or `chrome.browsingData`). The
/// engine keeps its own copy of history, recording page visits itself, because visited links,
/// `chrome.history`, and `chrome.topSites` come from it; apply these to the app's history so the
/// two stay in step. The engine's expiry of old visits isn't reported.
@property(nonatomic, copy, nullable) void (^onHistoryChange)(id<AXOHistoryChange> change);

/// Called when an extension's side panel opens (`chrome.sidePanel.open`, or its toolbar button
/// with `openPanelOnActionClick`). Show `panel.view` beside the page; another extension's panel
/// that was open has already closed. Without a handler, side panels don't open.
@property(nonatomic, copy, nullable) void (^onExtensionSidePanelOpen)(id<AXOExtensionSidePanel> panel);

/// Called when an extension opens a popup window (`chrome.windows.create` with `type: "popup"`),
/// such as a password manager's pop-out. Show the window's first page in a small window of
/// `size` (zero when the extension gave none), and set the window's delegate: it hears when
/// Chrome closes the page (`chrome.windows.remove`), which closes the window. Closing the page
/// closes the window for Chrome too. Normal windows (`type: "normal"`) don't come here: their tabs
/// open in the profile's existing window. Without a handler, popup windows fail to open.
@property(nonatomic, copy, nullable) void (^onExtensionWindowOpen)(id<AXOWindow> window, NSSize size);

/// Installs an extension package (a CRX3 `.crx` file), as Chrome does when a person drops one on
/// its Extensions page: Axo asks the person first. `completion` gets the extension's ID, or an
/// error saying why it didn't install.
- (void)installPackageAtURL:(NSURL*)url
                 completion:(void (^)(NSString* _Nullable extensionID, NSError* _Nullable error))completion
    NS_SWIFT_NAME(installPackage(at:completion:));

/// Deletes a profile's data for good. Close its pages first.
+ (void)removeProfileWithIdentifier:(NSUUID*)identifier
                         completion:(void (^)(NSError* _Nullable error))completion
    NS_SWIFT_NAME(removeProfile(withIdentifier:completion:));
@end

// MARK: - Pages

typedef NS_OPTIONS(NSUInteger, AXOLinkModifiers) {
  AXOLinkModifierCommand = 1 << 0,
  AXOLinkModifierShift = 1 << 1,
  AXOLinkModifierOption = 1 << 2,
  AXOLinkModifierControl = 1 << 3,
};

typedef NS_ENUM(NSInteger, AXOPermissionKind) {
  AXOPermissionKindCamera,
  AXOPermissionKindMicrophone,
  AXOPermissionKindCameraAndMicrophone,
  AXOPermissionKindLocation,
};

typedef NS_ENUM(NSInteger, AXODialogKind) {
  AXODialogKindAlert,
  AXODialogKindConfirm,
  AXODialogKindPrompt,
};

/// A page's events. Mirrors Axo's `EnginePageDelegate`.
NS_SWIFT_UI_ACTOR
@protocol AXOPageDelegate <NSObject>
/// URL, title, loading state, progress, or history changed. Read the new values from the page.
- (void)pageStateDidChange:(id<AXOPage>)page;
- (void)pageDidFinishLoad:(id<AXOPage>)page;
- (void)pageDidFailLoad:(id<AXOPage>)page;
- (void)pageDidTakeFocus:(id<AXOPage>)page;
/// A link click in the main frame, asked again at each redirect. Return `YES` to take it, so the
/// page doesn't navigate. Answer right away: it's called in the middle of the navigation, so
/// don't close or navigate this page from inside the call; do that work afterwards.
- (BOOL)page:(id<AXOPage>)page shouldHandleLinkToURL:(NSURL*)url modifiers:(AXOLinkModifiers)modifiers;
/// `target="_blank"`, `window.open`, and the like.
- (void)page:(id<AXOPage>)page wantsToOpenURLInNewTab:(NSURL*)url;
- (void)page:(id<AXOPage>)page
    requestsPermission:(AXOPermissionKind)kind
                origin:(NSURL*)origin
            completion:(void (^)(BOOL allowed))completion;
- (void)page:(id<AXOPage>)page
    showsDialog:(AXODialogKind)kind
        message:(NSString*)message
    defaultText:(nullable NSString*)defaultText
         origin:(NSURL*)origin
     completion:(void (^)(BOOL accepted, NSString* _Nullable text))completion;
- (void)page:(id<AXOPage>)page
    selectsFilesAllowingMultiple:(BOOL)allowsMultiple
                     directories:(BOOL)allowsDirectories
                      completion:(void (^)(NSArray<NSURL*>* _Nullable files))completion;
/// A download started, from the page or from `-startDownloadFromURL:` or the context menu. Set
/// `download.observer` before returning: the engine asks it where to save the file right away
/// (a download it can't ask is cancelled), then reports progress to it. A download whose server
/// can't be reached or answers with an error is asked about, then fails. Downloads without a page,
/// such as an extension's background downloads, go to the profile's download folder unreported.
- (void)page:(id<AXOPage>)page didStartDownload:(id<AXODownload>)download;
@optional
/// A right-click (or Control-click) in the page. Show the app's own menu for `menu` at
/// `menu.location`, and call `-[AXOContextMenu closedFollowingLink:]` when it closes. Return
/// `NO` to show nothing.
- (BOOL)page:(id<AXOPage>)page showContextMenu:(id<AXOContextMenu>)menu
    NS_SWIFT_NAME(page(_:showContextMenu:));
/// A key press the page didn't use, such as a ⌘ shortcut: the page sees key presses first while
/// it has keyboard focus. Return `YES` if the app used it, for example as a menu shortcut
/// (`-[NSMenu performKeyEquivalent:]`). Without this, unused key presses are dropped.
- (BOOL)page:(id<AXOPage>)page didNotHandleKeyEvent:(NSEvent*)event;
/// The page asked to fill the screen (`element.requestFullscreen()`, a video's full-screen
/// button), or to stop. Show only the page, filling the screen, or go back. When the person
/// leaves full screen another way, call `-[AXOPage exitFullscreen]`. Without this, pages can't
/// go full screen.
- (void)page:(id<AXOPage>)page setsFullscreen:(BOOL)fullscreen NS_SWIFT_NAME(page(_:setsFullscreen:));
/// The page opened another page (`window.open`, a `target="_blank"` link, a link opened in a new
/// tab): `newPage` is already loading `url`, with what the request carried (its opener, form
/// data, referrer). Show it as a tab after this one, in the background when `inBackground`, or as
/// a small window of `size` (zero when unspecified) when `isPopup`. Close it to drop it (and
/// load `url` some other way if you like). Without this, only the URL arrives, through
/// `page:wantsToOpenURLInNewTab:`.
- (void)page:(id<AXOPage>)page
    didOpenPage:(id<AXOPage>)newPage
            url:(NSURL*)url
          popup:(BOOL)isPopup
           size:(NSSize)size
   inBackground:(BOOL)inBackground NS_SWIFT_NAME(page(_:didOpen:url:popup:size:inBackground:));
@end

/// One tab's page: a Chromium `WebContents` and its view.
NS_SWIFT_UI_ACTOR
@protocol AXOPage <NSObject>
/// A new, empty page in `profile`, outside any window until a window's `pages` includes it.
+ (id<AXOPage>)pageWithProfile:(id<AXOProfile>)profile NS_SWIFT_NAME(page(with:));

@property(nonatomic, weak, nullable) id<AXOPageDelegate> delegate;
/// The view that draws the page. Size it with its autoresizing mask.
@property(nonatomic, readonly) NSView* view;

@property(nonatomic, readonly, nullable) NSURL* URL;
@property(nonatomic, readonly) NSString* title;
@property(nonatomic, readonly, getter=isLoading) BOOL loading;
@property(nonatomic, readonly) double estimatedProgress;
@property(nonatomic, readonly) BOOL canGoBack;
@property(nonatomic, readonly) BOOL canGoForward;

/// Back and forward history, serialized, for hibernation. `nil` while unsupported.
@property(nonatomic, readonly, nullable) NSData* navigationState;
/// Restores history saved from `navigationState` and loads its current entry.
- (void)restoreNavigationState:(NSData*)state;

- (void)loadURL:(NSURL*)url;
- (void)goBack;
- (void)goForward;
- (void)reload;
- (void)stopLoading;

/// Finds `text` (ignoring case, wrapping), highlights and scrolls to it. `completion` runs once,
/// on a later turn. A find that a newer find or `stopFinding` replaces is answered NO, so callers
/// ignore answers to finds they have replaced.
- (void)findString:(NSString*)text backwards:(BOOL)backwards completion:(void (^)(BOOL found))completion;
- (void)stopFinding;

/// Runs `functionBody` as an async function's body with `arguments` (JSON values, keyed by
/// parameter name) as its parameters, in the main frame's isolated world named `world`, and
/// waits for the promise it returns. Each name keeps its own world, which the page's and
/// extensions' scripts can't see, for the app's lifetime; the engine has five. The body sees only
/// globals and its arguments. The result arrives as Foundation values (JSON types: nil for
/// `undefined`, a string for a `Date`, NSNull for `NaN`). Errors are AXOEngineErrorDomain 105:
/// the function threw, the body has a syntax error, the arguments or result aren't JSON, or the
/// page navigated or closed first.
- (void)callFunctionBody:(NSString*)functionBody
               arguments:(NSDictionary<NSString*, id>*)arguments
                 inWorld:(NSString*)world
              completion:(void (^)(id _Nullable result, NSError* _Nullable error))completion;

/// A picture of the visible page, `width` points wide.
- (void)snapshotWithWidth:(CGFloat)width completion:(void (^)(NSImage* _Nullable image))completion;

/// Downloads `url` with the page's profile and cookies. Reported through the delegate
/// (`page:didStartDownload:`).
- (void)startDownloadFromURL:(NSURL*)url;

/// Opens or closes Chromium's DevTools for the page.
- (void)toggleDevTools;

/// A print operation for the page.
- (NSPrintOperation*)printOperationWithPrintInfo:(NSPrintInfo*)printInfo;
/// Leaves page full screen, when the person leaves full screen some other way than the page.
- (void)exitFullscreen;

/// Stops the page and releases its `WebContents`. The page is unusable afterwards.
- (void)close;
@end

// MARK: - Windows

/// What Chrome's extension APIs see as one browser window: a hidden Chrome window holding the
/// tabs of the Space an Axo window shows. A page is in at most one window; pages in none (other
/// Spaces) stay alive but extensions don't see them.
NS_SWIFT_UI_ACTOR
@protocol AXOWindow <NSObject>
/// A new, empty window for `profile`'s pages.
+ (id<AXOWindow>)windowWithProfile:(id<AXOProfile>)profile NS_SWIFT_NAME(window(with:));

/// Hears about tabs Chrome adds, closes, moves, or activates in this window (extensions,
/// `window.open`).
@property(nonatomic, weak, nullable) id<AXOWindowDelegate> delegate;

/// Whether the window is the one the person is using; set it as the app becomes active and
/// inactive. Extension calls that need the active window (`chrome.permissions.request`,
/// `chrome.action.openPopup`) only work while it is. `NO` at first.
@property(nonatomic, getter=isActive) BOOL active;

/// The window's pages, in order. Setting it adds, removes, and reorders tabs to match; pages
/// that leave stay alive. Pages from another profile are ignored.
@property(nonatomic, copy) NSArray<id<AXOPage>>* pages;

/// The page the person is looking at, if it's in `pages`.
@property(nonatomic, weak, nullable) id<AXOPage> activePage;

/// Closes the window. Its pages stay alive, outside any window.
- (void)close;
@end

/// Changes Chrome makes to a window's tabs on its own, so Axo's sidebar can follow. Changes Axo
/// makes through `pages` and `activePage` aren't reported back.
NS_SWIFT_UI_ACTOR
@protocol AXOWindowDelegate <NSObject>
/// Chrome added a tab, already loading (`chrome.tabs.create`, for one). Axo should show it.
- (void)window:(id<AXOWindow>)window didOpenPage:(id<AXOPage>)page atIndex:(NSInteger)index;
/// Chrome closed one of the window's pages (`chrome.tabs.remove`, for one). It's unusable now.
- (void)window:(id<AXOWindow>)window didClosePage:(id<AXOPage>)page;
/// Chrome moved a page to `index`.
- (void)window:(id<AXOWindow>)window didMovePage:(id<AXOPage>)page toIndex:(NSInteger)index;
/// Chrome made a page the active one (`chrome.tabs.update({active: true})`, for one).
- (void)window:(id<AXOWindow>)window didActivatePage:(id<AXOPage>)page;
@end

// MARK: - Extensions

/// An installed extension.
NS_SWIFT_UI_ACTOR
@protocol AXOExtension <NSObject>
@property(nonatomic, readonly) NSString* identifier;
@property(nonatomic, readonly) NSString* name;
@property(nonatomic, readonly) NSString* version;
@property(nonatomic, readonly, getter=isEnabled) BOOL enabled;
/// Loaded from a folder in developer mode rather than installed from a package.
@property(nonatomic, readonly, getter=isUnpacked) BOOL unpacked;
/// Whether the extension uses `chrome.userScripts`, which needs the person's permission
/// (Chrome's "Allow User Scripts" switch).
@property(nonatomic, readonly) BOOL usesUserScripts;
/// Whether that permission is given.
@property(nonatomic, readonly) BOOL userScriptsAllowed;
@end

/// An extension's toolbar button for one page.
NS_SWIFT_UI_ACTOR
@protocol AXOExtensionAction <NSObject>
@property(nonatomic, readonly) NSString* extensionIdentifier;
/// The button's title (its tooltip and VoiceOver label).
@property(nonatomic, readonly) NSString* title;
/// Badge text, or an empty string.
@property(nonatomic, readonly) NSString* badgeText;
/// The icon, or `nil` while it loads.
@property(nonatomic, readonly, nullable) NSImage* icon;
/// Whether the button can be clicked on this page.
@property(nonatomic, readonly, getter=isEnabled) BOOL enabled;
/// Whether clicking it opens a popup.
@property(nonatomic, readonly) BOOL hasPopup;
@end

// MARK: - Context menus

/// What a right-click hit, when it's media.
typedef NS_ENUM(NSInteger, AXOContextMenuMedia) {
  AXOContextMenuMediaNone,
  AXOContextMenuMediaImage,
  AXOContextMenuMediaVideo,
  AXOContextMenuMediaAudio,
  AXOContextMenuMediaCanvas,
  AXOContextMenuMediaOther,
};

/// The editing commands that apply where the right-click was.
typedef NS_OPTIONS(NSUInteger, AXOContextMenuEdits) {
  AXOContextMenuEditsUndo = 1 << 0,
  AXOContextMenuEditsRedo = 1 << 1,
  AXOContextMenuEditsCut = 1 << 2,
  AXOContextMenuEditsCopy = 1 << 3,
  AXOContextMenuEditsPaste = 1 << 4,
  AXOContextMenuEditsDelete = 1 << 5,
  AXOContextMenuEditsSelectAll = 1 << 6,
};

/// An editing command for `-[AXOContextMenu performEdit:]`.
typedef NS_ENUM(NSInteger, AXOContextMenuEdit) {
  AXOContextMenuEditUndo,
  AXOContextMenuEditRedo,
  AXOContextMenuEditCut,
  AXOContextMenuEditCopy,
  AXOContextMenuEditPaste,
  AXOContextMenuEditPasteAndMatchStyle,
  AXOContextMenuEditDelete,
  AXOContextMenuEditSelectAll,
};

typedef NS_ENUM(NSInteger, AXOContextMenuItemType) {
  AXOContextMenuItemTypeCommand,
  AXOContextMenuItemTypeCheckbox,
  AXOContextMenuItemTypeRadio,
  AXOContextMenuItemTypeSeparator,
  AXOContextMenuItemTypeSubmenu,
};

/// An extension's context menu item (`chrome.contextMenus`).
NS_SWIFT_UI_ACTOR
@protocol AXOContextMenuItem <NSObject>
@property(nonatomic, readonly) AXOContextMenuItemType type;
@property(nonatomic, readonly) NSString* title;
@property(nonatomic, readonly, getter=isEnabled) BOOL enabled;
@property(nonatomic, readonly, getter=isChecked) BOOL checked;
/// A submenu's items.
@property(nonatomic, readonly) NSArray<id<AXOContextMenuItem>>* children;
@end

/// A right-click in a page: what it hit, extensions' items for it, and the actions a menu for
/// it can run on the page.
NS_SWIFT_UI_ACTOR
@protocol AXOContextMenu <NSObject>
/// The link clicked, if any, and its text.
@property(nonatomic, readonly, nullable) NSURL* linkURL;
@property(nonatomic, readonly) NSString* linkText;
/// The media clicked, and its source (an image's URL, say).
@property(nonatomic, readonly) AXOContextMenuMedia media;
@property(nonatomic, readonly, nullable) NSURL* sourceURL;
/// Whether an image's pixels are loaded, so it can be copied.
@property(nonatomic, readonly) BOOL hasImageContents;
/// The selected text, or empty.
@property(nonatomic, readonly) NSString* selectionText;
/// Whether the click was in a text field or editable content, and which edits apply there.
@property(nonatomic, readonly, getter=isEditable) BOOL editable;
@property(nonatomic, readonly) AXOContextMenuEdits edits;
/// A misspelled word clicked, and the spelling checker's suggestions for it.
@property(nonatomic, readonly) NSString* misspelledWord;
@property(nonatomic, readonly) NSArray<NSString*>* suggestions;
/// The page's URL.
@property(nonatomic, readonly) NSURL* pageURL;
/// Where the click was, in the page view's coordinates with the origin at its top left.
@property(nonatomic, readonly) NSPoint location;
/// Extensions' items for this click, grouped as Chrome groups them: an extension's only item
/// at the top level, several in a submenu named for the extension.
@property(nonatomic, readonly) NSArray<id<AXOContextMenuItem>>* extensionItems;

- (void)performEdit:(AXOContextMenuEdit)edit;
- (void)replaceMisspellingWith:(NSString*)word;
/// Copies the clicked image.
- (void)copyImage;
/// Downloads a link's target (named by its download attribute) or an image, from the clicked
/// frame. Reported through the page's delegate (`page:didStartDownload:`).
- (void)download:(NSURL*)url;
/// Shows the selection's definition (Look Up).
- (void)lookUpSelection;
/// Runs an extension's item, one of `extensionItems` or their children.
- (void)performExtensionItem:(id<AXOContextMenuItem>)item;
/// Tells the page the menu closed, and which link it followed, if any. Call it once.
- (void)closedFollowingLink:(nullable NSURL*)url;
@end

/// Something to ask the person, for `AXOProfile.onExtensionPrompt`.
NS_SWIFT_UI_ACTOR
@protocol AXOExtensionPrompt <NSObject>
@property(nonatomic, readonly) AXOExtensionPromptKind kind;
/// The extension it's about, or empty for screen recording a page asked for.
@property(nonatomic, readonly) NSString* extensionIdentifier;
/// The extension's name, or for screen recording, who asked.
@property(nonatomic, readonly) NSString* extensionName;
/// Chrome's title for the prompt, which the app may use or replace, or empty.
@property(nonatomic, readonly) NSString* title;
/// What the extension can do, one line each (Chrome's permission descriptions).
@property(nonatomic, readonly) NSArray<NSString*>* details;
/// For an uninstall another extension asked for, that extension's name.
@property(nonatomic, readonly, copy, nullable) NSString* requestingExtensionName;
/// For screen recording, what may be shared.
@property(nonatomic, readonly) BOOL allowsScreen;
@property(nonatomic, readonly) BOOL allowsWindow;
@end

/// A bookmark or folder in the app's tree, for `setBookmarkBar:other:`.
NS_SWIFT_UI_ACTOR
@protocol AXOBookmarkNode <NSObject>
/// A UUID, unique in the tree: the app's own ID for the thing the bookmark stands for.
@property(nonatomic, readonly) NSString* identifier;
@property(nonatomic, readonly) NSString* title;
/// The bookmark's URL, or `nil` for a folder.
@property(nonatomic, readonly, nullable) NSURL* url;
/// A folder's contents, in order.
@property(nonatomic, readonly) NSArray<id<AXOBookmarkNode>>* children;
@end

typedef NS_ENUM(NSInteger, AXOBookmarkChangeKind) {
  AXOBookmarkChangeKindCreated,
  AXOBookmarkChangeKindUpdated,
  AXOBookmarkChangeKindMoved,
  AXOBookmarkChangeKindRemoved,
};

/// Where a changed bookmark is: at the top of the bookmarks bar or the other bookmarks, or in a
/// folder (`parentIdentifier`).
typedef NS_ENUM(NSInteger, AXOBookmarkRoot) {
  AXOBookmarkRootNone,
  AXOBookmarkRootBar,
  AXOBookmarkRootOther,
};

/// A change an extension made to the bookmarks.
NS_SWIFT_UI_ACTOR
@protocol AXOBookmarkChange <NSObject>
@property(nonatomic, readonly) AXOBookmarkChangeKind kind;
/// The bookmark's UUID; for a new one, made by the engine, for the app to use as its ID.
@property(nonatomic, readonly) NSString* identifier;
/// Where it is now (where it was, for a removal), and its position there.
@property(nonatomic, readonly) AXOBookmarkRoot parentRoot;
@property(nonatomic, readonly, copy, nullable) NSString* parentIdentifier;
@property(nonatomic, readonly) NSUInteger index;
@property(nonatomic, readonly) NSString* title;
/// The bookmark's URL, or `nil` for a folder.
@property(nonatomic, readonly, nullable) NSURL* url;
@end

typedef NS_ENUM(NSInteger, AXOHistoryChangeKind) {
  /// A visit to the one page in `urls`, titled `title`, at `date`.
  AXOHistoryChangeKindVisited,
  /// The pages in `urls` have no visits left. When `date` and `endDate` are set, the deletion
  /// was of the visits in that range only, so the app's record of an earlier visit to one of
  /// those pages (from before the engine kept history, or imported) is still right.
  AXOHistoryChangeKindDeleted,
  /// All history was deleted.
  AXOHistoryChangeKindDeletedAll,
};

/// A change to history, for `onHistoryChange`.
NS_SWIFT_UI_ACTOR
@protocol AXOHistoryChange <NSObject>
@property(nonatomic, readonly) AXOHistoryChangeKind kind;
@property(nonatomic, readonly) NSArray<NSURL*>* urls;
@property(nonatomic, readonly) NSString* title;
@property(nonatomic, readonly, nullable) NSDate* date;
/// For a deletion of a range of visits, the range's end (`date` is its start).
@property(nonatomic, readonly, nullable) NSDate* endDate;
@end

/// An extension's side panel, open. Show `view` beside the page, titled `title`.
NS_SWIFT_UI_ACTOR
@protocol AXOExtensionSidePanel <NSObject>
@property(nonatomic, readonly) NSString* extensionIdentifier;
/// The extension's name.
@property(nonatomic, readonly) NSString* title;
/// The view that draws the panel's page.
@property(nonatomic, readonly) NSView* view;
/// Called when the panel closes without the app asking: the extension closed it
/// (`chrome.sidePanel.close`, `window.close()`, or turned it off), or another opened.
@property(nonatomic, copy, nullable) void (^onClose)(void);
/// Closes the panel, as its close button does.
- (void)close;
@end

/// A keyboard shortcut an extension declares, as `NSMenuItem` takes it.
NS_SWIFT_UI_ACTOR
@protocol AXOExtensionCommand <NSObject>
/// The extension the shortcut belongs to.
@property(nonatomic, readonly) NSString* extensionIdentifier;
/// `_execute_action` (click the extension's toolbar button), or a name the extension chose.
@property(nonatomic, readonly) NSString* name;
/// What the shortcut does, for its menu item: the manifest's description, or for
/// `_execute_action` without one, the extension's name.
@property(nonatomic, readonly) NSString* title;
/// The key, as an `NSMenuItem` key equivalent.
@property(nonatomic, readonly) NSString* keyEquivalent;
/// The modifier keys.
@property(nonatomic, readonly) NSEventModifierFlags modifierFlags;
@end

/// An extension's popup, open. Show `view` in a popover; it sizes itself to its content.
NS_SWIFT_UI_ACTOR
@protocol AXOExtensionPopup <NSObject>
@property(nonatomic, readonly) NSString* extensionIdentifier;
/// The view that draws the popup.
@property(nonatomic, readonly) NSView* view;
/// The popup page's title, for VoiceOver.
@property(nonatomic, readonly) NSString* title;
/// The size the popup's content wants.
@property(nonatomic, readonly) NSSize preferredSize;
/// Called when `preferredSize` changes.
@property(nonatomic, copy, nullable) void (^onResize)(NSSize size);
/// Called once the popup page has loaded.
@property(nonatomic, copy, nullable) void (^onLoad)(void);
/// Called when the popup closes itself (`window.close()`); it's unusable after.
@property(nonatomic, copy, nullable) void (^onClose)(void);
/// Closes the popup.
- (void)close;
@end

// MARK: - Downloads

/// Receives a download's progress. After `downloadDidFinish:` or `download:didFailWithMessage:`,
/// or after the download is cancelled, nothing more arrives.
NS_SWIFT_UI_ACTOR
@protocol AXODownloadObserver <NSObject>
/// Where to save `suggestedFilename` (a file URL; the folder must exist), or `nil` to cancel.
/// `expectedLength` is 0 when the server didn't say.
- (nullable NSURL*)download:(id<AXODownload>)download
    destinationForSuggestedFilename:(NSString*)suggestedFilename
                     expectedLength:(int64_t)expectedLength;
/// Bytes saved so far, and the total (0 when unknown).
- (void)download:(id<AXODownload>)download didReceiveBytes:(int64_t)completed ofTotal:(int64_t)total;
/// The file is complete at its destination.
- (void)downloadDidFinish:(id<AXODownload>)download;
/// The download stopped, with why in words for the person. The partial file is deleted. Files
/// Chrome marks as possibly unsafe stop this way too, since Axo has no way to keep them yet.
- (void)download:(id<AXODownload>)download didFailWithMessage:(NSString*)message;
@end

/// A download. The engine keeps it until it ends.
NS_SWIFT_UI_ACTOR
@protocol AXODownload <NSObject>
@property(nonatomic, readonly, nullable) NSURL* sourceURL;
/// Held weakly: the app keeps it.
@property(nonatomic, weak, nullable) id<AXODownloadObserver> observer;
/// Stops the download and deletes the partial file. The observer hears nothing more.
- (void)cancel;
@end

NS_ASSUME_NONNULL_END
