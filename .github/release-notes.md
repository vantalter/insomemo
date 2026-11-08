Insomemo remembers your keyboard layout per window, tab, and conversation on Linux and macOS. See the [README](https://github.com/vantalter/insomemo#readme) for setup.

## Downloads

| File | Platform |
| --- | --- |
| `Insomemo-*-macos-universal.zip` | macOS 12+, Apple Silicon and Intel |
| `insomemo-*-linux-x86_64.tar.gz` | Linux x86_64, glibc 2.35+ (Ubuntu 22.04, Debian 12, Fedora 36 or newer) |
| `insomemo-*-linux-arm64.tar.gz` | Linux arm64, glibc 2.35+ |
| `SHA256SUMS` | Checksums for the files above |

## Install

**macOS:** unzip and move `Insomemo.app` to `/Applications`. The app is not notarized, so the first launch is blocked by Gatekeeper: right-click the app and choose **Open**, or run `xattr -d com.apple.quarantine /Applications/Insomemo.app`. Then choose **Enable Window / Tab Tracking…** in its menu and grant Accessibility access.

**Linux:** needs GLib, json-glib, libX11, and libxkbcommon (installed on most desktops) and a StatusNotifier tray host. Copy `insomemo` to `~/.local/bin`, then enable the included systemd user service or desktop entry. Build from source on systems older than glibc 2.35.

## Privacy

Insomemo opens no network connections and does not read keystrokes. To confirm, run `lsof -nP -i -a -p "$(pgrep -x insomemo)"` while it runs: it prints nothing. See the README's Privacy section for what is read and stored.

## Known limitations

- macOS builds are ad-hoc signed. Updating may require granting Accessibility access again.
- Sway and Hyprland support is experimental: IPC handling is tested, but real desktops have not been validated.
- GNOME and KDE on Wayland are not supported.
