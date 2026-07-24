#!/usr/bin/env bash
#===============================================================================
# autore — AI CLI 사용량 제한 자동 재개 도구 (auto-resume / retry / restart)
# English: watches AI CLI sessions (Claude Code, OpenCode, ...) and auto-resumes
#          work after usage-limit resets.
#
# Claude Code, OpenCode 등 AI CLI의 사용량 제한 메시지를 감지하면
# 리셋 시각까지 대기한 뒤, tmux 세션에 재개 메시지를 자동 입력해
# 중단된 작업을 이어간다.
#
# 빠른 시작:
#   autore start     # 백그라운드 감시 시작
#   autore attach    # AI CLI 세션 접속 (평소처럼 사용)
#   autore status    # 상태 확인
#   autore stop      # 감시 중지
#
# 지원 플랫폼: Linux, macOS (macOS는 GNU coreutils 필요 — README 참조)
# 출력 언어: OS 로케일 자동 감지 (한국어/English)
# 상세 도움말: autore help
#===============================================================================
set -uo pipefail

VERSION="2.2.0"
REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/2pylab/autore/main}"

#--- 스크립트 절대 경로 (macOS 호환: readlink -f 미사용) -------------------------
SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" >/dev/null 2>&1 && pwd -P)
SCRIPT_PATH="$SCRIPT_DIR/$(basename -- "$0")"

#--- 로케일 감지 — 한국어 로케일이면 한국어, 그 외에는 영어 -----------------------
case "${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}" in
  ko*) TSFX=KO ;;
  *)   TSFX=EN ;;
esac

# t <key> [printf 인자...] — 현재 로케일의 메시지 출력 (누락 시 한국어 → 키 순 폴 백)
t() {
  local v="MSG_${TSFX}_$1" fmt
  fmt="${!v:-}"
  if [[ -z $fmt && $TSFX != KO ]]; then v="MSG_KO_$1"; fmt="${!v:-}"; fi
  [[ -z $fmt ]] && fmt="$1"
  shift
  if (($#)); then printf "$fmt" "$@"; else printf '%s' "$fmt"; fi
}

#===============================================================================
# 메시지 카탈로그 (한국어 / English)
#===============================================================================
#--- 오류/공통 ---
MSG_KO_err_need_value="오류: '%s' 옵션에 값이 필요합니다"
MSG_EN_err_need_value="error: option '%s' requires a value"
MSG_KO_err_unknown_opt="알 수 없는 옵션: %s"
MSG_EN_err_unknown_opt="unknown option: %s"
MSG_KO_err_no_gnu_date=$'오류: GNU date를 찾을 수 없습니다.\n  - Linux: coreutils 패키지 (대부분 기본 포함)\n  - macOS: brew install coreutils  (gdate 명령이 생깁니다)'
MSG_EN_err_no_gnu_date=$'error: GNU date not found.\n  - Linux: coreutils package (preinstalled on most systems)\n  - macOS: brew install coreutils  (provides the gdate command)'
MSG_KO_err_no_tmux="오류: tmux가 설치되어 있지 않습니다"
MSG_EN_err_no_tmux="error: tmux is not installed"
MSG_KO_err_cli_not_found="오류: '%s' CLI를 찾을 수 없습니다"
MSG_EN_err_cli_not_found="error: '%s' CLI not found"
MSG_KO_warn_cli_not_found="경고: '%s' CLI를 찾을 수 없습니다 — 세션 자동 생성이 실패할 수 있습니다"
MSG_EN_warn_cli_not_found="warning: '%s' CLI not found — automatic session creation may fail"
MSG_KO_err_no_curl="오류: curl이 필요합니다"
MSG_EN_err_no_curl="error: curl is required"

#--- 로그/텔레그램 ---
MSG_KO_log_tg_no_curl="텔레그램 알림 실패: curl 없음"
MSG_EN_log_tg_no_curl="Telegram notification failed: curl not found"
MSG_KO_log_tg_sent="텔레그램 알림 전송됨"
MSG_EN_log_tg_sent="Telegram notification sent"
MSG_KO_log_tg_failed="텔레그램 알림 전송 실패 (네트워크/토큰/채팅 ID 확인)"
MSG_EN_log_tg_failed="Telegram notification failed (check network/token/chat ID)"
MSG_KO_log_watch_stop="감시 종료"
MSG_EN_log_watch_stop="watcher stopped"
MSG_KO_log_session_create="tmux 세션 '%s'이 없어 새로 만들고 '%s'를 시작합니다 (접속: %s attach)"
MSG_EN_log_session_create="tmux session '%s' not found — creating it and starting '%s' (attach: %s attach)"
MSG_KO_log_session_create_fail="세션 생성 실패"
MSG_EN_log_session_create_fail="failed to create session"
MSG_KO_log_watch_start="감시 시작: 세션='%s' 주기=%ss 버퍼=%ss dry_run=%s"
MSG_EN_log_watch_start="watch started: session='%s' poll=%ss buffer=%ss dry_run=%s"
MSG_KO_log_limit_detected="제한 감지 — 리셋 %s, 버퍼 포함 %s에 재개 예정"
MSG_EN_log_limit_detected="limit detected — reset at %s, resuming at %s (incl. buffer)"
MSG_KO_log_session_gone="대기 중 세션 사라짐"
MSG_EN_log_session_gone="session disappeared while waiting"
MSG_KO_log_limit_noparse="제한 감지 — 리셋 시각 파싱 불가(rc=%s, 샘플 기록됨: %s), %s초 후 재개 시도"
MSG_EN_log_limit_noparse="limit detected — could not parse reset time (rc=%s, sample saved: %s); attempting resume in %ss"
MSG_KO_log_resume_send="재개 메시지 전송: '%s'"
MSG_EN_log_resume_send="sending resume message: '%s'"
MSG_KO_log_dryrun_send="[DRY-RUN] '%s' 전송 생략"
MSG_EN_log_dryrun_send="[DRY-RUN] skipped sending '%s'"
MSG_KO_log_dryrun_session="[DRY-RUN] 세션 '%s' 없음 — 생성 생략"
MSG_EN_log_dryrun_session="[DRY-RUN] session '%s' not found — skipping creation"
MSG_KO_log_session_wait="세션 '%s' 없음 — %s초 후 재확인 (세션이 다시 생기면 자동 감시 재개)"
MSG_EN_log_session_wait="session '%s' not found — rechecking in %ss (watching resumes automatically when it reappears)"
MSG_KO_log_resend="같은 제한 메시지 지속 — 재개 메시지 재전송 (%s/%s)"
MSG_EN_log_resend="same limit message persists — resending resume message (%s/%s)"
MSG_KO_log_limit_cleared="제한 메시지 사라짐 — 정상 상태로 복귀"
MSG_EN_log_limit_cleared="limit message cleared — back to normal"
MSG_KO_tg_start=$'[autore] 감시 시작 (v%s)\n호스트: %s\n세션: %s — 텔레그램 연동이 정상적으로 연결되었습니다'
MSG_EN_tg_start=$'[autore] Watcher started (v%s)\nHost: %s\nSession: %s — Telegram integration connected successfully'
MSG_KO_tg_limit=$'[autore] 사용량 제한 감지\n리셋: %s\n재개 예정: %s'
MSG_EN_tg_limit=$'[autore] Usage limit detected\nReset: %s\nResume at: %s'
MSG_KO_tg_limit_noparse=$'[autore] 사용량 제한 감지 (리셋 시각 파싱 실패)\n%s초 후 재개 시도 예정'
MSG_EN_tg_limit_noparse=$'[autore] Usage limit detected (could not parse reset time)\nWill attempt resume in %ss'
MSG_KO_tg_resumed="[autore] 작업 재개 — '%s' 전송 완료"
MSG_EN_tg_resumed="[autore] Resumed — '%s' sent"
MSG_KO_tg_resend="[autore] 재개 메시지 재전송 (%s/%s)"
MSG_EN_tg_resend="[autore] Resent resume message (%s/%s)"
MSG_KO_tg_test="[autore] 테스트 메시지 — 텔레그램 연동이 정상입니다 (v%s)"
MSG_EN_tg_test="[autore] Test message — Telegram integration is working (v%s)"

#--- 샘플/자가진단 ---
MSG_KO_sample_failed="parsed: FAILED — 파서 업데이트 필요 (GitHub 이슈로 제보 환영)"
MSG_EN_sample_failed="parsed: FAILED — parser needs an update (GitHub issues welcome)"
MSG_KO_st_note_unexpected="(실패해야 하는데 rc=0, out=%s)"
MSG_EN_st_note_unexpected="(expected failure but rc=0, out=%s)"
MSG_KO_st_summary_pass="== 전체 통과 =="
MSG_EN_st_summary_pass="== all tests passed =="
MSG_KO_st_summary_fail="== 실패 있음 =="
MSG_EN_st_summary_fail="== some tests failed =="

#--- start/stop/status/logs/attach ---
MSG_KO_out_already_running="이미 감시 중입니다 (PID %s) — 상태 확인: %s status"
MSG_EN_out_already_running="already watching (PID %s) — check: %s status"
MSG_KO_err_watch_died="오류: 감시 프로세스가 즉시 종료되었습니다 — 로그 확인: %s"
MSG_EN_err_watch_died="error: watcher exited immediately — check log: %s"
MSG_KO_out_started="✓ 백그라운드 감시를 시작했습니다 (PID %s)"
MSG_EN_out_started="✓ background watcher started (PID %s)"
MSG_KO_out_attach_hint="  - 세션 접속: %s attach   (또는 tmux attach -t %s)"
MSG_EN_out_attach_hint="  - attach: %s attach   (or tmux attach -t %s)"
MSG_KO_out_status_hint="  - 상태 확인: %s status"
MSG_EN_out_status_hint="  - status: %s status"
MSG_KO_out_stop_hint="  - 감시 중지: %s stop"
MSG_EN_out_stop_hint="  - stop: %s stop"
MSG_KO_out_dryrun_warn="  ⚠ dry-run 모드: 실제 메시지는 전송되지 않습니다"
MSG_EN_out_dryrun_warn="  ⚠ dry-run mode: no messages will actually be sent"
MSG_KO_out_stopped="✓ 감시를 중지했습니다"
MSG_EN_out_stopped="✓ watcher stopped"
MSG_KO_out_not_running="실행 중인 감시 프로세스가 없습니다"
MSG_EN_out_not_running="no watcher is running"
MSG_KO_st_header_state="== 현재 상태 (실시간) =="
MSG_EN_st_header_state="== current state (live) =="
MSG_KO_st_header_log="== 최근 로그 (과거 기록) =="
MSG_EN_st_header_log="== recent logs (history) =="
MSG_KO_st_l_watch="감시:          "
MSG_EN_st_l_watch="Watcher:       "
MSG_KO_st_l_session="tmux 세션:     "
MSG_EN_st_l_session="tmux session:  "
MSG_KO_st_l_tg="텔레그램 알림: "
MSG_EN_st_l_tg="Telegram:      "
MSG_KO_st_running="실행 중"
MSG_EN_st_running="running"
MSG_KO_st_stopped="중지됨 — start로 시작"
MSG_EN_st_stopped="stopped — run: autore start"
MSG_KO_st_yes="있음"
MSG_EN_st_yes="present"
MSG_KO_st_no="없음"
MSG_EN_st_no="missing"
MSG_KO_st_no_hint="(%s — start/attach 시 자동 생성)"
MSG_EN_st_no_hint="(%s — auto-created on start/attach)"
MSG_KO_st_tg_set="설정됨"
MSG_EN_st_tg_set="configured"
MSG_KO_st_tg_unset="미설정"
MSG_EN_st_tg_unset="not configured"
MSG_KO_st_no_log="(로그 없음)"
MSG_EN_st_no_log="(no logs)"
MSG_KO_out_no_logs="(로그 없음: %s)"
MSG_EN_out_no_logs="(no logs: %s)"
MSG_KO_out_attach_creating="세션 '%s'이 없어 새로 만들고 '%s'를 시작합니다"
MSG_EN_out_attach_creating="session '%s' not found — creating it and starting '%s'"

#--- test-telegram ---
MSG_KO_tt_err_unset=$'오류: 텔레그램이 설정되어 있지 않습니다\n  - 환경변수: export TELEGRAM_BOT_TOKEN=... TELEGRAM_CHAT_ID=...\n  - 또는 옵션: autore test-telegram --telegram-token T --telegram-chat-id C'
MSG_EN_tt_err_unset=$'error: Telegram is not configured\n  - env vars: export TELEGRAM_BOT_TOKEN=... TELEGRAM_CHAT_ID=...\n  - or options: autore test-telegram --telegram-token T --telegram-chat-id C'
MSG_KO_tt_sending="텔레그램 테스트 메시지 발송 중... (chat_id: %s)"
MSG_EN_tt_sending="sending Telegram test message... (chat_id: %s)"
MSG_KO_tt_fail_net="✗ 발송 실패 — 네트워크 오류:"
MSG_EN_tt_fail_net="✗ send failed — network error:"
MSG_KO_tt_success="✓ 발송 성공 — 텔레그램에서 메시지를 확인하세요"
MSG_EN_tt_success="✓ sent — check the message in Telegram"
MSG_KO_tt_fail_api="✗ 발송 실패 — 텔레그램 API 응답:"
MSG_EN_tt_fail_api="✗ send failed — Telegram API response:"
MSG_KO_tt_hint_401="  힌트: 봇 토큰이 잘못되었습니다 (@BotFather에서 토큰 재확인)"
MSG_EN_tt_hint_401="  hint: invalid bot token (check the token with @BotFather)"
MSG_KO_tt_hint_chat="  힌트: 채팅 ID 오류이거나, 봇에게 먼저 아무 메시지나 전송하지 않은 상태입니다"
MSG_EN_tt_hint_chat="  hint: wrong chat ID, or you have not sent any message to the bot first"
MSG_KO_tt_hint_blocked="  힌트: 봇이 차단된 상태입니다 — 텔레그램에서 차단 해제 후 다시 시도"
MSG_EN_tt_hint_blocked="  hint: the bot is blocked — unblock it in Telegram and retry"

#--- update ---
MSG_KO_upd_checking="최신 버전 확인 중: %s"
MSG_EN_upd_checking="checking for the latest version: %s"
MSG_KO_upd_err_fetch="오류: 최신 버전을 가져오지 못했습니다 (네트워크 확인)"
MSG_EN_upd_err_fetch="error: failed to fetch the latest version (check network)"
MSG_KO_upd_err_nover="오류: 버전 정보를 읽지 못했습니다"
MSG_EN_upd_err_nover="error: could not read version info"
MSG_KO_upd_latest="✓ 이미 최신 버전입니다 (v%s)"
MSG_EN_upd_latest="✓ already up to date (v%s)"
MSG_KO_upd_found="새 버전 발견: v%s → v%s"
MSG_EN_upd_found="new version available: v%s → v%s"
MSG_KO_upd_err_verify="오류: 다운로드한 파일이 검증에 실패했습니다 — 업데이트 중단"
MSG_EN_upd_err_verify="error: downloaded file failed verification — update aborted"
MSG_KO_upd_err_nowrite="오류: %s 에 쓰기 권한이 없습니다 (sudo 또는 install.sh 재설치)"
MSG_EN_upd_err_nowrite="error: no write permission for %s (use sudo or reinstall via install.sh)"
MSG_KO_upd_stopping="감시 프로세스 중지 중..."
MSG_EN_upd_stopping="stopping watcher..."
MSG_KO_upd_err_replace="오류: 파일 교체 실패 — 백업으로 복원했습니다"
MSG_EN_upd_err_replace="error: failed to replace file — restored from backup"
MSG_KO_upd_done="✓ 업데이트 완료: v%s → v%s (백업: %s)"
MSG_EN_upd_done="✓ update complete: v%s → v%s (backup: %s)"
MSG_KO_upd_restart="  감시가 중지된 상태입니다 — 다시 시작: autore start"
MSG_EN_upd_restart="  the watcher is stopped — restart: autore start"

#--- 기본 재개 메시지 (AI CLI 세션에 입력되는 문구) ---
MSG_KO_default_resume_msg="계속 이어서 진행해줘"
MSG_EN_default_resume_msg="Keep going and continue"

#--- 자동 업데이트 ---
MSG_KO_log_autoupdate_found="자동 업데이트: 새 버전 발견 v%s → v%s"
MSG_EN_log_autoupdate_found="auto-update: new version found v%s → v%s"
MSG_KO_log_autoupdate_done="자동 업데이트 완료 — v%s로 재시작합니다"
MSG_EN_log_autoupdate_done="auto-update complete — restarting with v%s"
MSG_KO_log_autoupdate_fail="자동 업데이트 실패 — 기존 버전으로 계속 동작합니다"
MSG_EN_log_autoupdate_fail="auto-update failed — continuing with the current version"
MSG_KO_log_autoupdate_fetch_fail="자동 업데이트 확인 실패 (네트워크) — 다음 주기에 재시도"
MSG_EN_log_autoupdate_fetch_fail="auto-update check failed (network) — will retry next interval"
MSG_KO_tg_autoupdate="[autore] 자동 업데이트 완료: v%s → v%s"
MSG_EN_tg_autoupdate="[autore] Auto-updated: v%s → v%s"

#--- 기본 설정값 (환경변수로 재정의 가능, CLI 옵션이 최우선) ----------------------
# 구버전(claude-auto-resume) 상태 파일 하위호환 — 새 파일이 없고 구 파일만 있으면 구 파일 사용
_legacy_file() { [[ -f $1 || ! -f $2 ]] && printf '%s\n' "$1" || printf '%s\n' "$2"; }

SESSION="${AUTORE_SESSION:-${CLAUDE_SESSION:-claude}}"
CLI_CMD="${CLI_CMD:-claude}"
POLL_SEC="${POLL_SEC:-30}"
BUFFER_SEC="${BUFFER_SEC:-90}"
FALLBACK_SEC="${FALLBACK_SEC:-900}"
RETRY_SAME_KEY_SEC="${RETRY_SAME_KEY_SEC:-600}"
MAX_RESENDS="${MAX_RESENDS:-2}"
RESUME_MESSAGE="${RESUME_MESSAGE:-$(t default_resume_msg)}"
LOG_FILE="${LOG_FILE:-$(_legacy_file "$HOME/.autore.log" "$HOME/.claude-auto-resume.log")}"
SAMPLES_FILE="${SAMPLES_FILE:-$(_legacy_file "$HOME/.autore-samples.log" "$HOME/.claude-auto-resume-samples.log")}"
PID_FILE="${PID_FILE:-$(_legacy_file "$HOME/.autore.pid" "$HOME/.claude-auto-resume.pid")}"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
AUTO_UPDATE="${AUTO_UPDATE:-1}"                 # 0이면 자동 업데이트 비활성화
AUTO_UPDATE_SEC="${AUTO_UPDATE_SEC:-86400}"     # 자동 업데이트 확인 주기 (기본 24시간)

TAIL_LINES=40               # 화면 하단 몇 줄을 검사할지
GRACE_SEC=300               # 이 시간 이내로 지난 리셋 시각은 '방금 지남'으로 간주
MAX_FUTURE_SEC=21600        # 베어 시각(3pm 등): 최대 6시간 이내 (5시간 제한 창 + 마진)
MAX_FUTURE_DATE_SEC=691200  # 날짜 지정(Jul 28 등): 최대 8일 이내 (주간 제한 + 마진)
# Claude Code: usage limit / limit reached / hit your limit
# OpenCode 등 프로바이더 공통: rate limit / too many requests / quota exceeded
LIMIT_REGEX='usage limit|limit reached|hit your limit|rate limit|too many requests|quota exceeded'
MONTH_REGEX='(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec|tomorrow)'

DRY_RUN=0
SELFTEST=0
LOGS_FOLLOW=0
UPDATE_CHECK=0
CMD=""
DATE=""

usage() {
  if [[ $TSFX == KO ]]; then
    cat <<EOF
autore v${VERSION} — AI CLI 사용량 제한 자동 재개 도구

사용법:
  autore start [옵션]   백그라운드 감시 시작 (세션 없으면 자동 생성)
  autore stop           감시 중지
  autore status         감시 상태 + 최근 로그 확인
  autore logs [-f]      로그 보기 (-f: 실시간 따라가기)
  autore attach         감시 중인 AI CLI tmux 세션 접속
  autore run [옵션]     포그라운드 감시 (디버깅용)
  autore update [--check] 최신 버전으로 업데이트 (--check: 확인만)
  autore test-telegram  텔레그램 연동 테스트 메시지 발송
  autore --selftest     리셋 시각 파서 단위 테스트
  autore version        버전 출력 (--version 도 동일)
  autore help           이 도움말 출력 (-h, --help 도 동일)

옵션 (start / run):
  --session NAME      감시할 tmux 세션명            (기본: claude)
  --cli CMD           세션 생성 시 실행할 AI CLI     (기본: claude, 예: opencode)
  --poll SEC          화면 확인 주기                (기본: 30)
  --buffer SEC        리셋 시각 후 여유 대기         (기본: 90)
  --fallback SEC      리셋 시각 파싱 실패 시 재시도 대기 (기본: 900)
  --retry SEC         같은 제한 메시지 재전송 간격    (기본: 600)
  --max-resends N     같은 제한 메시지 최대 재전송 횟수 (기본: 2)
  --message TEXT      리셋 후 자동 입력할 메시지     (기본: 계속 이어서 진행해줘)
  --log-file PATH     로그 파일                    (기본: ~/.autore.log)
  --samples-file PATH 제한 메시지 샘플 수집 파일    (기본: ~/.autore-samples.log)
  --telegram-token T  텔레그램 봇 토큰 (채팅 ID와 함께 설정 시 알림 활성화)
  --telegram-chat-id C 텔레그램 채팅 ID
  --no-auto-update    자동 업데이트 비활성화       (기본: 활성 — 시작 시 + 주기마다 확인)
  --auto-update-sec S 자동 업데이트 확인 주기      (기본: 86400)
  --dry-run           실제 전송 없이 로그만 기록

환경변수로도 설정 가능: CLI_CMD, POLL_SEC, BUFFER_SEC, FALLBACK_SEC,
RETRY_SAME_KEY_SEC, MAX_RESENDS, RESUME_MESSAGE, LOG_FILE, SAMPLES_FILE,
TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID, AUTO_UPDATE, AUTO_UPDATE_SEC (CLI 옵션이 우선)

오픈코드 사용 예: autore start --session opencode --cli opencode
출력 언어: OS 로케일 자동 감지 (한국어/영어)

※ 텔레그램 토큰은 CLI 인자로 넘기면 프로세스 목록(ps)에 노출될 수 있으니
  환경변수(예: ~/.bashrc에 export) 사용을 권장합니다.
EOF
  else
    cat <<EOF
autore v${VERSION} — auto-resume watcher for AI CLI usage limits

Usage:
  autore start [options]   start background watcher (creates session if missing)
  autore stop              stop the watcher
  autore status            watcher state + recent logs
  autore logs [-f]         show logs (-f: follow)
  autore attach            attach to the AI CLI tmux session
  autore run [options]     foreground watcher (for debugging)
  autore update [--check]  update to the latest version (--check: check only)
  autore test-telegram     send a Telegram test message
  autore --selftest        reset-time parser unit tests
  autore version           print version (same as --version)
  autore help              print this help (same as -h, --help)

Options (start / run):
  --session NAME      tmux session to watch            (default: claude)
  --cli CMD           AI CLI to launch on session create (default: claude, e.g. opencode)
  --poll SEC          screen check interval            (default: 30)
  --buffer SEC        extra wait after reset time      (default: 90)
  --fallback SEC      retry delay when time parsing fails (default: 900)
  --retry SEC         resend interval for same limit message (default: 600)
  --max-resends N     max resends for same limit message (default: 2)
  --message TEXT      message typed after reset        (default: Keep going and continue)
  --log-file PATH     log file                         (default: ~/.autore.log)
  --samples-file PATH limit-message sample file        (default: ~/.autore-samples.log)
  --telegram-token T  Telegram bot token (enables alerts with chat ID)
  --telegram-chat-id C Telegram chat ID
  --no-auto-update    disable auto-update          (default: on — checks at start + every interval)
  --auto-update-sec S auto-update check interval   (default: 86400)
  --dry-run           log only, never send

Also configurable via env vars: CLI_CMD, POLL_SEC, BUFFER_SEC, FALLBACK_SEC,
RETRY_SAME_KEY_SEC, MAX_RESENDS, RESUME_MESSAGE, LOG_FILE, SAMPLES_FILE,
TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID, AUTO_UPDATE, AUTO_UPDATE_SEC (CLI options take precedence)

OpenCode example: autore start --session opencode --cli opencode
Language: auto-detected from OS locale (Korean/English)

Note: passing the Telegram token as a CLI argument can expose it in the
  process list (ps) — environment variables (e.g. export in ~/.bashrc) are recommended.
EOF
  fi
  exit "${1:-0}"
}

#--- 인자 파싱 -------------------------------------------------------------------
need_value() { [[ $# -ge 2 ]] || { echo "$(t err_need_value "$1")" >&2; exit 1; }; }

while (($#)); do
  case "$1" in
    start|stop|status|attach|run|test-telegram) CMD="$1"; shift ;;
    logs)
      CMD="logs"; shift
      [[ ${1:-} == -f ]] && { LOGS_FOLLOW=1; shift; }
      ;;
    update)
      CMD="update"; shift
      [[ ${1:-} == "--check" ]] && { UPDATE_CHECK=1; shift; }
      ;;
    --session)        need_value "$@"; SESSION="$2"; shift 2 ;;
    --cli)            need_value "$@"; CLI_CMD="$2"; shift 2 ;;
    --poll)           need_value "$@"; POLL_SEC="$2"; shift 2 ;;
    --buffer)         need_value "$@"; BUFFER_SEC="$2"; shift 2 ;;
    --fallback)       need_value "$@"; FALLBACK_SEC="$2"; shift 2 ;;
    --retry)          need_value "$@"; RETRY_SAME_KEY_SEC="$2"; shift 2 ;;
    --max-resends)    need_value "$@"; MAX_RESENDS="$2"; shift 2 ;;
    --message)        need_value "$@"; RESUME_MESSAGE="$2"; shift 2 ;;
    --log-file)       need_value "$@"; LOG_FILE="$2"; shift 2 ;;
    --samples-file)   need_value "$@"; SAMPLES_FILE="$2"; shift 2 ;;
    --telegram-token)    need_value "$@"; TELEGRAM_BOT_TOKEN="$2"; shift 2 ;;
    --telegram-chat-id)  need_value "$@"; TELEGRAM_CHAT_ID="$2"; shift 2 ;;
    --no-auto-update) AUTO_UPDATE=0; shift ;;
    --auto-update-sec) need_value "$@"; AUTO_UPDATE_SEC="$2"; shift 2 ;;
    --dry-run)        DRY_RUN=1; shift ;;
    --selftest)       SELFTEST=1; shift ;;
    version|--version) echo "autore v${VERSION}"; exit 0 ;;
    help|-h|--help)   usage 0 ;;
    -*)               echo "$(t err_unknown_opt "$1")" >&2; usage 1 ;;
    *)                SESSION="$1"; shift ;;  # 위치 인자 = 세션명 (하위호환)
  esac
done
[[ -z $CMD ]] && CMD="run"
(( SELFTEST )) && CMD="selftest"

#--- GNU date 탐지 (Linux: date, macOS: gdate from coreutils) --------------------
detect_gnu_date() {
  if date --version >/dev/null 2>&1; then
    echo "date"
  elif command -v gdate >/dev/null 2>&1 && gdate --version >/dev/null 2>&1; then
    echo "gdate"
  else
    return 1
  fi
}

require_date() {
  [[ -n $DATE ]] && return 0
  DATE=$(detect_gnu_date) && return 0
  echo "$(t err_no_gnu_date)" >&2
  exit 1
}

log() { printf '%s %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG_FILE"; }

# 텔레그램 알림 — TELEGRAM_BOT_TOKEN + TELEGRAM_CHAT_ID 둘 다 설정된 경우에만 동작
notify_telegram() { # <message>
  [[ -n $TELEGRAM_BOT_TOKEN && -n $TELEGRAM_CHAT_ID ]] || return 0
  command -v curl >/dev/null 2>&1 || { log "$(t log_tg_no_curl)"; return 0; }
  if curl -sS -m 10 -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
      --data-urlencode "text=$1" >/dev/null 2>&1; then
    log "$(t log_tg_sent)"
  else
    log "$(t log_tg_failed)"
  fi
}

#-------------------------------------------------------------------------------
# 리셋 시각 파서
#
# 2단계 전략:
#   1) 날짜 지정 표현(Jul 28, tomorrow 등)이 있으면 GNU date 범용 파싱 우선
#      — "Jul 28 at 3pm"의 '3pm'을 오늘 시각으로 오파싱하는 것을 방지
#   2) 베어 시각(3pm / 3:30 PM / 15:00)은 정규식으로 정밀 파싱
#   3) 그래도 실패하면 GNU date 범용 파싱을 마지막 수단으로 시도
#
# 반환코드: 0=성공(epoch 출력), 1=파싱 불가, 2=모순된 시각(제한 창 밖)
#-------------------------------------------------------------------------------

# 베어 시각 파싱: "reset at 3pm", "resets 3:30 PM", "reset at 15:00"
parse_bare_time() { # <text> <now_epoch>
  local text="$1" now="$2" hour="" min="0" ap="" epoch
  if [[ $text =~ [Rr]eset[s]?[^0-9]{0,20}([0-9]{1,2}):([0-9]{2})[[:space:]]*([AaPp])[[:space:]]*[Mm] ]]; then
    hour="${BASH_REMATCH[1]}"; min="${BASH_REMATCH[2]}"; ap="${BASH_REMATCH[3]}"
  elif [[ $text =~ [Rr]eset[s]?[^0-9]{0,20}([0-9]{1,2})[[:space:]]*([AaPp])[[:space:]]*[Mm] ]]; then
    hour="${BASH_REMATCH[1]}"; ap="${BASH_REMATCH[2]}"
  elif [[ $text =~ [Rr]eset[s]?[^0-9]{0,20}([0-9]{1,2}):([0-9]{2}) ]]; then
    hour="${BASH_REMATCH[1]}"; min="${BASH_REMATCH[2]}"
  else
    return 1
  fi

  hour=$((10#$hour)); min=$((10#$min))
  if [[ -n $ap ]]; then
    hour=$((hour % 12))
    case $ap in [Pp]) hour=$((hour + 12)) ;; esac
  fi
  (( hour > 23 || min > 59 )) && return 1

  epoch=$("$DATE" -d "today $(printf '%02d:%02d' "$hour" "$min")" +%s) || return 1
  # 이미 지난 시각이면(자정 넘김 등) 내일로 해석
  (( epoch < now - GRACE_SEC )) && epoch=$((epoch + 86400))
  # 5시간 제한 창상 리셋은 최대 ~6시간 이내 — 그 이상이면 파싱 결과를 신뢰하지 않음
  (( epoch > now + MAX_FUTURE_SEC )) && return 2
  printf '%s\n' "$epoch"
}

# 날짜 지정 표현 파싱: "reset on Jul 28 at 3pm", "reset tomorrow at 9am"
parse_date_expr() { # <text> <now_epoch>
  local text="$1" now="$2" cand epoch
  text=$(printf '%s' "$text" | tr '\n' ' ')
  # "reset" 이후 부분 추출 → (타임존) 괄호 제거 → at/on 전치사 제거 → 공백 정리
  cand=$(printf '%s\n' "$text" | sed -E \
    -e 's/^.*[Rr]eset[s]?[[:space:]]+//' \
    -e 's/\([^)]*\)//g' \
    -e 's/[[:space:]]+([Aa][Tt]|[Oo][Nn])[[:space:]]+/ /g' \
    -e 's/^[[:space:]]*([Aa][Tt]|[Oo][Nn])[[:space:]]+//' \
    -e 's/[[:space:]]+/ /g' -e 's/^ //' -e 's/ $//')
  [[ -n $cand ]] || return 1
  epoch=$("$DATE" -d "$cand" +%s 2>/dev/null) || return 1
  if (( epoch < now - GRACE_SEC )); then
    # 연도 경계 등으로 과거가 나오면 다음 해로 재해석
    epoch=$("$DATE" -d "$cand next year" +%s 2>/dev/null) || return 1
  fi
  # 주간 제한까지 고려해 최대 8일 이내이면 유효
  (( epoch >= now - GRACE_SEC && epoch <= now + MAX_FUTURE_DATE_SEC )) || return 2
  printf '%s\n' "$epoch"
}

parse_reset_epoch() { # <text> <now_epoch>
  local text="$1" now="$2" epoch rc
  if [[ $text =~ $MONTH_REGEX ]]; then
    parse_date_expr "$text" "$now"
    return $?
  fi
  epoch=$(parse_bare_time "$text" "$now"); rc=$?
  if (( rc == 1 )); then
    parse_date_expr "$text" "$now"
    return $?
  fi
  printf '%s\n' "$epoch"
  return "$rc"
}

#-------------------------------------------------------------------------------
# 파싱 샘플 수집 — 실제 제한 메시지 원문을 기록해 파서를 안전하게 개선할 근거 확보
#-------------------------------------------------------------------------------
collect_sample() { # <block> <rc> [epoch]
  local block="$1" rc="$2" epoch="${3:-}" first_line
  first_line=$(printf '%s\n' "$block" | head -n 1)
  if [[ -f $SAMPLES_FILE ]] && grep -qF "raw: $first_line" "$SAMPLES_FILE" 2>/dev/null; then
    return 0  # 이미 수집된 메시지
  fi
  {
    printf '[%s] rc=%s\n' "$(date '+%F %T')" "$rc"
    printf 'raw: %s\n' "$block"
    if (( rc == 0 )) && [[ -n $epoch ]]; then
      printf 'parsed: %s\n' "$("$DATE" -d "@$epoch" '+%F %T')"
    else
      printf '%s\n' "$(t sample_failed)"
    fi
    printf '\n'
  } >> "$SAMPLES_FILE"
}

#-------------------------------------------------------------------------------
# 단위 테스트
#-------------------------------------------------------------------------------
selftest() {
  require_date
  local fail=0
  check() { # <설명> <메시지> <현재 시각> <기대 시각|FAIL>
    local desc="$1" text="$2" now_s="$3" exp="$4"
    local now out rc exp_e
    now=$("$DATE" -d "$now_s" +%s)
    out=$(parse_reset_epoch "$text" "$now"); rc=$?
    if [[ $exp == FAIL ]]; then
      if (( rc != 0 )); then
        echo "PASS: $desc"
      else
        echo "FAIL: $desc $(t st_note_unexpected "$out")"; fail=1
      fi
    else
      exp_e=$("$DATE" -d "$exp" +%s)
      if (( rc == 0 )) && [[ $out == "$exp_e" ]]; then
        echo "PASS: $desc"
      else
        echo "FAIL: $desc (rc=$rc out=${out:-none} exp=$exp_e)"; fail=1
      fi
    fi
  }

  #--- 베어 시각 ---
  check "3pm 기본"       "Claude usage limit reached. Your limit will reset at 3pm" "2026-07-24 09:54" "2026-07-24 15:00"
  check "3:30pm 분 포함"  "Your limit will reset at 3:30pm"                          "2026-07-24 09:54" "2026-07-24 15:30"
  check "PM 대문자+tz"   "You've hit your limit · resets 6:30 PM (Asia/Seoul)"      "2026-07-24 14:00" "2026-07-24 18:30"
  check "24시간제"       "Your limit will reset at 15:00"                           "2026-07-24 09:54" "2026-07-24 15:00"
  check "12am 자정"      "Your limit will reset at 12am"                            "2026-07-24 23:00" "2026-07-25 00:00"
  check "12pm 정오"      "Your limit will reset at 12pm"                            "2026-07-24 09:00" "2026-07-24 12:00"
  check "자정 넘김"      "Your limit will reset at 1am"                             "2026-07-24 23:50" "2026-07-25 01:00"
  check "리셋 직후"      "Your limit will reset at 3pm"                             "2026-07-24 15:04" "2026-07-24 15:00"
  check "모순 시각 거부"  "Your limit will reset at 11am"                            "2026-07-24 15:00" FAIL
  check "파싱 불가 거부"  "Claude usage limit reached"                               "2026-07-24 15:00" FAIL
  #--- 날짜 지정 (주간 제한 등) ---
  check "날짜 지정"      "Your weekly usage limit will reset on Jul 28 at 3pm"      "2026-07-24 15:00" "2026-07-28 15:00"
  check "tomorrow"      "Your limit will reset tomorrow at 9am"                    "2026-07-24 15:00" "2026-07-25 09:00"
  check "연도 넘김 날짜"  "Your limit will reset on Jan 2 at 9am"                   "2026-12-31 20:00" "2027-01-02 09:00"
  check "날짜+PM+tz"    "Your limit will reset on Jul 28 at 3:00 PM (Asia/Seoul)"  "2026-07-24 15:00" "2026-07-28 15:00"
  check "날짜 모순 거부"  "Your limit will reset on Jul 88 at 3pm"                  "2026-07-24 15:00" FAIL
  #--- 줄바꿈(화면 wrap) ---
  check "줄바꿈 메시지"   $'Your limit will reset at\n3:30pm'                        "2026-07-24 09:54" "2026-07-24 15:30"

  if (( fail == 0 )); then echo "$(t st_summary_pass)"; else echo "$(t st_summary_fail)"; fi
  exit "$fail"
}

#-------------------------------------------------------------------------------
# 감시 루프
#-------------------------------------------------------------------------------
wait_until() { # <target_epoch> — 30초 단위로 끊어 대기 (세션 생존 확인)
  local target="$1" now
  while :; do
    now=$(date +%s)
    (( now >= target )) && return 0
    tmux has-session -t "$SESSION" 2>/dev/null || return 1
    sleep $(( (target - now) < 30 ? (target - now) : 30 ))
  done
}

send_resume() {
  if (( DRY_RUN )); then
    log "$(t log_dryrun_send "$RESUME_MESSAGE")"
    return 0
  fi
  tmux send-keys -t "$SESSION" -l -- "$RESUME_MESSAGE"
  sleep 0.5
  tmux send-keys -t "$SESSION" Enter
}

handle_limit() { # <limit_block>
  local block="$1" now target rc reset_desc resume_at
  now=$(date +%s)
  target=$(parse_reset_epoch "$block" "$now"); rc=$?
  collect_sample "$block" "$rc" "${target:-}"
  if (( rc == 0 )); then
    reset_desc=$("$DATE" -d "@$target" '+%m-%d %H:%M')
    target=$((target + BUFFER_SEC))
    resume_at=$("$DATE" -d "@$target" '+%H:%M:%S')
    log "$(t log_limit_detected "$reset_desc" "$resume_at")"
    notify_telegram "$(t tg_limit "$reset_desc" "$resume_at")"
    wait_until "$target" || { log "$(t log_session_gone)"; return 1; }
  else
    log "$(t log_limit_noparse "$rc" "$SAMPLES_FILE" "$FALLBACK_SEC")"
    notify_telegram "$(t tg_limit_noparse "$FALLBACK_SEC")"
    wait_until $((now + FALLBACK_SEC)) || { log "$(t log_session_gone)"; return 1; }
  fi
  log "$(t log_resume_send "$RESUME_MESSAGE")"
  send_resume
  notify_telegram "$(t tg_resumed "$RESUME_MESSAGE")"
}

watch_loop() {
  require_date
  command -v tmux >/dev/null 2>&1 || { echo "$(t err_no_tmux)" >&2; exit 1; }
  trap 'log "$(t log_watch_stop)"; exit 0' INT TERM

  if ! tmux has-session -t "$SESSION" 2>/dev/null; then
    if (( DRY_RUN )); then
      log "$(t log_dryrun_session "$SESSION")"
    else
      command -v "$CLI_CMD" >/dev/null 2>&1 || { echo "$(t err_cli_not_found "$CLI_CMD")" >&2; exit 1; }
      log "$(t log_session_create "$SESSION" "$CLI_CMD" "$SCRIPT_PATH")"
      tmux new-session -d -s "$SESSION" "$CLI_CMD" || { log "$(t log_session_create_fail)"; exit 1; }
    fi
  fi
  log "$(t log_watch_start "$SESSION" "$POLL_SEC" "$BUFFER_SEC" "$DRY_RUN")"
  notify_telegram "$(t tg_start "$VERSION" "$(hostname)" "$SESSION")"

  local last_key="" last_action=0 resends=0
  local tail_text limit_block limit_key now
  local last_update_check=0   # 0 = 시작하자마자 1회 확인
  while :; do
    now=$(date +%s)
    if (( now - last_update_check >= AUTO_UPDATE_SEC )); then
      last_update_check=$now
      auto_update_tick   # 새 버전이면 교체 후 exec으로 재시작 (성공 시 돌아오지 않음)
    fi
    if ! tmux has-session -t "$SESSION" 2>/dev/null; then
      log "$(t log_session_wait "$SESSION" "$POLL_SEC")"
      sleep "$POLL_SEC"; continue
    fi

    tail_text=$(tmux capture-pane -p -t "$SESSION" 2>/dev/null | tail -n "$TAIL_LINES")
    # 마지막 제한 메시지 + 아래 2줄까지 묶어서 추출 (화면 wrap 대비)
    limit_block=$(printf '%s\n' "$tail_text" | awk -v re="$LIMIT_REGEX" '
      tolower($0) ~ re { buf=$0; n=2; next }
      n > 0            { buf=buf "\n" $0; n-- }
      END              { if (buf != "") print buf }')

    if [[ -n $limit_block ]]; then
      limit_key=${limit_block%%$'\n'*}
      now=$(date +%s)
      if [[ $limit_key == "$last_key" ]]; then
        # 이미 처리한 제한 메시지 — 재개가 안 먹혔을 수 있으니 제한적으로 재전송
        if (( resends < MAX_RESENDS && now - last_action >= RETRY_SAME_KEY_SEC )); then
          log "$(t log_resend $((resends + 1)) "$MAX_RESENDS")"
          send_resume
          notify_telegram "$(t tg_resend $((resends + 1)) "$MAX_RESENDS")"
          resends=$((resends + 1)); last_action=$now
        fi
      else
        last_key="$limit_key"; resends=0
        handle_limit "$limit_block"
        last_action=$(date +%s)
      fi
    else
      [[ -n $last_key ]] && log "$(t log_limit_cleared)"
      last_key=""; resends=0
    fi
    sleep "$POLL_SEC"
  done
}

#-------------------------------------------------------------------------------
# 서브커맨드
#-------------------------------------------------------------------------------
is_running() { [[ -f $PID_FILE ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; }

cmd_start() {
  command -v tmux >/dev/null 2>&1 || { echo "$(t err_no_tmux)" >&2; exit 1; }
  require_date
  command -v "$CLI_CMD" >/dev/null 2>&1 || \
    echo "$(t warn_cli_not_found "$CLI_CMD")" >&2
  if is_running; then
    echo "$(t out_already_running "$(cat "$PID_FILE")" "$SCRIPT_PATH")"
    exit 0
  fi
  local extra=()
  (( DRY_RUN )) && extra+=(--dry-run)
  POLL_SEC="$POLL_SEC" BUFFER_SEC="$BUFFER_SEC" FALLBACK_SEC="$FALLBACK_SEC" \
  RETRY_SAME_KEY_SEC="$RETRY_SAME_KEY_SEC" MAX_RESENDS="$MAX_RESENDS" \
  RESUME_MESSAGE="$RESUME_MESSAGE" LOG_FILE="$LOG_FILE" SAMPLES_FILE="$SAMPLES_FILE" \
  PID_FILE="$PID_FILE" CLI_CMD="$CLI_CMD" LC_ALL="${LC_ALL:-${LANG:-}}" \
  AUTO_UPDATE="$AUTO_UPDATE" AUTO_UPDATE_SEC="$AUTO_UPDATE_SEC" \
  TELEGRAM_BOT_TOKEN="$TELEGRAM_BOT_TOKEN" TELEGRAM_CHAT_ID="$TELEGRAM_CHAT_ID" \
    nohup "$SCRIPT_PATH" run --session "$SESSION" "${extra[@]+"${extra[@]}"}" \
      >>/dev/null 2>>"$LOG_FILE" &
  echo $! > "$PID_FILE"
  sleep 1
  if ! is_running; then
    echo "$(t err_watch_died "$LOG_FILE")" >&2
    rm -f "$PID_FILE"
    exit 1
  fi
  echo "$(t out_started "$(cat "$PID_FILE")")"
  echo "$(t out_attach_hint "$SCRIPT_PATH" "$SESSION")"
  echo "$(t out_status_hint "$SCRIPT_PATH")"
  echo "$(t out_stop_hint "$SCRIPT_PATH")"
  (( DRY_RUN )) && echo "$(t out_dryrun_warn)"
  exit 0
}

cmd_stop() {
  if is_running; then
    kill "$(cat "$PID_FILE")" 2>/dev/null
    rm -f "$PID_FILE"
    echo "$(t out_stopped)"
  else
    rm -f "$PID_FILE"
    echo "$(t out_not_running)"
  fi
}

cmd_status() {
  # 색상 — 터미널 출력 시에만 적용 (파이프/리다이렉션 시 자동 해제, NO_COLOR 지원)
  local reset='' bold='' dim='' green='' red='' yellow='' cyan=''
  if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
    reset=$'\033[0m'; bold=$'\033[1m'; dim=$'\033[2m'
    green=$'\033[32m'; red=$'\033[31m'; yellow=$'\033[33m'; cyan=$'\033[36m'
  fi

  # 현재 상태 — 지금 이 순간의 실시간 검사 결과
  printf '%s%s%s%s\n' "$bold" "$cyan" "$(t st_header_state)" "$reset"
  if is_running; then
    printf '  %s●%s %s%s%s%s (PID %s)\n' \
      "$green" "$reset" "$(t st_l_watch)" "$bold$green" "$(t st_running)" "$reset" "$(cat "$PID_FILE")"
  else
    printf '  %s●%s %s%s%s%s\n' \
      "$red" "$reset" "$(t st_l_watch)" "$bold$red" "$(t st_stopped)" "$reset"
  fi
  if tmux has-session -t "$SESSION" 2>/dev/null; then
    printf '  %s●%s %s%s%s%s (%s)\n' \
      "$green" "$reset" "$(t st_l_session)" "$bold$green" "$(t st_yes)" "$reset" "$SESSION"
  else
    printf '  %s●%s %s%s%s%s %s\n' \
      "$yellow" "$reset" "$(t st_l_session)" "$bold$yellow" "$(t st_no)" "$reset" "$(t st_no_hint "$SESSION")"
  fi
  if [[ -n $TELEGRAM_BOT_TOKEN && -n $TELEGRAM_CHAT_ID ]]; then
    printf '  %s●%s %s%s%s%s (chat_id: %s)\n' \
      "$green" "$reset" "$(t st_l_tg)" "$bold$green" "$(t st_tg_set)" "$reset" "$TELEGRAM_CHAT_ID"
  else
    printf '  %s●%s %s%s%s%s\n' "$dim" "$reset" "$(t st_l_tg)" "$dim" "$(t st_tg_unset)" "$reset"
  fi

  # 최근 로그 — 과거 기록일 뿐, 현재 상태는 위 섹션 참조
  printf '\n%s%s%s%s %s[%s]%s\n' \
    "$bold" "$cyan" "$(t st_header_log)" "$reset" "$dim" "$LOG_FILE" "$reset"
  if [[ -f $LOG_FILE ]]; then
    tail -n 5 "$LOG_FILE" | while IFS= read -r line; do
      printf '  %s%s%s\n' "$dim" "$line" "$reset"
    done
  else
    printf '  %s%s%s\n' "$dim" "$(t st_no_log)" "$reset"
  fi
}

cmd_logs() {
  [[ -f $LOG_FILE ]] || { echo "$(t out_no_logs "$LOG_FILE")"; exit 0; }
  if (( LOGS_FOLLOW )); then tail -f "$LOG_FILE"; else tail -n 30 "$LOG_FILE"; fi
}

cmd_attach() {
  if ! tmux has-session -t "$SESSION" 2>/dev/null; then
    echo "$(t out_attach_creating "$SESSION" "$CLI_CMD")"
    tmux new-session -d -s "$SESSION" "$CLI_CMD" || { echo "$(t log_session_create_fail)" >&2; exit 1; }
  fi
  exec tmux attach -t "$SESSION"
}

# 텔레그램 연동 테스트 — 설정값으로 실제 메시지를 전송하고 결과를 상세히 보고
cmd_test_telegram() {
  if [[ -z $TELEGRAM_BOT_TOKEN || -z $TELEGRAM_CHAT_ID ]]; then
    echo "$(t tt_err_unset)" >&2
    exit 1
  fi
  command -v curl >/dev/null 2>&1 || { echo "$(t err_no_curl)" >&2; exit 1; }

  echo "$(t tt_sending "$TELEGRAM_CHAT_ID")"
  local resp
  if ! resp=$(curl -sS -m 10 -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
      --data-urlencode "text=$(t tg_test "$VERSION")" 2>&1); then
    echo "$(t tt_fail_net)" >&2
    echo "  $resp" >&2
    exit 1
  fi
  if [[ $resp == *'"ok":true'* ]]; then
    echo "$(t tt_success)"
    exit 0
  fi
  echo "$(t tt_fail_api)" >&2
  echo "  $resp" >&2
  case $resp in
    *'"error_code":401'*) echo "$(t tt_hint_401)" >&2 ;;
    *'chat not found'*)   echo "$(t tt_hint_chat)" >&2 ;;
    *'bot was blocked'*)  echo "$(t tt_hint_blocked)" >&2 ;;
  esac
  exit 1
}

# ver_ge A B — 버전 A >= B (semver 숫자 비교) 이면 0
ver_ge() {
  local a1 a2 a3 b1 b2 b3
  IFS=. read -r a1 a2 a3 <<<"$1"
  IFS=. read -r b1 b2 b3 <<<"$2"
  a1=$((10#${a1:-0})); a2=$((10#${a2:-0})); a3=$((10#${a3:-0}))
  b1=$((10#${b1:-0})); b2=$((10#${b2:-0})); b3=$((10#${b3:-0}))
  (( a1 != b1 )) && { (( a1 > b1 )); return $?; }
  (( a2 != b2 )) && { (( a2 > b2 )); return $?; }
  (( a3 >= b3 ))
}

# fetch_remote <outfile> — 원격 스크립트 다운로드 후 버전 출력 (실패 시 rc 1)
fetch_remote() {
  curl -fsSL "$REPO_RAW/autore.sh" -o "$1" 2>/dev/null || return 1
  local rv
  rv=$(sed -n 's/^VERSION="\([^"]*\)".*/\1/p' "$1" | head -n 1)
  [[ -n $rv ]] || return 1
  printf '%s\n' "$rv"
}

# replace_with <file> — 검증(문법+자가진단) 후 백업과 함께 교체 (실패 시 rc 1, 백업 복원)
replace_with() {
  bash -n "$1" || return 1
  bash "$1" --selftest >/dev/null 2>&1 || return 1
  [[ -w $SCRIPT_PATH ]] || return 1
  cp "$SCRIPT_PATH" "$SCRIPT_PATH.bak" || return 1
  if cp "$1" "$SCRIPT_PATH"; then
    chmod +x "$SCRIPT_PATH"
    return 0
  fi
  cp "$SCRIPT_PATH.bak" "$SCRIPT_PATH"
  return 1
}

cmd_update() {
  command -v curl >/dev/null 2>&1 || { echo "$(t err_no_curl)" >&2; exit 1; }

  local tmp remote_ver
  tmp=$(mktemp)
  echo "$(t upd_checking "$REPO_RAW/autore.sh")"
  if ! remote_ver=$(fetch_remote "$tmp"); then
    rm -f "$tmp"
    echo "$(t upd_err_fetch)" >&2
    exit 1
  fi

  if ver_ge "$VERSION" "$remote_ver"; then
    rm -f "$tmp"
    echo "$(t upd_latest "$VERSION")"
    exit 0
  fi
  echo "$(t upd_found "$VERSION" "$remote_ver")"
  if (( UPDATE_CHECK )); then
    rm -f "$tmp"
    exit 0
  fi

  # 다운로드 파일 검증: 문법 검사 + 자가진단 통과 시에만 교체
  if ! bash -n "$tmp" || ! bash "$tmp" --selftest >/dev/null 2>&1; then
    rm -f "$tmp"
    echo "$(t upd_err_verify)" >&2
    exit 1
  fi
  if [[ ! -w $SCRIPT_PATH ]]; then
    rm -f "$tmp"
    echo "$(t upd_err_nowrite "$SCRIPT_PATH")" >&2
    exit 1
  fi

  # 감시 실행 중이면 중지 후 교체 (실행 중인 bash 스크립트 덮어쓰기 방지)
  local was_running=0
  if is_running; then
    was_running=1
    echo "$(t upd_stopping)"
    cmd_stop >/dev/null
  fi

  cp "$SCRIPT_PATH" "$SCRIPT_PATH.bak"
  if ! cp "$tmp" "$SCRIPT_PATH"; then
    cp "$SCRIPT_PATH.bak" "$SCRIPT_PATH"
    rm -f "$tmp"
    echo "$(t upd_err_replace)" >&2
    exit 1
  fi
  chmod +x "$SCRIPT_PATH"
  rm -f "$tmp"
  echo "$(t upd_done "$VERSION" "$remote_ver" "$SCRIPT_PATH.bak")"
  (( was_running )) && echo "$(t upd_restart)"
  exit 0
}

# auto_update_tick — watch_loop에서 주기적으로 호출.
# 새 버전이 있으면 검증 후 교체하고 exec으로 자기 자신을 새 코드로 재시작한다.
# (exec은 같은 PID로 새 프로세스 이미지를 로드하므로 PID 파일이 그대로 유효하고,
#  실행 중인 스크립트를 덮어쓰는 문제도 생기지 않는다)
auto_update_tick() {
  (( AUTO_UPDATE && ! DRY_RUN )) || return 0
  command -v curl >/dev/null 2>&1 || return 0
  local tmp rv
  tmp=$(mktemp)
  if ! rv=$(fetch_remote "$tmp"); then
    rm -f "$tmp"
    log "$(t log_autoupdate_fetch_fail)"
    return 0
  fi
  if ! ver_ge "$VERSION" "$rv"; then
    log "$(t log_autoupdate_found "$VERSION" "$rv")"
    if replace_with "$tmp"; then
      rm -f "$tmp"
      log "$(t log_autoupdate_done "$rv")"
      notify_telegram "$(t tg_autoupdate "$VERSION" "$rv")"
      local extra=()
      (( DRY_RUN )) && extra+=(--dry-run)
      exec "$SCRIPT_PATH" run --session "$SESSION" "${extra[@]+"${extra[@]}"}"
    else
      log "$(t log_autoupdate_fail)"
    fi
  fi
  rm -f "$tmp"
  return 0
}

#--- 디스패치 --------------------------------------------------------------------
case "$CMD" in
  selftest) selftest ;;
  run)      watch_loop ;;
  start)    cmd_start ;;
  stop)     cmd_stop ;;
  status)   cmd_status ;;
  logs)     cmd_logs ;;
  attach)   cmd_attach ;;
  update)   cmd_update ;;
  test-telegram) cmd_test_telegram ;;
esac
