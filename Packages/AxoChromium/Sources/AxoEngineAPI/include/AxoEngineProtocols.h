// AxoEngine's stable API, as Objective-C protocols.
//
// Axo never links AxoEngine: it loads the framework at runtime (it's large, and only machines
// that build Chromium have it), finds the classes by name, and talks to them through these
// protocols. Axo keeps an identical copy of this file (Packages/AxoChromium); the two must
// match, and AXO_ENGINE_API_VERSION says which version a framework implements.
//
// Classes: AXOApplication (an NSApplication subclass), AXOEngine, AXOEngineConfiguration,
// AXOProfile, AXOWindow, AXOPage, and AXODownload, each adopting the protocol of the same name. Every class
// is main-thread only, like AppKit, and completion handlers run on the main thread.
//
// Every protocol is NS_SWIFT_UI_ACTOR, so Swift treats the API as main-actor isolated, which it
// is. Raise AXO_ENGINE_API_VERSION whenever anything in this file changes.

#import <AppKit/AppKit.h>

#define AXO_ENGINE_API_VERSION 6

NS_ASSUME_NONNULL_BEGIN

@protocol AXOPage;
@protocol AXOPageDelegate;
@protocol AXOWindow;
@protocol AXOWindowDelegate;
@protocol AXODownload;

/// The domain of errors the engine reports.
#define AXOEngineErrorDomain @"AXOEngineErrorDomain"

// MARK: - Engine

/// How to start the engine. Make one with `[[AXOEngineConfiguration alloc] init]`.
NS_SWIFT_UI_ACTOR
@protocol AXOEngineConfiguration <NSObject>
/// Where profiles keep their data, one folder per profile.
@property(nonatomic, copy) NSURL* userDataDirectory;
/// When `YES`, nothing is written to disk (tests).
@property(nonatomic) BOOL ephemeral;
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
/// A link click in the main frame. Return `YES` to take it, so the page doesn't navigate.
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
/// A download started. Report its progress through `download.observer`, which the delegate sets.
- (void)page:(id<AXOPage>)page didStartDownload:(id<AXODownload>)download;
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

/// Finds `text` (ignoring case, wrapping), highlights and scrolls to it.
- (void)findString:(NSString*)text backwards:(BOOL)backwards completion:(void (^)(BOOL found))completion;
- (void)stopFinding;

/// Runs `functionBody` as an async function's body with `arguments` as its parameters, in the
/// isolated world named `world`. The result arrives as Foundation values (JSON types).
- (void)callFunctionBody:(NSString*)functionBody
               arguments:(NSDictionary<NSString*, id>*)arguments
                 inWorld:(NSString*)world
              completion:(void (^)(id _Nullable result, NSError* _Nullable error))completion;

/// A picture of the visible page, `width` points wide.
- (void)snapshotWithWidth:(CGFloat)width completion:(void (^)(NSImage* _Nullable image))completion;

/// Downloads `url` with the page's profile. Reported through the delegate.
- (void)startDownloadFromURL:(NSURL*)url;

/// Opens or closes Chromium's DevTools for the page.
- (void)toggleDevTools;

/// A print operation for the page.
- (NSPrintOperation*)printOperationWithPrintInfo:(NSPrintInfo*)printInfo;

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

// MARK: - Downloads

/// Receives a download's progress.
NS_SWIFT_UI_ACTOR
@protocol AXODownloadObserver <NSObject>
/// Where to save `suggestedFilename`, or `nil` to cancel.
- (nullable NSURL*)download:(id<AXODownload>)download
    destinationForSuggestedFilename:(NSString*)suggestedFilename
                     expectedLength:(int64_t)expectedLength;
- (void)download:(id<AXODownload>)download didReceiveBytes:(int64_t)completed ofTotal:(int64_t)total;
- (void)downloadDidFinish:(id<AXODownload>)download;
- (void)download:(id<AXODownload>)download didFailWithMessage:(NSString*)message;
@end

NS_SWIFT_UI_ACTOR
@protocol AXODownload <NSObject>
@property(nonatomic, readonly, nullable) NSURL* sourceURL;
@property(nonatomic, weak, nullable) id<AXODownloadObserver> observer;
- (void)cancel;
@end

NS_ASSUME_NONNULL_END
