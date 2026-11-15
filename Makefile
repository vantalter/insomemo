.PHONY: build test check run app dmg notarize clean

build:
	cargo build --release --locked

test:
	cargo test --locked

check:
	cargo fmt --all -- --check
	cargo clippy --locked --all-targets -- -D warnings

run:
	cargo run --release --locked

app:
	scripts/build-macos-app.sh

dmg: app
	scripts/make-dmg.sh dist/Insomemo.dmg

# Requires CODESIGN_IDENTITY and NOTARY_PROFILE; see README > Releasing.
notarize:
	scripts/package-macos.sh dist/Insomemo

clean:
	cargo clean
