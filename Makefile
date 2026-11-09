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

app: build
	python3 scripts/bundle-macos.py

dmg: app
	scripts/make-dmg.sh dist/Insomemo.dmg

# Requires CODESIGN_IDENTITY and NOTARY_PROFILE; see README > Releasing.
notarize: build
	scripts/package-macos.sh target/release/insomemo dist/Insomemo

clean:
	cargo clean
