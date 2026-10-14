# Tailnet Manager

Dark-mode macOS control panel for the machines you actually use — RDP boxes, SSH servers, or both — with Tailscale-aware status LEDs.

## Layout

One window: **sidebar** (Overview · Pipelines · Orchestrate · Cloud · Keys · Snippets · Docs · your machines in folders, live LEDs, LIVE badges) → **detail** → optional **inspector** (▥).

- **Overview** — tailnet topology: Tailscale hub in the middle, this Mac + your machines on the ring, **grouped by top-level folder** (tinted bands). Links show the real path (solid = direct, dashed = DERP relay with region, dim = offline/off-tailnet); packets animate on links with traffic or live sessions. A **CLOUD** node appears while uploads run, with links from the machines doing them. The 500+ Mullvad exit nodes never appear here or in the Add sheet.
- **EXIT ▾** (toolbar) — Direct, your own exit nodes, or any Mullvad country → city. Runs `tailscale set --exit-node=…`.

## Folders (VMware-style library)

- Sidebar MACHINES is a tree of **folders** you create (⊕ in the header, or right-click → New subfolder…). Folders nest, collapse, show `online/total`, and take a **color** (right-click → Color).
- **Drag** a machine onto a folder to file it, onto another machine to place it just above (your order sticks), or onto the MACHINES header to move it back to the top level. Folders drag into folders the same way.
- No-drag fallback: right-click → **Move to ▸** (machines and folders), **New folder…** (creates it and moves the machine in), **Add machine here…**, Rename, Delete (machines are never deleted — they move up a level).
- The inspector and the Add sheet have a FOLDER picker; a machine's home page shows its folder path.
- The overview draws one colored band per **top-level folder** — e.g. one per company.

## Machines — nothing connects until you say so

- Selecting a machine shows its **home page** (route, access, specs, encrypted session log). No SSH happens.
- **Machine tabs:** every machine you're connected to gets a tab at the top of the window, on every page. Click one, or press **⌃1…⌃9** to jump to it and **⌃Tab / ⌃⇧Tab** for the next or previous machine. From Pipelines, Snippets and the other pages, ⌃Tab takes you back to the machine you were last on. Hover a tab for ✕ (disconnect) or right-click → Disconnect.
- **Connect** opens the first session; then **+** / ⌘T adds tabs (Ghostty-style; click-and-hold + for htop & presets; ⌘W close, ⌘1…9, ⌘⇧[ ⌘⇧]). **Disconnect** (toolbar), closing the last tab, the sidebar's **N LIVE ⏻** (disconnect all) or quitting the app ends sessions.
- Every tab open/close is logged in the encrypted vault with duration.
- **Copying:** drag to select (double-click = word, triple = line), then ⌘C or right-click → Copy. With `copy-on-select = clipboard` in your Ghostty config, selecting copies straight away. A small "copied" notice confirms it. A drag always selects, even when the remote app grabs the mouse (tmux, htop, vim, Windows' ConPTY); hold ⌥ to click or drag *in* the app instead. The wheel still scrolls the app, and new output no longer wipes your selection.
- Terminal is SwiftTerm styled from your Ghostty config (theme, palette, font-size, padding, wallpaper + opacity, option-as-alt). ↗ pops a session out into real Ghostty (outside the app's control).
- A remote host can't read or set this Mac's clipboard (OSC 52 is off), and ⌘-click opens only http(s) links.

## Connection (inspector → CONNECTION)

- Host, user, **port**, **key** (any private key in ~/.ssh, or auto), extra **options** (`-J bastion`, …) and a live preview of the exact `ssh` command.
- A chosen key is the only key offered (`-i key -o IdentitiesOnly=yes`) — fixes "ssh picked the wrong key / too many auth failures".
- **Test connection** runs a key-only login with `-v` and tells you which key the server accepted, or which keys were tried and why it failed. Changing the route clears the old verification.
- Hardening on every connection: `-o ControlPath=none` (no lingering multiplexed master sockets, even if ~/.ssh/config enables them) and `-a` (no agent forwarding — add `-A` in options to opt in for one host). Background checks use `StrictHostKeyChecking=yes`: a new host key is only ever accepted by you, in a real session.

## Passwords (sudo / root)

- Inspector → **PASSWORDS**: add a user + password per server (one per user; saving again replaces it). There's no reveal button.
- **Use:** at a `[sudo] password for …:` / `Password:` prompt press **⌘⇧P** (or 🔑 in the tab bar → Type). The app types it straight into the session — no clipboard. It checks that the cursor line really is a password prompt before *and* after Touch ID, and refuses on shell lines (`$ # % >`), so a secret can't end up in your shell history. If the prompt names a user, only that user's password is used; it never guesses between users.
- **Copy** (fallback): Touch ID, then on the clipboard for 30 s — this Mac only (no Universal Clipboard), flagged concealed/transient so clipboard managers skip it, cleared afterwards unless you've copied something else.
- **Storage:** each password is its own AES-256-GCM box under a key HKDF-derived from the vault key (Keychain), kept sealed inside the encrypted vault and opened only at the moment of use.
- **Gate:** Touch ID or your Mac password; one unlock covers 60 s, and it re-locks on screen lock, display/system sleep or 🔑 → Lock now.
- Every save / type / copy / delete is in the encrypted session log (never the secret). Deleting a machine deletes its passwords.

## Pipelines (webhooks from your servers)

- Servers POST `{job_id, timestamp, event, stage, status}` (+ optional `source`, `message`, `telemetry`) to `https://<this-mac>.<tailnet>.ts.net:8443/pipeline-events` with `Authorization: Bearer <token>`. Contract + snippets: **Docs** tab (it also copies a ready-made brief for the sending server).
- **Red box** in the sidebar (and the Dock icon) = updates since you last had the Pipelines page in front of you.
- **Sections by service:** events that send a `service` (e.g. `nightly-backup`) get their own section, with one sub-section per `resource.type`. Events with no `service` are grouped by the machine that sent them. ⋯ → **Rename…** gives a section your own label.
- **Built to stay fast with a busy sender:** the Pipelines page draws only what's on screen (8 runs per sub-section, then "show all"). Grouping ~1000 events happens in the background at most 5×/s, and the vault is written in the background at most every 0.3 s.
- Events carrying an `event_id` are de-duplicated (a replay still gets 202).
- **Pipelines (groups):** a scheduled job sends a new `job_id` every run, so name the pipeline once and its runs stack up under it. Click the folder-plus icon on a run (prefilled: its sender, its job_id minus the date/run-id tail, its stages as the name), or toolbar → **New pipeline**. Pick the sender and/or text every job_id shares, plus its **run days** (e.g. Tue · Wed · Sun). Each pipeline card shows its last result, next run day, a strip of the last 20 runs, and the runs themselves (click the header to fold). A run day that passes with no run started shows **MISSED**. FAILED/STALE count each pipeline's *latest* run, so an old failure that a newer run fixed doesn't keep the page red. Deleting a pipeline keeps its runs.
- Each run shows its stages in order (unzip → zip → upload), tinted by how each went, plus how long it took.
- Jobs group per server + `job_id`; failed jobs go red with their message and telemetry. A job whose last status was `running` and has been silent 30 min shows **STALE** (died without reporting). **Ask Claude…** on a red/stale job prefills an Orchestrate task against the machine that sent it.
- **HTTPS:** the app listens on **127.0.0.1:8787 only** (nothing on the LAN can connect). `tailscale serve` terminates TLS with Tailscale's certificate for this Mac's MagicDNS name and forwards tailnet-only traffic to it. Set it up once with Docs → **Enable HTTPS…** (`tailscale serve --bg --https=8443 http://127.0.0.1:8787`; needs MagicDNS + HTTPS certificates on the tailnet; undo with `tailscale serve --https=8443 off`).
- Bearer token (64 hex chars, constant-time check, sealed in the vault). Docs → Copy (Touch ID, 30 s clipboard) · Rotate. Bodies over 64 KB, chunked uploads and slow clients (10 s) are refused; Docs → LAST REFUSED shows why the most recent request was rejected.
- The last 1000 events are kept in the encrypted vault. Pipelines → Clear deletes them.

## Orchestrate (Claude on your machines, one login)

- Pick machines, describe the task, Run. The app runs `claude -p` **on this Mac** with your Claude subscription login (`ANTHROPIC_API_KEY` is stripped from its environment). The servers need no Claude install or login.
- Each run card shows the auth source ("subscription login"), every command Claude runs, its output, and the final summary. Stop kills the run; follow-ups continue the same session; **Copy resume** gives `claude --resume <id>` for a terminal.
- Locked down: Bash is the only tool, and it's allowed only for the exact `ssh … user@host -- '<remote command>'` line of each picked machine (`--allowedTools`, `--permission-mode dontAsk`). A PreToolUse hook (this app, `--bash-hook`) checks every call first and denies anything that isn't one of those lines with a single-quoted remote command, including the read-only commands `dontAsk` would otherwise allow in the run directory. `--setting-sources project` + `--strict-mcp-config` keep your user allow-rules, hooks, plugins and MCP servers out. The `--` stops a command from smuggling local ssh options such as `ProxyCommand`.
- Codex and z.ai (via Cline) get the same lock: Codex has no shell, only this app's ssh-only MCP tool; Cline asks this app before every tool call.
- Only machines with verified key auth are eligible (BatchMode ssh can't answer password prompts). `sudo` works only if passwordless (`sudo -n`).
- Runs live for this app session; each one leaves a line in the encrypted session log. Quitting the app stops running runs.

## Cloud

- Tracks running **rclone** (copy/sync/move/bisync), **gcloud storage** (cp/rsync/mv) and **gsutil** transfers by scanning `ps` — catches jobs started anywhere (tmux, cron, a tab). The scan only reads what `ps` shows; it never runs a program named in it.
- Per transfer: tool, src → dst, host, pid, elapsed, bytes sent + speed (Linux `/proc/<pid>/io`), and real **% / ETA / errors** when rclone runs with `--rc`.
- Shows each host's active **gcloud account · project** and **rclone remotes** (names + types only — never config secrets).
- **RCLONE REMOTES** — define a remote once, deploy it to any machine (or this Mac): S3 (AWS, Cloudflare R2, Wasabi, DigitalOcean, MinIO, Ceph, Scaleway, Linode, IDrive, GCS, other), SFTP, Google Cloud Storage, Backblaze B2, Azure Blob, WebDAV, SMB, FTP, Crypt, or Other (any backend, raw `key = value`). Each type gets its own form plus a live preview of the `rclone.conf` section (secrets masked).
  - Secret fields are sealed in the vault (own AES-GCM key, HKDF from the vault key); blank on edit = keep, "clear" drops one. No reveal.
  - **Deploy** (Touch ID first when secrets are involved) sends the section as a script on ssh **stdin** — secrets never appear in argv/`ps` — and rclone **obscures passwords on the host** (`rclone obscure -`). rclone.conf ends up 0600.
  - An existing remote of the same name is never overwritten silently: you're asked, and a timestamped backup is kept next to rclone.conf (only the newest, so rotated-out secrets don't pile up). Encrypted rclone.conf files are refused (add those with `rclone config`).
  - **Test** runs `rclone lsf name:<test path>` on the host; **Remove from** runs `rclone config delete`. Deploy / test / remove go to the encrypted log.
  - Safer defaults: SFTP verifies host keys (`known_hosts_file`), FTP uses FTPS, S3/GCS/Azure offer IAM-role / VM / managed-identity auth instead of static keys.
  - Deploy targets: this Mac + machines whose key auth you've verified. OAuth backends (Drive, Dropbox, OneDrive) need `rclone config` on the host.
- Finished transfers go to the encrypted log (bytes, duration, errors).
- This Mac is checked every minute (local `ps`, no network). Your servers are only contacted **while the Cloud page is open** (every 15 s) or on **Rescan**, and only ones whose key auth you've verified.

## Snippets

- Code you reuse, named like files (`gcs-upload.sh`, `tnm_notify.py`, `docker-compose.yml`). The extension picks the language (or a `#!` line; or pick one by hand). Shell, PowerShell, Batch, Python, Swift, JS/TS, Go, Rust, C/C++, Java/Kotlin/C#, SQL, JSON, YAML, INI/TOML/env, Dockerfile, HTML/XML, CSS, plain text.
- **Syntax highlighting** in your Ghostty theme and font (its 16-colour palette; One Dark if it has none). Real editor: undo, ⌘F find bar, no smart quotes or autocorrect, no wrapping.
- **Search** (⌘K): names first, then letters in order like ⌘P (`dcy` → docker-compose.yml), then snippets whose code contains it. Return opens the top hit, Esc clears.
- **Copy** (⇧⌘C) puts the whole snippet on the clipboard — this Mac only, marked concealed so clipboard managers skip it. Right-click a snippet for Copy / Delete.
- **Drop files** on the list to import them: the file name becomes the snippet name. UTF-8 text up to 256 KB.
- Saved in the encrypted vault a moment after you stop typing.

## Keys tab

- **Import private keys** (pasted) — stored OpenSSH-encrypted at rest (bcrypt KDF + AES-256-CTR); plaintext keys are encrypted with your passphrase on import
- Existing plaintext keys are flagged `PLAINTEXT ⚠` with one-click **Encrypt…**
- Import public keys, or **Generate** ed25519 keys (passphrase required)
- **Copy** public key · **Agent** loads it via `ssh-add --apple-use-keychain` (prompts once, Keychain remembers) · delete with confirm
- The app never stores passphrases or key material anywhere beyond `~/.ssh` itself. Passphrases reach `ssh-keygen` on stdin (via `SSH_ASKPASS`), never on the command line where `ps` could show them; a pasted key is staged inside `~/.ssh` (0700), never in a temp dir.

## Encrypted vault (persistent database)

- One AES-256-GCM sealed file: `~/Library/Application Support/io.github.xorroproprop.tailnet-manager/vault.bin` (0600)
- The 256-bit key lives in your macOS Keychain — never on disk
- Stores: machines, key registry (added/last-seen), and a session log — SSH tab open/close, RDP, specs, verify and finished cloud transfers, with timestamp, user and duration (last 500 kept, FIFO)
- Per-machine **SESSIONS · ENCRYPTED LOG** panel + SESSIONS stat on the Overview
- If decrypt ever fails (corrupt file, or the Keychain item is gone), the old file is kept as `vault.bin.corrupt-<ts>` rather than overwritten, and the window says so

## Install

Needs macOS 14+ and Xcode 16+ or its Command Line Tools (`xcode-select --install`), i.e. Swift 6. Tailscale is optional but powers the status LEDs.

```sh
./install.sh            # from your normal terminal
```

- Builds the app (or takes the `TailnetManager.app` shipped next to the script) and installs it to `~/Applications` — no sudo.
- Hooks it to your Mac: a Finder-launched app doesn't get your shell's PATH or SSH agent, so the installer records them, plus where `tailscale`, `claude`, `codex`, `cline` and Ghostty live, in `~/Library/Application Support/io.github.xorroproprop.tailnet-manager/environment` (0600; the app ignores it if anyone else could write it). Nothing about you or your machines is built into the app. Re-run it after installing new tools.
- Offers to publish the pipeline webhook over HTTPS on your tailnet (`tailscale serve`), and prints what the app will see.
- `./install.sh --uninstall` removes the app and that record; your vault stays until you delete it (the command is printed).

## Build

```sh
./build.sh && open build/TailnetManager.app
```

- `./build.sh` makes an ad-hoc signed app with the hardened runtime — fine for your own Mac.
- To distribute it, sign with a Developer ID and notarize:
  ```sh
  xcrun notarytool store-credentials tnm --apple-id you@example.com --team-id TEAMID   # once
  SIGN_ID="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE=tnm ./build.sh   # → build/TailnetManager.zip
  ```
- Dev: `swift build && swift run`, tests: `swift test`.

## Security model

- **Trusted:** your Mac and your login. **Untrusted:** remote hosts and everything they print, webhook bodies, and the processes `ps` lists.
- **At rest:** one AES-256-GCM vault; its key lives in your login Keychain, and saved passwords and rclone secrets are sealed again under their own HKDF-derived keys.
- **Touch ID is an app-level gate.** It decides when the app opens a sealed password, but the seal's key comes from the vault key. Anything that can read the vault key from your Keychain can open the passwords without Touch ID. A Developer ID build with a user-presence Keychain item would make Touch ID cryptographic; that's not done yet.
- **Ad-hoc builds** are re-trusted by macOS on every rebuild: you'll be asked again to release the vault key. A Developer ID-signed build keeps one stable identity.
- **Orchestrate transcripts** (every command and its output) are stored by Claude Code / Codex / Cline themselves, in plaintext under `~/.claude`, `~/.codex` and `~/.cline`, outside the vault.
- Remote output Claude reads is untrusted text; the ssh-only lock bounds what a run can do, but a run can still change anything on the machines you picked, so keep task wording explicit.

## Notes

- New host? Connect once and check the fingerprint ssh shows — background checks won't trust it for you
- No font-family in your Ghostty config → SF Mono (Ghostty's bundled JetBrains Mono isn't a system font)
- Passphrase-protected keys work everywhere once loaded into ssh-agent (Agent button)
- No sandbox — the app runs tailscale / ssh / ssh-keygen / claude locally on your behalf

## License

GPL-3.0 — see [LICENSE](LICENSE). Uses [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) (MIT).
