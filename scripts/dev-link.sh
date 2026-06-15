#!/usr/bin/env bash
#
# Point `graft` at your local dev build (stably signed), or restore the brew release.
# There's no separate `graft-dev` anymore — dev mode just *is* `graft`.
#
#   scripts/dev-link.sh           # dev mode: build + sign + link the dev build as `graft`
#   scripts/dev-link.sh restore   # back to the brew-installed release
#
# Why sign? `swift build` ad-hoc-signs the binary with a NEW code hash every build,
# which invalidates the Keychain ACL ("Always Allow") that lets graft read the GitHub
# App key — so it re-prompts on every rebuild. Signing with a stable identity keeps the
# designated requirement constant, so "Always Allow" sticks.
#
# Override the identity with GRAFT_SIGN_IDENTITY, or the link path with GRAFT_LINK.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IDENTITY="${GRAFT_SIGN_IDENTITY:-Developer ID Application: Brian Corbin (27N85AU6XK)}"
LINK="${GRAFT_LINK:-/opt/homebrew/bin/graft}"
BIN="$REPO/.build/release/graft"

if [[ "${1:-}" == "restore" ]]; then
  echo "▸ restoring the brew release…"
  [[ -L "$LINK" ]] && rm -f "$LINK"
  brew link --overwrite graft
  echo "✓ \`graft\` → brew release ($(graft --version 2>/dev/null || echo '?'))."
  exit 0
fi

cd "$REPO"

echo "▸ building release…"
swift build -c release

echo "▸ signing with: $IDENTITY"
codesign --force --sign "$IDENTITY" "$BIN"

echo "▸ unlinking brew graft so the dev build owns \`graft\`…"
brew unlink graft 2>/dev/null || true

ln -sf "$BIN" "$LINK"

echo "▸ graft → $BIN"
echo "✓ dev mode — \`graft\` is your local build. \`scripts/dev-link.sh restore\` to go back."
echo "  The first key read prompts once for keychain access; \"Always Allow\" sticks (stable sig)."
