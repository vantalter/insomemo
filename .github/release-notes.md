Insomemo remembers your keyboard layout per window, tab, and conversation on Linux and macOS. See the [README](https://github.com/vantalter/insomemo#readme) for setup.

## Downloads

| File | Platform |
| --- | --- |
| `Insomemo-*-macos-universal.dmg` | macOS 12+, Apple Silicon and Intel |
| `Insomemo-*-macos-universal.zip` | The same app as a zip, for scripted installs |
| `insomemo_*_amd64.deb`, `insomemo_*_arm64.deb` | Ubuntu 22.04+, Debian 12+, and derivatives such as Linux Mint and Pop!_OS |
| `insomemo-*.x86_64.rpm`, `insomemo-*.aarch64.rpm` | Fedora 36+, openSUSE Tumbleweed, and other RPM distributions with glibc 2.35+ |
| `insomemo-*-linux-x86_64.tar.gz`, `insomemo-*-linux-arm64.tar.gz` | Any other Linux with glibc 2.35+ |
| `SHA256SUMS` | Checksums for the files above |

## Install

<!-- signed -->
**macOS:** open the `.dmg` and drag Insomemo onto the Applications shortcut. The app is signed with a Developer ID and notarized by Apple, so it opens normally. Then choose **Enable Window / Tab Tracking…** in its menu and grant Accessibility access. To start Insomemo automatically, choose **Launch at Login** once the app is in `/Applications`; the login item points at the app's current location.
<!-- /signed -->
<!-- unsigned -->
**macOS:** open the `.dmg` and drag Insomemo onto the Applications shortcut. This build is not yet notarized, so macOS blocks the first launch. On macOS 15 or newer, open it once, then choose **Open Anyway** in System Settings → Privacy & Security. On macOS 12–14, right-click the app and choose **Open**. Alternatively, run `xattr -d com.apple.quarantine /Applications/Insomemo.app`. Then choose **Enable Window / Tab Tracking…** in its menu and grant Accessibility access. To start Insomemo automatically, choose **Launch at Login** once the app is in `/Applications`; the login item points at the app's current location.
<!-- /unsigned -->

**Debian, Ubuntu:** `sudo apt install ./insomemo_*_amd64.deb` (or `arm64`). **Fedora, openSUSE:** `sudo dnf install ./insomemo-*.x86_64.rpm` (or `zypper install`, or `aarch64`). The package manager installs GLib, json-glib, libX11, libxkbcommon, and GdkPixbuf, and Insomemo appears in your application menu. **Other distributions:** extract the tarball, install those libraries, and copy `insomemo` to `~/.local/bin`.

Then choose **Launch at Login** in the tray menu; a StatusNotifier tray host is needed for the menu. On Sway and Hyprland, which ignore autostart entries, run `systemctl --user enable --now insomemo` instead (packages include the unit; for the tarball, copy `insomemo.service` to `~/.config/systemd/user/`). Build from source on systems older than glibc 2.35.

## Privacy

Insomemo opens no network connections and does not read keystrokes. To confirm, run `lsof -nP -i -a -p "$(pgrep -x insomemo)"` while it runs: it prints nothing. See the README's Privacy section for what is read and stored.

## Known limitations

<!-- unsigned -->
- This macOS build is ad-hoc signed, so after updating, macOS treats it as a new app. If the menu still says **Enable Window / Tab Tracking…**, run `tccutil reset Accessibility dev.insomemo.app` and grant the permission again (see the README's Troubleshooting section).
<!-- /unsigned -->
- Sway and Hyprland support is experimental: IPC handling is tested, but real desktops have not been validated.
- GNOME and KDE on Wayland are not supported.
