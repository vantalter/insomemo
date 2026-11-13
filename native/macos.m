#include "bridge.h"
#include "tray_icon.h"
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Carbon/Carbon.h>
#import <CommonCrypto/CommonDigest.h>
#import <ServiceManagement/ServiceManagement.h>
#include <signal.h>

static void emit(NSString *kind, NSString *first, NSString *second) {
    switcher_event(kind.UTF8String, (first ?: @"").UTF8String, (second ?: @"").UTF8String);
}

static NSString *sourceID(TISInputSourceRef source) {
    return source
               ? (__bridge NSString *)TISGetInputSourceProperty(source, kTISPropertyInputSourceID)
               : @"";
}

static NSString *shortcode(TISInputSourceRef source) {
    NSArray *languages =
        (__bridge NSArray *)TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages);
    NSString *language = languages.firstObject ?: @"--";
    NSString *code = [[language componentsSeparatedByString:@"-"] firstObject].uppercaseString;
    return [code isEqualToString:@"UK"] ? @"UA" : code;
}

// Host of an http(s) page without "www.", or nil for other documents.
static NSString *pageHost(id value) {
    NSURL *url = [value isKindOfClass:NSURL.class]      ? value
                 : [value isKindOfClass:NSString.class] ? [NSURL URLWithString:value]
                                                        : nil;
    NSString *scheme = url.scheme.lowercaseString;
    if (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"])
        return nil;
    NSString *host = url.host.lowercaseString;
    if ([host hasPrefix:@"www."])
        host = [host substringFromIndex:4];
    return host.length ? host : nil;
}

// Breadth-first, without descending into page content: Safari's web area is
// about 50 elements from the window.
static NSString *webAreaHost(AXUIElementRef window) {
    NSMutableArray *queue = [NSMutableArray arrayWithObject:(__bridge id)window];
    for (NSUInteger visited = 0; queue.count && visited < 300; visited++) {
        id element = queue.firstObject;
        [queue removeObjectAtIndex:0];
        AXUIElementRef ax = (__bridge AXUIElementRef)element;
        CFTypeRef role = NULL;
        BOOL webArea = AXUIElementCopyAttributeValue(ax, kAXRoleAttribute, &role) ==
                           kAXErrorSuccess &&
                       role && CFEqual(role, CFSTR("AXWebArea"));
        if (role)
            CFRelease(role);
        if (webArea) {
            CFTypeRef url = NULL;
            if (AXUIElementCopyAttributeValue(ax, kAXURLAttribute, &url) != kAXErrorSuccess)
                return nil;
            return pageHost(CFBridgingRelease(url));
        }
        CFTypeRef children = NULL;
        if (AXUIElementCopyAttributeValue(ax, kAXChildrenAttribute, &children) ==
                kAXErrorSuccess &&
            children)
            [queue addObjectsFromArray:CFBridgingRelease(children)];
    }
    return nil;
}

static NSString *windowSite(AXUIElementRef window, BOOL safari) {
    // Chromium browsers and Electron apps publish the page URL on the window.
    CFTypeRef document = NULL;
    NSString *host = nil;
    if (AXUIElementCopyAttributeValue(window, kAXDocumentAttribute, &document) ==
            kAXErrorSuccess &&
        document)
        host = pageHost(CFBridgingRelease(document));
    if (!host && safari)
        host = webAreaHost(window);
    return host ?: @"";
}

// The tray icon with a dot in its top-right corner. A transparent
// ring around the dot keeps it distinct from the cards in the one-colour template.
static NSImage *badgedIcon(NSImage *icon) {
    NSImage *badged = [NSImage
         imageWithSize:icon.size
               flipped:NO
        drawingHandler:^BOOL(NSRect rect) {
            [icon drawInRect:rect];
            CGFloat diameter = rect.size.width * 0.36, gap = rect.size.width * 0.08;
            NSRect dot = NSMakeRect(NSMaxX(rect) - diameter,
                                    NSMaxY(rect) - diameter, diameter,
                                    diameter);
            NSGraphicsContext *context = NSGraphicsContext.currentContext;
            context.compositingOperation = NSCompositingOperationClear;
            [[NSBezierPath bezierPathWithOvalInRect:NSInsetRect(dot, -gap, -gap)] fill];
            context.compositingOperation = NSCompositingOperationSourceOver;
            [NSColor.blackColor set];
            [[NSBezierPath bezierPathWithOvalInRect:dot] fill];
            return YES;
        }];
    badged.template = YES;
    return badged;
}

static NSArray *layoutList(void) {
    NSDictionary *filter = @{
        (__bridge NSString *)kTISPropertyInputSourceIsSelectCapable : @YES,
        (__bridge NSString *)
        kTISPropertyInputSourceCategory : (__bridge NSString *)kTISCategoryKeyboardInputSource
    };
    CFArrayRef sources = TISCreateInputSourceList((__bridge CFDictionaryRef)filter, false);
    NSMutableArray *layouts = [NSMutableArray array];
    for (id object in (__bridge NSArray *)sources) {
        TISInputSourceRef source = (__bridge TISInputSourceRef)object;
        NSString *identifier = sourceID(source);
        NSString *name =
            (__bridge NSString *)TISGetInputSourceProperty(source, kTISPropertyLocalizedName);
        if (identifier.length)
            [layouts addObject:@{
                @"id" : identifier,
                @"name" : name ?: identifier,
                @"code" : shortcode(source)
            }];
    }
    if (sources)
        CFRelease(sources);
    return layouts;
}

@interface Switcher : NSObject <NSApplicationDelegate, NSMenuDelegate>
@property NSStatusItem *status;
@property NSMenuItem *contextItem;
@property NSMenuItem *pauseItem;
@property NSMenuItem *errorItem;
@property NSMenu *layoutsMenu;
@property NSTimer *saveTimer;
@property dispatch_source_t terminateSignal;
@property dispatch_source_t interruptSignal;
@property AXObserverRef observer;
@property AXUIElementRef observedApp;
@property AXUIElementRef observedWindow;
@property NSRunningApplication *activeApp;
@property NSString *layoutsJSON;
@property NSMenuItem *pinItem;
@property NSMenuItem *forgetItem;
@property NSMenuItem *removePinsItem;
@property NSString *menuJSON;
@property NSMenuItem *loginItem;
@property NSMenuItem *checkUpdatesItem;
@property NSMenuItem *autoUpdatesItem;
@property NSMenuItem *updateResultItem;
@property NSTimer *updateTimer;
@property NSImage *trayImage;
@property NSImage *badgeImage;
@property NSTimer *badgeTimer;
@property BOOL trusted;
// Last site read from observedWindow and the title it was read under.
@property NSString *siteTitle;
@property NSString *siteHost;
@property NSMenuItem *permissionItem;
@end

static Switcher *delegate;
static void axCallback(AXObserverRef observer, AXUIElementRef element, CFStringRef notification,
                       void *context);

@implementation Switcher
- (void)installSignalHandlers {
    signal(SIGTERM, SIG_IGN);
    signal(SIGINT, SIG_IGN);
    self.terminateSignal =
        dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGTERM, 0, dispatch_get_main_queue());
    self.interruptSignal =
        dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGINT, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(self.terminateSignal, ^{
        emit(@"quit", @"", @"");
    });
    dispatch_source_set_event_handler(self.interruptSignal, ^{
        emit(@"quit", @"", @"");
    });
    dispatch_resume(self.terminateSignal);
    dispatch_resume(self.interruptSignal);
}
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    self.status = [[NSStatusBar systemStatusBar] statusItemWithLength:NSSquareStatusItemLength];
    self.status.autosaveName = @"dev.insomemo.app.status";
    self.status.button.title = @"";
    self.status.button.accessibilityLabel = @"Insomemo";
    NSImage *trayImage = [[NSImage alloc] initWithData:[NSData dataWithBytes:tray_icon
                                                                      length:sizeof(tray_icon)]];
    // Keep the artwork at the selected 20-point menu-bar size without allowing
    // the button to shrink the template further.
    trayImage.size = NSMakeSize(20, 20);
    // A template uses its alpha mask: AppKit supplies white/dark ink for the
    // actual menu-bar appearance, including selected and high-contrast states.
    trayImage.template = YES;
    self.status.button.image = trayImage;
    self.trayImage = trayImage;
    self.badgeImage = badgedIcon(trayImage);
    self.status.button.imagePosition = NSImageOnly;
    self.status.button.imageScaling = NSImageScaleNone;
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Insomemo"];
    menu.autoenablesItems = NO;
    menu.delegate = self;
    self.contextItem = [menu addItemWithTitle:@"Active Context: —" action:nil keyEquivalent:@""];
    self.contextItem.enabled = NO;
    self.errorItem = [menu addItemWithTitle:@"" action:nil keyEquivalent:@""];
    self.errorItem.enabled = NO;
    self.errorItem.hidden = YES;
    [menu addItem:[NSMenuItem separatorItem]];
    self.pauseItem = [menu addItemWithTitle:@"Pause Auto-Switching"
                                     action:@selector(pause:)
                              keyEquivalent:@""];
    self.pauseItem.target = self;
    self.pinItem = [menu addItemWithTitle:@"Always Use Current Layout In"
                                   action:nil
                            keyEquivalent:@""];
    self.pinItem.submenu = [[NSMenu alloc] initWithTitle:@"Pin"];
    self.forgetItem = [menu addItemWithTitle:@"Forget Learned Layout"
                                      action:nil
                               keyEquivalent:@""];
    self.forgetItem.submenu = [[NSMenu alloc] initWithTitle:@"Forget"];
    self.pinItem.submenu.autoenablesItems = NO;
    self.forgetItem.submenu.autoenablesItems = NO;
    NSMenuItem *defaults = [menu addItemWithTitle:@"Force Default Layout"
                                           action:nil
                                    keyEquivalent:@""];
    self.layoutsMenu = [[NSMenu alloc] initWithTitle:@"Layouts"];
    defaults.submenu = self.layoutsMenu;
    NSMenuItem *clear = [menu addItemWithTitle:@"Clear Cache"
                                        action:@selector(clear:)
                                 keyEquivalent:@""];
    clear.target = self;
    self.removePinsItem = [menu addItemWithTitle:@"Remove All Pins"
                                          action:@selector(removePins:)
                                   keyEquivalent:@""];
    self.removePinsItem.target = self;
    self.removePinsItem.enabled = NO;
    [menu addItem:[NSMenuItem separatorItem]];
    self.permissionItem = [menu addItemWithTitle:@"Enable Window / Tab Tracking…"
                                          action:@selector(permission:)
                                   keyEquivalent:@""];
    self.permissionItem.target = self;
    self.loginItem = [menu addItemWithTitle:@"Launch at Login"
                                     action:@selector(toggleLogin:)
                              keyEquivalent:@""];
    self.loginItem.target = self;
    self.loginItem.hidden = YES;
    self.checkUpdatesItem = [menu addItemWithTitle:@"Check for Updates…"
                                               action:@selector(checkUpdates:)
                                        keyEquivalent:@""];
    self.checkUpdatesItem.target = self;
    self.autoUpdatesItem = [menu addItemWithTitle:@"Automatically Check for Updates"
                                              action:@selector(toggleAutoUpdates:)
                                       keyEquivalent:@""];
    self.autoUpdatesItem.target = self;
    self.updateResultItem = [menu addItemWithTitle:@"" action:@selector(openUpdates:) keyEquivalent:@""];
    self.updateResultItem.target = self;
    self.updateResultItem.hidden = YES;
    [menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *quit = [menu addItemWithTitle:@"Quit" action:@selector(quit:) keyEquivalent:@"q"];
    quit.target = self;
    self.status.menu = menu;
    [[[NSWorkspace sharedWorkspace] notificationCenter]
        addObserver:self
           selector:@selector(activated:)
               name:NSWorkspaceDidActivateApplicationNotification
             object:nil];
    [[NSDistributedNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(layoutChanged:)
               name:(__bridge NSString *)kTISNotifySelectedKeyboardInputSourceChanged
             object:nil];
    [[NSDistributedNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(layoutsChanged:)
               name:(__bridge NSString *)kTISNotifyEnabledKeyboardInputSourcesChanged
             object:nil];
    // Posted whenever any app's Accessibility permission changes in System
    // Settings, so the menu and tracking follow it without polling.
    [[NSDistributedNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(accessibilityChanged:)
               name:@"com.apple.accessibility.api"
             object:nil
 suspensionBehavior:NSNotificationSuspensionBehaviorDeliverImmediately];
    self.trusted = AXIsProcessTrusted();
    emit(@"ready", @"", @"");
    [self layoutChanged:nil];
    [self activated:nil];
    [self refreshTrust];
    [self reportTrust];
}
// Shows the current Accessibility permission in the menu and starts or stops
// window tracking when it changes.
- (void)refreshTrust {
    BOOL trusted = AXIsProcessTrusted();
    self.permissionItem.title =
        trusted ? @"Window / Tab Tracking" : @"Enable Window / Tab Tracking…";
    self.permissionItem.state = trusted ? NSControlStateValueOn : NSControlStateValueOff;
    if (trusted == self.trusted)
        return;
    self.trusted = trusted;
    [self reportTrust];
    [self activated:nil];
}
- (void)accessibilityChanged:(NSNotification *)notification {
    // The notification can arrive before the permission database is updated.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       [self refreshTrust];
                   });
}
- (void)reportTrust {
    emit(@"warning",
         self.trusted ? @""
                      : @"App tracking active. Grant Accessibility access for window/tab tracking.",
         @"");
}
- (void)removeObserver {
    if (self.observer)
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(self.observer),
                              kCFRunLoopCommonModes);
    if (self.observedWindow) {
        CFRelease(self.observedWindow);
        self.observedWindow = NULL;
    }
    self.siteTitle = nil;
    if (self.observedApp) {
        CFRelease(self.observedApp);
        self.observedApp = NULL;
    }
    if (self.observer) {
        CFRelease(self.observer);
        self.observer = NULL;
    }
}
- (void)activated:(NSNotification *)notification {
    NSRunningApplication *app = NSWorkspace.sharedWorkspace.frontmostApplication;
    if (!app || app.processIdentifier == getpid())
        return;
    [self removeObserver];
    self.activeApp = app;
    BOOL trusted = AXIsProcessTrusted();
    if (trusted != self.trusted) {
        self.trusted = trusted;
        [self reportTrust];
    }
    if (self.trusted) {
        AXUIElementRef axApp = AXUIElementCreateApplication(app.processIdentifier);
        self.observedApp = axApp;
        AXUIElementSetMessagingTimeout(axApp, 0.2);
        AXObserverRef observer = NULL;
        if (AXObserverCreate(app.processIdentifier, axCallback, &observer) == kAXErrorSuccess) {
            self.observer = observer;
            AXObserverAddNotification(observer, axApp, kAXFocusedWindowChangedNotification,
                                      (__bridge void *)self);
            AXObserverAddNotification(observer, axApp, kAXMainWindowChangedNotification,
                                      (__bridge void *)self);
            AXObserverAddNotification(observer, axApp, kAXFocusedUIElementChangedNotification,
                                      (__bridge void *)self);
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer),
                               kCFRunLoopCommonModes);
        }
    }
    [self readContext];
}
- (void)readContext {
    // Ignore stale queued AX notifications after another application is focused.
    if (NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier !=
        self.activeApp.processIdentifier)
        return;
    NSString *title = @"";
    NSString *windowID = @"";
    NSString *site = @"";
    NSString *identifier = self.activeApp.bundleIdentifier
                               ?: self.activeApp.executableURL.path
                               ?: self.activeApp.localizedName;
    BOOL ghostty = [identifier isEqualToString:@"com.mitchellh.ghostty"];
    BOOL safari = [identifier isEqualToString:@"com.apple.Safari"] ||
                  [identifier isEqualToString:@"com.apple.SafariTechnologyPreview"];
    if (self.observedApp) {
        AXUIElementRef window = NULL;
        // AppKit native tabs are separate AX windows. The selected tab can
        // change the main window without changing the focused UI element.
        AXError windowError = AXUIElementCopyAttributeValue(
            self.observedApp, ghostty ? kAXMainWindowAttribute : kAXFocusedWindowAttribute,
            (CFTypeRef *)&window);
        if (ghostty && (windowError != kAXErrorSuccess || !window))
            windowError = AXUIElementCopyAttributeValue(
                self.observedApp, kAXFocusedWindowAttribute, (CFTypeRef *)&window);
        if (windowError == kAXErrorSuccess && window) {
            if (!self.observedWindow || !CFEqual(window, self.observedWindow)) {
                if (self.observedWindow) {
                    if (self.observer)
                        AXObserverRemoveNotification(self.observer, self.observedWindow,
                                                     kAXTitleChangedNotification);
                    CFRelease(self.observedWindow);
                }
                self.observedWindow = window;
                self.siteTitle = nil;
                if (self.observer)
                    AXObserverAddNotification(self.observer, window, kAXTitleChangedNotification,
                                              (__bridge void *)self);
            } else {
                CFRelease(window);
            }
            CFTypeRef value = NULL;
            if (AXUIElementCopyAttributeValue(self.observedWindow, kAXTitleAttribute, &value) ==
                    kAXErrorSuccess &&
                value) {
                if (CFGetTypeID(value) == CFStringGetTypeID())
                    title = [(__bridge NSString *)value copy];
                CFRelease(value);
            }
            if (ghostty)
                windowID = [NSString stringWithFormat:@"%d:%lu", self.activeApp.processIdentifier,
                                                       (unsigned long)CFHash(self.observedWindow)];
            else if ([title isEqualToString:self.siteTitle])
                // Navigation changes the title, so focus moving within the
                // same page keeps its site; Safari's lookup walks the AX tree.
                site = self.siteHost;
            else {
                site = windowSite(self.observedWindow, safari);
                self.siteTitle = title;
                self.siteHost = site;
            }
        }
    }
    switcher_context(identifier.UTF8String, title.UTF8String, windowID.UTF8String,
                     site.UTF8String);
}
- (void)layoutChanged:(NSNotification *)notification {
    TISInputSourceRef source = TISCopyCurrentKeyboardInputSource();
    emit(@"layout", sourceID(source), @"");
    if (source)
        CFRelease(source);
}
- (void)layoutsChanged:(NSNotification *)notification {
    emit(@"layouts", @"", @"");
}
- (void)menuWillOpen:(NSMenu *)menu {
    [self refreshTrust];
    emit(@"layouts", @"", @"");
}
- (void)pause:(id)sender {
    emit(@"pause", @"", @"");
}
- (void)pin:(NSMenuItem *)sender {
    emit(@"pin", sender.representedObject, @"");
}
- (void)forget:(NSMenuItem *)sender {
    emit(@"forget", sender.representedObject, @"");
}
- (void)toggleLogin:(id)sender {
    emit(@"login-toggle", @"", @"");
}
- (void)checkUpdates:(id)sender { emit(@"check-updates-manual", @"", @""); }
- (void)toggleAutoUpdates:(id)sender { emit(@"auto-updates", @"", @""); }
- (void)openUpdates:(id)sender { emit(@"open-updates", @"", @""); }
- (void)removePins:(id)sender {
    emit(@"clear-pins", @"", @"");
}
- (void)clear:(id)sender {
    emit(@"clear", @"", @"");
}
- (void)choose:(NSMenuItem *)sender {
    emit(@"default", sender.representedObject, @"");
}
- (void)permission:(id)sender {
    if (AXIsProcessTrusted()) {
        // Already granted: the permission can only be changed in System Settings.
        [NSWorkspace.sharedWorkspace
            openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?"
                                         @"Privacy_Accessibility"]];
        return;
    }
    NSDictionary *options = @{(__bridge NSString *)kAXTrustedCheckOptionPrompt : @YES};
    AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);
    [self refreshTrust];
}
- (void)quit:(id)sender {
    emit(@"quit", @"", @"");
}
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    emit(@"flush", @"", @"");
    return NSTerminateNow;
}
- (void)applicationWillTerminate:(NSNotification *)notification {
    [self removeObserver];
}
@end

static void axCallback(AXObserverRef observer, AXUIElementRef element, CFStringRef notification,
                       void *context) {
    (void)observer;
    (void)element;
    (void)notification;
    @autoreleasepool {
        [(__bridge Switcher *)context readContext];
    }
}

int native_run(int event_fd) {
    (void)event_fd;
    @autoreleasepool {
        delegate = [[Switcher alloc] init];
        [delegate installSignalHandlers];
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        app.delegate = delegate;
        [app finishLaunching];
        [app run];
    }
    return 0;
}

int native_set_layout(const char *id) {
    @autoreleasepool {
        NSDictionary *filter = @{(__bridge NSString *)kTISPropertyInputSourceID : @(id)};
        CFArrayRef sources = TISCreateInputSourceList((__bridge CFDictionaryRef)filter, false);
        int success =
            sources && CFArrayGetCount(sources) > 0 &&
            TISSelectInputSource((TISInputSourceRef)CFArrayGetValueAtIndex(sources, 0)) == noErr;
        if (sources)
            CFRelease(sources);
        return success;
    }
}

char *native_layouts(void) {
    @autoreleasepool {
        NSData *json = [NSJSONSerialization dataWithJSONObject:layoutList() options:0 error:NULL];
        return json ? strndup(json.bytes, json.length) : NULL;
    }
}
void native_free(char *value) { free(value); }

static void updateScopeMenus(NSString *json) {
    NSDictionary *menu =
        [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding]
                                        options:0
                                          error:NULL];
    NSArray *scopes = menu[@"scopes"];
    delegate.pinItem.title = menu[@"pin_title"] ?: @"Always Use Current Layout In";
    [delegate.pinItem.submenu removeAllItems];
    [delegate.forgetItem.submenu removeAllItems];
    for (NSDictionary *scope in scopes) {
        NSMenuItem *pin = [delegate.pinItem.submenu addItemWithTitle:scope[@"pin_label"]
                                                              action:@selector(pin:)
                                                       keyEquivalent:@""];
        pin.target = delegate;
        pin.representedObject = scope[@"id"];
        pin.state = [scope[@"pinned"] boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
        NSMenuItem *forget = [delegate.forgetItem.submenu addItemWithTitle:scope[@"label"]
                                                                    action:@selector(forget:)
                                                             keyEquivalent:@""];
        forget.target = delegate;
        forget.representedObject = scope[@"id"];
        forget.enabled = [scope[@"learned"] boolValue];
    }
    delegate.pinItem.enabled = scopes.count > 0;
    delegate.forgetItem.enabled = scopes.count > 0;
    NSUInteger pins = [menu[@"pins"] unsignedIntegerValue];
    delegate.removePinsItem.title =
        pins ? [NSString stringWithFormat:@"Remove All Pins (%lu)", (unsigned long)pins]
             : @"Remove All Pins";
    delegate.removePinsItem.enabled = pins > 0;
    delegate.autoUpdatesItem.state = [menu[@"auto_updates"] boolValue]
                                         ? NSControlStateValueOn : NSControlStateValueOff;
    delegate.checkUpdatesItem.enabled = ![menu[@"update_checking"] boolValue];
    NSString *updateLabel = menu[@"update_label"] ?: @"";
    delegate.updateResultItem.title = updateLabel;
    delegate.updateResultItem.hidden = !updateLabel.length;
    delegate.updateResultItem.enabled = [menu[@"update_available"] boolValue];
    NSString *login = menu[@"login"];
    delegate.loginItem.hidden = !login || [login isEqualToString:@"unsupported"];
    delegate.loginItem.state =
        [login isEqualToString:@"on"] ? NSControlStateValueOn : NSControlStateValueOff;
    delegate.loginItem.title = [login isEqualToString:@"approval"]
                                   ? @"Launch at Login (Approve in System Settings…)"
                                   : @"Launch at Login";

}

void native_update(const char *context, int paused, const char *error, const char *layouts_json,
                   const char *menu_json) {
    if (!delegate.status)
        return;
    delegate.status.button.appearsDisabled = paused;
    delegate.status.button.toolTip =
        [NSString stringWithFormat:@"Insomemo%@ — %@", paused ? @" (Paused)" : @"", @(context)];
    delegate.contextItem.title = [@"Active Context: " stringByAppendingString:@(context)];
    delegate.pauseItem.title = paused ? @"Resume Auto-Switching" : @"Pause Auto-Switching";
    delegate.errorItem.title = @(error);
    delegate.errorItem.hidden = strlen(error) == 0;
    NSString *json = @(layouts_json);
    if (![delegate.layoutsJSON isEqualToString:json]) {
        delegate.layoutsJSON = json;
        NSArray *layouts =
            [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding]
                                            options:0
                                              error:NULL];
        [delegate.layoutsMenu removeAllItems];
        for (NSDictionary *layout in layouts) {
            NSMenuItem *item = [delegate.layoutsMenu addItemWithTitle:layout[@"name"]
                                                               action:@selector(choose:)
                                                        keyEquivalent:@""];
            item.target = delegate;
            item.representedObject = layout[@"id"];
        }
    }
    NSString *menu = @(menu_json);
    if (![delegate.menuJSON isEqualToString:menu]) {
        delegate.menuJSON = menu;
        updateScopeMenus(menu);
    }
}
// SMAppService exists from macOS 13. A runtime class check stands in for
// @available, whose helper lives in clang's runtime that Rust does not link.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability-new"
int native_login_item(int action) {
    // SMAppService registers the running bundle; a bare binary has none.
    if (!NSClassFromString(@"SMAppService") ||
        ![NSBundle.mainBundle.bundlePath hasSuffix:@".app"])
        return -1;
    SMAppService *service = SMAppService.mainAppService;
    NSError *error = nil;
    if (action == 1 && service.status != SMAppServiceStatusEnabled &&
        service.status != SMAppServiceStatusRequiresApproval &&
        ![service registerAndReturnError:&error])
        NSLog(@"insomemo: cannot enable Launch at Login: %@", error);
    else if (action == 0 && service.status != SMAppServiceStatusNotRegistered &&
             ![service unregisterAndReturnError:&error])
        NSLog(@"insomemo: cannot disable Launch at Login: %@", error);
    // Registration may need the user's approval; take them straight there.
    if (action == 1 && service.status == SMAppServiceStatusRequiresApproval)
        [SMAppService openSystemSettingsLoginItems];
    switch (service.status) {
    case SMAppServiceStatusEnabled:
        return 1;
    case SMAppServiceStatusRequiresApproval:
        return 2;
    default:
        return 0;
    }
}
#pragma clang diagnostic pop
void native_indicate_switch(void) {
    if (!delegate.status)
        return;
    delegate.status.button.image = delegate.badgeImage;
    // Restarting the timer turns rapid tab flicking into one continuous badge.
    [delegate.badgeTimer invalidate];
    delegate.badgeTimer = [NSTimer timerWithTimeInterval:1.2
                                                 repeats:NO
                                                   block:^(NSTimer *timer) {
                                                       (void)timer;
                                                       delegate.badgeTimer = nil;
                                                       delegate.status.button.image =
                                                           delegate.trayImage;
                                                   }];
    [[NSRunLoop mainRunLoop] addTimer:delegate.badgeTimer forMode:NSRunLoopCommonModes];
}
void native_post_update_result(const char *kind, const char *value) {
    NSString *resultKind = @(kind), *resultValue = @(value);
    dispatch_async(dispatch_get_main_queue(), ^{
        emit(@"update-result", resultKind, resultValue);
    });
}
void native_show_update_result(const char *message) {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleInformational;
    alert.messageText = @"Update Check";
    alert.informativeText = @(message);
    [alert addButtonWithTitle:@"OK"];
    [NSApp activateIgnoringOtherApps:YES];
    [alert runModal];
}
void native_set_update_checks(int enabled) {
    [delegate.updateTimer invalidate];
    delegate.updateTimer = nil;
    if (!enabled) return;
    delegate.updateTimer = [NSTimer timerWithTimeInterval:86400 repeats:YES block:^(NSTimer *timer) {
        (void)timer;
        emit(@"check-updates", @"", @"");
    }];
    [[NSRunLoop mainRunLoop] addTimer:delegate.updateTimer forMode:NSRunLoopCommonModes];
}
void native_open_updates_page(void) {
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"https://github.com/vantalter/insomemo/releases"]];
}
void native_schedule_save(void) {
    [delegate.saveTimer invalidate];
    delegate.saveTimer = [NSTimer timerWithTimeInterval:2
                                                repeats:NO
                                                  block:^(NSTimer *timer) {
                                                      (void)timer;
                                                      emit(@"flush", @"", @"");
                                                  }];
    [[NSRunLoop mainRunLoop] addTimer:delegate.saveTimer forMode:NSRunLoopCommonModes];
}
void native_stop(void) {
    // Stop the run loop instead of terminate: so Rust can return and report errors.
    [NSApp stop:nil];
    [NSApp postEvent:[NSEvent otherEventWithType:NSEventTypeApplicationDefined
                                        location:NSZeroPoint
                                   modifierFlags:0
                                       timestamp:0
                                    windowNumber:0
                                         context:nil
                                         subtype:0
                                           data1:0
                                           data2:0]
             atStart:NO];
}
void native_alert(const char *message) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        [NSApp activateIgnoringOtherApps:YES];
        NSAlert *alert = [[NSAlert alloc] init];
        alert.alertStyle = NSAlertStyleCritical;
        alert.messageText = @"Insomemo stopped";
        alert.informativeText = @(message);
        [alert addButtonWithTitle:@"Quit"];
        [alert runModal];
    }
}
void native_hash(const char *text, char *output) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(text, (CC_LONG)strlen(text), digest);
    for (int i = 0; i < 8; i++)
        sprintf(output + i * 2, "%02x", digest[i]);
    output[16] = 0;
}
