#!/usr/bin/env bash
#===============================================================================
# claude-auto-resume — Claude Code 사용량 제한(5시간) 자동 재개 도구
#
# Claude Code의 사용량 제한 메시지를 감지하면 리셋 시각까지 대기한 뒤,
# tmux 세션에 재개 메시지를 자동 입력해 중단된 작업을 이어간다.
#
# 빠른 시작:
#   claude-auto-resume start     # 백그라운드 감시 시작
#   claude-auto-resume attach    # Claude Code 세션 접속 (평소처럼 사용)
#   claude-auto-resume status    # 상태 확인
#   claude-auto-resume stop      # 감시 중지
#
# 지원 플랫폼: Linux, macOS (macOS는 GNU coreutils 필요 — README 참조)
# 상세 도움말: claude-auto-resume --help
#===============================================================================
set -uo pipefail

VERSION="1.1.1"
REPO_RAW="https://raw.githubusercontent.com/2pylab/claude-auto-resume/main"

#--- 스크립트 절대 경로 (macOS 호환: readlink -f 미사용) -------------------------
SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" >/dev/null 2>&1 && pwd -P)
SCRIPT_PATH="$SCRIPT_DIR/$(basename -- "$0")"

#--- 기본 설정값 (환경변수로 재정의 가능, CLI 옵션이 최우선) ----------------------
SESSION="${CLAUDE_SESSION:-claude}"
POLL_SEC="${POLL_SEC:-30}"
BUFFER_SEC="${BUFFER_SEC:-90}"
FALLBACK_SEC="${FALLBACK_SEC:-900}"
RETRY_SAME_KEY_SEC="${RETRY_SAME_KEY_SEC:-600}"
MAX_RESENDS="${MAX_RESENDS:-2}"
RESUME_MESSAGE="${RESUME_MESSAGE:-계속 이어서 진행해줘}"
LOG_FILE="${LOG_FILE:-$HOME/.claude-auto-resume.log}"
SAMPLES_FILE="${SAMPLES_FILE:-$HOME/.claude-auto-resume-samples.log}"
PID_FILE="${PID_FILE:-$HOME/.claude-auto-resume.pid}"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"

TAIL_LINES=40               # 화면 하단 몇 줄을 검사할지
GRACE_SEC=300               # 이 시간 이내로 지난 리셋 시각은 '방금 지남'으로 간주
MAX_FUTURE_SEC=21600        # 베어 시각(3pm 등): 최대 6시간 이내 (5시간 제한 창 + 마진)
MAX_FUTURE_DATE_SEC=691200  # 날짜 지정(Jul 28 등): 최대 8일 이내 (주간 제한 + 마진)
LIMIT_REGEX='usage limit|limit reached|hit your limit|rate limit'
MONTH_REGEX='(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec|tomorrow)'

DRY_RUN=0
SELFTEST=0
LOGS_FOLLOW=0
UPDATE_CHECK=0
CMD=""
DATE=""

usage() {
  cat <<EOF
claude-auto-resume v${VERSION} — Claude Code 사용량 제한 자동 재개 도구

사용법:
  claude-auto-resume start [옵션]   백그라운드 감시 시작 (세션 없으면 자동 생성)
  claude-auto-resume stop           감시 중지
  claude-auto-resume status         감시 상태 + 최근 로그 확인
  claude-auto-resume logs [-f]      로그 보기 (-f: 실시간 따라가기)
  claude-auto-resume attach         Claude Code tmux 세션 접속
  claude-auto-resume run [옵션]     포그라운드 감시 (디버깅용)
  claude-auto-resume update [--check] 최신 버전으로 업데이트 (--check: 확인만)
  claude-auto-resume --selftest     리셋 시각 파서 단위 테스트
  claude-auto-resume --version      버전 출력

옵션 (start / run):
  --session NAME      감시할 tmux 세션명            (기본: claude)
  --poll SEC          화면 확인 주기                (기본: 30)
  --buffer SEC        리셋 시각 후 여유 대기         (기본: 90)
  --fallback SEC      리셋 시각 파싱 실패 시 재시도 대기 (기본: 900)
  --retry SEC         같은 제한 메시지 재전송 간격    (기본: 600)
  --max-resends N     같은 제한 메시지 최대 재전송 횟수 (기본: 2)
  --message TEXT      리셋 후 자동 입력할 메시지     (기본: 계속 이어서 진행해줘)
  --log-file PATH     로그 파일                    (기본: ~/.claude-auto-resume.log)
  --samples-file PATH 제한 메시지 샘플 수집 파일    (기본: ~/.claude-auto-resume-samples.log)
  --telegram-token T  텔레그램 봇 토큰 (채팅 ID와 함께 설정 시 알림 활성화)
  --telegram-chat-id C 텔레그램 채팅 ID
  --dry-run           실제 전송 없이 로그만 기록

환경변수로도 설정 가능: POLL_SEC, BUFFER_SEC, FALLBACK_SEC, RETRY_SAME_KEY_SEC,
MAX_RESENDS, RESUME_MESSAGE, LOG_FILE, SAMPLES_FILE,
TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID (CLI 옵션이 우선)

※ 텔레그램 토큰은 CLI 인자로 넘기면 프로세스 목록(ps)에 노출될 수 있으니
  환경변수(예: ~/.bashrc에 export) 사용을 권장합니다.
EOF
  exit "${1:-0}"
}

#--- 인자 파싱 -------------------------------------------------------------------
need_value() { [[ $# -ge 2 ]] || { echo "오류: '$1' 옵션에 값이 필요합니다" >&2; exit 1; }; }

while (($#)); do
  case "$1" in
    start|stop|status|attach|run) CMD="$1"; shift ;;
    logs)
      CMD="logs"; shift
      [[ ${1:-} == -f ]] && { LOGS_FOLLOW=1; shift; }
      ;;
    update)
      CMD="update"; shift
      [[ ${1:-} == "--check" ]] && { UPDATE_CHECK=1; shift; }
      ;;
    --session)        need_value "$@"; SESSION="$2"; shift 2 ;;
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
    --dry-run)        DRY_RUN=1; shift ;;
    --selftest)       SELFTEST=1; shift ;;
    --version)        echo "claude-auto-resume v${VERSION}"; exit 0 ;;
    -h|--help)        usage 0 ;;
    -*)               echo "알 수 없는 옵션: $1" >&2; usage 1 ;;
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
  echo "오류: GNU date를 찾을 수 없습니다." >&2
  echo "  - Linux: coreutils 패키지 (대부분 기본 포함)" >&2
  echo "  - macOS: brew install coreutils  (gdate 명령이 생깁니다)" >&2
  exit 1
}

log() { printf '%s %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG_FILE"; }

# 텔레그램 알림 — TELEGRAM_BOT_TOKEN + TELEGRAM_CHAT_ID 둘 다 설정된 경우에만 동작
notify_telegram() { # <message>
  [[ -n $TELEGRAM_BOT_TOKEN && -n $TELEGRAM_CHAT_ID ]] || return 0
  command -v curl >/dev/null 2>&1 || { log "텔레그램 알림 실패: curl 없음"; return 0; }
  if curl -sS -m 10 -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
      --data-urlencode "text=$1" >/dev/null 2>&1; then
    log "텔레그램 알림 전송됨"
  else
    log "텔레그램 알림 전송 실패 (네트워크/토큰/채팅 ID 확인)"
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
  # 주간 제한까지 고려해 최대 8일 이내만 유효
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
      printf 'parsed: FAILED — 파서 업데이트 필요 (GitHub 이슈로 제보 환영)\n'
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
        echo "FAIL: $desc (실패해야 하는데 rc=0, out=$out)"; fail=1
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

  if (( fail == 0 )); then echo "== 전체 통과 =="; else echo "== 실패 있음 =="; fi
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
    log "[DRY-RUN] '$RESUME_MESSAGE' 전송 생략"
    return 0
  fi
  tmux send-keys -t "$SESSION" -l -- "$RESUME_MESSAGE"
  sleep 0.5
  tmux send-keys -t "$SESSION" Enter
}

handle_limit() { # <limit_block>
  local block="$1" now target rc reset_desc
  now=$(date +%s)
  target=$(parse_reset_epoch "$block" "$now"); rc=$?
  collect_sample "$block" "$rc" "${target:-}"
  if (( rc == 0 )); then
    reset_desc=$("$DATE" -d "@$target" '+%m-%d %H:%M')
    target=$((target + BUFFER_SEC))
    log "제한 감지 — 리셋 ${reset_desc}, 버퍼 포함 $("$DATE" -d "@$target" '+%H:%M:%S')에 재개 예정"
    notify_telegram "[claude-auto-resume] 사용량 제한 감지
리셋: ${reset_desc}
재개 예정: $("$DATE" -d "@$target" '+%H:%M:%S')"
    wait_until "$target" || { log "대기 중 세션 사라짐"; return 1; }
  else
    log "제한 감지 — 리셋 시각 파싱 불가(rc=$rc, 샘플 기록됨: $SAMPLES_FILE), ${FALLBACK_SEC}초 후 재개 시도"
    notify_telegram "[claude-auto-resume] 사용량 제한 감지 (리셋 시각 파싱 실패)
${FALLBACK_SEC}초 후 재개 시도 예정"
    wait_until $((now + FALLBACK_SEC)) || { log "대기 중 세션 사라짐"; return 1; }
  fi
  log "재개 메시지 전송: '$RESUME_MESSAGE'"
  send_resume
  notify_telegram "[claude-auto-resume] 작업 재개 — '$RESUME_MESSAGE' 전송 완료"
}

watch_loop() {
  require_date
  command -v tmux >/dev/null 2>&1 || { echo "오류: tmux가 설치되어 있지 않습니다" >&2; exit 1; }
  trap 'log "감시 종료"; exit 0' INT TERM

  if ! tmux has-session -t "$SESSION" 2>/dev/null; then
    if (( DRY_RUN )); then
      log "[DRY-RUN] 세션 '$SESSION' 없음 — 생성 생략"
    else
      command -v claude >/dev/null 2>&1 || { echo "오류: claude CLI를 찾을 수 없습니다" >&2; exit 1; }
      log "tmux 세션 '$SESSION'이 없어 새로 만들고 claude를 시작합니다 (접속: $SCRIPT_PATH attach)"
      tmux new-session -d -s "$SESSION" 'claude' || { log "세션 생성 실패"; exit 1; }
    fi
  fi
  log "감시 시작: 세션='$SESSION' 주기=${POLL_SEC}s 버퍼=${BUFFER_SEC}s dry_run=$DRY_RUN"

  local last_key="" last_action=0 resends=0
  local tail_text limit_block limit_key now
  while :; do
    if ! tmux has-session -t "$SESSION" 2>/dev/null; then
      log "세션 '$SESSION' 없음 — ${POLL_SEC}초 후 재확인 (세션이 다시 생기면 자동 감시 재개)"
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
          log "같은 제한 메시지 지속 — 재개 메시지 재전송 ($((resends + 1))/${MAX_RESENDS})"
          send_resume
          notify_telegram "[claude-auto-resume] 재개 메시지 재전송 ($((resends + 1))/${MAX_RESENDS})"
          resends=$((resends + 1)); last_action=$now
        fi
      else
        last_key="$limit_key"; resends=0
        handle_limit "$limit_block"
        last_action=$(date +%s)
      fi
    else
      [[ -n $last_key ]] && log "제한 메시지 사라짐 — 정상 상태로 복귀"
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
  command -v tmux >/dev/null 2>&1 || { echo "오류: tmux가 설치되어 있지 않습니다" >&2; exit 1; }
  require_date
  command -v claude >/dev/null 2>&1 || \
    echo "경고: claude CLI를 찾을 수 없습니다 — 세션 자동 생성이 실패할 수 있습니다" >&2
  if is_running; then
    echo "이미 감시 중입니다 (PID $(cat "$PID_FILE")) — 상태 확인: $SCRIPT_PATH status"
    exit 0
  fi
  local extra=()
  (( DRY_RUN )) && extra+=(--dry-run)
  POLL_SEC="$POLL_SEC" BUFFER_SEC="$BUFFER_SEC" FALLBACK_SEC="$FALLBACK_SEC" \
  RETRY_SAME_KEY_SEC="$RETRY_SAME_KEY_SEC" MAX_RESENDS="$MAX_RESENDS" \
  RESUME_MESSAGE="$RESUME_MESSAGE" LOG_FILE="$LOG_FILE" SAMPLES_FILE="$SAMPLES_FILE" \
  PID_FILE="$PID_FILE" \
  TELEGRAM_BOT_TOKEN="$TELEGRAM_BOT_TOKEN" TELEGRAM_CHAT_ID="$TELEGRAM_CHAT_ID" \
    nohup "$SCRIPT_PATH" run --session "$SESSION" "${extra[@]+"${extra[@]}"}" \
      >>/dev/null 2>>"$LOG_FILE" &
  echo $! > "$PID_FILE"
  sleep 1
  if ! is_running; then
    echo "오류: 감시 프로세스가 즉시 종료되었습니다 — 로그 확인: $LOG_FILE" >&2
    rm -f "$PID_FILE"
    exit 1
  fi
  echo "✓ 백그라운드 감시를 시작했습니다 (PID $(cat "$PID_FILE"))"
  echo "  - 세션 접속: $SCRIPT_PATH attach   (또는 tmux attach -t $SESSION)"
  echo "  - 상태 확인: $SCRIPT_PATH status"
  echo "  - 감시 중지: $SCRIPT_PATH stop"
  (( DRY_RUN )) && echo "  ⚠ dry-run 모드: 실제 메시지는 전송되지 않습니다"
  exit 0
}

cmd_stop() {
  if is_running; then
    kill "$(cat "$PID_FILE")" 2>/dev/null
    rm -f "$PID_FILE"
    echo "✓ 감시를 중지했습니다"
  else
    rm -f "$PID_FILE"
    echo "실행 중인 감시 프로세스가 없습니다"
  fi
}

cmd_status() {
  if is_running; then
    echo "감시: 실행 중 (PID $(cat "$PID_FILE"))"
  else
    echo "감시: 중지됨"
  fi
  if tmux has-session -t "$SESSION" 2>/dev/null; then
    echo "tmux 세션 '$SESSION': 있음"
  else
    echo "tmux 세션 '$SESSION': 없음 (start/attach 시 자동 생성)"
  fi
  if [[ -n $TELEGRAM_BOT_TOKEN && -n $TELEGRAM_CHAT_ID ]]; then
    echo "텔레그램 알림: 설정됨 (chat_id: $TELEGRAM_CHAT_ID)"
  else
    echo "텔레그램 알림: 미설정"
  fi
  echo "--- 최근 로그 ($LOG_FILE) ---"
  if [[ -f $LOG_FILE ]]; then tail -n 5 "$LOG_FILE"; else echo "(로그 없음)"; fi
}

cmd_logs() {
  [[ -f $LOG_FILE ]] || { echo "(로그 없음: $LOG_FILE)"; exit 0; }
  if (( LOGS_FOLLOW )); then tail -f "$LOG_FILE"; else tail -n 30 "$LOG_FILE"; fi
}

cmd_attach() {
  if ! tmux has-session -t "$SESSION" 2>/dev/null; then
    echo "세션 '$SESSION'이 없어 새로 만들고 claude를 시작합니다"
    tmux new-session -d -s "$SESSION" 'claude' || { echo "세션 생성 실패" >&2; exit 1; }
  fi
  exec tmux attach -t "$SESSION"
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

cmd_update() {
  command -v curl >/dev/null 2>&1 || { echo "오류: curl이 필요합니다" >&2; exit 1; }

  local tmp remote_ver
  tmp=$(mktemp)
  echo "최신 버전 확인 중: $REPO_RAW/claude-auto-resume.sh"
  if ! curl -fsSL "$REPO_RAW/claude-auto-resume.sh" -o "$tmp"; then
    rm -f "$tmp"
    echo "오류: 최신 버전을 가져오지 못했습니다 (네트워크 확인)" >&2
    exit 1
  fi
  remote_ver=$(sed -n 's/^VERSION="\([^"]*\)".*/\1/p' "$tmp" | head -n 1)
  if [[ -z $remote_ver ]]; then
    rm -f "$tmp"
    echo "오류: 버전 정보를 읽지 못했습니다" >&2
    exit 1
  fi

  if ver_ge "$VERSION" "$remote_ver"; then
    rm -f "$tmp"
    echo "✓ 이미 최신 버전입니다 (v$VERSION)"
    exit 0
  fi
  echo "새 버전 발견: v$VERSION → v$remote_ver"
  if (( UPDATE_CHECK )); then
    rm -f "$tmp"
    exit 0
  fi

  # 다운로드 파일 검증: 문법 검사 + 자가진단 통과 시에만 교체
  if ! bash -n "$tmp" || ! bash "$tmp" --selftest >/dev/null 2>&1; then
    rm -f "$tmp"
    echo "오류: 다운로드한 파일이 검증에 실패했습니다 — 업데이트 중단" >&2
    exit 1
  fi
  if [[ ! -w $SCRIPT_PATH ]]; then
    rm -f "$tmp"
    echo "오류: $SCRIPT_PATH 에 쓰기 권한이 없습니다 (sudo 또는 install.sh 재설치)" >&2
    exit 1
  fi

  # 감시 실행 중이면 중지 후 교체 (실행 중인 bash 스크립트 덮어쓰기 방지)
  local was_running=0
  if is_running; then
    was_running=1
    echo "감시 프로세스 중지 중..."
    cmd_stop >/dev/null
  fi

  cp "$SCRIPT_PATH" "$SCRIPT_PATH.bak"
  if ! cp "$tmp" "$SCRIPT_PATH"; then
    cp "$SCRIPT_PATH.bak" "$SCRIPT_PATH"
    rm -f "$tmp"
    echo "오류: 파일 교체 실패 — 백업으로 복원했습니다" >&2
    exit 1
  fi
  chmod +x "$SCRIPT_PATH"
  rm -f "$tmp"
  echo "✓ 업데이트 완료: v$VERSION → v$remote_ver (백업: $SCRIPT_PATH.bak)"
  (( was_running )) && echo "  감시가 중지된 상태입니다 — 다시 시작: claude-auto-resume start"
  exit 0
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
esac
