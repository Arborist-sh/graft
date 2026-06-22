# CLAUDE.md

Guidance for Claude Code (and humans) working in the **graft** repo. Keep this file
accurate — if a command, path, or step here drifts from reality, fix it.

## What graft is

One golden [Tart](https://tart.run) VM image for macOS that powers both a **dev
environment** and **ephemeral GitHub Actions runners**, off a single `.graft` seed.
Open-source CLI; **macOS / Apple Silicon only** (Linux guests are a planned future
epic, not supported today). The three verbs:

- `graft sapling grow` — bake a golden image ("sapling") with toolchain + warm caches.
- `graft nest` — develop *inside* that image over VS Code Remote-SSH.
- `graft arborist tend` — ephemeral runners: each VM boots, registers, runs exactly one
  job (JIT runners), then tears down.

Commercial note: the **CLI stays OSS and free**; monetization is a hosted control plane
(arborist.sh). Don't add paywalls or license gates to the CLI.

## Layout

Swift Package (`Package.swift`, swift-tools 6.0, macOS 14+) with two products plus an
Xcode app generated from `project.yml`:

| Path | What |
|------|------|
| `Sources/GraftCore/` | Library — all the real logic (VM, GitHub App auth, secrets, image builder, pools, health, Orchard backend, registry). |
| `Sources/graft/` | The `graft` CLI executable (ArgumentParser). Subcommands live in `Sources/graft/Commands/`. Entry point + `version:` string is `Sources/graft/Graft.swift`. |
| `GraftBar/` | The macOS menu-bar / desktop app (SwiftUI). Built via **XcodeGen** (`project.yml` → `Graft.xcodeproj`), not SwiftPM. |
| `Tests/GraftCoreTests/` | XCTest suite (~21 files) against `GraftCore`. |
| `scripts/` | `dev-link.sh`, `dev-app.sh`, `release-app.sh` (see below). |
| `Assets/` | README banner SVGs + generated PNGs. |
| `docs/` | `orchard.md`, `images-and-caching.md`, `health-and-monitoring.md`, `dev-boxes.md`, `ec2-mac-setup.md`. |
| `examples/`, `editors/vscode/` | Example `.graft` images; VS Code extension (published as `arborist-sh.graftfile`). |

Dependencies: `swift-argument-parser`, `Yams` (YAML for `.graft` seeds).

## Build, dev, test

```sh
# CLI (release binary used by the brew formula)
swift build -c release            # -> .build/release/graft
sudo cp .build/release/graft /usr/local/bin/graft

# Tests
swift test                        # GraftCore unit tests

# Local dev CLI: build + sign + symlink the dev build AS `graft`
scripts/dev-link.sh               # dev mode
scripts/dev-link.sh restore       # back to the brew release

# Desktop app (ad-hoc signed, local testing) — regenerates the Xcode project
scripts/dev-app.sh

# Regenerate the Xcode project after editing project.yml
xcodegen generate
```

App signing identity: `DEVELOPMENT_TEAM 27N85AU6XK`, bundle id `dev.graft.Graft`,
hardened runtime on. `project.yml` stamps the short git commit into `Info.plist` via a
post-build script.

## Repo conventions

- **`main` is PR-only**, guarded by a **GitHub ruleset** (not classic branch protection —
  the `branches/main/protection` API 404s). Direct `git push origin main` is rejected.
  The repo **squash-merges** (one `… (#N)` commit per PR). Tag the squashed commit on
  main *after* it lands; never push a tag before the commit is on main.
- **Branch naming:** `type/ticket-#/description` (no username prefix).
- **Commits are signed by default** (SSH signing via 1Password). Plain `git commit`
  signs — don't disable `gpgsign`. If commits show Unverified `unknown_key`, the GitHub
  SSH signing key needs re-registering.
- **`main` lives in the primary worktree** — do release commits there. Other work uses
  sibling worktrees at `graft-workspace/graft-<branch-slug>`.
- `dist/` is gitignored (release build output lands there).

## Release checklist (`vX.Y.Z`)

Codename for the 0.5.x series is **Sakura** (used in the banner pill).

### 1. Bump the version — every spot

The version string lives in **5 places**; all must match or things drift:

1. `project.yml` → `MARKETING_VERSION`
2. `Sources/graft/Graft.swift` → `version:` (the `graft --version` output + the test assert)
3. `Assets/header-light.svg` → version pill text (`vX.Y.Z · Sakura`)
4. `Assets/header-dark.svg` → version pill text (`vX.Y.Z · Sakura`)
5. `README.md` → the `?v=X.Y.Z` cache-bust on **both** the dark `<source srcset>` and
   the `<img src>`, **plus the alt text**. (GitHub's camo proxy serves the stale banner
   PNG otherwise.)

### 2. Regenerate banner PNGs from the SVGs

PNGs are 1280×300 (2× the 640×150 SVG). `rsvg-convert` + `magick` are installed.

```sh
rsvg-convert -w 1280 -h 300 Assets/header-light.svg -o Assets/header-light.png
rsvg-convert -w 1280 -h 300 Assets/header-dark.svg  -o Assets/header-dark.png
```

### 3. Land on main + tag

Open a PR with the version bumps, squash-merge, then tag the squashed main commit and
push the tag:

```sh
git tag vX.Y.Z <squashed-commit>
git push origin vX.Y.Z
```

Create the GitHub release for the tag (`gh release create vX.Y.Z …`).

### 4. Build & upload the CLI tarball — DON'T SKIP THIS

> **This step broke v0.5.4:** the release was tagged and titled but shipped with **zero
> assets**, so the Homebrew formula couldn't be bumped and `brew` stayed on the prior
> version. The CLI tarball is built and attached **manually** — there is no CI workflow
> that does it. Always verify `gh release view vX.Y.Z` shows the tarball before moving on.

The formula installs just the `graft` binary (`bin.install "graft"`), so the tarball is
the release binary at the tar root (adhoc/linker-signed — that's what `swift build`
produces, matches prior releases, needs no Apple creds):

```sh
swift build -c release
mkdir -p dist && cp .build/release/graft dist/graft
( cd dist && tar -czf graft-X.Y.Z-arm64-macos.tar.gz graft )
shasum -a 256 dist/graft-X.Y.Z-arm64-macos.tar.gz     # note the sha256
gh release upload vX.Y.Z dist/graft-X.Y.Z-arm64-macos.tar.gz --repo arborist-sh/graft
gh release view vX.Y.Z --repo arborist-sh/graft --json assets   # verify it's attached
```

### 5. Bump the Homebrew formula (CLI)

Tap repo: `arborist-sh/homebrew-tap`, formula `Formula/graft.rb`. Update **four** fields,
via a PR (tap `main` is not protected, so it can be squash-merged once green):

- `url` → the vX.Y.Z tarball URL
- `sha256` → the checksum from step 4
- `version` → X.Y.Z
- the test `assert_match "X.Y.Z", …`

Verify end to end: `brew update && brew upgrade graft && graft --version`.

### 6. Notarized desktop app + cask (needs Apple Developer creds — Brian only)

`scripts/release-app.sh X.Y.Z` builds, Developer-ID-signs, **notarizes**, and staples
`Graft.app` into `dist/Graft-X.Y.Z.zip`. Requires:
- a "Developer ID Application" cert in the login keychain, and
- a stored notary profile named `graft-notary` (`GRAFT_NOTARY_PROFILE` to override).

Then attach the `.zip` to the release and bump the **cask** (`graft-app`) with the new
url + sha256. This step is **not automatable from a headless session** — it's Brian's.
`brew install --cask arborist-sh/tap/graft-app` installs this (CLI included).

## Gotchas

- Don't confuse the two brew artifacts: **`graft`** (formula → CLI tarball, automatable)
  vs **`graft-app`** (cask → notarized `.zip`, needs Apple creds). A release isn't done
  until *both* are attached and *both* taps are bumped.
- The Graft EC2 Mac host runs over SSH and needs the no-nohup boot path + a system
  keychain for secrets.
- `brew style Formula/graft.rb` flags two pre-existing ordering nits (version-before-sha256,
  dependency order). Harmless; `brew style --fix` if you want them gone.
