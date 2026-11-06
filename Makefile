.PHONY: build test check run app clean

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

clean:
	cargo clean
