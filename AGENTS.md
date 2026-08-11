# Repository Guidelines

## Project Structure & Module Organization

Lithe is a macOS 14+ Swift utility built with AppKit and SwiftUI. Production sources live at the repository root. `LitheApp.swift` defines the app entry and lifecycle; `SessionCoordinator.swift` and `SessionModel.swift` own workflow state; `CompressionEngine.swift`, `ToolRunner.swift`, and `FileLifecycle.swift` handle encoding, subprocesses, snapshots, and atomic publication. UI code is split across `ResultUI.swift`, `InspectorUI.swift`, and `SettingsView.swift`. Tests live in `Tests/CoreTests.swift`. Bundled universal codec binaries and their licenses are under `Vendor/bin/` and `Vendor/licenses/`. Treat `.build/` as generated output.

## Build, Test, and Development Commands

- `./run-tests.sh` compiles the custom Swift test executable, runs core regression tests, and smoke-tests all four bundled codecs, architectures, and dynamic dependencies.
- `./build.sh` builds, signs, and verifies the arm64+x86_64 app at `.build/Lithe.app`. Close any running copy from that path first.
- `./package-dmg.sh` builds and verifies a versioned DMG; `--release` requires Apple signing and notarizes when Developer ID credentials are provided.
- `LITHE_SIGN_IDENTITY="Developer ID Application: …" ./build.sh` creates a Developer ID-signed build; the default is ad-hoc signing.
- `./vendor-<tool>.sh` reproducibly rebuilds one bundled codec from pinned upstream inputs. Do not use these scripts for ordinary app builds.

## Architecture & Safety Boundaries

Keep compression logic independent of windows, Finder, and clipboard code. Route external processes through `ToolRunner` using executable URLs and argument arrays. Original snapshots are immutable; never overwrite source files or unverified user-modified outputs. Preserve generation checks, cancellation, atomic publication, and session cleanup when changing asynchronous flows.

## Coding Style & Naming Conventions

Use four-space indentation. Name types in `UpperCamelCase`, members and enum cases in `lowerCamelCase`, and prefer descriptive domain names over abbreviations. No formatter or linter is configured, so match nearby Swift style and keep patches focused. Use semantic colors and SF Symbols in UI work.

## Testing Guidelines

Tests use a small custom runner rather than XCTest. Add descriptive `lowerCamelCase` regression methods to `Tests/CoreTests.swift`, invoke them from `CoreTests.main`, and exercise the production path. Run `./run-tests.sh` for every change and `./build.sh` for source, resource, signing, or dependency changes. Include manual screenshots for visible panel or inspector changes.

## Commit & Pull Request Guidelines

Use short imperative subjects, preferably scoped (for example, `fix: preserve JPEG density`). Keep commits single-purpose. Pull requests should explain behavior, list verification commands, link relevant issues, include UI screenshots when applicable, and document any codec or license changes. Do not push without maintainer approval.
