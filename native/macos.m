#include "bridge.h"
#include "tray_icon.h"
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Carbon/Carbon.h>
#import <CommonCrypto/CommonDigest.h>
#import <ServiceManagement/ServiceManagement.h>
#include <fcntl.h>
#include <signal.h>
#include <stdarg.h>
#include <sys/stat.h>
#include <sys/time.h>

/* Event log for diagnosing switching problems, off by default and turned on in
 * Settings → General. It writes ~/Library/Logs/Insomemo/insomemo.log. Titles and
 * sites appear only as short hashes, so the log can be shared. */
static NSString *const DebugLogKey = @"DebugLog";
/* Past this size the log starts over, keeping the previous one beside it. */
static const long DebugLogLimit = 1024 * 1024;
/* A random secret mixed into the log's hashes, kept until Clear Log. Without
 * it, anyone holding the log could hash a guessed site or title and look for
 * it; with it, the codes only show which events share a window or site. */
static NSString *const DebugSaltKey = @"DebugLogSalt";
static FILE *debugFile;
/* What the last context line recorded, so repeats of it are skipped. */
static NSString *loggedContext;
static void updateDebugLog(void);
static NSString *debugLogPath(void) {
    return [NSHomeDirectory()
        stringByAppendingPathComponent:@"Library/Logs/Insomemo/insomemo.log"];
}
static NSString *debugLogBackupPath(void) {
    return [debugLogPath() stringByAppendingString:@".1"];
}
/* Versions up to 0.3.3 wrote ~/Library/Logs/Insomemo.log and Insomemo.log.old.
 * They move into the folder at launch, whether or not logging is on, so Clear
 * Log can always remove them; where a newer log is already there, the older
 * one is deleted. */
static void moveOldDebugLogs(void) {
    NSFileManager *files = NSFileManager.defaultManager;
    NSString *old = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/Insomemo.log"];
    NSArray *moves = @[
        @[ old, debugLogPath() ],
        @[ [old stringByAppendingString:@".old"], debugLogBackupPath() ],
    ];
    for (NSArray *move in moves) {
        if (![files fileExistsAtPath:move[0]])
            continue;
        [files createDirectoryAtPath:[move[1] stringByDeletingLastPathComponent]
            withIntermediateDirectories:YES
                             attributes:nil
                                  error:NULL];
        if ([files fileExistsAtPath:move[1]])
            [files removeItemAtPath:move[0] error:NULL];
        else if ([files moveItemAtPath:move[0] toPath:move[1] error:NULL])
            chmod([move[1] fileSystemRepresentation], 0600);
    }
}
static void debugLog(const char *format, ...) __attribute__((format(printf, 1, 2)));
static void debugLog(const char *format, ...) {
    if (!debugFile)
        return;
    struct timeval now;
    gettimeofday(&now, NULL);
    struct tm local;
    localtime_r(&now.tv_sec, &local);
    char stamp[32];
    strftime(stamp, sizeof stamp, "%Y-%m-%dT%H:%M:%S", &local);
    // ISO 8601 with the UTC offset, so logs from any time zone, or across a
    // daylight saving change, read unambiguously.
    long offset = labs(local.tm_gmtoff) / 60;
    fprintf(debugFile, "%s.%03d%c%02ld:%02ld ", stamp, (int)(now.tv_usec / 1000),
            local.tm_gmtoff < 0 ? '-' : '+', offset / 60, offset % 60);
    va_list arguments;
    va_start(arguments, format);
    vfprintf(debugFile, format, arguments);
    va_end(arguments);
    fputc('\n', debugFile);
    fflush(debugFile);
    // Insomemo can run for weeks, so the size is also checked while writing.
    if (ftell(debugFile) > DebugLogLimit) {
        fclose(debugFile);
        debugFile = NULL;
        updateDebugLog();
    }
}
/* Opens or closes the log to match the setting. */
static void updateDebugLog(void) {
    moveOldDebugLogs();
    BOOL enabled = [NSUserDefaults.standardUserDefaults boolForKey:DebugLogKey];
    if (!enabled && debugFile) {
        debugLog("log off");
        fclose(debugFile);
        debugFile = NULL;
    }
    if (!enabled || debugFile)
        return;
    NSString *path = debugLogPath();
    [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:NULL];
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:path
                                                                              error:NULL];
    if ((long long)attributes.fileSize > DebugLogLimit)
        rename(path.fileSystemRepresentation, debugLogBackupPath().fileSystemRepresentation);
    // Readable only by the user, also when an older version created it.
    int fd = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND, 0600);
    if (fd >= 0) {
        fchmod(fd, 0600);
        debugFile = fdopen(fd, "a");
        if (!debugFile)
            close(fd);
    }
    if (!debugFile)
        return;
    // A new file starts with the current context, even if it has not changed.
    loggedContext = nil;
    NSString *version = NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"];
    debugLog("log on, Insomemo %s, macOS %s", (version ?: @"(no bundle)").UTF8String,
             NSProcessInfo.processInfo.operatingSystemVersionString.UTF8String);
}
/* Deletes the log and the previous one; logging, if on, continues in a new file. */
static void clearDebugLog(void) {
    if (debugFile) {
        fclose(debugFile);
        debugFile = NULL;
    }
    NSString *path = debugLogPath();
    [NSFileManager.defaultManager removeItemAtPath:path error:NULL];
    [NSFileManager.defaultManager removeItemAtPath:debugLogBackupPath()
                                             error:NULL];
    // A new log gets new codes, unrelated to those in logs already shared.
    [NSUserDefaults.standardUserDefaults removeObjectForKey:DebugSaltKey];
    updateDebugLog();
}
/* A short stand-in for a title or site, the same throughout one log; "-" when
 * there is none. */
static const char *debugHash(NSString *text) {
    if (!text.length)
        return "-";
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSString *salt = [defaults stringForKey:DebugSaltKey];
    if (!salt.length) {
        unsigned char bytes[16];
        arc4random_buf(bytes, sizeof bytes);
        NSMutableString *hex = [NSMutableString string];
        for (size_t i = 0; i < sizeof bytes; i++)
            [hex appendFormat:@"%02x", bytes[i]];
        salt = hex;
        [defaults setObject:salt forKey:DebugSaltKey];
    }
    char hash[17];
    native_hash([NSString stringWithFormat:@"%@\n%@", salt, text].UTF8String, hash);
    hash[8] = 0;
    // Each call gets its own string, so one log line can hold several hashes.
    return @(hash).UTF8String;
}

static void emit(NSString *kind, NSString *first, NSString *second) {
    if (![kind isEqualToString:@"layouts"] && ![kind isEqualToString:@"flush"])
        debugLog("event %s %s", kind.UTF8String, (first ?: @"").UTF8String);
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
/* The menu's warning while Accessibility is missing; choosing it opens Settings. */
static NSString *const TrustWarning = @"Window / Tab Tracking Is Off — Open Settings…";

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
// Whether the current window was already given time to report its title.
@property BOOL waitedForTitle;
- (void)permission:(id)sender;
- (void)checkUpdates:(id)sender;
@end

static Switcher *delegate;
/* The layout Insomemo last selected and when, to tell macOS's late reports of
 * the previous layout from the user's own changes. */
static NSString *selectedLayout;
static CFAbsoluteTime selectedAt;
static const CFTimeInterval SelectionSettleTime = 0.15;
/* How long a window may take to report its title; most need under 0.3 s. */
static const CFTimeInterval TitleWaitTime = 0.3;

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

/* The Settings window: General, Updates, and Support tabs in a toolbar. */
@interface Settings : NSObject <NSWindowDelegate>
@property NSWindow *window;
@property NSButton *loginBox;
@property NSTextField *loginNote;
@property NSTextField *trackingStatus;
@property NSTextField *trackingNote;
@property NSTextField *documentStatus;
@property NSTextField *documentNote;
@property NSButton *trackingButton;
@property NSButton *debugBox;
@property NSButton *showLog;
@property NSButton *clearLog;
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
    self.debugBox = [NSButton checkboxWithTitle:@"Record switching events"
                                         target:self
                                         action:@selector(toggleDebugLog:)];
    NSTextField *debugNote = noteLabel();
    debugNote.stringValue = @"Writes ~/Library/Logs/Insomemo/insomemo.log for bug reports. "
                            @"Window titles and sites appear only as codes that only this Mac "
                            @"can match, never as text.";
    self.showLog = pushButton(@"Show Log", self, @selector(showDebugLog:));
    self.clearLog = pushButton(@"Clear Log", self, @selector(clearDebugLog:));
    NSStackView *logButtons = [NSStackView stackViewWithViews:@[ self.showLog, self.clearLog ]];
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
        @[ @"Debug Log:", column(@[ self.debugBox, debugNote, logButtons ]) ],
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
- (NSView *)support {
    // Ko-fi's logo from the app's asset catalog; a build without one shows a cup.
    NSImage *logo = [NSImage imageNamed:@"KoFi"];
    NSImageView *cup;
    if (logo) {
        cup = [NSImageView imageViewWithImage:logo];
        [cup.widthAnchor constraintEqualToAnchor:cup.heightAnchor
                                      multiplier:logo.size.width / logo.size.height]
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
    // Both images get the same height, so the buttons below line up.
    [cup.heightAnchor constraintEqualToConstant:40].active = YES;
    // GitHub's mark from Primer Octicons (MIT), a template drawn in the text
    // colour; a build without it shows a star.
    NSImage *mark = [NSImage imageNamed:@"GitHub"]
                        ?: [NSImage imageWithSystemSymbolName:@"star"
                                     accessibilityDescription:nil];
    mark.accessibilityDescription = @"GitHub";
    NSImageView *github = [NSImageView imageViewWithImage:mark];
    github.contentTintColor = NSColor.labelColor;
    github.imageScaling = NSImageScaleProportionallyUpOrDown;
    [github.heightAnchor constraintEqualToConstant:40].active = YES;
    [github.widthAnchor constraintEqualToAnchor:github.heightAnchor].active = YES;
    NSButton *starButton = pushButton(@"Star on GitHub", self, @selector(openProject:));
    NSButton *coffeeButton = pushButton(@"Buy a Coffee", self, @selector(openDonate:));
    [starButton.widthAnchor constraintEqualToConstant:150].active = YES;
    [coffeeButton.widthAnchor constraintEqualToConstant:150].active = YES;
    NSStackView *(^option)(NSArray<NSView *> *) = ^NSStackView *(NSArray<NSView *> *views) {
        NSStackView *group = [NSStackView stackViewWithViews:views];
        group.orientation = NSUserInterfaceLayoutOrientationVertical;
        group.alignment = NSLayoutAttributeCenterX;
        group.spacing = 10;
        return group;
    };
    NSStackView *choices = [NSStackView
        stackViewWithViews:@[ option(@[ github, starButton ]), option(@[ cup, coffeeButton ]) ]];
    choices.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    choices.alignment = NSLayoutAttributeTop;
    choices.distribution = NSStackViewDistributionFillEqually;
    choices.spacing = 24;
    NSStackView *stack = column(@[
        wrappingLabel(@"Insomemo is free and open source. Every feature is available to everyone."),
        wrappingLabel(@"If you find it useful, star the project on GitHub or support its "
                      @"development with a coffee on Ko-fi."),
        choices,
    ]);
    stack.spacing = 16;
    [stack setCustomSpacing:26 afterView:stack.arrangedSubviews[1]];
    [choices.widthAnchor constraintEqualToConstant:380].active = YES;
    return stack;
}
- (void)build {
    NSTabViewController *tabs = [[NSTabViewController alloc] init];
    tabs.tabStyle = NSTabViewControllerTabStyleToolbar;
    [tabs addTabViewItem:pane(@"General", symbol(@"gearshape", @"General"), [self general])];
    [tabs addTabViewItem:pane(@"Updates", symbol(@"arrow.triangle.2.circlepath", @"Updates"),
                              [self updates])];
    [tabs addTabViewItem:pane(@"Support", symbol(@"heart", @"Support"), [self support])];
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
    self.debugBox.state = debugFile ? NSControlStateValueOn : NSControlStateValueOff;
    BOOL logged = [NSFileManager.defaultManager fileExistsAtPath:debugLogPath()];
    self.showLog.enabled = logged;
    self.clearLog.enabled =
        logged || [NSFileManager.defaultManager
                      fileExistsAtPath:debugLogBackupPath()];
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
- (void)toggleDebugLog:(NSButton *)sender {
    [NSUserDefaults.standardUserDefaults setBool:sender.state == NSControlStateValueOn
                                          forKey:DebugLogKey];
    updateDebugLog();
    debugLog("accessibility %s", AXIsProcessTrusted() ? "granted" : "missing");
    [self refresh:nil];
}
- (void)showDebugLog:(id)sender {
    // The log selected in its folder, ready to attach to a bug report.
    [NSWorkspace.sharedWorkspace
        activateFileViewerSelectingURLs:@[ [NSURL fileURLWithPath:debugLogPath()] ]];
}
- (void)clearDebugLog:(id)sender {
    clearDebugLog();
    [self refresh:nil];
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
    self.contextItem = [menu addItemWithTitle:@"Active Context: —" action:nil keyEquivalent:@""];
    self.contextItem.enabled = NO;
    self.errorItem = [menu addItemWithTitle:@""
                                     action:@selector(showGeneral:)
                                keyEquivalent:@""];
    self.errorItem.target = self;
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
    // AppKit suspends distributed notifications while the app is inactive once
    // it has been active, as after Settings was open. Insomemo is inactive
    // nearly always, so layout changes must arrive at once: a coalesced one
    // arrives late, is learned for whatever context is active by then, and
    // leaves the remembered current layout stale, which skips restores.
    [[NSDistributedNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(layoutChanged:)
               name:(__bridge NSString *)kTISNotifySelectedKeyboardInputSourceChanged
             object:nil
 suspensionBehavior:NSNotificationSuspensionBehaviorDeliverImmediately];
    [[NSDistributedNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(layoutsChanged:)
               name:(__bridge NSString *)kTISNotifyEnabledKeyboardInputSourcesChanged
             object:nil
 suspensionBehavior:NSNotificationSuspensionBehaviorDeliverImmediately];
    // Posted whenever any app's Accessibility permission changes in System
    // Settings, so the menu and tracking follow it without polling.
    [[NSDistributedNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(accessibilityChanged:)
               name:@"com.apple.accessibility.api"
             object:nil
 suspensionBehavior:NSNotificationSuspensionBehaviorDeliverImmediately];
    self.trusted = AXIsProcessTrusted();
    debugLog("accessibility %s", self.trusted ? "granted" : "missing");
    emit(@"ready", @"", @"");
    [self layoutChanged:nil];
    [self activated:nil];
    [self refreshTrust];
    [self reportTrust];
    // Without Accessibility, Insomemo remembers layouts per app only. Settings
    // explains this and offers access once, on the first launch without it.
    NSString *shown = @"ShowedTrackingSettings";
    if (!self.trusted && ![NSUserDefaults.standardUserDefaults boolForKey:shown]) {
        [NSUserDefaults.standardUserDefaults setBool:YES forKey:shown];
        [self showGeneral:nil];
    }
}
// Follows the Accessibility permission in Settings and the menu's warning, and
// starts or stops window tracking when it changes.
- (void)refreshTrust {
    BOOL trusted = AXIsProcessTrusted();
    [self.settings refresh:nil];
    if (trusted == self.trusted)
        return;
    self.trusted = trusted;
    debugLog("accessibility %s", trusted ? "granted" : "missing");
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
    emit(@"warning", self.trusted ? @"" : TrustWarning, @"");
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
    self.waitedForTitle = NO;
    BOOL trusted = AXIsProcessTrusted();
    if (trusted != self.trusted) {
        self.trusted = trusted;
        debugLog("accessibility %s", trusted ? "granted" : "missing");
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
    [NSObject cancelPreviousPerformRequestsWithTarget:self
                                             selector:@selector(readContext)
                                               object:nil];
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
    // A new window or tab often has no title for a moment. Switching for it
    // would switch again once the title arrives, so it gets a short wait; a
    // window still untitled after that is taken as it is.
    if (self.observedApp && !title.length && !windowID.length && !self.waitedForTitle) {
        self.waitedForTitle = YES;
        debugLog("context %s untitled, waiting", identifier.UTF8String);
        [self performSelector:@selector(readContext) withObject:nil afterDelay:TitleWaitTime];
        return;
    }
    self.waitedForTitle = NO;
    // Focus moving within a window repeats its context, and a window tracked by
    // identity, as in Ghostty, keeps it while its title changes, so neither is
    // logged again.
    NSString *logged = [NSString stringWithFormat:@"%@ %@ %@ %@", identifier, windowID,
                                                  windowID.length ? @"" : title, site];
    if (debugFile && ![logged isEqualToString:loggedContext]) {
        loggedContext = logged;
        debugLog("context %s window=%s title=%s site=%s", identifier.UTF8String,
                 windowID.length ? windowID.UTF8String : "-", debugHash(title), debugHash(site));
    }
    switcher_context(identifier.UTF8String, title.UTF8String, windowID.UTF8String,
                     site.UTF8String);
}
- (void)layoutChanged:(NSNotification *)notification {
    TISInputSourceRef source = TISCopyCurrentKeyboardInputSource();
    NSString *layout = sourceID(source);
    if (source)
        CFRelease(source);
    // Just after Insomemo selects a layout, macOS can still report the one
    // before it for a few milliseconds. That is not the user's choice, so it
    // is checked again once the selection has settled.
    CFTimeInterval settled = selectedAt + SelectionSettleTime - CFAbsoluteTimeGetCurrent();
    if (settled > 0 && ![layout isEqualToString:selectedLayout]) {
        debugLog("layout %s ignored, %s was just selected", layout.UTF8String,
                 selectedLayout.UTF8String);
        [NSObject cancelPreviousPerformRequestsWithTarget:self
                                                 selector:@selector(layoutChanged:)
                                                   object:nil];
        [self performSelector:@selector(layoutChanged:) withObject:nil afterDelay:settled];
        return;
    }
    emit(@"layout", layout, @"");
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
- (void)showGeneral:(id)sender {
    [self.settings show];
    ((NSTabViewController *)self.settings.window.contentViewController).selectedTabViewItemIndex =
        0;
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
        updateDebugLog();
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
        if (success) {
            selectedLayout = @(id);
            selectedAt = CFAbsoluteTimeGetCurrent();
        }
        debugLog("select %s %s", id, success ? "ok" : "failed");
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
    delegate.contextItem.title = [@"Active Context: " stringByAppendingString:@(context)];
    delegate.pauseItem.title = paused ? @"Resume Auto-Switching" : @"Pause Auto-Switching";
    delegate.errorItem.title = @(error);
    delegate.errorItem.hidden = strlen(error) == 0;
    // Errors are information only; the Accessibility warning leads to Settings.
    delegate.errorItem.enabled = [delegate.errorItem.title isEqualToString:TrustWarning];
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
