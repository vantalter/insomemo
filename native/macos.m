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

// Sparkle checks for, downloads, and installs updates. Only the Xcode build
// links it; a plain cargo build runs without it and keeps Rust's update check,
// so Sparkle is found at run time and used through these declarations and KVC.
@interface NSObject (InsomemoSparkle)
- (instancetype)initWithStartingUpdater:(BOOL)startUpdater
                        updaterDelegate:(id)updaterDelegate
                     userDriverDelegate:(id)userDriverDelegate;
- (void)checkForUpdates:(id)sender;
@end

static NSString *const ProjectURL = @"https://github.com/vantalter/insomemo";
static NSString *const DonateURL = @"https://ko-fi.com/vantalter";

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

@class Settings;
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
@property NSMenuItem *updateResultItem;
@property Settings *settings;
/* SPUStandardUpdaterController when Sparkle is present, otherwise nil. */
@property id updaterController;
@property NSTimer *updateTimer;
@property NSImage *trayImage;
@property NSImage *badgeImage;
@property NSTimer *badgeTimer;
@property BOOL trusted;
// Last site read from observedWindow and the title it was read under.
@property NSString *siteTitle;
@property NSString *siteHost;
@property NSMenuItem *permissionItem;
- (void)permission:(id)sender;
- (void)checkUpdates:(id)sender;
@end

static Switcher *delegate;

static NSTextField *wrappingLabel(NSString *text) {
    NSTextField *label = [NSTextField wrappingLabelWithString:text];
    label.preferredMaxLayoutWidth = 400;
    return label;
}
/* Secondary text in a fixed-width column, so changing it wraps the text
 * instead of resizing the window. */
static NSTextField *noteLabel(void) {
    NSTextField *label = wrappingLabel(@"");
    label.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    label.textColor = NSColor.secondaryLabelColor;
    label.preferredMaxLayoutWidth = 260;
    [label.widthAnchor constraintEqualToConstant:260].active = YES;
    return label;
}
static NSButton *pushButton(NSString *title, id target, SEL action) {
    NSButton *button = [NSButton buttonWithTitle:title target:target action:action];
    button.bezelStyle = NSBezelStyleRounded;
    return button;
}
static NSStackView *column(NSArray<NSView *> *views) {
    NSStackView *stack = [NSStackView stackViewWithViews:views];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 6;
    return stack;
}
/* Label-and-control rows with right-aligned labels, as in System Settings'
 * older panes. A nil row is a separator across both columns. */
static NSGridView *form(NSArray *rows) {
    NSGridView *grid = [[NSGridView alloc] init];
    grid.rowSpacing = 12;
    grid.columnSpacing = 8;
    for (id row in rows) {
        if (row == NSNull.null) {
            NSBox *line = [[NSBox alloc] init];
            line.boxType = NSBoxSeparator;
            NSGridRow *separator = [grid addRowWithViews:@[ line, NSGridCell.emptyContentView ]];
            [separator mergeCellsInRange:NSMakeRange(0, 2)];
            separator.topPadding = separator.bottomPadding = 4;
            continue;
        }
        NSString *title = row[0];
        NSView *label = title.length ? [NSTextField labelWithString:title]
                                     : NSGridCell.emptyContentView;
        [grid addRowWithViews:@[ label, row[1] ]];
    }
    [grid columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
    grid.rowAlignment = NSGridRowAlignmentFirstBaseline;
    return grid;
}
/* A cup with a heart, in the outline style of the other tab symbols. */
static NSImage *donateIcon(void) {
    NSImage *icon = [NSImage
         imageWithSize:NSMakeSize(22, 20)
               flipped:NO
        drawingHandler:^BOOL(NSRect rect) {
            (void)rect;
            [NSColor.blackColor set];
            NSBezierPath *handle = [NSBezierPath
                bezierPathWithRoundedRect:NSMakeRect(13.5, 7, 6.5, 7.5)
                                  xRadius:3.25
                                  yRadius:3.25];
            handle.lineWidth = 1.5;
            [handle stroke];
            NSRect cup = NSMakeRect(2.5, 3.5, 13.5, 12.5);
            NSBezierPath *body = [NSBezierPath bezierPathWithRoundedRect:cup
                                                                 xRadius:4
                                                                 yRadius:4];
            // Clear the handle's inner half so it joins the cup's outline.
            NSGraphicsContext.currentContext.compositingOperation = NSCompositingOperationClear;
            [body fill];
            NSGraphicsContext.currentContext.compositingOperation =
                NSCompositingOperationSourceOver;
            body.lineWidth = 1.5;
            [body stroke];
            // Two lobes and a point, filled separately so their overlap stays solid.
            CGFloat x = NSMidX(cup), y = NSMidY(cup) + 0.4, r = 2;
            [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(x - 1.6 - r, y + 0.6 - r, 2 * r,
                                                              2 * r)] fill];
            [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(x + 1.6 - r, y + 0.6 - r, 2 * r,
                                                              2 * r)] fill];
            NSBezierPath *point = [NSBezierPath bezierPath];
            [point moveToPoint:NSMakePoint(x - 3.45, y - 0.1)];
            [point lineToPoint:NSMakePoint(x + 3.45, y - 0.1)];
            [point lineToPoint:NSMakePoint(x, y - 3.9)];
            [point closePath];
            [point fill];
            return YES;
        }];
    icon.template = YES;
    icon.accessibilityDescription = @"Donate";
    return icon;
}
static NSImage *symbol(NSString *name, NSString *description) {
    return [NSImage imageWithSystemSymbolName:name accessibilityDescription:description];
}
static NSTabViewItem *pane(NSString *title, NSImage *image, NSView *content) {
    NSViewController *controller = [[NSViewController alloc] init];
    controller.title = title;
    NSView *view = [[NSView alloc] init];
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [view addSubview:content];
    [NSLayoutConstraint activateConstraints:@[
        [content.topAnchor constraintEqualToAnchor:view.topAnchor constant:20],
        [content.bottomAnchor constraintEqualToAnchor:view.bottomAnchor constant:-20],
        [content.leadingAnchor constraintGreaterThanOrEqualToAnchor:view.leadingAnchor constant:30],
        [content.centerXAnchor constraintEqualToAnchor:view.centerXAnchor],
        [view.widthAnchor constraintEqualToConstant:500],
    ]];
    controller.view = view;
    [view layoutSubtreeIfNeeded];
    controller.preferredContentSize = view.fittingSize;
    NSTabViewItem *item = [NSTabViewItem tabViewItemWithViewController:controller];
    item.image = image;
    return item;
}

/* The Settings window: General, Updates, and Donate tabs in a toolbar. */
@interface Settings : NSObject <NSWindowDelegate>
@property NSWindow *window;
@property NSButton *loginBox;
@property NSTextField *loginNote;
@property NSTextField *trackingStatus;
@property NSTextField *trackingNote;
@property NSTextField *documentStatus;
@property NSTextField *documentNote;
@property NSButton *trackingButton;
@property NSTextField *updatesVersionLabel;
@property NSButton *autoBox;
@property NSPopUpButton *interval;
@property NSTextField *lastChecked;
@property NSButton *checkNow;
@property NSArray<NSGridRow *> *sparkleRows;
@property NSString *configDir;
/* Rust's latest menu state, which can arrive before the window exists. */
@property NSDictionary *menu;
@end

@implementation Settings
- (id)updater {
    return [delegate.updaterController valueForKey:@"updater"];
}
/* macOS's own "Automatically switch to a document's input source" option. */
static BOOL documentInputSources(void) {
    CFPreferencesAppSynchronize(CFSTR("com.apple.HIToolbox"));
    NSDictionary *properties = CFBridgingRelease(CFPreferencesCopyAppValue(
        CFSTR("AppleGlobalTextInputProperties"), CFSTR("com.apple.HIToolbox")));
    return [properties[@"TextInputGlobalPropertyPerContextInput"] boolValue];
}
- (NSView *)general {
    self.loginBox = [NSButton checkboxWithTitle:@"Launch at Login"
                                         target:self
                                         action:@selector(toggleLogin:)];
    self.loginNote = noteLabel();
    self.trackingStatus = [NSTextField labelWithString:@""];
    self.trackingNote = noteLabel();
    self.trackingButton = pushButton(@"", delegate, @selector(permission:));
    self.documentStatus = [NSTextField labelWithString:@""];
    self.documentNote = noteLabel();
    NSButton *inputSources =
        pushButton(@"Open Input Sources…", self, @selector(openInputSources:));
    NSStackView *links = [NSStackView stackViewWithViews:@[
        pushButton(@"GitHub Project", self, @selector(openProject:)),
        pushButton(@"Configuration Folder", self, @selector(openConfig:)),
    ]];
    return form(@[
        @[ @"Startup:", column(@[ self.loginBox, self.loginNote ]) ],
        @[
            @"Window / Tab Tracking:",
            column(@[ self.trackingStatus, self.trackingNote, self.trackingButton ])
        ],
        @[
            @"macOS Document Switching:",
            column(@[ self.documentStatus, self.documentNote, inputSources ])
        ],
        NSNull.null,
        @[ @"Links:", links ],
    ]);
}
- (NSView *)updates {
    self.autoBox = [NSButton checkboxWithTitle:@"Automatically check for updates"
                                        target:self
                                        action:@selector(toggleAutomatic:)];
    self.interval = [[NSPopUpButton alloc] init];
    for (NSArray *choice in @[ @[ @"Daily", @86400 ], @[ @"Weekly", @604800 ],
                               @[ @"Monthly", @2592000 ] ]) {
        [self.interval addItemWithTitle:choice[0]];
        self.interval.lastItem.tag = [choice[1] integerValue];
    }
    self.interval.target = self;
    self.interval.action = @selector(chooseInterval:);
    self.lastChecked = [NSTextField labelWithString:@""];
    self.checkNow = pushButton(@"Check Now…", delegate, @selector(checkUpdates:));
    self.updatesVersionLabel = [NSTextField labelWithString:@""];
    NSGridView *grid = form(@[
        @[ @"Software Update:", self.autoBox ],
        @[ @"", self.interval ],
        @[ @"Last checked:", self.lastChecked ],
        @[ @"", self.checkNow ],
        NSNull.null,
        @[ @"Version:", self.updatesVersionLabel ],
    ]);
    // Without Sparkle, Rust checks daily and keeps no check history.
    self.sparkleRows = @[ [grid rowAtIndex:1], [grid rowAtIndex:2] ];
    return grid;
}
- (NSView *)donate {
    // Ko-fi's logo from the app's asset catalog; a build without one shows a cup.
    NSImage *logo = [NSImage imageNamed:@"KoFi"];
    NSImageView *cup;
    if (logo) {
        cup = [NSImageView imageViewWithImage:logo];
        [cup.widthAnchor constraintEqualToConstant:50].active = YES;
        [cup.heightAnchor constraintEqualToAnchor:cup.widthAnchor
                                       multiplier:logo.size.height / logo.size.width]
            .active = YES;
    } else {
        NSImageSymbolConfiguration *large =
            [NSImageSymbolConfiguration configurationWithPointSize:34 weight:NSFontWeightRegular];
        cup = [NSImageView
            imageViewWithImage:[[NSImage imageWithSystemSymbolName:@"cup.and.saucer.fill"
                                           accessibilityDescription:@"Ko-fi"]
                                   imageWithSymbolConfiguration:large]];
        cup.contentTintColor = NSColor.controlAccentColor;
    }
    cup.imageScaling = NSImageScaleProportionallyUpOrDown;
    NSButton *support = pushButton(@"Support", self, @selector(openDonate:));
    support.keyEquivalent = @"\r";
    NSTextField *name = [NSTextField labelWithString:@"Ko-fi"];
    name.font = [NSFont boldSystemFontOfSize:NSFont.systemFontSize];
    NSStackView *kofi = [NSStackView stackViewWithViews:@[ cup, name, support ]];
    kofi.orientation = NSUserInterfaceLayoutOrientationVertical;
    kofi.spacing = 8;
    NSStackView *stack = column(@[
        wrappingLabel(@"Insomemo is free and open source, and every feature is available to "
                      @"everyone."),
        wrappingLabel(@"Donations help keep it developed. If you would like to support the work, "
                      @"you can buy a coffee on Ko-fi."),
        kofi,
    ]);
    stack.spacing = 16;
    [stack setCustomSpacing:24 afterView:stack.arrangedSubviews[1]];
    [kofi.centerXAnchor constraintEqualToAnchor:stack.centerXAnchor].active = YES;
    return stack;
}
- (void)build {
    NSTabViewController *tabs = [[NSTabViewController alloc] init];
    tabs.tabStyle = NSTabViewControllerTabStyleToolbar;
    [tabs addTabViewItem:pane(@"General", symbol(@"gearshape", @"General"), [self general])];
    [tabs addTabViewItem:pane(@"Updates", symbol(@"arrow.triangle.2.circlepath", @"Updates"),
                              [self updates])];
    [tabs addTabViewItem:pane(@"Donate", donateIcon(), [self donate])];
    self.window = [NSWindow windowWithContentViewController:tabs];
    self.window.styleMask = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable;
    self.window.releasedWhenClosed = NO;
    self.window.delegate = self;
    [self.window center];
}
- (void)show {
    if (!self.window)
        [self build];
    [self refresh:nil];
    [NSApp activateIgnoringOtherApps:YES];
    [self.window makeKeyAndOrderFront:nil];
}
- (void)windowDidBecomeKey:(NSNotification *)notification {
    [self refresh:nil];
}
/* Updates the controls from Rust's menu state; nil reuses the last state. */
- (void)refresh:(NSDictionary *)menu {
    if (menu)
        self.menu = menu;
    menu = self.menu;
    if (!self.window)
        return;
    if (menu) {
        NSString *login = menu[@"login"];
        BOOL supported = login && ![login isEqualToString:@"unsupported"];
        self.loginBox.enabled = supported;
        self.loginBox.state = [login isEqualToString:@"on"] || [login isEqualToString:@"approval"]
                                  ? NSControlStateValueOn
                                  : NSControlStateValueOff;
        self.loginNote.stringValue =
            !supported ? @"Requires macOS 13 or newer and the Insomemo app."
            : [login isEqualToString:@"approval"]
                ? @"Approve Insomemo in System Settings → General → Login Items."
                : @"";
        self.loginNote.hidden = !self.loginNote.stringValue.length;
        self.autoBox.state = [menu[@"auto_updates"] boolValue] ? NSControlStateValueOn
                                                               : NSControlStateValueOff;
        NSString *version = menu[@"version"] ?: @"";
        self.updatesVersionLabel.stringValue = version;
        self.configDir = menu[@"config_dir"];
        // Rust's own check, without Sparkle, runs one request at a time.
        self.checkNow.enabled = ![menu[@"update_checking"] boolValue];
    }
    BOOL trusted = AXIsProcessTrusted();
    self.trackingStatus.stringValue = trusted ? @"On" : @"Off";
    self.trackingNote.stringValue =
        trusted ? @"Layouts are remembered for each window and tab."
                : @"Layouts are remembered for each app only. Grant Accessibility access to "
                  @"tell windows and tabs apart.";
    self.trackingButton.title = trusted ? @"Open Privacy Settings…" : @"Grant Access…";
    BOOL documents = documentInputSources();
    self.documentStatus.stringValue = documents ? @"On" : @"Off";
    self.documentNote.stringValue =
        documents ? @"macOS's “Automatically switch to a document's input source” is on. It "
                    @"switches layouts too, so the two compete; turn it off to let Insomemo "
                    @"choose."
                  : @"macOS's “Automatically switch to a document's input source” is off, as "
                    @"it should be. It keeps one layout per document window, only in apps "
                    @"that support it. Insomemo learns per window, tab, site, and app in "
                    @"every app.";
    id updater = [self updater];
    for (NSGridRow *row in self.sparkleRows)
        row.hidden = !updater;
    if (updater) {
        NSInteger interval = [[updater valueForKey:@"updateCheckInterval"] integerValue];
        [self.interval selectItemWithTag:interval];
        if (self.interval.indexOfSelectedItem < 0)
            [self.interval selectItemAtIndex:0];
        self.interval.enabled = self.autoBox.state == NSControlStateValueOn;
        NSDate *date = [updater valueForKey:@"lastUpdateCheckDate"];
        self.lastChecked.stringValue =
            date ? [NSDateFormatter localizedStringFromDate:date
                                                  dateStyle:NSDateFormatterMediumStyle
                                                  timeStyle:NSDateFormatterMediumStyle]
                 : @"Never";
    }
}
- (void)toggleLogin:(id)sender {
    emit(@"login-toggle", @"", @"");
}
- (void)toggleAutomatic:(id)sender {
    emit(@"auto-updates", @"", @"");
}
- (void)chooseInterval:(NSPopUpButton *)sender {
    [[self updater] setValue:@((double)sender.selectedTag) forKey:@"updateCheckInterval"];
}
- (void)openProject:(id)sender {
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:ProjectURL]];
}
- (void)openConfig:(id)sender {
    if (self.configDir.length)
        [NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:self.configDir
                                                         isDirectory:YES]];
}
- (void)openInputSources:(id)sender {
    // The Keyboard settings' input source sheet, where macOS's own option is;
    // this older form of the link also works in macOS 12's System Preferences.
    [NSWorkspace.sharedWorkspace
        openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.keyboard?"
                                     @"InputSources"]];
}
- (void)openDonate:(id)sender {
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:DonateURL]];
}
@end

/* Shows a menu item as a line of information: a plain label in the secondary
 * colour, aligned with the item titles, as Apple's own menu bar extras show
 * status. macOS dims a disabled item's text whatever its colour, but not a
 * custom view. */
static void showInfo(NSMenuItem *item, NSString *text) {
    if (item.view && [item.title isEqualToString:text])
        return;
    item.title = text;
    NSTextField *label = [NSTextField labelWithString:text];
    label.font = [NSFont menuFontOfSize:0];
    label.textColor = NSColor.secondaryLabelColor;
    [label sizeToFit];
    // Leaves room for the checkmark column, so the text lines up with titles.
    CGFloat leading = 17, trailing = 16, height = 22;
    NSView *view = [[NSView alloc]
        initWithFrame:NSMakeRect(0, 0, ceil(label.frame.size.width) + leading + trailing, height)];
    [label setFrameOrigin:NSMakePoint(leading, floor((height - label.frame.size.height) / 2))];
    [view addSubview:label];
    item.view = view;
}

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
    Class sparkle = NSClassFromString(@"SPUStandardUpdaterController");
    if (sparkle)
        self.updaterController = [[sparkle alloc] initWithStartingUpdater:YES
                                                          updaterDelegate:nil
                                                       userDriverDelegate:self];
    self.settings = [[Settings alloc] init];
    // Accessory apps have no visible menu bar, but its key equivalents still
    // work, so Command-W closes the Settings window.
    NSMenu *mainMenu = [[NSMenu alloc] init];
    NSMenu *appMenu = [[NSMenu alloc] init];
    [appMenu addItemWithTitle:@"Close Window" action:@selector(performClose:) keyEquivalent:@"w"];
    [mainMenu addItemWithTitle:@"Insomemo" action:nil keyEquivalent:@""].submenu = appMenu;
    NSApp.mainMenu = mainMenu;
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
    self.contextItem = [menu addItemWithTitle:@"" action:nil keyEquivalent:@""];
    self.contextItem.enabled = NO;
    showInfo(self.contextItem, @"Active Context: —");
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
    self.updateResultItem = [menu addItemWithTitle:@""
                                            action:@selector(openUpdates:)
                                     keyEquivalent:@""];
    self.updateResultItem.target = self;
    self.updateResultItem.hidden = YES;
    NSMenuItem *settings = [menu addItemWithTitle:@"Settings…"
                                           action:@selector(showSettings:)
                                    keyEquivalent:@","];
    settings.target = self;
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
    // Once granted, the permission's state lives in Settings.
    self.permissionItem.hidden = trusted;
    [self.settings refresh:nil];
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
- (void)checkUpdates:(id)sender {
    if (self.updaterController)
        [self.updaterController checkForUpdates:sender];
    else
        emit(@"check-updates-manual", @"", @"");
}
- (void)openUpdates:(id)sender {
    emit(@"open-updates", @"", @"");
}
- (void)showSettings:(id)sender {
    [self.settings show];
}
// Opening the app again from Finder or Spotlight while it runs shows Settings.
- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)visible {
    [self.settings show];
    return NO;
}
// Sparkle's user driver: a menu-bar app has no Dock icon to badge, so a
// scheduled update is shown in its own window right away.
- (BOOL)supportsGentleScheduledUpdateReminders {
    return YES;
}
- (BOOL)standardUserDriverShouldHandleShowingScheduledUpdate:(id)update
                                        andInImmediateFocus:(BOOL)immediateFocus {
    return YES;
}
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
    // Rust's check result; Sparkle shows its own windows instead.
    NSString *updateLabel = delegate.updaterController ? @"" : menu[@"update_label"] ?: @"";
    delegate.updateResultItem.title = updateLabel;
    delegate.updateResultItem.hidden = !updateLabel.length;
    delegate.updateResultItem.enabled = [menu[@"update_available"] boolValue];
    [delegate.settings refresh:menu];
}

void native_update(const char *context, int paused, const char *error, const char *layouts_json,
                   const char *menu_json) {
    if (!delegate.status)
        return;
    delegate.status.button.appearsDisabled = paused;
    delegate.status.button.toolTip =
        [NSString stringWithFormat:@"Insomemo%@ — %@", paused ? @" (Paused)" : @"", @(context)];
    showInfo(delegate.contextItem, [@"Active Context: " stringByAppendingString:@(context)]);
    delegate.pauseItem.title = paused ? @"Resume Auto-Switching" : @"Pause Auto-Switching";
    showInfo(delegate.errorItem, @(error));
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
int native_set_update_checks(int enabled) {
    if (delegate.updaterController) {
        // Sparkle keeps its own schedule; state.json stays the setting's source.
        [[delegate.updaterController valueForKey:@"updater"]
            setValue:@(enabled != 0)
              forKey:@"automaticallyChecksForUpdates"];
        return 1;
    }
    [delegate.updateTimer invalidate];
    delegate.updateTimer = nil;
    if (!enabled)
        return 0;
    delegate.updateTimer = [NSTimer timerWithTimeInterval:86400 repeats:YES block:^(NSTimer *timer) {
        (void)timer;
        emit(@"check-updates", @"", @"");
    }];
    [[NSRunLoop mainRunLoop] addTimer:delegate.updateTimer forMode:NSRunLoopCommonModes];
    return 0;
}
void native_open_updates_page(void) {
    NSString *releases = [ProjectURL stringByAppendingString:@"/releases"];
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:releases]];
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
