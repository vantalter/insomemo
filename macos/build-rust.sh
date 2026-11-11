#!/bin/sh
# Xcode build phase: compiles the Rust crate as a static library for each
# architecture Xcode builds and joins them into one library for the linker.
# It also writes version.h, which Info.plist preprocessing reads, so the app's
# version comes from Cargo.toml.
set -eu
# Xcode does not read shell profiles, so rustup's default location is added.
export PATH="$HOME/.cargo/bin:$PATH"
cd "$PROJECT_DIR/.."
# Cargo's dev profile builds into target/<triple>/debug.
if [ "$CONFIGURATION" = Debug ]; then profile=dev output=debug; else profile=release output=release; fi
libraries=""
for arch in $ARCHS; do
    case "$arch" in
    arm64) triple=aarch64-apple-darwin ;;
    x86_64) triple=x86_64-apple-darwin ;;
    *) echo "error: unsupported architecture $arch" >&2; exit 1 ;;
    esac
    if ! rustup target list --installed | grep -qx "$triple"; then
        echo "error: missing Rust target; run: rustup target add $triple" >&2
        exit 1
    fi
    cargo rustc --profile "$profile" --locked --lib --target "$triple" --crate-type staticlib
    libraries="$libraries target/$triple/$output/libinsomemo.a"
done
mkdir -p "$DERIVED_FILE_DIR"
lipo -create -output "$DERIVED_FILE_DIR/libinsomemo.a" $libraries
version=$(sed -n 's/^version = "\(.*\)"/\1/p' Cargo.toml | head -1)
echo "#define INSOMEMO_VERSION $version" > "$DERIVED_FILE_DIR/version.h"
