# autore

**auto + re(resume / retry / restart)** — AI CLI 사용량 제한 자동 재개 도구

**한국어** | [English](README_EN.md)

Claude Code, OpenCode 등 AI CLI의 **사용량 제한**에 걸렸을 때, 리셋 시각까지 대기했다가 **자동으로 작업을 이어가는** 경량 감시 도구입니다.

tmux 세션에서 실행 중인 AI CLI 화면을 주기적으로 확인하다가, 사용량 제한 메시지를 감지하면 리셋 시각을 파싱해 그 시각까지 잠든 뒤, 세션에 재개 메시지(기본: `계속 이어서 진행해줘`)를 자동 입력합니다. 대화 맥락이 그대로 유지된 채로 작업이 다시 시작됩니다.

> 📖 안내 웹페이지: <https://2pylab.github.io/autore/>

## 특징

- 🔁 **자동 재개** — 제한 감지 → 리셋 시각 파싱 → 대기 → 세션에 자동 입력
- 🤖 **멀티 CLI** — `--cli` 옵션으로 다른 AI CLI도 감시 가능 (단, OpenCode는 자체 재시도가 내장되어 있어 대부분 불필요 — 텔레그램 알림 목적 등에 유용)
- ⏱ **다단계 시각 파서** — `3pm`, `3:30 PM`, `15:00`, `Jul 28 at 3pm`(주간 제한), `tomorrow at 9am`, 자정/연도 넘김, 화면 줄바꿈까지 처리
- 🖥 **세션 한눈에** — `status`가 tmux 세션 개수와 함께 **AI CLI가 어느 세션·pane·디렉터리에서 돌고 있는지** 표시
- ⏸ **중단 시점 표시** — 제한에 걸린 순간의 화면을 스냅샷으로 저장. `status`로 "언제 멈췄고 언제 이어지는지", `last`로 "무엇을 하다 멈췄는지" 확인
- 🛡 **안전장치** — 같은 제한 메시지 중복 처리 방지, 모순된 시각 거부(5시간 창 검증), 파싱 실패 시 주기적 재시도
- 📨 **텔레그램 알림 + 범용 훅** — 제한 감지 / 재개 완료 / 재시도 시 봇 알림, `--notify-cmd`로 Slack·Discord·ntfy 등 무엇이든 연결
- ✅ **재개 확인** — 대기 중 사용자가 직접 이어갔으면 전송을 건너뛰고, 전송 후 화면 반응이 없으면 경고
- 🔐 **서명된 업데이트** — 배포 SHA256과 대조해 일치할 때만 교체 (자동 업데이트는 검증 실패 시 무조건 중단)
- 🧪 **자가진단 내장** — `--selftest`로 파서·상태기록 단위 테스트 29종 실행
- 🐧🍎 **Linux + macOS** — bash 3.2 호환, macOS는 coreutils만 있으면 동작
- 🌐 **한/영 출력** — OS 로케일에 따라 CLI 메시지·로그·텔레그램 알림·설치 스크립트가 한국어/영어로 자동 전환
- 🔄 **자동 업데이트** — 감시 시작 시 + 주기적(기본 24시간)으로 새 버전 확인, 검증 후 자동 교체 (`--no-auto-update`로 끄기)
- 📦 **원라인 설치** — 의존성 검사 포함 설치 스크립트

## 요구사항

| 항목 | Linux | macOS |
|---|---|---|
| bash | ✅ (3.2+ 아무거나) | ✅ 기본 bash 3.2로 동작 |
| tmux | `sudo apt install tmux` | `brew install tmux` |
| GNU date | 기본 포함 (coreutils) | `brew install coreutils` (→ `gdate`) |
| curl | 선택 (텔레그램 알림용) | 선택 (텔레그램 알림용) |
| AI CLI (Claude Code, OpenCode 등) | ✅ | ✅ |

## 설치

**원라인 설치:**

```bash
curl -fsSL https://raw.githubusercontent.com/2pylab/autore/main/install.sh | bash
```

**또는 클론 후 설치:**

```bash
git clone https://github.com/2pylab/autore.git
cd autore
./install.sh            # ~/.local/bin에 설치 (의존성 검사 + 자가진단 포함)
```

- 시스템 전체 설치: `./install.sh --system`
- 다른 경로: `./install.sh --prefix=/원하는/경로`
- 제거: `./install.sh --uninstall`
- 설치 없이 직접 실행: `./autore.sh start`

## 업데이트

설치본에는 자체 업데이트 명령이 있습니다:

```bash
autore update          # 최신 버전 확인 → 검증 후 교체
autore update --check  # 새 버전이 있는지 확인만
```

> **v1.x(`claude-auto-resume`) 사용자 참고:** v2.0.0부터 이름이 `autore`로 바뀌었습니다.
> 설치 원라인을 한 번만 다시 실행하면 `autore`로 설치되고 구버전 바이너리는 자동 정리됩니다:
> `curl -fsSL https://raw.githubusercontent.com/2pylab/autore/main/install.sh | bash`
> (기존 `claude-auto-resume update`로도 v2.0.0 코드를 받을 수 있지만, 명령어 이름이 그대로이므로 재설치를 권장합니다.
> 기존 로그·PID 파일은 그대로 이어서 사용합니다.)

- GitHub에서 최신 스크립트를 받아 **문법 검사 + 자가진단(`--selftest`) 통과 후에만** 교체합니다.
- 기존 파일은 `autore.bak`으로 자동 백업됩니다.
- 감시 실행 중이면 자동으로 중지 후 교체하므로, 업데이트 뒤 `autore start`로 다시 시작하세요.
- 그 외 방법: 설치 원라인 재실행(`curl ... | bash`, 덮어쓰기) 또는 클론 사용 시 `git pull && ./install.sh`

## 빠른 시작

```bash
autore start     # ① 백그라운드 감시 시작
autore attach    # ② AI CLI 세션 접속 → 평소처럼 작업
```

이제 사용량 제한에 걸려도 신경 끄면 됩니다. 리셋 후 자동으로 이어집니다.

OpenCode 등 다른 AI CLI를 감시하려면:

```bash
autore start --session opencode --cli opencode
```

> ※ 참고: OpenCode는 레이트 리밋 자동 재시도가 내장되어 있어 autore 없이도 리밋 후 알아서 이어집니다.
> 텔레그램 알림을 받고 싶거나, 재시도가 없는 다른 AI CLI를 쓸 때 활용하세요.

```bash
autore status    # 상태 확인
autore logs -f   # 실시간 로그
autore stop      # 감시 중지
```

## 명령어

| 명령 | 설명 |
|---|---|
| `start [옵션]` | 백그라운드 감시 시작 (tmux 세션이 없으면 자동 생성) |
| `stop` | 감시 중지 |
| `status` | 감시 상태 + **중단 시점** + **tmux 세션 목록(AI CLI 실행 위치)** + 텔레그램 설정 + 최근 로그 |
| `last` | 마지막 중단 시점 화면 스냅샷 + 중단 이력 |
| `logs [-f]` | 로그 보기 (`-f`: 실시간) |
| `attach` | AI CLI tmux 세션 접속 |
| `run [옵션]` | 포그라운드 감시 (디버깅용) |
| `update [--check]` | 최신 버전으로 자동 업데이트 (`--check`: 확인만) |
| `test-telegram` | 텔레그램 연동 테스트 메시지 발송 |
| `checksum` | 배포용 SHA256 출력 (릴리스 시 `autore.sh.sha256` 갱신용) |
| `--selftest` | 파서·상태기록 단위 테스트 |
| `version` | 버전 출력 (`--version`과 동일) |
| `help` | 도움말 출력 (`-h`, `--help`와 동일) |

## 옵션

`start` / `run`에 사용 (또는 동명 환경변수):

| 옵션 | 환경변수 | 기본값 | 설명 |
|---|---|---|---|
| `--session NAME` | `AUTORE_SESSION` | `claude` | 감시할 tmux 세션명 (구 `CLAUDE_SESSION`도 동작) |
| `--cli CMD` | `CLI_CMD` | `claude` | 세션 생성 시 실행할 AI CLI (예: `opencode`) |
| `--target PANE` | `TARGET` | — | 특정 window/pane만 감시 (기본: 세션의 모든 pane) |
| `--poll SEC` | `POLL_SEC` | `30` | 화면 확인 주기 |
| `--buffer SEC` | `BUFFER_SEC` | `90` | 리셋 시각 후 여유 대기 |
| `--fallback SEC` | `FALLBACK_SEC` | `900` | 시각 파싱 실패 시 재시도 대기 |
| `--retry SEC` | `RETRY_SAME_KEY_SEC` | `600` | 같은 제한 메시지 재전송 간격 |
| `--max-resends N` | `MAX_RESENDS` | `2` | 같은 제한 메시지 최대 재전송 횟수 |
| `--verify-sec SEC` | `VERIFY_SEC` | `15` | 전송 후 화면 반응 확인 대기 (0이면 확인 안 함) |
| `--no-clear-input` | `CLEAR_INPUT` | 활성 | 전송 전 입력줄 비우기(C-u) 끄기 |
| `--message TEXT` | `RESUME_MESSAGE` | `계속 이어서 진행해줘` | 리셋 후 자동 입력할 메시지 |
| `--log-file PATH` | `LOG_FILE` | `~/.autore.log` | 로그 파일 |
| `--samples-file PATH` | `SAMPLES_FILE` | `~/.autore-samples.log` | 파싱 샘플 수집 파일 |
| `--state-file PATH` | `STATE_FILE` | `~/.autore-state` | 중단 시점 상태 파일 |
| `--break-file PATH` | `BREAK_FILE` | `~/.autore-break.txt` | 중단 시점 화면 스냅샷 |
| `--breaks-log PATH` | `BREAKS_LOG` | `~/.autore-breaks.log` | 중단 이력 (1건 1줄) |
| `--pid-file PATH` | `PID_FILE` | `~/.autore.pid` | PID 파일 |
| `--snapshot-lines N` | `SNAPSHOT_LINES` | `60` | 스냅샷에 남길 화면 줄 수 |
| `--log-max-bytes N` | `LOG_MAX_BYTES` | `1048576` | 로그 회전 기준 (0이면 회전 안 함) |
| `--telegram-token T` | `TELEGRAM_BOT_TOKEN` | — | 텔레그램 봇 토큰 |
| `--telegram-chat-id C` | `TELEGRAM_CHAT_ID` | — | 텔레그램 채팅 ID |
| `--notify-cmd CMD` | `NOTIFY_CMD` | — | 범용 알림 훅 (Slack/Discord/ntfy 등) |
| `--no-auto-update` | `AUTO_UPDATE` | 활성 | 자동 업데이트 끄기 |
| `--auto-update-sec S` | `AUTO_UPDATE_SEC` | `86400` | 자동 업데이트 확인 주기 (초) |
| `--allow-unverified` | `ALLOW_UNVERIFIED` | — | 체크섬 확인 불가 시에도 수동 업데이트 강행 (`update` 전용) |
| `--dry-run` | — | — | 실제 전송 없이 로그만 (테스트용) |

> 숫자 옵션에 정수가 아닌 값을 주면 즉시 오류로 막습니다 (`--poll abc` 등).
> **기본 세션(`claude`)이 아니면 로그·상태 파일 이름에 세션명이 자동으로 붙습니다** —
> `autore start --session opencode`는 `~/.autore-opencode.log`, `~/.autore-opencode.pid` …를 사용하므로
> 여러 세션을 동시에 감시해도 상태가 섞이지 않습니다.

## 텔레그램 알림 설정 (선택)

1. 텔레그램에서 [@BotFather](https://t.me/BotFather)에게 `/newbot` → **봇 토큰** 발급
2. 만든 봇과 대화 시작 후 [@userinfobot](https://t.me/userinfobot) 등으로 **채팅 ID** 확인
3. `~/.bashrc`에 추가:

```bash
export TELEGRAM_BOT_TOKEN="123456:ABC..."
export TELEGRAM_CHAT_ID="123456789"
```

4. 연동 테스트:

```bash
autore test-telegram   # 테스트 메시지가 오면 설정 완료
```

이후 `autore start` 하면 **감시 시작 / 제한 감지 / 재개 완료 / 재시도** 시 알림이 옵니다.

> ⚠️ 토큰은 `--telegram-token` CLI 인자로 넘기면 `ps` 출력에 노출될 수 있으니 환경변수 사용을 권장합니다.

## 다른 알림 채널 (`--notify-cmd`)

텔레그램 외의 채널은 알림 훅으로 연결합니다. 메시지가 `$1`로 전달되고, 환경변수 `AUTORE_EVENT`(`started` / `limit` / `limit_noparse` / `resumed` / `resume_skipped` / `resume_noreact` / `resend` / `autoupdate`), `AUTORE_MESSAGE`, `AUTORE_SESSION`, `AUTORE_VERSION`도 함께 넘어옵니다.

```bash
# Slack
autore start --notify-cmd 'curl -s -X POST -H "Content-type: application/json" \
  -d "{\"text\":\"$1\"}" https://hooks.slack.com/services/XXX'

# ntfy
autore start --notify-cmd 'curl -s -d "$1" https://ntfy.sh/my-topic'

# 데스크톱 알림 (Linux)
autore start --notify-cmd 'notify-send autore "$1"'
```

## 업데이트 무결성

`update` / 자동 업데이트는 내려받은 스크립트를 저장소의 `autore.sh.sha256`과 대조합니다.

- **자동 업데이트**: 해시가 다르거나 확인할 수 없으면 **교체하지 않고 기존 버전으로 계속 동작**합니다 (fail-closed).
- **수동 업데이트**: 해시가 다르면 중단, 확인이 불가능한 경우에만 `autore update --allow-unverified`로 강행할 수 있습니다.
- 이후 문법 검사와 자가진단까지 통과해야 교체됩니다.

> **릴리스 시 주의:** `autore.sh`를 수정했다면 반드시 체크섬을 다시 만들어 함께 커밋해야 합니다.
> 갱신을 잊으면 모든 사용자의 자동 업데이트가 (안전하게) 멈춥니다.
>
> ```bash
> ./autore.sh checksum > autore.sh.sha256
> ```

## 동작 원리

```
┌─────────────┐   30초마다 화면 확인   ┌──────────────────┐
│  tmux 세션   │ ───────────────────→ │  감시 프로세스      │
│  (AI CLI)    │                      │                    │
└─────────────┘                      │ 1. 제한 메시지 감지  │
       ↑                             │ 2. 리셋 시각 파싱    │
       │  리셋+버퍼 후                │ 3. 그 시각까지 sleep │
       │  "계속 이어서 진행해줘" 입력   │ 4. send-keys로 재개  │
       └──────────────────────────── │ 5. 텔레그램 알림     │
                                     └──────────────────┘
```

- 제한 메시지는 **세션의 모든 pane**에서, 각 화면 하단 40줄을 검색하며, 줄바꿈된 메시지도 아래 2줄까지 묶어서 파싱합니다. 재개 메시지는 제한이 발견된 그 pane으로 전송됩니다 (`--target`으로 고정 가능).
- 리셋 시각이 5시간 제한 창(베어 시각은 6시간, 날짜 지정은 8일)을 벗어나면 **오파싱으로 간주하고 거부**합니다.
- 같은 제한 메시지에 대해서는 최대 `MAX_RESENDS`회까지만 재전송해 메시지 도배를 방지합니다.

## 세션 확인

`status`는 지금 떠 있는 tmux 세션과, 그중 **AI CLI가 실제로 어디서 돌고 있는지**를 함께 보여줍니다.

```
== tmux 세션 (3개) ==
  ● claude       창 2개 · 접속됨 · claude 실행 중 → claude:0.0 (~/Github/vllm-setup)  ← 감시 중
  ○ dev          창 1개 · claude 없음
  ○ opencode     창 1개 · claude 없음
```

- `●`/`← 감시 중` = autore가 감시 중인 세션, `○` = 그 외 세션
- 실행 위치는 `세션:창.pane`과 그 pane의 현재 디렉터리로 표시됩니다
- pane의 표면 명령이 `node`처럼 보여도, **프로세스 트리를 따라가 CLI를 찾아냅니다** (npm/nvm 경유 실행 포함)
- 어떤 CLI를 찾을지는 `--cli` 값을 따릅니다 (`--cli opencode`면 opencode 기준으로 표시)

## 중단 시점 확인

제한에 걸린 **그 순간**을 기록해 둡니다. 자리를 비운 사이에 무슨 일이 있었는지 나중에 확인할 수 있습니다.

```bash
autore status    # 언제 멈췄고, 언제 이어지는지 (남은 시간 카운트다운)
autore last      # 멈추기 직전 화면 스냅샷 + 최근 중단 이력
```

`status` 출력 예:

```
== 중단 시점 ==
  ⏸ 중단됨:     2026-07-27 15:04:39 (30분 전)
     리셋 시각:   2026-07-27 15:49
     재개 예정:   2026-07-27 15:49:39 (15분 남음)
     마지막 작업: ● Update(src/app.ts) — 42 additions
     전체 보기: autore last
```

재개 후에는 `▶ 재개됨 … (중단 45분)`처럼 **실제로 얼마나 멈춰 있었는지**가 표시되고, 감시가 죽은 채 예정 시각이 지났다면 `(예정 시각 경과)` 경고가 붙습니다.

기록되는 파일:

| 파일 | 내용 |
|---|---|
| `~/.autore-state` | 현재 중단 상태(대기/재개/해소) + 중단·리셋·재개 시각 |
| `~/.autore-break.txt` | 중단 직전 세션 화면 스냅샷 (기본 60줄) |
| `~/.autore-breaks.log` | 중단 이력 (1건 1줄) |

텔레그램 알림에도 중단 시점의 **마지막 작업 줄**이 함께 전송됩니다.

## 파싱 샘플 수집 & 파서 업데이트

감지된 실제 제한 메시지 원문과 파싱 결과가 `~/.autore-samples.log`에 자동 수집됩니다.

Anthropic이 메시지 형식을 바꾸면:

1. 샘플 파일에서 새 형식의 `raw:` 줄 확인
2. 스크립트의 `LIMIT_REGEX` / 파서 정규식 수정
3. `./autore.sh --selftest` 로 회귀 테스트 (29종)
4. 새 형식은 [이슈](https://github.com/2pylab/autore/issues)로 제보해주시면 반영하겠습니다

## 법률 검토 및 면책조항 (Legal Review & Disclaimer)

**이 도구는 무엇인가:**

- Claude Code가 **화면에 이미 표시한** 제한 안내 메시지를 읽고, 안낐된 리셋 시각까지 **단순 대기**한 뒤, **사용자 본인의** 터미널 세션에 재개 메시지를 입력하는 **단순 대기·재개 자동화 스크립트**입니다.
- 사용량 제한을 **우회하거나 회피하지 않습니다.** Anthropic 서비스에 추가 API 요청을 별도로 **보내지 않으며**, 인증·접근 제어를 변경하지도 않습니다. 제한이 **해제된 후에만** 정상적으로 세션을 재개합니다.

**면책조항:**

- 본 프로젝트는 **Anthropic과 무관한 비공식 오픈소스 도구**이며, Anthropic이 보증·지원·승인하지 않습니다. "Claude" 및 "Claude Code"는 Anthropic의 상표입니다.
- Anthropic의 **이용약관 및 사용 정책을 확인하고 준수할 책임은 사용자 본인**에게 있습니다. 사용으로 인해 발생하는 모든 결과(계정 제한, 약관 위반 판정, 데이터 손실, 업무 중단 등)에 대한 책임은 사용자에게 있습니다.
- 이 소프트웨어는 **어떠한 보증 없이 "있는 그대로"** 제공됩니다 (MIT License).

**English summary:**

> autore is an unofficial open-source automation script that reads the usage-limit notice Claude Code already displays, simply waits until the stated reset time, and then resumes your own terminal session. It does **not** bypass, avoid, or circumvent any rate limits, nor does it make any additional API calls. This project is **not affiliated with, endorsed by, or supported by Anthropic**. You are solely responsible for reviewing and complying with Anthropic's Terms of Service and Usage Policies. Provided **as-is, without warranty of any kind** (MIT License). Use at your own risk.

## 제한사항

- 제한 메시지 형식은 Claude Code 영문 UI 및 프로바이더 공통 표현(rate limit, too many requests, quota exceeded) 기준입니다. 형식이 바뀌면 샘플 로그를 보고 파서를 업데이트해야 합니다 (위 섹션 참조).
- 리셋 시각은 로컬 타임존 기준으로 해석됩니다.
- 대기 중 사용자가 직접 세션을 이어가면, 예정 시각에 화면을 다시 확인해 제한이 이미 풀렸으면 재개 메시지를 보내지 않습니다.

## 라이선스

[MIT](LICENSE)
