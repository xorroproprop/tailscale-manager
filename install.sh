#!/bin/zsh
# Installs Tailnet Manager for you and hooks it to this Mac. Run it from your normal terminal:
#   ./install.sh               build (in a source checkout) or take the .app next to this script → ~/Applications,
#                              then record your tools, PATH and SSH agent, and offer HTTPS for pipeline webhooks
#   ./install.sh --uninstall   remove the app and that record (your encrypted vault is left alone)
# Nothing about you or your machines is built into the app. What it needs to know about this Mac is written to
#   ~/Library/Application Support/io.github.xorroproprop.tailnet-manager/environment     (0600 — re-run after installing new tools)
set -euo pipefail
cd "$(dirname "$0")"
DEST="$HOME/Applications/TailnetManager.app"
SUPPORT="$HOME/Library/Application Support/io.github.xorroproprop.tailnet-manager"
ENVFILE="$SUPPORT/environment"

if pgrep -xq TailnetManager; then echo "Quit Tailnet Manager first (⌘Q), then run this again."; exit 1; fi

if [[ "${1:-}" == "--uninstall" ]]; then
    rm -rf "$DEST" "$ENVFILE"
    echo "✓ Removed the app and its environment record."
    echo "  Your data is still in $SUPPORT (vault.bin) and its key in the Keychain. To erase both:"
    echo "  rm -rf \"$SUPPORT\" && security delete-generic-password -s io.github.xorroproprop.tailnet-manager.vault"
    exit 0
fi

[[ "$(sw_vers -productVersion | cut -d. -f1)" -ge 14 ]] || { echo "Tailnet Manager needs macOS 14 or later."; exit 1; }

# 1. The app
if [[ -f Package.swift ]]; then
    # not `command -v swift`: /usr/bin/swift is a stub that exists even with no developer tools installed
    xcode-select -p >/dev/null 2>&1 || { echo "Building needs Xcode 16+ or its Command Line Tools: xcode-select --install"; exit 1; }
    ./build.sh
    SRC=build/TailnetManager.app
else
    SRC=TailnetManager.app
fi
[[ -d "$SRC" ]] || { echo "TailnetManager.app not found next to install.sh"; exit 1; }
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
ditto "$SRC" "$DEST"

# 2. Your environment. This script inherits your terminal's, which is exactly what a Finder-launched app lacks.
find_bin() { for c in "$@"; do [[ "$c" == /* && -x "$c" ]] && { echo "$c"; return; }; command -v "$c" 2>/dev/null && return; done; true; }
find_app() { for c in "/Applications/$1" "$HOME/Applications/$1"; do [[ -d "$c" ]] && { echo "$c"; return; }; done; true; }
TS=$(find_bin tailscale /Applications/Tailscale.app/Contents/MacOS/Tailscale)
typeset -A found=(
    TAILSCALE_BIN "$TS"
    CLAUDE_BIN "$(find_bin claude "$HOME/.claude/local/claude")"
    CODEX_BIN "$(find_bin codex)"
    CLINE_BIN "$(find_bin cline)"
    GHOSTTY_APP "$(find_app Ghostty.app)"
)
safe_path=${(j.:.)${(M)${(s.:.)PATH}:#/*}}   # absolute entries only — never ".", never relative
mkdir -p "$SUPPORT"
(
    umask 077
    {
        echo "PATH=$safe_path"
        [[ -n "${SSH_AUTH_SOCK:-}" ]] && echo "SSH_AUTH_SOCK=$SSH_AUTH_SOCK"
        for k v in "${(@kv)found}"; do [[ -n "$v" ]] && echo "$k=$v"; done
        true
    } > "$ENVFILE.tmp"
    mv "$ENVFILE.tmp" "$ENVFILE"
)

# 3. Pipeline webhooks over HTTPS (tailnet only) — asked, never assumed
if [[ -n "$TS" && -t 0 ]] && ! "$TS" serve status 2>/dev/null | grep -q '127.0.0.1:8787'; then
    if read -q "?Publish the pipeline webhook to your tailnet over HTTPS (tailscale serve :8443 → 127.0.0.1:8787)? [y/N] "; then
        echo; "$TS" serve --bg --https=8443 http://127.0.0.1:8787 || echo "  (skipped — enable it later from Docs → Enable HTTPS…)"
    else
        echo; echo "  Skipped. Docs → Enable HTTPS… does it later."
    fi
fi

# 4. What the app will see
mark() { [[ -n "$2" ]] && echo "  ✓ $1  $2" || echo "  – $1  ${3:-not found}"; }
echo
echo "Installed $DEST"
mark "Tailscale CLI " "$TS" "not found — install Tailscale, then re-run (status LEDs need it)"
[[ -n "$TS" ]] && { "$TS" status >/dev/null 2>&1 && echo "      logged in" || echo "      not connected — run: tailscale up"; }
mark "ssh           " "$(command -v ssh)"
mark "SSH agent     " "${SSH_AUTH_SOCK:-}" "none — passphrase keys need ssh-add (Keys → Agent)"
mark "Claude Code   " "${found[CLAUDE_BIN]}" "optional (Orchestrate)"
mark "Codex         " "${found[CODEX_BIN]}" "optional (Orchestrate)"
mark "Cline         " "${found[CLINE_BIN]}" "optional (Orchestrate)"
mark "rclone        " "$(command -v rclone || true)" "optional (Cloud)"
mark "Ghostty       " "${found[GHOSTTY_APP]}" "optional — sessions pop out to Terminal instead"
echo
echo "Open it:  open \"$DEST\""
