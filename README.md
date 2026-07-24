# autore

**auto + re(resume / retry / restart)** — AI CLI 사용량 제한 자동 재개 도구

**한국어** | [English](README_EN.md)

Claude Code, OpenCode 등 AI CLI의 **사용량 제한**에 걸렸을 때, 리셋 시각까지 대기했다가 **자동으로 작업을 이어가는** 경량 감시 도구입니다.

tmux 세션에서 실행 중인 AI CLI 화면을 주기적으로 확인하다가, 사용량 제한 메시지를 감지하면 리셋 시각을 파싱해 그 시각까지 잠든 뒤, 세션에 재개 메시지(기본: `계속 이어서 진행해줘`)를 자동 입력합니다. 대화 맥락이 그대로 유지된 채로 작업이 다시 시작됩니다.

> 📖 안내 웹페이지: <https://2pylab.github.io/autore/>

## 특징

- 🔁 **자동 재개** — 제한 감지 → 리셋 시각 파싱 → 대기 → 세션에 자동 입력
- 🤖 **멀티 CLI** — Claude Code 기본 지원, `--cli` 옵션으로 OpenCode 등 다른 AI CLI도 감시
- ⏱ **다단계 시각 파서** — `3pm`, `3:30 PM`, `15:00`, `Jul 28 at 3pm`(주간 제한), `tomorrow at 9am`, 자정/연도 넘김, 화면 줄바꿈까지 처리
- 🛡 **안전장치** — 같은 제한 메시지 중복 처리 방지, 모순된 시각 거부(5시간 창 검증), 파싱 실패 시 주기적 재시도
- 📨 **텔레그램 알림** — 제한 감지 / 재개 완료 / 재시도 시 봇 알림 (선택 사항)
- 🧪 **자가진단 내장** — `--selftest`로 파서 단위 테스트 16종 실행
- 🐧🍎 **Linux + macOS** — bash 3.2 호환, macOS는 coreutils만 있으면 동작
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
| `status` | 감시 상태 + tmux 세션 + 텔레그램 설정 + 최근 로그 |
| `logs [-f]` | 로그 보기 (`-f`: 실시간) |
| `attach` | AI CLI tmux 세션 접속 |
| `run [옵션]` | 포그라운드 감시 (디버깅용) |
| `update [--check]` | 최신 버전으로 자동 업데이트 (`--check`: 확인만) |
| `test-telegram` | 텔레그램 연동 테스트 메시지 발송 |
| `--selftest` | 리셋 시각 파서 단위 테스트 |
| `version` | 버전 출력 (`--version`과 동일) |
| `help` | 도움말 출력 (`-h`, `--help`와 동일) |

## 옵션

`start` / `run`에 사용 (또는 동명 환경변수):

| 옵션 | 환경변수 | 기본값 | 설명 |
|---|---|---|---|
| `--session NAME` | `AUTORE_SESSION` | `claude` | 감시할 tmux 세션명 (구 `CLAUDE_SESSION`도 동작) |
| `--cli CMD` | `CLI_CMD` | `claude` | 세션 생성 시 실행할 AI CLI (예: `opencode`) |
| `--poll SEC` | `POLL_SEC` | `30` | 화면 확인 주기 |
| `--buffer SEC` | `BUFFER_SEC` | `90` | 리셋 시각 후 여유 대기 |
| `--fallback SEC` | `FALLBACK_SEC` | `900` | 시각 파싱 실패 시 재시도 대기 |
| `--retry SEC` | `RETRY_SAME_KEY_SEC` | `600` | 같은 제한 메시지 재전송 간격 |
| `--max-resends N` | `MAX_RESENDS` | `2` | 같은 제한 메시지 최대 재전송 횟수 |
| `--message TEXT` | `RESUME_MESSAGE` | `계속 이어서 진행해줘` | 리셋 후 자동 입력할 메시지 |
| `--log-file PATH` | `LOG_FILE` | `~/.autore.log` | 로그 파일 |
| `--samples-file PATH` | `SAMPLES_FILE` | `~/.autore-samples.log` | 파싱 샘플 수집 파일 |
| `--telegram-token T` | `TELEGRAM_BOT_TOKEN` | — | 텔레그램 봇 토큰 |
| `--telegram-chat-id C` | `TELEGRAM_CHAT_ID` | — | 텔레그램 채팅 ID |
| `--dry-run` | — | — | 실제 전송 없이 로그만 (테스트용) |

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

- 제한 메시지는 화면 하단 40줄에서 검색하며, 줄바꿈된 메시지도 아래 2줄까지 묶어서 파싱합니다.
- 리셋 시각이 5시간 제한 창(베어 시각은 6시간, 날짜 지정은 8일)을 벗어나면 **오파싱으로 간주하고 거부**합니다.
- 같은 제한 메시지에 대해서는 최대 `MAX_RESENDS`회까지만 재전송해 메시지 도배를 방지합니다.

## 파싱 샘플 수집 & 파서 업데이트

감지된 실제 제한 메시지 원문과 파싱 결과가 `~/.autore-samples.log`에 자동 수집됩니다.

Anthropic이 메시지 형식을 바꾸면:

1. 샘플 파일에서 새 형식의 `raw:` 줄 확인
2. 스크립트의 `LIMIT_REGEX` / 파서 정규식 수정
3. `./autore.sh --selftest` 로 회귀 테스트 (16종)
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
- 대기 중 사용자가 수동으로 세션을 재개핸도, 예정 시각에 재개 메시지가 한 번 입력될 수 있습니다 (무해하지만 참고).

## 라이선스

[MIT](LICENSE)
