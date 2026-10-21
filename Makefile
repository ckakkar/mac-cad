.DEFAULT_GOAL := help
.PHONY: help build run dmg check test lint bench smoke clean
export CLANG_MODULE_CACHE_PATH := $(CURDIR)/.build/ModuleCache
export SWIFTPM_MODULECACHE_OVERRIDE := $(CURDIR)/.build/ModuleCache
SWIFT = swift build --build-system native --disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security

help: ## List tasks
	@awk 'BEGIN {FS = ":.*## "} /^[a-z-]+:.*## / {printf "  %-10s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

build: ## Build the Apple Silicon MacCAD.app bundle
	cargo build --release --locked -p cad-core --lib
	$(SWIFT) -c release --arch arm64
	bash scripts/bundle.sh

run: build ## Build and open MacCAD.app
	open build/MacCAD.app

dmg: build ## Package build/MacCAD.dmg for direct download
	bash scripts/dmg.sh

lint: ## Rust formatting and clippy
	cargo fmt --all --check
	cargo clippy --locked --workspace --all-targets -- -D warnings

test: ## Core geometry, editing, files and ABI tests
	cargo test --locked --workspace

smoke: build ## Exercise the Swift/C/Rust bridge and verify the app bundle
	xcrun swiftc -target arm64-apple-macosx14.0 -import-objc-header native/CCadCore/include/cad_core.h scripts/bridge-smoke.swift -L target/release -lcad_core -o build/bridge-smoke
	build/bridge-smoke
	bash scripts/verify-bundle.sh
	build/MacCAD.app/Contents/MacOS/MacCAD --self-test

check: lint test smoke ## All local CI checks

bench: ## Measure CPU indexing, tessellation and picking (10k/100k lines)
	cargo run --release --locked -p cad-core --bin cad-bench

clean: ## Remove generated output
	cargo clean
	rm -rf .build build
