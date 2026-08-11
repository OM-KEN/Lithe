# Repository Guidelines

## Project Structure & Module Organization

Lithe is a macOS 14+ Swift utility built with AppKit and SwiftUI. Production sources live at the repository root. `LitheApp.swift` defines the app entry and lifecycle; `SessionCoordinator.swift` and `SessionModel.swift` own workflow state; `CompressionEngine.swift`, `ToolRunner.swift`, and `FileLifecycle.swift` handle encoding, subprocesses, snapshots, and atomic publication. UI code is split across `ResultUI.swift`, `InspectorUI.swift`, and `SettingsView.swift`. Tests live in `Tests/CoreTests.swift`. Bundled universal codec binaries and their licenses are under `Vendor/bin/` and `Vendor/licenses/`. Treat `.build/` as generated output.

## Build, Test, and Development Commands

- `./run-tests.sh` compiles the custom Swift test executable, runs core regression tests, and smoke-tests all four bundled codecs, architectures, and dynamic dependencies.
- `./build.sh` builds, signs, and verifies the arm64+x86_64 app at `.build/Lithe.app`. Close any running copy from that path first.
- `./package-dmg.sh` builds and verifies a versioned DMG; `--release` requires an Apple Development signing identity.
- `LITHE_SIGN_IDENTITY="Apple Development: …" ./build.sh` creates a locally signed build; the default is ad-hoc signing.
- `./vendor-<tool>.sh` reproducibly rebuilds one bundled codec from pinned upstream inputs. Do not use these scripts for ordinary app builds.

## Architecture & Safety Boundaries

Keep compression logic independent of windows, Finder, and clipboard code. Route external processes through `ToolRunner` using executable URLs and argument arrays. Original snapshots are immutable; never overwrite source files or unverified user-modified outputs. Preserve generation checks, cancellation, atomic publication, and session cleanup when changing asynchronous flows.

## Coding Style & Naming Conventions

Use four-space indentation. Name types in `UpperCamelCase`, members and enum cases in `lowerCamelCase`, and prefer descriptive domain names over abbreviations. No formatter or linter is configured, so match nearby Swift style and keep patches focused. Use semantic colors and SF Symbols in UI work.

## Testing Guidelines

Tests use a small custom runner rather than XCTest. Add descriptive `lowerCamelCase` regression methods to `Tests/CoreTests.swift`, invoke them from `CoreTests.main`, and exercise the production path. Run `./run-tests.sh` for every change and `./build.sh` for source, resource, signing, or dependency changes. Include manual screenshots for visible panel or inspector changes.

## Commit & Release Guidelines

Lithe normally uses a direct `main` workflow: do not create a worktree, branch, pull request, pull, or rebase unless the maintainer explicitly asks. Use short imperative subjects (for example, `fix: preserve JPEG density`) and keep commits single-purpose. Never push or publish a release without maintainer approval.
