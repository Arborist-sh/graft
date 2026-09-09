# React Native iOS — fast-build reference

A copy-paste path to the fastest job graft can give a React Native iOS team: a golden
image with the app tree, node_modules, Pods, and DerivedData already baked in, paired
with a workflow that doesn't undo the baking. Two of the biggest wins here live in the
*workflow*, not the image — graft can't change `actions/checkout`'s behavior for you, so
this doc walks the whole path end to end.

Recipe: [`examples/images/rn-ios.graft`](../examples/images/rn-ios.graft). Background on
`repos:`, `path:`, and `ccache:` individually: [images-and-caching.md](images-and-caching.md).

## Where the time goes

Rough ranges for a mid-size RN iOS job, cold (stock runner) vs. warm (graft image):

| Phase | Cold | Warm |
|---|---|---|
| VM boot + runner register | 30–60s | 30–60s |
| `actions/checkout` | 0.5–3 min | 5–15s |
| `yarn install` | 1–3 min | seconds |
| `pod install` | 2–6 min | seconds, or skipped entirely |
| `xcodebuild` | 10–25 min | 1–4 min |
| Simulator boot | 30–90s | seconds |

VM boot and checkout barely move — they're bounded by hardware and repo size, not
caching. **The compile is the whole game**: `xcodebuild` dwarfs everything else on a
cold runner, and shaving 20+ minutes off it is where a warm image actually pays for
itself.

## The layering

Two caches stack, in order of how much they cover and how easily they break:

1. **Warm DerivedData at a stable path** is the fast path, and it's the only thing that
   covers Swift — Xcode's own incremental build. It only helps if the job's checkout
   lands at the *same path* DerivedData was warmed at (DerivedData is keyed by a hash of
   the project path), which is exactly what `repos: path: workspace` buys you.
2. **`ccache` is the floor underneath it** — a content-addressed, path-independent store
   for the ObjC/C++ compiles React Native's pods emit. It doesn't cover Swift, but it
   survives what DerivedData can't: an Xcode point upgrade, a clean build, a scheme
   change. When DerivedData gets invalidated, ccache is what keeps the rebuild from going
   all the way back to a cold compile.

Both caches live **in the image**, not in `actions/cache`. Every runner VM is a Tart
clone — an APFS copy-on-write snapshot — so every runner gets its own writable copy of
the baked caches for free, instantly, with no zip/unzip and no cache-service round trip
anywhere in the job. The tradeoff is staleness: rebake the image (a nightly cron is
enough for most teams) so the incremental delta a job has to catch up on stays small.

## The recipe

See [`examples/images/rn-ios.graft`](../examples/images/rn-ios.graft) in full. The parts
that make this fast:

```yaml
repos:
  - url: https://github.com/your-org/app.git
    ref: main
    path: workspace              # bake the tree at the exact path actions/checkout uses
    run:
      - yarn install --frozen-lockfile
      - cd ios && bundle exec pod install
      - cd ios && xcodebuild -workspace App.xcworkspace -scheme App -sdk iphonesimulator \
          -configuration Debug -destination 'generic/platform=iOS Simulator' \
          -derivedDataPath build build CODE_SIGNING_ALLOWED=NO
      - shasum -a 256 ios/Podfile.lock | awk '{print $1}' > "$HOME/.rn-ios-baked-podfile-lock-sha256"

ccache: true                     # floor under DerivedData for ObjC/C++ pods
```

`path: workspace` resolves to `$HOME/actions-runner/_work/<repo>/<repo>` — the same
directory `actions/checkout` writes to — so the job's checkout lands on top of the baked
tree instead of next to it, and DerivedData's path-keyed cache actually applies. The
`shasum` line bakes a marker of the Podfile.lock this image was built against, which the
workflow below uses to decide whether `pod install` needs to run at all.

`-derivedDataPath build` keeps DerivedData inside the tree (`ios/build`, already in React
Native's default `.gitignore`) instead of under `~/Library/Developer/Xcode/DerivedData/<Name>-<path-hash>`.
That does two things: the warm build travels with the kept tree regardless of DerivedData's
path hash, and the `-I`/`-F` search paths into `Build/Products` sit under ccache's `base_dir`,
so its path rewriting covers them. Use the same flag at bake time and in the job.

**Baked source, not just caches.** With `path:` set, the app's source lives in the image,
not just its dependency caches — fine for a private runner pool, not something to publish.

## The workflow

The image alone doesn't help if the job's own `actions/checkout` throws away what was
baked. Two adjustments matter, both in `.github/workflows/ios.yml`:

```yaml
name: iOS
on: [pull_request]

jobs:
  build:
    runs-on: [self-hosted, macos, rn-ios]   # match the pool's `labels:` in ~/.graft config
    steps:
      - uses: actions/checkout@v4
        with:
          clean: false        # default is `git clean -ffdx` — wipes node_modules/Pods/.yarn
          fetch-depth: 1

      - name: yarn install
        run: yarn install --frozen-lockfile   # fast: node_modules is already warm

      - name: pod install (only if Podfile.lock changed)
        run: |
          cd ios
          if [ -f "$HOME/.rn-ios-baked-podfile-lock-sha256" ] && \
             [ "$(shasum -a 256 Podfile.lock | awk '{print $1}')" = "$(cat "$HOME/.rn-ios-baked-podfile-lock-sha256")" ]; then
            echo "Podfile.lock unchanged since bake — skipping pod install"
          else
            bundle exec pod install
          fi

      - name: xcodebuild
        run: |
          cd ios
          xcodebuild -workspace App.xcworkspace -scheme App -sdk iphonesimulator \
            -configuration Debug -destination 'generic/platform=iOS Simulator' \
            -derivedDataPath build build CODE_SIGNING_ALLOWED=NO

      - name: ccache stats
        run: ccache -s
```

**Why compare against a baked marker instead of `git diff HEAD@{1}`:** graft's runners
are ephemeral — a VM boots fresh from the same image, runs exactly one job, and tears
down (see the project README) — so there's no reflog or prior-job git history to diff
against on the runner itself. Comparing the job's `Podfile.lock` to a hash written *at
bake time* is the check that's actually true across ephemeral VMs: it answers "does this
job's lockfile match what this image's `Pods/` was built against", which is the only
question that matters here.

Two things you own in your own repo, not in the image. React Native's post-install hook
needs `:ccache_enabled => true` for ccache to see any compiles at all, and RN's ccache
wrapper must be pointed at graft's config: the wrapper sets `CCACHE_CONFIGPATH` to RN's own
bundled file unless it is already set, and ccache reads only that one file, so without the
build setting below graft's `base_dir`/`hash_dir` tuning is never read and the bake-time
fill misses at job time. graft's config is a superset of RN's, so nothing regresses.

```ruby
# ios/Podfile
react_native_post_install(
  installer,
  config[:reactNativePath],
  :mac_catalyst_enabled => false,
  :ccache_enabled => true
)

installer.pods_project.targets.each do |target|
  target.build_configurations.each do |config|
    config.build_settings['CCACHE_CONFIGPATH'] = "#{ENV['HOME']}/Library/Preferences/ccache/ccache.conf"
  end
end
```

## Tradeoffs and gotchas

- **Source is baked into the image.** `path:` keeps the app's tree in the image, not
  just its caches — keep the image private, never `graft image push` it to a public
  registry.
- **`clean: false` means the job trusts the baked tree.** This is safe: `actions/checkout`
  still does a `git fetch` + `git reset --hard` on top of it (that's the checkout, not the
  clean step) — `clean: false` only turns off the *extra* `git clean -ffdx` that deletes
  untracked files. It does not skip verifying the tree against the ref you asked for.
- **DerivedData can still be invalidated** by an Xcode upgrade, a scheme change, or a
  clean build — this is exactly why ccache exists underneath it. When DerivedData goes
  cold, ccache is what keeps the rebuild from being a full cold compile.
- **Rebake when it matters.** Bump the image whenever Xcode changes, or whenever
  `Podfile.lock` drifts far enough that the baked `Pods/` and marker are stale for most
  jobs — a nightly rebuild keeps the incremental delta small either way.
