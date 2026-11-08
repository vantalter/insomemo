# Insomemo

**Your keyboard layout, remembered per window, per tab, and per conversation — on Linux and macOS.**

Switch to Ukrainian in one Slack conversation and English in a terminal tab. Insomemo learns each choice as you make it and restores it whenever you return to that window, tab, or chat. There are no rules to write: the layout you pick in a context is the layout that context gets next time.

It is a small Rust daemon (about 400 KiB) with a native tray on both platforms. No webview, telemetry, ads, network service, or polling loop.

## Why Insomemo

- **Linux first-class.** X11, Sway, and Hyprland are supported natively through EWMH/XKB and compositor IPC, with a StatusNotifier tray for KDE, Waybar, and other hosts. Per-window layout memory on Linux usually depends on your desktop environment; Insomemo behaves the same on X11, Sway, Hyprland, and macOS.
- **Learns per window, not just per app.** For terminals, chat apps, and browsers, each window or tab title is its own context. On macOS, browsers also learn per site, so a new page on a site you have used starts in that site's layout. Ghostty's native macOS tabs are tracked by window identity, so tabs with the same title stay separate.
- **Zero configuration.** Change the layout once in a context and it is remembered. The first choice in an app also becomes that app's fallback for contexts it has not seen yet.
- **Private by design.** Titles are stored only as truncated SHA-256 hashes in a user-private state file. Nothing leaves your machine, and Insomemo never reads keystrokes or page content.

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
| Linux X11 | EWMH active window, WM_CLASS/title events, XKB group notifications | Implemented; Linux CI smoke test supplied |
| Sway | Window/input/workspace IPC subscriptions | Implemented; framing tested, desktop validation needed |
| Hyprland | Active window/title/layout IPC events | Implemented; framing tested, desktop validation needed |
| macOS 12+ | NSWorkspace, Accessibility observers, Carbon input sources, NSStatusItem | Built and unit-tested on Apple Silicon |
| GNOME/KDE Wayland | Requires compositor-specific extension | Not supported in this version |

Context depends on what an app exposes: most apps must reflect tab or conversation changes in their window title. Ghostty on macOS is tracked by window identity instead.

## Install

Download the latest build from [Releases](https://github.com/vantalter/insomemo/releases): a universal macOS app (Apple Silicon and Intel) and Linux binaries for x86_64 and arm64 (glibc 2.35+). The release notes cover first-launch steps; the sections below build from source.

## Build and run on Linux

Development dependencies on Debian/Ubuntu:

```sh
sudo apt install build-essential pkg-config libglib2.0-dev libjson-glib-dev libx11-dev libxkbcommon-dev
cargo build --release --locked
./target/release/insomemo
```

The executable dynamically links the platform's native libraries. A StatusNotifier-compatible tray host is needed for its menu, such as KDE's system tray or Waybar's tray module. The tray shows an icon without an input-source label; its tooltip identifies Insomemo and the active context. Without a tray host, switching continues and SIGTERM quits cleanly.

Sway and Hyprland are detected before X11 from `SWAYSOCK` / `HYPRLAND_INSTANCE_SIGNATURE`. Other Wayland sessions fail explicitly; XWayland cannot provide complete context for native Wayland applications. Run the daemon inside the graphical session so it inherits compositor and D-Bus environment variables.

X11 uses the core keyboard. On Wayland, the first Sway keyboard or the main Hyprland keyboard is selected. Set `keyboard` in the configuration to choose a particular Sway identifier or Hyprland device name. Only that keyboard is tracked and switched; multiple independently configured keyboards are not synchronized. Hyprland's named XKB rules are supported; custom `kb_file` keymaps need additional integration.

## Build and run on macOS

Install Rust and Xcode Command Line Tools, then:

```sh
make app
open "dist/Insomemo.app"
```

The app lives in the menu bar, without a Dock icon. Its monochrome keyboard/sync symbol automatically renders white or dark to match the macOS menu bar. The tray is icon-only; the OS input menu shows the current language. Pausing dims the macOS icon while keeping its menu available. The purple app artwork is bundled as a multi-resolution macOS icon; artwork and preparation notes are in [assets](assets/README.md).

To place Insomemo beside the macOS input-source icon, hold **Command** and drag the Insomemo icon there. The status item has a stable macOS autosave name so the system can retain its identity across launches. If the system input-source icon is hidden, Insomemo remains in its normal menu-bar position. macOS does not provide a supported API to position this app automatically relative to that system icon.

Open its menu and select **Enable Window / Tab Tracking…**, then grant **Accessibility** access in System Settings → Privacy & Security → Accessibility. Until granted, application-level tracking works, but titles are unavailable. After granting access, switch to another app or reopen the tray menu. A rebuild may require granting permission again; keep the bundle at a stable path. This local app is ad-hoc signed, not notarized for distribution.

The standalone executable is `target/release/insomemo`. To run it in a terminal:

```sh
cargo run --release --locked
```

The build targets the host architecture. Build natively on Apple Silicon or Intel; a universal binary is not produced. macOS 12 or newer is the deployment target.

## Configuration

No configuration file is required. Defaults include Ghostty, iTerm2, Terminal, Slack, Discord, Viber, common browsers, and several Linux terminals. Matching is exact and case-sensitive against bundle IDs, WM_CLASS, or app_id. The tray displays the identifier to help configure it.

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

Upgrading from Input Switcher: when no `insomemo` directory exists, the app reuses an existing `input-switcher` directory so your settings, learned layouts, and single-instance lock are preserved. Quit the old app before opening Insomemo. Its new bundle identifier is `dev.insomemo.app`, so macOS may require a fresh Accessibility grant. The GitHub repository name and visibility are unchanged.

## How memory works

1. Each context is an app identifier, optionally followed by `:` and the first 16 hex characters of SHA-256 of its normalized title. Ghostty on macOS uses its accessibility window identity instead, so tabs with the same title remain separate and title changes stay in the same tab context. These Ghostty identities last for the Ghostty process, so they are kept in memory only (with their own 200-entry budget) and never written to `state.json`; after either app restarts, the Ghostty app fallback applies until each tab learns a layout again. For title-based apps, whitespace is collapsed and one leading unread badge such as `(3) ` or `[12+] ` is removed; titles are otherwise preserved unless a configured suffix matches. Terminal working directories and renamed documents can still produce new contexts.
2. On focus/title change, the daemon tries the exact context, its site (macOS browsers), its app fallback, then the optional global default. Without a match, it leaves the layout alone. The site is the page's host without `www.`, read through Accessibility: Chrome and other Chromium-based apps publish it on the window, Safari on its web view. Firefox and apps without a web address fall back to titles only.
3. A manual layout change teaches the active context. The first manual choice in a title-tracked app also establishes its app fallback. Later tab-specific changes preserve that fallback, while a site always takes its latest choice. Automatic restores are not learned as manual choices.
4. App defaults and title contexts share a 200-entry LRU budget. Least recently used entries are evicted, including app fallbacks. Access order updates in memory and is persisted with the next state write.
5. Changes save atomically after two seconds of inactivity. Quit, SIGINT, and SIGTERM flush pending changes. A corrupt/unknown-version state file is preserved and startup fails with an explanation. Unknown fields written by a newer build are ignored, so downgrading keeps your learned layouts. A file lock prevents two instances from modifying the same state directory.

`state.json` contains layout IDs, app IDs, title and site hashes, and recency counters, not raw titles. The active title is shown locally in the tray. Files are private to the user. Hashes are identifiers, not encryption; predictable titles can still be guessed.

**Pause Auto-Switching** freezes both switching and learning. Resuming restores the focused context. **Force Default Layout** selects a layout immediately, sets the global fallback, and updates the current context and its app fallback. **Clear Cache** removes learned contexts and the tray-selected default; it retains a default explicitly specified in config. Clear/default actions use the same debounced persistence as manual layout changes.

Avoid running another per-window layout restorer at the same time. The macOS “Automatically switch to a document's input source” setting can compete with this app. Most apps must expose tab changes through their window title; Ghostty's native macOS tabs are tracked by accessibility window identity. Insomemo does not inspect browser content or capture keystrokes.

## Performance and validation

The macOS main run loop and Linux GLib event loop sleep waiting for OS notifications, IPC sockets, D-Bus, or signals. The only scheduled timer is a one-shot two-second save debounce. Linux drains Xlib's internal event queue through a custom GLib source, including events buffered by synchronous X calls. Compositor requests have bounded response sizes and two-second timeouts.

The release binary built here is approximately 432 KiB. A sandboxed macOS startup/shutdown smoke test succeeded and peaked at about **58 MiB RSS**. This is a startup peak, not an idle measurement. The PRD's **under 15 MB idle RAM has not been demonstrated**: native framework memory and the target desktop need measurement outside the restricted build environment. No claim of zero measured CPU usage or production readiness is made.

```sh
make test
make check
```

Tests cover context restoration, fallback, pause/resume, failed selections, normalization and hashing, bounded LRU state, atomic storage and locking, and fragmented compositor IPC. CI builds on macOS and Linux for arm64 and x86_64. Linux CI runs `scripts/smoke-linux.py` under Xvfb and a session D-Bus to exercise the native tray and persistence.

Manual desktop acceptance checks:

- Choose different layouts in two title-tracked tabs; revisit both and verify restoration.
- Rename a tab and verify app fallback, then teach its own layout.
- Pause, switch apps/layouts, and resume; check that paused changes were not learned.
- Use Force Default Layout and Clear Cache; restart and verify persistence.
- Remove a saved OS layout; verify that failed restoration is visible in the tray and manual switching still works.
- Measure idle RSS and CPU after startup and during focus/title/layout changes on each target desktop.

## Releasing

Set `version` in `Cargo.toml`, merge to `main`, then push a matching tag, for example `git tag v0.1.0 && git push origin v0.1.0`. The release workflow checks that the tag matches, tests and builds every platform, and publishes a GitHub release with checksums. Versions below 1.0 are published as pre-releases.

## Optional startup

On macOS, add the built app through System Settings → General → Login Items. On Linux, copy the binary into `~/.local/bin` and use either the provided [desktop entry](packaging/insomemo.desktop) or [systemd user service](packaging/insomemo.service). Ensure the compositor environment is imported before starting the service. Nothing is installed or enabled automatically.

## Native references

- [Apple application activation notification](https://developer.apple.com/documentation/appkit/nsworkspace/didactivateapplicationnotification)
- [Sway IPC specification](https://github.com/swaywm/sway/blob/master/sway/sway-ipc.7.scd)
- [Hyprland IPC](https://wiki.hypr.land/ipc/)

MIT licensed. See [LICENSE](LICENSE).
