---
name: lithe-release
description: Use for any Git operation in the Lithe repository, including staging, committing, pushing, tagging, version changes, DMG packaging, GitHub Release creation, or release-note edits. Follow Lithe's direct-main workflow; do not create a worktree, pull, rebase, open a PR, push, or publish a release unless the maintainer's request authorizes that action.
---

# Lithe Release

Use this instruction-only workflow in `/Users/om/Projects/Lithe` with remote `OM-KEN/Lithe`.

## Interpret Authorization

- Treat “提交” as permission to commit, “推送” as permission to commit and push, and “发布 X.Y.Z” as permission to prepare, push, and publish that exact release.
- Do not infer push or release permission from a completed code change or a commit prefix.
- Use `main` directly. Do not create a branch, worktree, PR, stash, pull, or rebase unless explicitly requested.
- If local `main` and `origin/main` have diverged, stop and report both SHAs. Never force-push, rewrite a tag, or delete a release.

## Commit and Push

1. Confirm the repository root, `main`, and `origin`; run `git fetch origin main`, inspect `git status --short --branch`, and require `HEAD` to equal the refreshed `origin/main` before new commits.
2. Preserve unrelated changes. Stage exact paths; avoid `git add -A` in a mixed worktree.
3. Run `./run-tests.sh` for every change. Also run `./build.sh` after source, resource, codec, signing, or packaging changes.
4. Inspect `git diff --cached --check`, the staged file list, and the staged diff. Check that no credentials, private signing data, `.build/` output, or unrelated files are staged.
5. Commit one coherent change with a short imperative subject such as `fix: ...`, `feat: ...`, `docs: ...`, `chore: ...`, or `release: prepare vX.Y.Z`.
6. Push with `git push origin main`. Verify the local and remote SHAs match and the worktree has the expected state.

## Publish a Release

Run this section only when the maintainer explicitly requests a release.

1. Require an explicit SemVer version and update `VERSION`. Do not invent or silently bump a version.
2. Run `./run-tests.sh`, resolve an available Apple Development identity without recording private identity data, then run:

   ```bash
   LITHE_SIGN_IDENTITY="Apple Development: ..." ./package-dmg.sh --release
   ```

3. Confirm `.build/Lithe-X.Y.Z.dmg`, its SHA-256 file, embedded app version, universal architectures, signature verification, and DMG mount contents.
4. Commit and push the release preparation before publishing. Confirm that `vX.Y.Z` and its GitHub Release do not already exist; stop if either exists unexpectedly.
5. Write concise, user-facing Chinese and English notes in an ignored `.build/` file. State visible changes and a short installation hint only. Omit internal workflow, signing, notarization, codec internals, and unrelated projects.
6. Create the release against the pushed commit and attach only the DMG:

   ```bash
   gh release create vX.Y.Z .build/Lithe-X.Y.Z.dmg --repo OM-KEN/Lithe --target COMMIT_SHA --title "Lithe X.Y.Z" --notes-file .build/release-notes-X.Y.Z.md --latest
   ```

7. Verify the release URL, tag target, asset name, size, and digest. Download the asset to a temporary directory, compare its SHA-256 with the local DMG, and verify it mounts.

## Report

Report tests, commit SHA, push result, and—when applicable—the release URL and DMG SHA-256. Keep the summary concise and disclose anything skipped or blocked.
