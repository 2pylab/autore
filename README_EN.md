# autore

**auto + re(resume / retry / restart)** — auto-resume watcher for AI CLI usage limits

[한국어](README.md) | **English**

A lightweight watcher that waits out **usage limits** of AI CLIs (Claude Code, OpenCode, ...) and **automatically resumes your work** when they reset.

It periodically checks the screen of an AI CLI session running in tmux. When it detects a usage-limit message, it parses the reset time, sleeps until then, and types a resume message (default: `계속 이어서 진행해줘` — "keep going") into the session. Your conversation context stays intact and work continues automatically.

> 📖 Docs website: <https://2pylab.github.io/autore/>

## Features

- 🔁 **Auto-resume** — detect limit → parse reset time → sleep → type resume message into the session
- 🤖 **Multi-CLI** — watch other AI CLIs via `--cli` (note: OpenCode has built-in rate-limit retry, so this is mainly useful for Telegram alerts)
- ⏱ **Layered time parser** — handles `3pm`, `3:30 PM`, `15:00`, `Jul 28 at 3pm` (weekly limits), `tomorrow at 9am`, midnight/year rollover, and line-wrapped messages
- 🖥 **Session overview** — `status` shows how many tmux sessions are up and **which session/pane/directory the AI CLI is actually running in**
- ⏸ **Interruption point** — snapshots the screen at the moment the limit hit; `status` shows when it stopped and when it resumes, `last` shows what it was doing
- 🛡 **Safety guards** — dedupes identical limit messages, rejects implausible times (5-hour window validation), periodic retry on parse failure
- 📨 **Telegram + generic hook** — bot alerts on limit detection / resume / retry, plus `--notify-cmd` for Slack, Discord, ntfy, anything
- ✅ **Resume verification** — skips sending if you already resumed by hand, and warns when the screen does not react after sending
- 🔐 **Signed updates** — replaces the script only when it matches the published SHA256 (auto-update aborts on any verification failure)
- 🧪 **Built-in self-test** — `--selftest` runs 29 parser + state unit tests
- 🐧🍎 **Linux + macOS** — bash 3.2 compatible; macOS only needs coreutils
- 🌐 **Bilingual output** — CLI messages, logs, and Telegram alerts follow the OS locale (Korean/English)
- 🔄 **Auto-update** — checks for a new version at watcher start and periodically (default 24h), verifies and replaces itself (disable with `--no-auto-update`)
- 📦 **One-line install** — installer with dependency checks

## Requirements

| Item | Linux | macOS |
|---|---|---|
| bash | ✅ (any 3.2+) | ✅ stock bash 3.2 works |
| tmux | `sudo apt install tmux` | `brew install tmux` |
| GNU date | built-in (coreutils) | `brew install coreutils` (provides `gdate`) |
| curl | optional (Telegram) | optional (Telegram) |
| AI CLI (Claude Code, OpenCode, ...) | ✅ | ✅ |

## Install

**One-liner:**

```bash
curl -fsSL https://raw.githubusercontent.com/2pylab/autore/main/install.sh | bash
```

**Or clone and install:**

```bash
git clone https://github.com/2pylab/autore.git
cd autore
./install.sh            # installs to ~/.local/bin (dependency check + self-test included)
```

- System-wide: `./install.sh --system`
- Custom path: `./install.sh --prefix=/your/path`
- Uninstall: `./install.sh --uninstall`
- Run without installing: `./autore.sh start`

## Updating

The installed command has a built-in self-update:

```bash
autore update          # check latest → verify → replace
autore update --check  # only check whether a new version exists
```

> **Note for v1.x (`claude-auto-resume`) users:** the project was renamed to `autore` in v2.0.0.
> Re-run the install one-liner once — it installs `autore` and removes the old binary:
> `curl -fsSL https://raw.githubusercontent.com/2pylab/autore/main/install.sh | bash`
> (The old `claude-auto-resume update` also fetches v2.0.0, but keeps the old command name — reinstalling is recommended.
> Existing log/PID files are picked up automatically.)

- The new script is downloaded from GitHub and **only installed after passing a syntax check and the self-test (`--selftest`)**.
- The previous file is backed up automatically to `autore.bak`.
- If the watcher is running, it is stopped before the replacement — run `autore start` again afterwards.
- Alternatives: re-run the install one-liner (`curl ... | bash`, overwrites) or, for clones, `git pull && ./install.sh`

## Quick start

```bash
autore start     # ① start background watcher
autore attach    # ② attach to the AI CLI session → work as usual
```

That's it. If you hit the usage limit, it resumes automatically after the reset.

To watch another AI CLI such as OpenCode:

```bash
autore start --session opencode --cli opencode
```

> Note: OpenCode has built-in rate-limit retry and resumes on its own — autore is only
> useful here if you want Telegram alerts, or for other AI CLIs without built-in retry.

```bash
autore status    # check status
autore logs -f   # live logs
autore stop      # stop watching
```

## Commands

| Command | Description |
|---|---|
| `start [options]` | Start background watcher (creates the tmux session if missing) |
| `stop` | Stop the watcher |
| `status` | Watcher state + **interruption point** + **tmux session list (where the AI CLI runs)** + Telegram config + recent logs |
| `last` | Screen snapshot at the last interruption + history |
| `logs [-f]` | Show logs (`-f`: follow) |
| `attach` | Attach to the AI CLI tmux session |
| `run [options]` | Foreground watcher (for debugging) |
| `update [--check]` | Self-update to the latest version (`--check`: check only) |
| `test-telegram` | Send a Telegram test message to verify the setup |
| `checksum` | Print the release SHA256 (to refresh `autore.sh.sha256`) |
| `--selftest` | Parser + state-record unit tests |
| `version` | Print version (same as `--version`) |
| `help` | Print usage (same as `-h`, `--help`) |

## Options

For `start` / `run` (or use the matching environment variable):

| Option | Env var | Default | Description |
|---|---|---|---|
| `--session NAME` | `AUTORE_SESSION` | `claude` | tmux session to watch (legacy `CLAUDE_SESSION` also works) |
| `--cli CMD` | `CLI_CMD` | `claude` | AI CLI to launch when creating the session (e.g. `opencode`) |
| `--target PANE` | `TARGET` | — | Watch only this window/pane (default: every pane in the session) |
| `--poll SEC` | `POLL_SEC` | `30` | Screen check interval |
| `--buffer SEC` | `BUFFER_SEC` | `90` | Extra wait after reset time |
| `--fallback SEC` | `FALLBACK_SEC` | `900` | Retry delay when time parsing fails |
| `--retry SEC` | `RETRY_SAME_KEY_SEC` | `600` | Resend interval for the same limit message |
| `--max-resends N` | `MAX_RESENDS` | `2` | Max resends for the same limit message |
| `--verify-sec SEC` | `VERIFY_SEC` | `15` | Wait for a screen reaction after sending (0 = off) |
| `--no-clear-input` | `CLEAR_INPUT` | on | Do not clear the input line (C-u) before typing |
| `--message TEXT` | `RESUME_MESSAGE` | `계속 이어서 진행해줘` | Message typed after reset |
| `--log-file PATH` | `LOG_FILE` | `~/.autore.log` | Log file |
| `--samples-file PATH` | `SAMPLES_FILE` | `~/.autore-samples.log` | Parse-sample collection file |
| `--state-file PATH` | `STATE_FILE` | `~/.autore-state` | Interruption state file |
| `--break-file PATH` | `BREAK_FILE` | `~/.autore-break.txt` | Screen snapshot at interruption |
| `--breaks-log PATH` | `BREAKS_LOG` | `~/.autore-breaks.log` | Interruption history (one line each) |
| `--pid-file PATH` | `PID_FILE` | `~/.autore.pid` | PID file |
| `--snapshot-lines N` | `SNAPSHOT_LINES` | `60` | Screen lines kept in a snapshot |
| `--telegram-token T` | `TELEGRAM_BOT_TOKEN` | — | Telegram bot token |
| `--telegram-chat-id C` | `TELEGRAM_CHAT_ID` | — | Telegram chat ID |
| `--no-auto-update` | `AUTO_UPDATE` | on | Disable auto-update |
| `--log-max-bytes N` | `LOG_MAX_BYTES` | `1048576` | Log rotation threshold (0 = never) |
| `--notify-cmd CMD` | `NOTIFY_CMD` | — | Generic notify hook (Slack/Discord/ntfy/...) |
| `--auto-update-sec S` | `AUTO_UPDATE_SEC` | `86400` | Auto-update check interval (seconds) |
| `--allow-unverified` | `ALLOW_UNVERIFIED` | — | Force a manual update when the checksum cannot be verified (`update` only) |
| `--dry-run` | — | — | Log only, never send (for testing) |

> Non-integer values for numeric options are rejected up front (e.g. `--poll abc`).
> **For any session other than the default (`claude`), the file names get the session name appended** —
> `autore start --session opencode` uses `~/.autore-opencode.log`, `~/.autore-opencode.pid`, and so on,
> so watching several sessions never mixes their state.

## Telegram notifications (optional)

1. In Telegram, message [@BotFather](https://t.me/BotFather) → `/newbot` → get a **bot token**
2. Start a chat with your bot, then get your **chat ID** via [@userinfobot](https://t.me/userinfobot)
3. Add to `~/.bashrc`:

```bash
export TELEGRAM_BOT_TOKEN="123456:ABC..."
export TELEGRAM_CHAT_ID="123456789"
```

4. Verify the integration:

```bash
autore test-telegram   # setup is complete when the test message arrives
```

Then `autore start` will notify you on **watcher start / limit detection / resume / retry**.

> ⚠️ Passing the token as a CLI argument can expose it in `ps` output — environment variables are recommended.

## Other notification channels (`--notify-cmd`)

Any other channel goes through the notify hook. The message arrives as `$1`, along with the environment variables `AUTORE_EVENT` (`started` / `limit` / `limit_noparse` / `resumed` / `resume_skipped` / `resume_noreact` / `resend` / `autoupdate`), `AUTORE_MESSAGE`, `AUTORE_SESSION` and `AUTORE_VERSION`.

```bash
# Slack
autore start --notify-cmd 'curl -s -X POST -H "Content-type: application/json" \
  -d "{\"text\":\"$1\"}" https://hooks.slack.com/services/XXX'

# ntfy
autore start --notify-cmd 'curl -s -d "$1" https://ntfy.sh/my-topic'

# desktop notification (Linux)
autore start --notify-cmd 'notify-send autore "$1"'
```

## Update integrity

`update` and auto-update compare the downloaded script against `autore.sh.sha256` in the repository.

- **Auto-update**: if the hash differs or cannot be checked, the script is **not replaced** and the watcher keeps running the current version (fail-closed).
- **Manual update**: a mismatch always aborts; only an *unavailable* checksum can be forced with `autore update --allow-unverified`.
- Syntax check and self-test must still pass before the swap.

> **Release note:** whenever `autore.sh` changes, regenerate the checksum and commit it together.
> Forgetting it stops every user's auto-update (safely).
>
> ```bash
> ./autore.sh checksum > autore.sh.sha256
> ```

## How it works

```
┌─────────────┐   checks screen       ┌──────────────────┐
│  tmux        │   every 30s          │  watcher          │
│  session     │ ───────────────────→ │  process          │
│  (AI CLI)    │                      │                   │
└─────────────┘                      │ 1. detect limit    │
       ↑                             │ 2. parse reset time│
       │  after reset+buffer         │ 3. sleep until then│
       │  types "keep going"         │ 4. send-keys resume│
       └──────────────────────────── │ 5. Telegram alert  │
                                     └──────────────────┘
```

- The limit message is searched in **every pane of the session**, in the last 40 lines of each; wrapped messages are joined with the next 2 lines before parsing. The resume message goes to the pane where the limit was found (pin it with `--target`).
- Reset times outside the limit window (6h for bare times, 8 days for dated ones) are **rejected as misparses**.
- The same limit message is resent at most `MAX_RESENDS` times to avoid spamming the session.

## Session overview

`status` lists the tmux sessions that are up, and where the AI CLI is actually running.

```
== tmux sessions (3) ==
  ● claude       2 windows · attached · claude running -> claude:0.0 (~/Github/vllm-setup)  <- watching
  o dev          1 window · no claude
  o opencode     1 window · no claude
```

- `●` / `<- watching` marks the session autore watches; `o` marks the others
- The location is shown as `session:window.pane` plus that pane's current directory
- Even when the pane's surface command looks like `node`, autore **walks the process tree** to find the CLI (including npm/nvm launches)
- Which CLI to look for follows `--cli` (`--cli opencode` reports opencode instead)

## Where did it stop?

autore records the **exact moment** the limit hit, so you can see what happened while you were away.

```bash
autore status    # when it stopped, when it resumes (live countdown)
autore last      # screen snapshot right before the stop + recent history
```

Example `status` output:

```
== interruption point ==
  ⏸ interrupted: 2026-07-27 15:04:39 (30m ago)
     reset at:   2026-07-27 15:49
     resume at:  2026-07-27 15:49:39 (in 15m)
     last work:  ● Update(src/app.ts) — 42 additions
     full snapshot: autore last
```

After resuming it shows `▶ resumed … (down for 45m)` — how long the work was actually stopped — and if the watcher died while waiting, the scheduled time is flagged as past due.

Files written:

| File | Contents |
|---|---|
| `~/.autore-state` | Current interruption state (waiting/resumed/cleared) + break, reset and resume times |
| `~/.autore-break.txt` | Session screen snapshot right before the stop (60 lines by default) |
| `~/.autore-breaks.log` | Interruption history, one line per event |

Telegram alerts include the **last work line** from the interruption point as well.

## Parse samples & parser updates

Every detected limit message and its parse result is collected in `~/.autore-samples.log`.

If Anthropic changes the message format:

1. Check the new `raw:` lines in the samples file
2. Update `LIMIT_REGEX` / parser regexes in the script
3. Run `./autore.sh --selftest` (16 regression tests)
4. Please [open an issue](https://github.com/2pylab/autore/issues) with the new format so we can ship the fix

## Legal Review & Disclaimer

**What this tool is:**

- A **simple wait-and-resume automation script** that reads the limit notice Claude Code **already displays on screen**, waits until the stated reset time, and types a resume message into **your own** terminal session.
- It does **not** bypass or circumvent usage limits. It makes no additional API calls to Anthropic services and does not alter authentication or access controls. It only resumes the session **after** the limit has legitimately reset.

**Disclaimer:**

- This is an **unofficial open-source project with no affiliation to Anthropic**; it is not endorsed, supported, or approved by Anthropic. "Claude" and "Claude Code" are trademarks of Anthropic.
- **You are solely responsible** for reviewing and complying with Anthropic's Terms of Service and Usage Policies. All consequences of use (account restrictions, policy violations, data loss, work interruption, etc.) are your own responsibility.
- This software is provided **"as is", without warranty of any kind** (MIT License).

## Limitations

- Message formats are based on the English Claude Code UI and common provider phrasings (rate limit, too many requests, quota exceeded). If the format changes, update the parser using the samples log (see above).
- Reset times are interpreted in the local timezone.
- If you resume the session yourself while the watcher is waiting, it re-checks the screen at the scheduled time and skips the resume message when the limit is already gone.

## License

[MIT](LICENSE)
