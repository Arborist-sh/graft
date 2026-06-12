const vscode = require("vscode");

// Field metadata drives completion + hover (and documents what each compiles to).
const FIELDS = {
  name: { detail: "string", doc: "Local image name produced by the build.", insert: "name: " },
  from: { detail: "string", doc: "Base Tart image to clone, e.g. `ghcr.io/cirruslabs/macos-sequoia-xcode:latest`.", insert: "from: " },

  // ── Toolchain ──
  xcode: { detail: "version", doc: "Select active Xcode → `sudo xcodes select <version>`.", insert: "xcode: \"$0\"" },
  node: { detail: "version", doc: "Node version → `fnm install`/`default` + `corepack` + a stable `/usr/local/bin` node symlink (Xcode needs it). Installs fnm if missing.", insert: "node: \"$0\"" },
  ruby: { detail: "version", doc: "Ruby version → `rbenv install` + `global` + rbenv shims + `bundler`.", insert: "ruby: \"$0\"" },
  python: { detail: "version", doc: "Python version → `pyenv install` + `global` + `pip` upgrade.", insert: "python: \"$0\"" },
  java: { detail: "version", doc: "OpenJDK major version → `brew install openjdk@<v>` + JavaVirtualMachines symlink.", insert: "java: \"$0\"" },
  go: { detail: "boolean", doc: "Install Go → `brew install go`.", insert: "go: true" },
  rust: { detail: "version", doc: "Rust toolchain → `rustup toolchain install` + `default` (e.g. `stable`).", insert: "rust: \"$0\"" },
  "package-manager": { detail: "pnpm | yarn | bun", doc: "JS package manager. pnpm/yarn via `corepack prepare`; bun via brew.", insert: "package-manager: $0" },
  brew: { detail: "string[]", doc: "Homebrew formulae → `brew install …`.", insert: "brew: [$0]" },
  cocoapods: { detail: "version", doc: "CocoaPods → `gem install cocoapods -v <v>`. Pair with `ruby:` so it lands on a modern ruby.", insert: "cocoapods: \"$0\"" },
  fastlane: { detail: "boolean", doc: "Install fastlane → `gem install fastlane`.", insert: "fastlane: true" },
  gems: { detail: "string[]", doc: "RubyGems → `gem install … --no-document`.", insert: "gems: [$0]" },
  npm: { detail: "string[]", doc: "Global npm packages → `npm install -g …`.", insert: "npm: [$0]" },
  "xcode-first-launch": { detail: "boolean", doc: "Run `sudo xcodebuild -runFirstLaunch` (install Xcode components headlessly).", insert: "xcode-first-launch: true" },
  "simulator-runtimes": { detail: "string[]", doc: "Download simulator runtimes by platform → `xcodebuild -downloadPlatform <name>`. E.g. [\"iOS 26\"].", insert: "simulator-runtimes: [\"$0\"]" },
  "warm-simulators": { detail: "string[]", doc: "Cold-boot each simulator once (warms on-disk caches), then shut down.", insert: "warm-simulators: [\"$0\"]" },

  // ── System config (baked into the image) ──
  env: { detail: "map", doc: "Environment variables → exported for the build + persisted to `/etc/zshenv` for runner shells.", insert: "env:\n  $0" },
  git: { detail: "{ user, email }", doc: "Global git identity → `git config --global user.name/.email`.", insert: "git: { user: \"$1\", email: \"$0\" }" },
  "known-hosts": { detail: "string[]", doc: "Pre-seed SSH host keys → `ssh-keyscan` into `~/.ssh/known_hosts` (no clone prompts).", insert: "known-hosts: [$0]" },
  write: { detail: "map (path → contents)", doc: "Write files into the guest (e.g. `.npmrc`, `.gemrc`).", insert: "write:\n  $0" },
  timezone: { detail: "string", doc: "Set the timezone → `systemsetup -settimezone`.", insert: "timezone: $0" },
  hostname: { detail: "string", doc: "Set HostName/LocalHostName/ComputerName.", insert: "hostname: $0" },
  "disable-spotlight": { detail: "boolean", doc: "Disable Spotlight indexing → `mdutil -a -i off` (CI perf win).", insert: "disable-spotlight: true" },
  "disable-sleep": { detail: "boolean", doc: "Never sleep → `pmset -a sleep 0 …` (long jobs).", insert: "disable-sleep: true" },
  description: { detail: "string", doc: "Image description, baked to `/etc/graft-image`.", insert: "description: " },
  labels: { detail: "map", doc: "Arbitrary metadata, baked to `/etc/graft-image`.", insert: "labels:\n  $0" },

  // ── Cache warming ──
  "pod-repo-warm": { detail: "boolean", doc: "Warm the CocoaPods spec repo → `pod repo update` / `pod setup`.", insert: "pod-repo-warm: true" },
  prefetch: { detail: "string[]", doc: "Cache-warming commands, run in the `repo` mount dir (bundle/yarn/pod install → baked in).", insert: "prefetch: [$0]" },
  repos: { detail: "list", doc: "Clone repos into the guest to warm global caches (yarn/CocoaPods/bundler), then discard the source — no source baked. `{ url, ref, run, ssh-key }`. For private repos, mount your key read-only (mounts aren't baked).", insert: "repos:\n  - url: $1\n    run:\n      - $0" },

  // ── Verify + hygiene ──
  verify: { detail: "string[]", doc: "Assertions run at the end — each must exit 0 or the build fails.", insert: "verify: [$0]" },
  cleanup: { detail: "boolean", doc: "`brew cleanup` + clear caches at the end → smaller image to clone.", insert: "cleanup: true" },

  // ── VM shape (applied via `tart set`) ──
  cpu: { detail: "int", doc: "CPU count for the baked image → `tart set --cpu`.", insert: "cpu: $0" },
  memory: { detail: "int (MB)", doc: "Memory in megabytes → `tart set --memory`.", insert: "memory: $0" },
  disk: { detail: "int (GB)", doc: "Disk size in GB (grow-only) → `tart set --disk-size`.", insert: "disk: $0" },
  display: { detail: "WxH", doc: "Display resolution → `tart set --display`. E.g. `1920x1080`.", insert: "display: $0" },

  // ── Escape hatches ──
  run: { detail: "block | list", doc: "Escape hatch — raw bash. A `|` block or a list. Runs after the declarative fields.", insert: "run: |\n  $0" },
  script: { detail: "path", doc: "Path to a shell script run in the guest (relative to this recipe). Runs before `run`.", insert: "script: " },
  os: { detail: "macos | linux", doc: "Guest OS (default `macos`).", insert: "os: macos" },
  network: { detail: "nat | bridged:<iface> | softnet", doc: "VM networking. `bridged:en0` puts the VM on the LAN — needed where NAT is blocked (e.g. behind Zscaler). `softnet` is isolated.", insert: "network: $0" },
  mounts: { detail: "list", doc: "Host directories shared into the build VM.", insert: "mounts: [$0]" }
};

function activate(context) {
  const selector = { language: "graft" };

  context.subscriptions.push(
    vscode.commands.registerCommand("graft.render", () => runGraft("render")),
    vscode.commands.registerCommand("graft.build", () => runGraft("build")),

    vscode.languages.registerCompletionItemProvider(selector, {
      provideCompletionItems(document, position) {
        // Only complete at the start of a (top-level) key.
        const prefix = document.lineAt(position).text.slice(0, position.character);
        if (!/^\s*[\w-]*$/.test(prefix)) return undefined;
        return Object.entries(FIELDS).map(([key, meta]) => {
          const item = new vscode.CompletionItem(key, vscode.CompletionItemKind.Property);
          item.detail = meta.detail;
          item.documentation = new vscode.MarkdownString(meta.doc);
          item.insertText = new vscode.SnippetString(meta.insert);
          return item;
        });
      }
    }),

    vscode.languages.registerHoverProvider(selector, {
      provideHover(document, position) {
        const range = document.getWordRangeAtPosition(position, /[\w-]+/);
        if (!range) return undefined;
        const meta = FIELDS[document.getText(range)];
        if (!meta) return undefined;
        return new vscode.Hover(
          new vscode.MarkdownString(`**${document.getText(range)}** — _${meta.detail}_\n\n${meta.doc}`),
          range
        );
      }
    })
  );
}

// Save the file, then shell out to `graft image <sub> -f <file>` in a terminal.
function runGraft(sub) {
  const editor = vscode.window.activeTextEditor;
  if (!editor || editor.document.languageId !== "graft") {
    vscode.window.showWarningMessage("Open a .graft recipe first.");
    return;
  }
  editor.document.save().then(() => {
    const term = vscode.window.createTerminal("graft");
    term.show();
    term.sendText(`graft image ${sub} -f "${editor.document.fileName}"`);
  });
}

exports.activate = activate;
exports.deactivate = function () {};
