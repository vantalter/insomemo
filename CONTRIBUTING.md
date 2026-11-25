# Contributing to Insomemo

Thanks for helping. Bug reports, desktop compatibility reports, and pull requests are all welcome.

## Reporting a bug

Choose **Report a Problem…** in **Settings → Support** on macOS or in the tray menu on Linux. It opens the bug report form with Insomemo's version, the platform, and your system filled in. Layout switching depends heavily on the desktop, so please also name the app whose window or tab was involved, and on Linux the tray host.

On macOS, the debug log in **Settings → General** records what Insomemo saw and did, with window titles and sites only as codes; turn it on, reproduce the problem, and attach the log. On Linux, terminal output from running `insomemo` directly often shows the cause.

Window titles can contain private information. Check screenshots and terminal output before attaching them.

## Building and testing

The [README](README.md) lists the build dependencies for Linux and macOS. Before opening a pull request, run:

```sh
make check   # rustfmt and clippy, warnings as errors
make test    # unit tests
```

On Linux, the tray and persistence smoke test needs Xvfb and a session D-Bus:

```sh
cargo build --release --locked
dbus-run-session -- xvfb-run -a cargo test --release --test smoke_linux -- --ignored
```

On macOS, also run `make app`, then `scripts/check-macos-app.sh`, and launch `dist/Insomemo.app`. The build goes through the Xcode project and links the release configuration, which catches problems that `cargo build` does not; the check confirms the app's version, Sparkle settings, and signatures, as CI does.

Native code follows [.clang-format](.clang-format), with a 100-column limit.

## Pull requests

- Keep each pull request to one change, and describe what it fixes and how you tested it.
- Explain behaviour changes in the README when they affect users.
- CI must pass on macOS and Linux.
- Do not bump the version in `Cargo.toml`; releases are cut separately.

## Releasing

Set `version` in `Cargo.toml`, merge to `main`, then push a matching tag, for example `git tag v0.1.0 && git push origin v0.1.0`. The release workflow checks that the tag matches, tests and builds every platform, and publishes a GitHub release with checksums. Only versions with a suffix, such as `1.2.0-beta`, are published as pre-releases, because the macOS app reads its update feed from the latest release, which GitHub never sets to a pre-release.

A pre-release updates to its final release: the app's bundle version, which Sparkle compares, drops the suffix's separators, so `0.4.0-rc.1` becomes `0.4.0rc1`, which comes before `0.4.0` ([scripts/bundle-version.sh](scripts/bundle-version.sh)). Pre-releases are not offered as updates to anyone, so testers install them from the releases page.

Sparkle's update window lists the titles of the commits since the previous release, or since the previous final release for a final one. Titles starting with "Release" are left out, and a merged pull request shows its own title. Users read these titles, so give pull requests titles that say what changed for them.

The macOS app updates itself from `appcast.xml`, a feed the workflow adds to each release. Sparkle installs only updates signed with the project's private EdDSA key. Create the key once with Sparkle's `generate_keys` tool, which Xcode downloads with the package (Xcode → Settings → Locations shows the DerivedData folder):

```sh
tools=$(find ~/Library/Developer/Xcode/DerivedData -path '*artifacts/sparkle/Sparkle/bin' | head -1)
"$tools/generate_keys" --account insomemo        # stores the key in your login keychain
"$tools/generate_keys" --account insomemo -p > macos/sparkle-public-key
"$tools/generate_keys" --account insomemo -x sparkle-private-key   # for the workflow
gh secret set SPARKLE_PRIVATE_KEY < sparkle-private-key && rm sparkle-private-key
```

Commit `macos/sparkle-public-key`; the build puts it in the app's `Info.plist`. Without the `SPARKLE_PRIVATE_KEY` secret, a release has no update feed and the workflow says so in a warning. Keep the private key safe: anyone holding it can publish updates the app accepts, and losing it means existing installations can no longer update automatically.

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

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
