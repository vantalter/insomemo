# Insomemo

**Your keyboard layout, remembered per window, per tab, and per conversation — on Linux and macOS.**

Switch to Ukrainian in one Slack conversation and English in a terminal tab. Insomemo learns each choice as you make it and restores it whenever you return to that window, tab, or chat. There are no rules to write: the layout you pick in a context is the layout that context gets next time.

It is a small Rust daemon (under 1 MiB, about 15 MB of memory on macOS) with a native tray on both platforms. No telemetry, ads, server, or polling loop.

## Why Insomemo

- **Linux first-class.** X11, Sway, and Hyprland are supported natively through EWMH/XKB and compositor IPC, with a StatusNotifier tray for KDE, Waybar, and other hosts. Per-window layout memory on Linux usually depends on your desktop environment; Insomemo learns and restores the same way on X11, Sway, Hyprland, and macOS, with the same tray menu and icon.
- **Learns per window, not just per app.** For terminals, chat apps, and browsers, each window or tab title is its own context. On macOS, browsers also learn per site, so a new page on a site you have used starts in that site's layout. Ghostty's native macOS tabs are tracked by window identity, so tabs with the same title stay separate.
- **Zero configuration.** Change the layout once in a context and it is remembered. The first choice in an app also becomes that app's fallback for contexts it has not seen yet.
- **Rules when you want them.** Pin the current layout to a tab, a site, or a whole app from the tray, and forget any learned layout you no longer want.
- **Private by design.** Titles and sites are stored only as truncated SHA-256 hashes in a user-private state file. Network access is limited to optional update checks; Insomemo never reads keystrokes or page content. You can [check this yourself](#privacy).

### Compared with alternatives

| | Insomemo | Rule-based switchers (e.g. [Input Source Pro](https://github.com/runjuu/InputSourcePro)) | macOS “switch to a document's input source” |
| --- | --- | --- | --- |
| Linux (X11, Sway, Hyprland) | ✓ | – | – |
| Per window / tab / conversation | ✓ learned automatically | per app or website, configured by hand | per document window, only in supporting apps |
| Setup | none | a rule per app or site | a system setting |

If you only need fixed per-app or per-website rules on macOS, a rule-based switcher with more features may suit you better. Insomemo is for layouts that follow individual windows and conversations, on every desktop you use.

## Supported desktops

| Session | Integration | Availability |
| --- | --- | --- |
| Linux X11 | EWMH active window, WM_CLASS/title events, XKB group notifications | Implemented; smoke-tested in CI under Xvfb |
| Sway | Window/input/workspace IPC subscriptions | Implemented; framing tested, desktop validation needed |
| Hyprland | Active window/title/layout IPC events | Implemented; framing tested, desktop validation needed |
| macOS 12+ | NSWorkspace, Accessibility observers, Carbon input sources, NSStatusItem | Built and tested in CI on Apple Silicon and Intel; used daily on Apple Silicon |
| GNOME/KDE Wayland | Requires compositor-specific extension | Not supported in this version |

Context depends on what an app exposes: most apps must reflect tab or conversation changes in their window title. Ghostty on macOS is tracked by window identity instead.

## Install

Download the latest build from [Releases](https://github.com/vantalter/insomemo/releases):

- **macOS:** a universal `.dmg` (Apple Silicon and Intel). Drag Insomemo onto Applications.
- **Debian, Ubuntu, and derivatives:** a `.deb`; `sudo apt install ./insomemo_*.deb`.
- **Fedora, openSUSE, and other RPM distributions:** an `.rpm`; `sudo dnf install ./insomemo-*.rpm` or `zypper install`.
- **Any other Linux:** a tarball with the binary, desktop entry, and systemd user unit.

Linux builds are for x86_64 and arm64 and need glibc 2.35 or newer. Packages pull in their libraries and install a desktop entry and a systemd user unit (not enabled). The release notes cover first-launch steps, and [Building from source](#building-from-source) covers the rest.

## Using Insomemo

Insomemo works without any setup: change the layout in a window, tab, or chat, and Insomemo remembers it there. Its tray menu shows the active context and holds the few controls you may need.

### The menu

On macOS, Insomemo lives in the menu bar, without a Dock icon; on Linux, in the tray of a StatusNotifier host. Its monochrome stacked-keyboard symbol renders white or dark to match the bar. The icon has no language label, since the system's input menu already shows the current layout; the menu's first line names the active context. Pausing dims the macOS icon while keeping its menu available. The purple macOS app icon uses the same keyboard mark with a static switch dot; source artwork and preparation notes are in [assets](assets/README.md).

**Pause Auto-Switching** freezes both switching and learning. Resuming restores the focused context. **Force Default Layout** selects a layout immediately, sets the global fallback, and updates the current context and its app fallback. **Clear Cache** removes learned contexts and the tray-selected default; it retains a default explicitly specified in config. Clear/default actions use the same debounced persistence as manual layout changes.

**Always Use … In** pins the current layout to *This Tab or Window*, *This Site* (macOS browsers), or *This App*. A pin beats every learned layout: the tab pin first, then the site, then the app. Clicking a checked pin removes it. Manual changes in a pinned context are still learned, so removing the pin restores learned behaviour. **Forget Learned Layout** removes the learned layout for one of those scopes without touching pins. Pins survive **Clear Cache**; **Remove All Pins** clears them. Pins on Ghostty tabs last only for the session, like the tabs' learned layouts.

Automatic layout restores briefly badge the tray icon with a dot in its top-right corner. Switching tabs quickly keeps one badge showing rather than flashing. The badge is an instant icon change with no animation.

### Settings on macOS

**Settings…** (⌘,) in the menu opens a small window with three tabs: **General** (Launch at Login, Window / Tab Tracking, whether macOS's own document input switching is on, the debug log, and links to the project and the configuration folder), **Updates** (with the version), and **Support** (with links to star the project on GitHub or donate through Ko-fi, and **Report a Problem…**). Opening Insomemo again from Finder or Spotlight while it runs also opens Settings.

Window and tab tracking needs **Accessibility** access. On the first launch without it, Insomemo opens **Settings → General**, which explains the permission; choose **Grant Access…** there and turn on Insomemo in System Settings → Privacy & Security → Accessibility. Until granted, application-level tracking works, but titles are unavailable, and the menu shows **Window / Tab Tracking Is Off — Open Settings…**, which leads back to the same place. Once granted, tracking starts without a restart and the menu line disappears; **Settings → General** shows the permission's state, and its **Open Privacy Settings…** button opens the Accessibility settings, where the permission can be turned off. Release builds are signed with a Developer ID and notarized, so the grant survives updates.

Avoid running another per-window layout restorer at the same time. The macOS “Automatically switch to a document's input source” setting can compete with this app: it keeps one input source per document window, only in apps that support it, while Insomemo learns per window, tab, site, and app in every app. **Settings → General** shows whether it is on, and **Open Input Sources…** opens the System Settings page where it is turned off. Most apps must expose tab changes through their window title; Ghostty's native macOS tabs are tracked by accessibility window identity. Insomemo does not inspect browser content or capture keystrokes.

To place Insomemo beside the macOS input-source icon, hold **Command** and drag the Insomemo icon there. The status item has a stable macOS autosave name so the system can retain its identity across launches. If the system input-source icon is hidden, Insomemo remains in its normal menu-bar position. macOS does not provide a supported API to position this app automatically relative to that system icon.

### Updates

Update checks run when you ask or, if you turn them on, automatically. Automatic checks are off by default; the choice is saved in `state.json`.

- **macOS app:** updates use [Sparkle](https://sparkle-project.org). A new version opens a window with its release notes and a button to download it; Insomemo then installs it and relaunches. Turn on automatic checks, choose how often (daily, weekly, or monthly), see when it last checked, and check right away with **Check Now…** in **Settings → Updates**. Updates are verified against the project's signing key before they are installed.
- **Linux:** the tray menu has **Check for Updates…** and **Automatically Check for Updates**, which checks once a day. A macOS build run with `cargo`, which has no Sparkle, uses the same check from **Settings → Updates**. A newer version appears in the menu with a link to the releases page, and a manual check reports its result in a desktop notification or alert. These checks do not install anything.

### Launch at login

Choose **Launch at Login** in **Settings → General** on macOS or in the tray menu on Linux. It is off until you turn it on, and the operating system keeps the setting, so the checkmark always reflects what will happen at your next login.

- **macOS 13 or newer:** the app registers itself as a login item, which appears in System Settings → General → Login Items. If macOS asks for approval, Settings says so and opens that page. Keep the app at a stable path, such as `/Applications`. On macOS 12, or when running the bare `insomemo` binary, the item is hidden; add the app in Login Items yourself.
- **Linux:** the app writes an XDG autostart entry, `~/.config/autostart/insomemo.desktop`, that starts the binary at its current path, so install it somewhere stable such as `~/.local/bin` first. GNOME, KDE, Xfce, and other desktops that follow the XDG autostart specification run it; Sway and Hyprland do not by default, so start it from their config (`exec insomemo` or `exec-once = insomemo`) or use the provided [systemd user service](packaging/insomemo.service) instead. Use one method only; a second copy exits because the first holds the state lock.

## How memory works

1. Each context is an app identifier, optionally followed by `:` and the first 16 hex characters of SHA-256 of its normalized title. Ghostty on macOS uses its accessibility window identity instead, so tabs with the same title remain separate and title changes stay in the same tab context. These Ghostty identities last for the Ghostty process, so they are kept in memory only (with their own 200-entry budget) and never written to `state.json`; after either app restarts, the Ghostty app fallback applies until each tab learns a layout again. For title-based apps, whitespace is collapsed and one leading unread badge such as `(3) ` or `[12+] ` is removed; titles are otherwise preserved unless a configured suffix matches. Terminal working directories and renamed documents can still produce new contexts.
2. On focus/title change, the daemon tries the exact context, its site (macOS browsers), its app fallback, then the optional global default. Without a match, it leaves the layout alone. The site is the page's host without `www.`, read through Accessibility: Chrome publishes it on the window, Safari on its web view. Site learning applies to apps in `title_tracking_apps`; other Chromium-based browsers likely work the same way once added there, for example `com.microsoft.edgemac`, `com.brave.Browser`, or `company.thebrowser.Browser` (Arc). Firefox has not been verified; apps without a web address use titles only.
3. A manual layout change teaches the active context once it settles: when you move to another window, tab, or app, or after it has been kept for a second. A layout passed through while cycling input sources is not learned, and on macOS a late report of the previous layout, just after an automatic switch, is ignored. The first manual choice in a title-tracked app also establishes its app fallback. Later tab-specific changes preserve that fallback, while a site always takes its latest choice. Automatic restores are not learned as manual choices. On macOS, while the password or Touch ID dialog, the lock screen, or the screen saver is in front, Insomemo neither switches nor learns: macOS switches to a Latin layout for a password and back afterwards, and that is not your choice.
4. App fallbacks, site contexts, and title contexts share a 200-entry LRU budget. Least recently used entries are evicted, including app fallbacks. Pins are never evicted. Access order updates in memory and is persisted with the next state write.
5. Changes save atomically after two seconds of inactivity. Quit, SIGINT, and SIGTERM flush pending changes. A corrupt/unknown-version state file is preserved and startup fails with an explanation. Unknown fields written by a newer build are ignored, so downgrading keeps your learned layouts. A file lock prevents two instances from modifying the same state directory.

`state.json` contains layout IDs, app IDs, title and site hashes, pins, and recency counters, not raw titles. The active title is shown locally in the tray. Files are private to the user. Hashes are identifiers, not encryption; predictable titles can still be guessed.

## Configuration

No configuration file is required. Defaults include Ghostty, iTerm2, Terminal, Slack, Discord, Viber, Chrome, Firefox, Safari, and several Linux terminals. Matching is exact and case-sensitive against bundle IDs, WM_CLASS, or app_id. The tray shows a short app name, so look up the exact identifier with `osascript -e 'id of app "Safari"'` on macOS, `xprop WM_CLASS` (the second value) on X11, `swaymsg -t get_tree` (`app_id`) on Sway, or `hyprctl activewindow` (`class`) on Hyprland.

```sh
mkdir -p ~/.config/insomemo
./target/release/insomemo --print-default-config > ~/.config/insomemo/config.json
./target/release/insomemo --list-layouts
./target/release/insomemo --check
```

See [config/example.json](config/example.json). Restart after editing configuration. Unknown fields and malformed JSON are errors.

| Field | Meaning |
| --- | --- |
| `title_tracking_apps` | Exact app identifiers for which titles define separate contexts |
| `title_suffixes` | Optional exact trailing strings removed after whitespace normalization |
| `default_layout` | Optional fallback layout ID; `null` leaves unknown apps unchanged |
| `keyboard` | Optional Wayland keyboard identifier/name; `null` chooses automatically |

The default directory is `$XDG_CONFIG_HOME/insomemo`, falling back to `~/.config/insomemo`. `--state-dir DIR` overrides it; `--config PATH` overrides only the config file. `--check` validates config/state and checks the single-instance lock; it does not start the daemon or test graphical permissions. It creates the private directory and lock if absent.

Upgrading from Input Switcher: when no `insomemo` directory exists, the app reuses an existing `input-switcher` directory so your settings, learned layouts, and single-instance lock are preserved. Quit the old app before opening Insomemo. Its new bundle identifier is `dev.insomemo.app`, so macOS may require a fresh Accessibility grant.

## Privacy

What Insomemo reads, in memory only:

- **macOS:** the frontmost app's bundle ID, its focused window's title, Ghostty's window identity, and, for web pages, the page address (through Accessibility). Only the host, such as `docs.google.com`, is used, and only as a hash. It asks for Accessibility, not Input Monitoring, so macOS does not let it read keystrokes.
- **Linux:** the active window's class and title (X11 properties or Sway/Hyprland IPC).

What it stores: `state.json` (see [How memory works](#how-memory-works)) and your optional `config.json`, in a directory only you can open. Besides those, it writes only its own tray icons on Linux (`$XDG_RUNTIME_DIR/insomemo/icons`); if you turn on **Launch at Login**, a login item on macOS or `~/.config/autostart/insomemo.desktop` on Linux; and, on macOS only if you turn on the debug log in **Settings → General**, `~/Library/Logs/Insomemo/` (see [Troubleshooting](#troubleshooting)), whose codes use a random secret kept in Insomemo's preferences. **Report a Problem…** only opens a prefilled GitHub issue in your browser; Insomemo sends nothing itself. Update checks connect to GitHub only when requested or when automatic checks are enabled: the macOS app reads the update feed from `github.com` and downloads updates from there, and the Linux tray asks `api.github.com` for the release list. They send the standard HTTPS request and no saved layouts, titles, or state; Sparkle's optional system profile is not enabled.

Ways to check:

```sh
# Linux: optional checks run curl as a short-lived child process.
ps -ax -o command | grep '[c]url.*api.github.com'
# Linux: local Unix sockets (D-Bus, X11, compositor IPC).
ss -xp | grep insomemo
# No network crate is linked.
cargo tree --edges normal,build
# Everything it remembers (~/.config/input-switcher if you upgraded from Input Switcher).
cat ~/.config/insomemo/state.json
```

## Troubleshooting

To report a problem, choose **Report a Problem…** in **Settings → Support** on macOS or in the tray menu on Linux. It opens a new GitHub issue with Insomemo's version, the platform, and your operating system and processor filled in; it never includes window titles, sites, or saved layouts. Nothing is sent until you submit the issue, so add what happened, and on macOS the debug log described below, first.

**macOS: Window / Tab Tracking is off although Insomemo is switched on in System Settings.** macOS ties the Accessibility permission to the app's signature. Versions up to 0.2.10 were ad-hoc signed, so the first Developer ID release (0.3.0) is a new app to macOS, as is each ad-hoc local build; the existing switch belongs to the previous version and no longer applies. Remove the stale entry and grant the permission again:

```sh
tccutil reset Accessibility dev.insomemo.app
```

Then choose **Grant Access…** in **Settings → General** and turn on the new entry. Within a second Settings shows **On** and tracking starts, without a restart. Later Developer ID releases keep the permission.

**macOS: Insomemo's icon looks like coloured stripes in System Settings' privacy lists.** Versions up to 0.2.3 stored the small icon sizes in a format those lists misread. Install a newer version, then clear macOS's icon cache in Terminal and restart the Mac:

```sh
sudo rm -rf /Library/Caches/com.apple.iconservices.store
rm -rf "$(getconf DARWIN_USER_CACHE_DIR)com.apple.iconservices"
```

**macOS: switching misbehaves now and then, and you want to report it.** In **Settings → General**, turn on **Record switching events** under **Debug Log**, then use Insomemo until the problem happens again. Logging starts at once, without a restart.

The log, `~/Library/Logs/Insomemo/insomemo.log`, lists each focused app and window, layout change, and layout Insomemo selected, with timestamps. Window titles and web sites appear only as short codes, made with a secret that stays on your Mac, so someone reading the log cannot check it for a site or title they guess; **Clear Log** also starts new codes. App identifiers, such as `com.apple.Safari`, and times do appear, and each time includes your UTC offset. The log is readable only by your user account. **Show Log** reveals it in Finder, and **Clear Log** deletes it, the previous log, and their folder. It starts over past 1 MB, keeping the previous log as `insomemo.log.1`. A log from version 0.3.3 or earlier, `~/Library/Logs/Insomemo.log`, moves into this folder when Insomemo starts. Turn the setting off when you are done.

## Building from source

### Linux

Development dependencies on Debian/Ubuntu:

```sh
sudo apt install build-essential pkg-config libglib2.0-dev libjson-glib-dev libx11-dev libxkbcommon-dev libgdk-pixbuf-2.0-dev curl
cargo build --release --locked
./target/release/insomemo
```

The executable dynamically links the platform's native libraries. A StatusNotifier-compatible tray host is needed for its menu, such as KDE's system tray or Waybar's tray module. The tray shows the same stacked-keyboard icon as on macOS. Cinnamon receives an absolute PNG path to avoid differences in symbolic SVG loading; every host can also use a D-Bus ARGB pixel fallback. KDE and GTK-based hosts such as Waybar receive symbolic SVGs that they recolour to match the panel. For PNGs and hosts that draw SVGs as is, Insomemo chooses light or dark ink from Cinnamon's panel theme or the desktop's light/dark preference, following changes to either. Icon files live in `$XDG_RUNTIME_DIR/insomemo/icons` (or `~/.cache/insomemo/icons`). There is no input-source label; the tooltip identifies Insomemo and the active context. Without a tray host, switching continues and SIGTERM quits cleanly.

Sway and Hyprland are detected before X11 from `SWAYSOCK` / `HYPRLAND_INSTANCE_SIGNATURE`. Other Wayland sessions fail explicitly; XWayland cannot provide complete context for native Wayland applications. Run the daemon inside the graphical session so it inherits compositor and D-Bus environment variables.

X11 uses the core keyboard. On Wayland, the first Sway keyboard or the main Hyprland keyboard is selected. Set `keyboard` in the configuration to choose a particular Sway identifier or Hyprland device name. Only that keyboard is tracked and switched; multiple independently configured keyboards are not synchronized. Hyprland's named XKB rules are supported; custom `kb_file` keymaps need additional integration.

### macOS

Install Rust and Xcode, then:

```sh
make app
open "dist/Insomemo.app"
```

The app is an Xcode project, [macos/Insomemo.xcodeproj](macos/Insomemo.xcodeproj), around the Rust crate: its first build phase, [build-rust.sh](macos/build-rust.sh), compiles the crate as a static library for each architecture being built, and a one-line Swift `main` calls the library's `insomemo_main`. The app version comes from `Cargo.toml`. `make app` runs `xcodebuild` and signs the result; in Xcode, **Product → Run** and **Product → Archive** work directly. To build in Xcode under another Apple team, choose it under the target's **Signing & Capabilities**.

macOS ties the Accessibility permission to the app's signature. `make app` signs with your Apple Development certificate when one is installed, so the permission survives rebuilds; without one, the build is ad-hoc signed, macOS treats every rebuild as a new app, and you must grant the permission again (remove the old Insomemo entry first). Keep the bundle at a stable path.

`make dmg` also packages the app as `dist/Insomemo.dmg`, the same drag-to-install disk image the releases publish.

The standalone executable is `target/release/insomemo`. To run it in a terminal:

```sh
cargo run --release --locked
```

`make app` builds for the host architecture; `make notarize`, Xcode archives, and the app on the Releases page are universal (Apple Silicon and Intel), which needs both Rust targets: `rustup target add aarch64-apple-darwin x86_64-apple-darwin`. macOS 12 or newer is the deployment target.

## Performance and validation

The macOS main run loop and Linux GLib event loop sleep waiting for OS notifications, IPC sockets, D-Bus, or signals. The two-second save debounce and 1.2-second badge use one-shot timers, as do, on macOS, the 0.3-second wait for an untitled window's title and the 0.15-second check after an automatic switch. Automatic update checks use a daily timer while enabled; requests run on a worker thread. Linux drains Xlib's internal event queue through a custom GLib source, including events buffered by synchronous X calls. Compositor requests have bounded response sizes and two-second timeouts.

The macOS release binary is about 820 KiB per architecture, so 1.6 MiB in the universal app. Idle on macOS (Apple Silicon), Insomemo's physical memory footprint is about **15 MB** and its CPU use rounds to 0%, measured with `footprint` and `ps`; opening Settings loads its window and images, which raises it to about 33 MB until Insomemo restarts. Its resident size (RSS) reads higher, around 75 MiB, because RSS also counts system framework pages shared with other apps. Linux memory has not been measured yet.

```sh
make test
make check
```

Tests cover context restoration, site and app fallback, layouts passed through while cycling input sources, pins and forgetting, Linux tray icons, Launch at Login entries, pause/resume, failed selections, normalization and hashing, bounded LRU state, atomic storage and locking, and fragmented compositor IPC. CI builds on macOS and Linux for arm64 and x86_64. Linux CI also runs a smoke test, [tests/smoke_linux.rs](tests/smoke_linux.rs), that exercises the native tray and persistence under Xvfb and a session D-Bus; it is ignored by default and runs with `dbus-run-session -- xvfb-run -a cargo test --release --test smoke_linux -- --ignored`.

Linux CI also runs [tests/tray_linux.py](tests/tray_linux.py), which checks PNG decoding, SNI pixel byte order, both icon colours, badge changes, pause, and registration when a tray host starts late or restarts. It requires the normal Linux build dependencies plus `python3-gi` and `gir1.2-gdkpixbuf-2.0`. Run it with `dbus-run-session -- xvfb-run -a /usr/bin/python3 tests/tray_linux.py target/release/insomemo`.

Manual desktop acceptance checks:

- Choose different layouts in two title-tracked tabs; revisit both and verify restoration.
- Rename a tab and verify app fallback, then teach its own layout.
- Pause, switch apps/layouts, and resume; check that paused changes were not learned.
- Use Force Default Layout and Clear Cache; restart and verify persistence.
- Pin a layout to a tab, a site, and an app; check each wins over learned layouts and that unpinning restores them.
- Remove a saved OS layout; verify that failed restoration is visible in the tray and manual switching still works.
- Measure idle RSS and CPU after startup and during focus/title/layout changes on each target desktop.

## Native references

- [Apple application activation notification](https://developer.apple.com/documentation/appkit/nsworkspace/didactivateapplicationnotification)
- [Sway IPC specification](https://github.com/swaywm/sway/blob/master/sway/sway-ipc.7.scd)
- [Hyprland IPC](https://wiki.hypr.land/ipc/)

## Contributing and security

Bug reports and pull requests are welcome; see [CONTRIBUTING.md](CONTRIBUTING.md), which also describes how releases are made. Please report security issues privately as described in [SECURITY.md](SECURITY.md).

## License

Insomemo is released under the [MIT License](LICENSE). The macOS app also includes [Sparkle](https://sparkle-project.org) and GitHub's mark from [Primer Octicons](https://github.com/primer/octicons), each under its own MIT License. The Ko-fi logo on the Support tab belongs to Ko-fi Labs and is used under their brand guidelines; it is not covered by these licenses (see [assets](assets/README.md)).
