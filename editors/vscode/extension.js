const vscode = require("vscode");

// Field metadata drives completion + hover (and documents what each compiles to).
const FIELDS = {
  name: { detail: "string", doc: "Local image name produced by the build.", insert: "name: " },
  from: { detail: "string", doc: "Base Tart image to clone, e.g. `ghcr.io/cirruslabs/macos-sequoia-xcode:latest`.", insert: "from: " },
  node: { detail: "version", doc: "Node version → `fnm install`/`default` + `corepack` + a stable `/usr/local/bin` node symlink (Xcode needs it).", insert: "node: \"$0\"" },
  ruby: { detail: "version", doc: "Ruby version → `rbenv install` + `global` + `bundler`.", insert: "ruby: \"$0\"" },
  brew: { detail: "string[]", doc: "Homebrew formulae → `brew install …`.", insert: "brew: [$0]" },
  gems: { detail: "string[]", doc: "RubyGems → `gem install … --no-document`.", insert: "gems: [$0]" },
  npm: { detail: "string[]", doc: "Global npm packages → `npm install -g …`.", insert: "npm: [$0]" },
  "xcode-first-launch": { detail: "boolean", doc: "Run `sudo xcodebuild -runFirstLaunch` (install Xcode components headlessly).", insert: "xcode-first-launch: true" },
  "warm-simulators": { detail: "string[]", doc: "Cold-boot each simulator once (warms on-disk caches), then shut down.", insert: "warm-simulators: [\"$0\"]" },
  run: { detail: "block | list", doc: "Escape hatch — raw bash. A `|` block or a list. Runs after the declarative fields.", insert: "run: |\n  $0" },
  script: { detail: "path", doc: "Path to a shell script run in the guest (relative to this recipe). Runs before `run`.", insert: "script: " },
  os: { detail: "macos | linux", doc: "Guest OS (default `macos`).", insert: "os: macos" },
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
