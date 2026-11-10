# Insomemo

**Your keyboard layout, remembered per window, per tab, and per conversation — on Linux and macOS.**

Switch to Ukrainian in one Slack conversation and English in a terminal tab. Insomemo learns each choice as you make it and restores it whenever you return to that window, tab, or chat. There are no rules to write: the layout you pick in a context is the layout that context gets next time.

It is a small Rust daemon (under 500 KiB, about 12 MB of memory on macOS) with a native tray on both platforms. No webview, telemetry, ads, network service, or polling loop.

## Why Insomemo

- **Linux first-class.** X11, Sway, and Hyprland are supported natively through EWMH/XKB and compositor IPC, with a StatusNotifier tray for KDE, Waybar, and other hosts. Per-window layout memory on Linux usually depends on your desktop environment; Insomemo learns and restores the same way on X11, Sway, Hyprland, and macOS, with the same tray menu and icon.
- **Learns per window, not just per app.** For terminals, chat apps, and browsers, each window or tab title is its own context. On macOS, browsers also learn per site, so a new page on a site you have used starts in that site's layout. Ghostty's native macOS tabs are tracked by window identity, so tabs with the same title stay separate.
- **Zero configuration.** Change the layout once in a context and it is remembered. The first choice in an app also becomes that app's fallback for contexts it has not seen yet.
- **Rules when you want them.** Pin the current layout to a tab, a site, or a whole app from the tray, and forget any learned layout you no longer want.
- **Private by design.** Titles and sites are stored only as truncated SHA-256 hashes in a user-private state file. Insomemo opens no network connections and never reads keystrokes or page content. You can [check this yourself](#privacy).

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

Linux builds are for x86_64 and arm64 and need glibc 2.35 or newer. Packages pull in their libraries and install a desktop entry and a systemd user unit (not enabled). The release notes cover first-launch steps; the sections below build from source.

## Build and run on Linux

Development dependencies on Debian/Ubuntu:

```sh
sudo apt install build-essential pkg-config libglib2.0-dev libjson-glib-dev libx11-dev libxkbcommon-dev
cargo build --release --locked
./target/release/insomemo
```

The executable dynamically links the platform's native libraries. A StatusNotifier-compatible tray host is needed for its menu, such as KDE's system tray or Waybar's tray module. The tray shows the same stacked-keyboard icon as on macOS, as symbolic SVGs that KDE and GTK-based hosts such as Waybar recolour to match the panel; the app writes them to `$XDG_RUNTIME_DIR/insomemo/icons` (or `~/.cache/insomemo/icons`) at startup. There is no input-source label; the tooltip identifies Insomemo and the active context. Without a tray host, switching continues and SIGTERM quits cleanly.

Sway and Hyprland are detected before X11 from `SWAYSOCK` / `HYPRLAND_INSTANCE_SIGNATURE`. Other Wayland sessions fail explicitly; XWayland cannot provide complete context for native Wayland applications. Run the daemon inside the graphical session so it inherits compositor and D-Bus environment variables.

X11 uses the core keyboard. On Wayland, the first Sway keyboard or the main Hyprland keyboard is selected. Set `keyboard` in the configuration to choose a particular Sway identifier or Hyprland device name. Only that keyboard is tracked and switched; multiple independently configured keyboards are not synchronized. Hyprland's named XKB rules are supported; custom `kb_file` keymaps need additional integration.

## Build and run on macOS

Install Rust and Xcode Command Line Tools, then:

```sh
make app
open "dist/Insomemo.app"
```

`make dmg` also packages the app as `dist/Insomemo.dmg`, the same drag-to-install disk image the releases publish.

The app lives in the menu bar, without a Dock icon. Its monochrome stacked-keyboard symbol automatically renders white or dark to match the macOS menu bar. The tray is icon-only; the OS input menu shows the current language. Pausing dims the macOS icon while keeping its menu available. The purple app artwork is bundled as a multi-resolution macOS icon; artwork and preparation notes are in [assets](assets/README.md).

To place Insomemo beside the macOS input-source icon, hold **Command** and drag the Insomemo icon there. The status item has a stable macOS autosave name so the system can retain its identity across launches. If the system input-source icon is hidden, Insomemo remains in its normal menu-bar position. macOS does not provide a supported API to position this app automatically relative to that system icon.

Open its menu and select **Enable Window / Tab Tracking…**, then grant **Accessibility** access in System Settings → Privacy & Security → Accessibility. Until granted, application-level tracking works, but titles are unavailable. The menu item then changes to **Window / Tab Tracking** with a checkmark, and tracking starts without a restart; choosing it again opens the Accessibility settings, where the permission can be turned off. macOS ties the permission to the app's signature. `make app` signs with your Apple Development certificate when one is installed, so the permission survives rebuilds; without one, the build is ad-hoc signed, macOS treats every rebuild as a new app, and you must grant the permission again (remove the old Insomemo entry first). Keep the bundle at a stable path. Once release signing is configured, release builds are signed with a Developer ID and notarized, so the grant survives updates.

The standalone executable is `target/release/insomemo`. To run it in a terminal:

```sh
cargo run --release --locked
```

`make app` builds for the host architecture; the app on the Releases page is universal (Apple Silicon and Intel). macOS 12 or newer is the deployment target.

## Configuration

No configuration file is required. Defaults include Ghostty, iTerm2, Terminal, Slack, Discord, Viber, Chrome, Firefox, Safari, and several Linux terminals. Matching is exact and case-sensitive against bundle IDs, WM_CLASS, or app_id. The tray displays the identifier to help configure it.

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

## How memory works

1. Each context is an app identifier, optionally followed by `:` and the first 16 hex characters of SHA-256 of its normalized title. Ghostty on macOS uses its accessibility window identity instead, so tabs with the same title remain separate and title changes stay in the same tab context. These Ghostty identities last for the Ghostty process, so they are kept in memory only (with their own 200-entry budget) and never written to `state.json`; after either app restarts, the Ghostty app fallback applies until each tab learns a layout again. For title-based apps, whitespace is collapsed and one leading unread badge such as `(3) ` or `[12+] ` is removed; titles are otherwise preserved unless a configured suffix matches. Terminal working directories and renamed documents can still produce new contexts.
2. On focus/title change, the daemon tries the exact context, its site (macOS browsers), its app fallback, then the optional global default. Without a match, it leaves the layout alone. The site is the page's host without `www.`, read through Accessibility: Chrome publishes it on the window, Safari on its web view. Site learning applies to apps in `title_tracking_apps`; other Chromium-based browsers likely work the same way once added there, for example `com.microsoft.edgemac`, `com.brave.Browser`, or `company.thebrowser.Browser` (Arc). Firefox has not been verified; apps without a web address use titles only.
3. A manual layout change teaches the active context. The first manual choice in a title-tracked app also establishes its app fallback. Later tab-specific changes preserve that fallback, while a site always takes its latest choice. Automatic restores are not learned as manual choices.
4. App fallbacks, site contexts, and title contexts share a 200-entry LRU budget. Least recently used entries are evicted, including app fallbacks. Pins are never evicted. Access order updates in memory and is persisted with the next state write.
5. Changes save atomically after two seconds of inactivity. Quit, SIGINT, and SIGTERM flush pending changes. A corrupt/unknown-version state file is preserved and startup fails with an explanation. Unknown fields written by a newer build are ignored, so downgrading keeps your learned layouts. A file lock prevents two instances from modifying the same state directory.

`state.json` contains layout IDs, app IDs, title and site hashes, pins, the switch-indicator settings, and recency counters, not raw titles. The active title is shown locally in the tray. Files are private to the user. Hashes are identifiers, not encryption; predictable titles can still be guessed.

**Pause Auto-Switching** freezes both switching and learning. Resuming restores the focused context. **Force Default Layout** selects a layout immediately, sets the global fallback, and updates the current context and its app fallback. **Clear Cache** removes learned contexts and the tray-selected default; it retains a default explicitly specified in config. Clear/default actions use the same debounced persistence as manual layout changes.

**Always Use … In** pins the current layout to *This Tab or Window*, *This Site* (macOS browsers), or *This App*. A pin beats every learned layout: the tab pin first, then the site, then the app. Clicking a checked pin removes it. Manual changes in a pinned context are still learned, so removing the pin restores learned behaviour. **Forget Learned Layout** removes the learned layout for one of those scopes without touching pins. Pins survive **Clear Cache**; **Remove All Pins** clears them. Pins on Ghostty tabs last only for the session, like the tabs' learned layouts.

**Switch Indicator** (on by default) badges the tray icon with a dot for about a second whenever Insomemo itself switches the layout, so you can tell an automatic restore from your own change. Switching tabs quickly keeps one badge showing rather than flashing. The badge is an instant icon change with no animation, and the **Switch Indicator** submenu chooses **Off**, **Top Right** (the default), or **Bottom Right** for the dot. The settings are saved in `state.json`.

Avoid running another per-window layout restorer at the same time. The macOS “Automatically switch to a document's input source” setting can compete with this app. Most apps must expose tab changes through their window title; Ghostty's native macOS tabs are tracked by accessibility window identity. Insomemo does not inspect browser content or capture keystrokes.

## Privacy

What Insomemo reads, in memory only:

- **macOS:** the frontmost app's bundle ID, its focused window's title, Ghostty's window identity, and, for web pages, the page address (through Accessibility). Only the host, such as `docs.google.com`, is used, and only as a hash. It asks for Accessibility, not Input Monitoring, so macOS does not let it read keystrokes.
- **Linux:** the active window's class and title (X11 properties or Sway/Hyprland IPC).

What it stores: `state.json` (see [How memory works](#how-memory-works)) and your optional `config.json`, in a directory only you can open. Besides those, it writes only its own tray icons on Linux (`$XDG_RUNTIME_DIR/insomemo/icons`) and, if you turn on **Launch at Login**, a login item on macOS or `~/.config/autostart/insomemo.desktop` on Linux. Nothing is sent anywhere.

Ways to check:

```sh
# No network sockets: prints nothing while Insomemo runs (macOS and Linux).
lsof -nP -i -a -p "$(pgrep -x insomemo)"
# Linux: only local Unix sockets (D-Bus, X11, compositor IPC).
ss -xp | grep insomemo
# No networking libraries among the dependencies.
cargo tree --edges normal,build
# Everything it remembers (~/.config/input-switcher if you upgraded from Input Switcher).
cat ~/.config/insomemo/state.json
```

## Performance and validation

The macOS main run loop and Linux GLib event loop sleep waiting for OS notifications, IPC sockets, D-Bus, or signals. The only timers are one-shot: the two-second save debounce and, when the switch indicator is on, the 1.2-second badge. Linux drains Xlib's internal event queue through a custom GLib source, including events buffered by synchronous X calls. Compositor requests have bounded response sizes and two-second timeouts.

The macOS release binary is about 480 KiB. Idle on macOS (Apple Silicon), Insomemo's physical memory footprint is about **12 MB** and its CPU use rounds to 0%, measured with `footprint` and `ps`. Its resident size (RSS) reads higher, around 75 MiB, because RSS also counts system framework pages shared with other apps. Linux memory has not been measured yet.

```sh
make test
make check
```

Tests cover context restoration, site and app fallback, pins and forgetting, switch-indicator settings, Linux tray icons, Launch at Login entries, pause/resume, failed selections, normalization and hashing, bounded LRU state, atomic storage and locking, and fragmented compositor IPC. CI builds on macOS and Linux for arm64 and x86_64. Linux CI runs `scripts/smoke-linux.py` under Xvfb and a session D-Bus to exercise the native tray and persistence.

Manual desktop acceptance checks:

- Choose different layouts in two title-tracked tabs; revisit both and verify restoration.
- Rename a tab and verify app fallback, then teach its own layout.
- Pause, switch apps/layouts, and resume; check that paused changes were not learned.
- Use Force Default Layout and Clear Cache; restart and verify persistence.
- Pin a layout to a tab, a site, and an app; check each wins over learned layouts and that unpinning restores them.
- Remove a saved OS layout; verify that failed restoration is visible in the tray and manual switching still works.
- Measure idle RSS and CPU after startup and during focus/title/layout changes on each target desktop.

## Releasing

Set `version` in `Cargo.toml`, merge to `main`, then push a matching tag, for example `git tag v0.1.0 && git push origin v0.1.0`. The release workflow checks that the tag matches, tests and builds every platform, and publishes a GitHub release with checksums. Versions below 1.0 are published as pre-releases.

When these repository secrets are set, the macOS app and disk image are signed with a Developer ID, use the hardened runtime, and are notarized and stapled. Without any of them, the app is ad-hoc signed and the release notes show the Gatekeeper steps instead. Setting only some of them fails the release, so a typo cannot silently publish an unsigned build.

| Secret | Value |
| --- | --- |
| `MACOS_CERTIFICATE` | The **Developer ID Application** certificate and its private key, exported from Keychain Access as `.p12`, base64-encoded: `base64 -i certificate.p12 \| pbcopy` |
| `MACOS_CERTIFICATE_PASSWORD` | The password chosen when exporting the `.p12` |
| `APPLE_API_KEY` | The contents of an App Store Connect API key file, `AuthKey_XXXXXXXXXX.p8` (Users and Access → Integrations → Team Keys, Developer access) |
| `APPLE_API_KEY_ID` | That key's ID |
| `APPLE_API_ISSUER` | The Issuer ID shown above the key list |

Set them with `gh secret set NAME` or in the repository's Settings → Secrets and variables → Actions.

To produce the same notarized build locally, store notary credentials once with `xcrun notarytool store-credentials insomemo` (it prompts for an API key or Apple ID), then run:

```sh
CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE=insomemo make notarize
```

This writes `dist/Insomemo.zip` and `dist/Insomemo.dmg`.

## Optional startup

Choose **Launch at Login** in the tray menu. It is off until you turn it on, and the operating system keeps the setting, so the checkmark always reflects what will happen at your next login.

- **macOS 13 or newer:** the app registers itself as a login item, which appears in System Settings → General → Login Items. If macOS asks for approval, the menu item says so and opens that page. Keep the app at a stable path, such as `/Applications`. On macOS 12, or when running the bare `insomemo` binary, the item is hidden; add the app in Login Items yourself.
- **Linux:** the app writes an XDG autostart entry, `~/.config/autostart/insomemo.desktop`, that starts the binary at its current path, so install it somewhere stable such as `~/.local/bin` first. GNOME, KDE, Xfce, and other desktops that follow the XDG autostart specification run it; Sway and Hyprland do not by default, so start it from their config (`exec insomemo` or `exec-once = insomemo`) or use the provided [systemd user service](packaging/insomemo.service) instead. Use one method only; a second copy exits because the first holds the state lock.

## Troubleshooting

**macOS: the menu still says "Enable Window / Tab Tracking…" although Insomemo is switched on in System Settings.** macOS ties the Accessibility permission to the app's signature. Release builds are not yet signed with a Developer ID, so each update, like each ad-hoc local build, is a new app to macOS; the existing switch belongs to the previous version and no longer applies. Remove the stale entry and grant the permission again:

```sh
tccutil reset Accessibility dev.insomemo.app
```

Then choose **Enable Window / Tab Tracking…** in Insomemo's menu and turn on the new entry. The menu changes to **Window / Tab Tracking** within a second, without a restart.

**macOS: Insomemo's icon looks like coloured stripes in System Settings' privacy lists.** Versions up to 0.2.3 stored the small icon sizes in a format those lists misread. Install a newer version, then clear macOS's icon cache in Terminal and restart the Mac:

```sh
sudo rm -rf /Library/Caches/com.apple.iconservices.store
rm -rf "$(getconf DARWIN_USER_CACHE_DIR)com.apple.iconservices"
```

## Native references

- [Apple application activation notification](https://developer.apple.com/documentation/appkit/nsworkspace/didactivateapplicationnotification)
- [Sway IPC specification](https://github.com/swaywm/sway/blob/master/sway/sway-ipc.7.scd)
- [Hyprland IPC](https://wiki.hypr.land/ipc/)

MIT licensed. See [LICENSE](LICENSE).
