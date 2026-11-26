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
- Title it in the [Conventional Commits](https://www.conventionalcommits.org) form, which CI checks: `fix: …` for a bug fix, `feat: …` for a new feature, and `docs:`, `ci:`, `test:`, `refactor:`, `build:`, or `chore:` for changes users do not notice. Add `!` after the type, as in `feat!: …`, for a change that breaks existing setups. Pull requests are squash-merged under their title, which decides the next version and becomes a line in the changelog and in the app's update window, so after the type, say what changed for users.
- Explain behaviour changes in the README when they affect users.
- CI must pass on macOS and Linux.
- Do not bump the version in `Cargo.toml` or edit `CHANGELOG.md`; release-please does both.

## Releasing

Releases are prepared by [release-please](https://github.com/googleapis/release-please). After each merge to `main`, it keeps a release pull request open, titled like `chore: release 0.4.0`, that sets the next version in `Cargo.toml` and `Cargo.lock` and adds the changes to `CHANGELOG.md`. While Insomemo is below 1.0, `feat:` raises the minor version (0.3.5 to 0.4.0), `fix:` and `perf:` the patch version (0.3.5 to 0.3.6), and a breaking change also the minor version. Titles of other types are left out of the changelog and start no release.

To release, merge the release pull request. release-please then tags the merge and creates a draft release with the changelog, and the release workflow tests and builds every platform, attaches the files and their checksums, puts the install notes above the changelog, and publishes the release. Until then the release stays a draft, so the app's update feed never points at a release without its files. If the build fails, fix the cause and re-run the failed jobs from the Actions tab; the draft waits.

The pull request is opened with the workflow's own token, so CI does not run on it; it changes only the version and the changelog. Two repository settings are needed: **Settings → Actions → General → Allow GitHub Actions to create and approve pull requests**, and, under **Settings → General → Pull Requests**, squash merging with **Default to pull request title**, so a single-commit pull request is still merged under its title.

Pushing a tag by hand still runs the release workflow, for a tag that matches the version in `Cargo.toml`, as in `git tag v0.4.0 && git push origin v0.4.0`. Release-please does not make pre-releases: for a release candidate, set a version such as `0.4.0-rc.1` in `Cargo.toml` by hand, merge it, and push its tag; the release pull request sets the final version again. Only versions with a suffix are published as pre-releases, because the macOS app reads its update feed from the latest release, which GitHub never sets to a pre-release.

A pre-release updates to its final release: the app's bundle version, which Sparkle compares, drops the suffix's separators, so `0.4.0-rc.1` becomes `0.4.0rc1`, which comes before `0.4.0` ([scripts/bundle-version.sh](scripts/bundle-version.sh)). Pre-releases are not offered as updates to anyone, so testers install them from the releases page.

Sparkle's update window lists the titles of the commits since the previous release, or since the previous final release for a final one, without their `fix:` or `feat:` prefix. Release pull requests and titles of other types, such as `docs:` or `ci:`, are left out.

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
