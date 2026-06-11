# Graft for VS Code

Editor support for **`.graft`** image recipes (and `Graftfile`).

- **Syntax highlighting** — graft keywords colored, and the bash inside `run: |` /
  `script: |` blocks highlighted as shell (the pretty part).
- **Completion + hover** — type a field and get the declarative keys (`node`, `ruby`,
  `brew`, `xcode-first-launch`, …) with docs on what each compiles to.
- **Snippets** — `graft`, `graft-rn`, `graft-ios` scaffold a recipe.
- **Commands** — `Graft: Render compiled provisioning script` (an eye icon in the editor
  title bar) and `Graft: Build image from this recipe`. Both shell out to the `graft`
  CLI on your PATH.
- **JSON schema** — bundled at [`schemas/graft.schema.json`](schemas/graft.schema.json).

## Install

**Try it (dev):** open this folder (`editors/vscode`) in VS Code and press **F5** — a
new "Extension Development Host" window launches with the extension loaded. Open any
`.graft` file there.

**Use it everywhere:** symlink it into your extensions folder and reload VS Code:

```sh
ln -s "$PWD/editors/vscode" ~/.vscode/extensions/graft-0.1.0
```

**Or package a `.vsix`:**

```sh
cd editors/vscode
npx @vscode/vsce package
code --install-extension graft-0.1.0.vsix
```

## Notes

- The render/build commands run `graft image render|build -f <file>`. Make sure `graft`
  (or a symlink to your dev build) is on the PATH the integrated terminal uses.
- No build step — the extension is plain JS + declarative contributions.
