# claude-auto-resume

[한국어](README.md) | **English**

A lightweight watcher that waits out Claude Code's **5-hour usage limit** and **automatically resumes your work** when it resets.

It periodically checks the screen of a Claude Code session running in tmux. When it detects a usage-limit message, it parses the reset time, sleeps until then, and types a resume message (default: `계속 이어서 진행해줘` — "keep going") into the session. Your conversation context stays intact and work continues automatically.

> 📖 Docs website: <https://2pylab.github.io/claude-auto-resume/>

## Features

- 🔁 **Auto-resume** — detect limit → parse reset time → sleep → type resume message into the session
- ⏱ **Layered time parser** — handles `3pm`, `3:30 PM`, `15:00`, `Jul 28 at 3pm` (weekly limits), `tomorrow at 9am`, midnight/year rollover, and line-wrapped messages
- 🛡 **Safety guards** — dedupes identical limit messages, rejects implausible times (5-hour window validation), periodic retry on parse failure
- 📨 **Telegram notifications** — bot alerts on limit detection / resume / retry (optional)
- 🧪 **Built-in self-test** — `--selftest` runs 16 parser unit tests
- 🐧🍎 **Linux + macOS** — bash 3.2 compatible; macOS only needs coreutils
- 📦 **One-line install** — installer with dependency checks

## Requirements

| Item | Linux | macOS |
|---|---|---|
| bash | ✅ (any 3.2+) | ✅ stock bash 3.2 works |
| tmux | `sudo apt install tmux` | `brew install tmux` |
| GNU date | built-in (coreutils) | `brew install coreutils` (provides `gdate`) |
| curl | optional (Telegram) | optional (Telegram) |
| Claude Code | ✅ | ✅ |

## Install

**One-liner:**

```bash
curl -fsSL https://raw.githubusercontent.com/2pylab/claude-auto-resume/main/install.sh | bash
```

**Or clone and install:**

```bash
git clone https://github.com/2pylab/claude-auto-resume.git
cd claude-auto-resume
./install.sh            # installs to ~/.local/bin (dependency check + self-test included)
```

- System-wide: `./install.sh --system`
- Custom path: `./install.sh --prefix=/your/path`
- Uninstall: `./install.sh --uninstall`
- Run without installing: `./claude-auto-resume.sh start`

## Updating

The installed command has a built-in self-update:

```bash
claude-auto-resume update          # check latest → verify → replace
claude-auto-resume update --check  # only check whether a new version exists
```

- The new script is downloaded from GitHub and **only installed after passing a syntax check and the self-test (`--selftest`)**.
- The previous file is backed up automatically to `claude-auto-resume.bak`.
- If the watcher is running, it is stopped before the replacement — run `claude-auto-resume start` again afterwards.
- Alternatives: re-run the install one-liner (`curl ... | bash`, overwrites) or, for clones, `git pull && ./install.sh`

## Quick start

```bash
claude-auto-resume start     # ① start background watcher
claude-auto-resume attach    # ② attach to the Claude Code session → work as usual
```

That's it. If you hit the usage limit, it resumes automatically after the reset.

```bash
claude-auto-resume status    # check status
claude-auto-resume logs -f   # live logs
claude-auto-resume stop      # stop watching
```

## Commands

| Command | Description |
|---|---|
| `start [options]` | Start background watcher (creates the tmux session if missing) |
| `stop` | Stop the watcher |
| `status` | Watcher state + tmux session + Telegram config + recent logs |
| `logs [-f]` | Show logs (`-f`: follow) |
| `attach` | Attach to the Claude Code tmux session |
| `run [options]` | Foreground watcher (for debugging) |
| `update [--check]` | Self-update to the latest version (`--check`: check only) |
| `--selftest` | Parser unit tests |
| `--version` | Print version |

## Options

For `start` / `run` (or use the matching environment variable):

| Option | Env var | Default | Description |
|---|---|---|---|
| `--session NAME` | `CLAUDE_SESSION` | `claude` | tmux session to watch |
| `--poll SEC` | `POLL_SEC` | `30` | Screen check interval |
| `--buffer SEC` | `BUFFER_SEC` | `90` | Extra wait after reset time |
| `--fallback SEC` | `FALLBACK_SEC` | `900` | Retry delay when time parsing fails |
| `--retry SEC` | `RETRY_SAME_KEY_SEC` | `600` | Resend interval for the same limit message |
| `--max-resends N` | `MAX_RESENDS` | `2` | Max resends for the same limit message |
| `--message TEXT` | `RESUME_MESSAGE` | `계속 이어서 진행해줘` | Message typed after reset |
| `--log-file PATH` | `LOG_FILE` | `~/.claude-auto-resume.log` | Log file |
| `--samples-file PATH` | `SAMPLES_FILE` | `~/.claude-auto-resume-samples.log` | Parse-sample collection file |
| `--telegram-token T` | `TELEGRAM_BOT_TOKEN` | — | Telegram bot token |
| `--telegram-chat-id C` | `TELEGRAM_CHAT_ID` | — | Telegram chat ID |
| `--dry-run` | — | — | Log only, never send (for testing) |

## Telegram notifications (optional)

1. In Telegram, message [@BotFather](https://t.me/BotFather) → `/newbot` → get a **bot token**
2. Start a chat with your bot, then get your **chat ID** via [@userinfobot](https://t.me/userinfobot)
3. Add to `~/.bashrc`:

```bash
export TELEGRAM_BOT_TOKEN="123456:ABC..."
export TELEGRAM_CHAT_ID="123456789"
```

Then `claude-auto-resume start` will notify you on **limit detection / resume / retry**.

> ⚠️ Passing the token as a CLI argument can expose it in `ps` output — environment variables are recommended.

## How it works

```
┌─────────────┐   checks screen       ┌──────────────────┐
│  tmux        │   every 30s          │  watcher          │
│  session     │ ───────────────────→ │  process          │
│ (Claude Code)│                      │                   │
└─────────────┘                      │ 1. detect limit    │
       ↑                             │ 2. parse reset time│
       │  after reset+buffer         │ 3. sleep until then│
       │  types "keep going"         │ 4. send-keys resume│
       └──────────────────────────── │ 5. Telegram alert  │
                                     └──────────────────┘
```

- The limit message is searched in the last 40 screen lines; wrapped messages are joined with the next 2 lines before parsing.
- Reset times outside the limit window (6h for bare times, 8 days for dated ones) are **rejected as misparses**.
- The same limit message is resent at most `MAX_RESENDS` times to avoid spamming the session.

## Parse samples & parser updates

Every detected limit message and its parse result is collected in `~/.claude-auto-resume-samples.log`.

If Anthropic changes the message format:

1. Check the new `raw:` lines in the samples file
2. Update `LIMIT_REGEX` / parser regexes in the script
3. Run `./claude-auto-resume.sh --selftest` (16 regression tests)
4. Please [open an issue](https://github.com/2pylab/claude-auto-resume/issues) with the new format so we can ship the fix

## Legal Review & Disclaimer

**What this tool is:**

- A **simple wait-and-resume automation script** that reads the limit notice Claude Code **already displays on screen**, waits until the stated reset time, and types a resume message into **your own** terminal session.
- It does **not** bypass or circumvent usage limits. It makes no additional API calls to Anthropic services and does not alter authentication or access controls. It only resumes the session **after** the limit has legitimately reset.

**Disclaimer:**

- This is an **unofficial open-source project with no affiliation to Anthropic**; it is not endorsed, supported, or approved by Anthropic. "Claude" and "Claude Code" are trademarks of Anthropic.
- **You are solely responsible** for reviewing and complying with Anthropic's Terms of Service and Usage Policies. All consequences of use (account restrictions, policy violations, data loss, work interruption, etc.) are your own responsibility.
- This software is provided **"as is", without warranty of any kind** (MIT License).

## Limitations

- Message formats are based on the English Claude Code UI. If the format changes, update the parser using the samples log (see above).
- Reset times are interpreted in the local timezone.
- If you manually resume the session while the watcher is waiting, one resume message may still be typed at the scheduled time (harmless, but good to know).

## License

[MIT](LICENSE)
