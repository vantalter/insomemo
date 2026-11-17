# Contributing to Insomemo

Thanks for helping. Bug reports, desktop compatibility reports, and pull requests are all welcome.

## Reporting a bug

Open an issue with the bug report form. Layout switching depends heavily on the desktop, so please include your operating system, session (X11, Sway, Hyprland, or macOS), tray host on Linux, the app whose window or tab was involved, and the Insomemo version from `insomemo --version`. Terminal output from running `insomemo` directly often shows the cause.

Window titles can contain private information. Check logs and screenshots before attaching them.

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

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
