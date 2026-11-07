#include "bridge.h"
#include "tray_icon.h"
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Carbon/Carbon.h>
#import <CommonCrypto/CommonDigest.h>
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

static BOOL addressFieldLabel(AXUIElementRef element) {
    CFStringRef attributes[] = {kAXIdentifierAttribute, kAXDescriptionAttribute,
                                kAXTitleAttribute, kAXHelpAttribute,
                                kAXPlaceholderValueAttribute};
    NSArray<NSString *> *terms = @[@"address", @"url", @"omnibox", @"location", @"smart search"];
    for (NSUInteger index = 0; index < sizeof(attributes) / sizeof(attributes[0]); index++) {
        CFTypeRef value = NULL;
        if (AXUIElementCopyAttributeValue(element, attributes[index], &value) != kAXErrorSuccess ||
            !value)
            continue;
        BOOL match = NO;
        if (CFGetTypeID(value) == CFStringGetTypeID()) {
            NSString *label = [(__bridge NSString *)value lowercaseString];
            for (NSString *term in terms)
                if ([label containsString:term]) {
                    match = YES;
                    break;
                }
        }
        CFRelease(value);
        if (match)
            return YES;
    }
    return NO;
}

static BOOL focusedBrowserAddressField(AXUIElementRef app) {
    AXUIElementRef element = NULL;
    if (AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute,
                                      (CFTypeRef *)&element) != kAXErrorSuccess || !element)
        return NO;
    CFTypeRef role = NULL;
    BOOL textField = NO;
    if (AXUIElementCopyAttributeValue(element, kAXRoleAttribute, &role) == kAXErrorSuccess && role) {
        textField = CFEqual(role, kAXTextFieldRole) || CFEqual(role, kAXComboBoxRole) ||
                    CFEqual(role, kAXTextAreaRole);
        CFRelease(role);
    }
    // Labels identify address fields outside a toolbar, but only editable
    // elements qualify; a focused "Copy URL" button must not switch layouts.
    if (!textField) {
        CFRelease(element);
        return NO;
    }
    BOOL namedAddressField = addressFieldLabel(element);
    BOOL toolbar = NO;
    BOOL webArea = NO;
    // Browser chrome varies by browser. Exclude fields inside webpage content.
    for (NSUInteger depth = 0; depth < 16; depth++) {
        role = NULL;
        if (AXUIElementCopyAttributeValue(element, kAXRoleAttribute, &role) == kAXErrorSuccess &&
            role) {
            toolbar |= CFEqual(role, kAXToolbarRole);
            webArea |= CFEqual(role, CFSTR("AXWebArea"));
            CFRelease(role);
            if (webArea)
                break;
        }
        AXUIElementRef parent = NULL;
        if (AXUIElementCopyAttributeValue(element, kAXParentAttribute,
                                          (CFTypeRef *)&parent) != kAXErrorSuccess || !parent)
            break;
        CFRelease(element);
        element = parent;
    }
    CFRelease(element);
    return !webArea && (toolbar || namedAddressField);
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
@property NSMenuItem *addressBarItem;
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
@property BOOL trusted;
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
    self.addressBarItem = [menu addItemWithTitle:@"English in Browser Address/Search Bar"
                                         action:@selector(toggleAddressBar:)
                                  keyEquivalent:@""];
    self.addressBarItem.target = self;
    NSMenuItem *defaults = [menu addItemWithTitle:@"Force Default Layout"
                                           action:nil
                                    keyEquivalent:@""];
    self.layoutsMenu = [[NSMenu alloc] initWithTitle:@"Layouts"];
    defaults.submenu = self.layoutsMenu;
    NSMenuItem *clear = [menu addItemWithTitle:@"Clear Cache"
                                        action:@selector(clear:)
                                 keyEquivalent:@""];
    clear.target = self;
    NSMenuItem *permission = [menu addItemWithTitle:@"Enable Window / Tab Tracking…"
                                             action:@selector(permission:)
                                      keyEquivalent:@""];
    permission.target = self;
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
    self.trusted = AXIsProcessTrusted();
    emit(@"ready", @"", @"");
    [self layoutChanged:nil];
    [self activated:nil];
    if (!self.trusted)
        emit(@"error", @"App tracking active. Grant Accessibility access for window/tab tracking.",
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
    self.trusted = AXIsProcessTrusted();
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
    NSString *identifier = self.activeApp.bundleIdentifier ?: self.activeApp.executableURL.path ?: self.activeApp.localizedName;
    BOOL ghostty = [identifier isEqualToString:@"com.mitchellh.ghostty"];
    BOOL browser = [identifier isEqualToString:@"com.google.Chrome"] ||
                   [identifier isEqualToString:@"com.apple.Safari"] ||
                   [identifier isEqualToString:@"org.mozilla.firefox"];
    BOOL addressBar = browser && self.observedApp && focusedBrowserAddressField(self.observedApp);
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
                    if (self.observer)
                        AXObserverRemoveNotification(self.observer, self.observedWindow,
                                                     kAXFocusedUIElementChangedNotification);
                    CFRelease(self.observedWindow);
                }
                self.observedWindow = window;
                if (self.observer)
                    AXObserverAddNotification(self.observer, window, kAXTitleChangedNotification,
                                              (__bridge void *)self);
                if (self.observer)
                    AXObserverAddNotification(self.observer, window,
                                              kAXFocusedUIElementChangedNotification,
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
        }
    }
    switcher_context(identifier.UTF8String, title.UTF8String, windowID.UTF8String, addressBar);
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
    if (AXIsProcessTrusted() != self.trusted)
        [self activated:nil];
    emit(@"layouts", @"", @"");
}
- (void)pause:(id)sender {
    emit(@"pause", @"", @"");
}
- (void)toggleAddressBar:(id)sender {
    emit(@"address-toggle", @"", @"");
    dispatch_async(dispatch_get_main_queue(), ^{
        [self readContext];
    });
}
- (void)clear:(id)sender {
    emit(@"clear", @"", @"");
}
- (void)choose:(NSMenuItem *)sender {
    emit(@"default", sender.representedObject, @"");
}
- (void)permission:(id)sender {
    NSDictionary *options = @{(__bridge NSString *)kAXTrustedCheckOptionPrompt : @YES};
    AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);
    [self activated:nil];
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
    @autoreleasepool {
        Switcher *switcher = (__bridge Switcher *)context;
        if (CFEqual(notification, kAXFocusedUIElementChangedNotification)) {
            // Some browsers post focus before updating AXFocusedUIElement.
            dispatch_async(dispatch_get_main_queue(), ^{
                [switcher readContext];
            });
        } else {
            [switcher readContext];
        }
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

void native_update(const char *context, int paused, int address_bar_enabled, const char *error,
                   const char *layouts_json) {
    if (!delegate.status)
        return;
    delegate.status.button.appearsDisabled = paused;
    delegate.status.button.toolTip =
        [NSString stringWithFormat:@"Insomemo%@ — %@", paused ? @" (Paused)" : @"", @(context)];
    delegate.contextItem.title = [@"Active Context: " stringByAppendingString:@(context)];
    delegate.pauseItem.title = paused ? @"Resume Auto-Switching" : @"Pause Auto-Switching";
    delegate.addressBarItem.state =
        address_bar_enabled ? NSControlStateValueOn : NSControlStateValueOff;
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
void native_hash(const char *text, char *output) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(text, (CC_LONG)strlen(text), digest);
    for (int i = 0; i < 8; i++)
        sprintf(output + i * 2, "%02x", digest[i]);
    output[16] = 0;
}
