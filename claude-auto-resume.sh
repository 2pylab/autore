#!/usr/bin/env bash
# [구버전 호환 셈] 이 파일은 v1.x 'claude-auto-resume update' 경로를 위한 것으로,
# 실제 개발본은 autore.sh 입니다. v1.x 사용자가 update 시 이 파일을 받아
# 새 버전으로 전환되며, 이후 업데이트는 autore.sh 경로를 사용합니다.
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

VERSION="2.5.0"
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
MSG_KO_err_no_sha="오류: SHA256 도구를 찾을 수 없습니다 (sha256sum / shasum / openssl 중 하나 필요)"
MSG_EN_err_no_sha="error: no SHA256 tool found (need one of sha256sum / shasum / openssl)"
MSG_KO_err_no_curl="오류: curl이 필요합니다"
MSG_EN_err_no_curl="error: curl is required"
MSG_KO_err_not_number="오류: %s 값은 정수여야 합니다 (입력: '%s')"
MSG_EN_err_not_number="error: %s must be an integer (got '%s')"
MSG_KO_err_too_small="오류: %s 값은 %s 이상이어야 합니다"
MSG_EN_err_too_small="error: %s must be at least %s"
MSG_KO_err_locked="오류: 다른 start가 진행 중입니다 (잠금: %s)"
MSG_EN_err_locked="error: another start is in progress (lock: %s)"

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
MSG_KO_log_rotated="로그 파일이 커서 회전했습니다: %s → %s"
MSG_EN_log_rotated="log rotated (too large): %s → %s"
MSG_KO_log_notify_failed="알림 훅(--notify-cmd) 실행 실패"
MSG_EN_log_notify_failed="notify hook (--notify-cmd) failed"
MSG_KO_log_resume_skip="대기 중 제한이 이미 해소됨 — 재개 메시지 전송 생략"
MSG_EN_log_resume_skip="limit already cleared while waiting — skipping resume message"
MSG_KO_tg_resume_skip="[autore] 대기 중 제한이 해소되어 재개 메시지를 보내지 않았습니다"
MSG_EN_tg_resume_skip="[autore] Limit cleared while waiting — resume message not sent"
MSG_KO_log_resume_noreact="재개 메시지 전송 후 %s초 동안 화면 반응 없음 — 확인 필요"
MSG_EN_log_resume_noreact="no screen change for %ss after sending resume — needs a look"
MSG_KO_tg_resume_noreact=$'[autore] 재개 메시지를 보냈지만 %s초 동안 화면 반응이 없습니다\n세션을 확인해 주세요'
MSG_EN_tg_resume_noreact=$'[autore] Resume message sent but no screen change for %ss\nPlease check the session'
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
MSG_KO_out_stopped_forced="✓ 감시를 강제 종료했습니다 (SIGKILL, PID %s)"
MSG_EN_out_stopped_forced="✓ watcher force-killed (SIGKILL, PID %s)"
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
MSG_KO_upd_verified="✓ 무결성 검증 통과 (SHA256)"
MSG_EN_upd_verified="✓ integrity verified (SHA256)"
MSG_KO_upd_err_checksum=$'오류: SHA256 체크섬이 일치하지 않습니다 — 업데이트를 중단합니다\n  파일이 변조되었거나 배포가 진행 중일 수 있습니다'
MSG_EN_upd_err_checksum=$'error: SHA256 checksum mismatch — update aborted\n  the file may be tampered with, or a release may be in progress'
MSG_KO_upd_err_no_checksum=$'오류: 체크섬을 확인할 수 없습니다 (해시 파일 또는 sha256 도구 없음) — 업데이트 중단\n  확인 없이 진행하려면: autore update --allow-unverified'
MSG_EN_upd_err_no_checksum=$'error: cannot verify checksum (no hash file or sha256 tool) — update aborted\n  to proceed anyway: autore update --allow-unverified'
MSG_KO_upd_warn_unverified="⚠ 체크섬 확인 없이 진행합니다 (--allow-unverified)"
MSG_EN_upd_warn_unverified="⚠ proceeding without checksum verification (--allow-unverified)"
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
MSG_KO_log_autoupdate_checksum_fail="자동 업데이트 중단 — SHA256 검증 실패 또는 확인 불가"
MSG_EN_log_autoupdate_checksum_fail="auto-update aborted — SHA256 verification failed or unavailable"
MSG_KO_log_autoupdate_fail="자동 업데이트 실패 — 기존 버전으로 계속 동작합니다"
MSG_EN_log_autoupdate_fail="auto-update failed — continuing with the current version"
MSG_KO_log_autoupdate_fetch_fail="자동 업데이트 확인 실패 (네트워크) — 다음 주기에 재시도"
MSG_EN_log_autoupdate_fetch_fail="auto-update check failed (network) — will retry next interval"
MSG_KO_tg_autoupdate="[autore] 자동 업데이트 완료: v%s → v%s"
MSG_EN_tg_autoupdate="[autore] Auto-updated: v%s → v%s"

#--- 중단 시점 기록 ---
MSG_KO_dur_h="%d시간 %d분"
MSG_EN_dur_h="%dh %dm"
MSG_KO_dur_m="%d분"
MSG_EN_dur_m="%dm"
MSG_KO_dur_s="%d초"
MSG_EN_dur_s="%ds"
MSG_KO_dur_ago="%s 전"
MSG_EN_dur_ago="%s ago"
MSG_KO_dur_left="%s 남음"
MSG_EN_dur_left="in %s"
MSG_KO_br_snap_header="[%s] 세션 '%s' — 중단 시점 화면"
MSG_EN_br_snap_header="[%s] session '%s' — screen at interruption"
MSG_KO_br_reset_unknown="파싱 실패"
MSG_EN_br_reset_unknown="unparsed"
MSG_KO_st_header_sessions="== tmux 세션 (%s개) =="
MSG_EN_st_header_sessions="== tmux sessions (%s) =="
MSG_KO_st_sess_none="(실행 중인 tmux 세션 없음)"
MSG_EN_st_sess_none="(no tmux session running)"
MSG_KO_st_sess_windows="창 %s개"
MSG_EN_st_sess_windows="%s windows"
MSG_KO_st_sess_window="창 %s개"
MSG_EN_st_sess_window="%s window"
MSG_KO_st_sess_attached="접속됨"
MSG_EN_st_sess_attached="attached"
MSG_KO_st_sess_cli_run="%s 실행 중"
MSG_EN_st_sess_cli_run="%s running"
MSG_KO_st_sess_cli_none="%s 없음"
MSG_EN_st_sess_cli_none="no %s"
MSG_KO_st_sess_watching="← 감시 중"
MSG_EN_st_sess_watching="← watching"
MSG_KO_st_header_break="== 중단 시점 =="
MSG_EN_st_header_break="== interruption point =="
MSG_KO_st_br_none="(중단 기록 없음)"
MSG_EN_st_br_none="(no interruption recorded)"
MSG_KO_st_br_paused="⏸ 중단됨:     "
MSG_EN_st_br_paused="⏸ interrupted: "
MSG_KO_st_br_resumed="▶ 재개됨:     "
MSG_EN_st_br_resumed="▶ resumed:     "
MSG_KO_st_br_cleared="○ 최근 중단:  "
MSG_EN_st_br_cleared="○ last break:  "
MSG_KO_st_br_reset="   리셋 시각:   "
MSG_EN_st_br_reset="   reset at:   "
MSG_KO_st_br_eta="   재개 예정:   "
MSG_EN_st_br_eta="   resume at:  "
MSG_KO_st_br_last="   마지막 작업: "
MSG_EN_st_br_last="   last work:  "
MSG_KO_st_br_hint="   전체 보기: %s last"
MSG_EN_st_br_hint="   full snapshot: %s last"
MSG_KO_st_br_overdue="(예정 시각 경과 — 감시가 중지된 상태일 수 있음)"
MSG_EN_st_br_overdue="(past due — the watcher may have stopped)"
MSG_KO_st_br_downtime="중단 %s"
MSG_EN_st_br_downtime="down for %s"
MSG_KO_st_br_resends="   재전송:      %s/%s"
MSG_EN_st_br_resends="   resends:    %s/%s"
MSG_KO_last_none="중단 기록이 없습니다 (%s)"
MSG_EN_last_none="no interruption recorded (%s)"
MSG_KO_last_header="== 마지막 중단 시점 스냅샷 =="
MSG_EN_last_header="== snapshot at last interruption =="
MSG_KO_last_hist="== 중단 이력 (최근 %s건) =="
MSG_EN_last_hist="== interruption history (last %s) =="
MSG_KO_tg_lastwork=$'\n마지막 작업: %s'
MSG_EN_tg_lastwork=$'\nLast work: %s'

#--- 기본 설정값 (환경변수로 재정의 가능, CLI 옵션이 최우선) ----------------------
# 구버전(claude-auto-resume) 상태 파일 하위호환 — 새 파일이 없고 구 파일만 있으면 구 파일 사용
_legacy_file() { [[ -f $1 || ! -f $2 ]] && printf '%s\n' "$1" || printf '%s\n' "$2"; }

# 자동 업데이트가 exec으로 자기 자신을 재시작할 때 원래 인자를 그대로 넘기기 위해 보관
ORIG_ARGS=("$@")

# 파일 경로를 사용자가 직접 지정했는지 기록 — 세션별 기본 경로 결정에 사용
# (지정했으면 그대로 쓰고, 아니면 세션명을 붙인 기본 경로를 만든다)
_is_set() { [[ -n ${!1:-} ]] && printf '1' || printf '0'; }
LOG_FILE_SET=$(_is_set LOG_FILE)
SAMPLES_FILE_SET=$(_is_set SAMPLES_FILE)
PID_FILE_SET=$(_is_set PID_FILE)
STATE_FILE_SET=$(_is_set STATE_FILE)
BREAK_FILE_SET=$(_is_set BREAK_FILE)
BREAKS_LOG_SET=$(_is_set BREAKS_LOG)

SESSION="${AUTORE_SESSION:-${CLAUDE_SESSION:-claude}}"
CLI_CMD="${CLI_CMD:-claude}"
TARGET="${TARGET:-}"                            # 특정 window/pane 고정 (예: claude:0.1)
POLL_SEC="${POLL_SEC:-30}"
BUFFER_SEC="${BUFFER_SEC:-90}"
FALLBACK_SEC="${FALLBACK_SEC:-900}"
RETRY_SAME_KEY_SEC="${RETRY_SAME_KEY_SEC:-600}"
MAX_RESENDS="${MAX_RESENDS:-2}"
VERIFY_SEC="${VERIFY_SEC:-15}"                  # 재개 전송 후 반응 확인 대기 (0이면 확인 안 함)
CLEAR_INPUT="${CLEAR_INPUT:-1}"                 # 전송 전 입력줄 비우기 (C-u)
RESUME_MESSAGE="${RESUME_MESSAGE:-$(t default_resume_msg)}"
LOG_FILE="${LOG_FILE:-}"
SAMPLES_FILE="${SAMPLES_FILE:-}"
PID_FILE="${PID_FILE:-}"
STATE_FILE="${STATE_FILE:-}"                    # 중단 시점 상태 (key=value)
BREAK_FILE="${BREAK_FILE:-}"                    # 중단 시점 화면 스냅샷
BREAKS_LOG="${BREAKS_LOG:-}"                    # 중단 이력 (1건 1줄)
SNAPSHOT_LINES="${SNAPSHOT_LINES:-60}"          # 스냅샷에 남길 화면 줄 수
LOG_MAX_BYTES="${LOG_MAX_BYTES:-1048576}"       # 로그 파일 회전 기준 (0이면 회전 안 함)
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
NOTIFY_CMD="${NOTIFY_CMD:-}"                    # 범용 알림 훅 ($1=메시지, AUTORE_EVENT=이벤트명)
AUTO_UPDATE="${AUTO_UPDATE:-1}"                 # 0이면 자동 업데이트 비활성화
AUTO_UPDATE_SEC="${AUTO_UPDATE_SEC:-86400}"     # 자동 업데이트 확인 주기 (기본 24시간)
ALLOW_UNVERIFIED="${ALLOW_UNVERIFIED:-0}"       # 1이면 체크섬 없이도 수동 업데이트 허용

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
  autore status         감시 상태 + 중단 시점 + 최근 로그 확인
  autore last           마지막 중단 시점 화면 스냅샷 + 중단 이력
  autore logs [-f]      로그 보기 (-f: 실시간 따라가기)
  autore attach         감시 중인 AI CLI tmux 세션 접속
  autore run [옵션]     포그라운드 감시 (디버깅용)
  autore update [--check] 최신 버전으로 업데이트 (--check: 확인만)
  autore test-telegram  텔레그램 연동 테스트 메시지 발송
  autore checksum       배포용 SHA256 출력 (릴리스 시 autore.sh.sha256 갱신용)
  autore --selftest     파서·상태기록 단위 테스트
  autore version        버전 출력 (--version 도 동일)
  autore help           이 도움말 출력 (-h, --help 도 동일)

옵션 (start / run):
  --session NAME      감시할 tmux 세션명            (기본: claude)
  --cli CMD           세션 생성 시 실행할 AI CLI     (기본: claude, 예: opencode)
  --target PANE       특정 window/pane만 감시       (기본: 세션의 모든 pane, 예: claude:0.1)
  --poll SEC          화면 확인 주기                (기본: 30)
  --buffer SEC        리셋 시각 후 여유 대기         (기본: 90)
  --fallback SEC      리셋 시각 파싱 실패 시 재시도 대기 (기본: 900)
  --retry SEC         같은 제한 메시지 재전송 간격    (기본: 600)
  --max-resends N     같은 제한 메시지 최대 재전송 횟수 (기본: 2)
  --verify-sec SEC    전송 후 화면 반응 확인 대기   (기본: 15, 0이면 확인 안 함)
  --no-clear-input    전송 전 입력줄 비우기 끄기    (기본: C-u로 비움)
  --message TEXT      리셋 후 자동 입력할 메시지     (기본: 계속 이어서 진행해줘)
  --log-file PATH     로그 파일                    (기본: ~/.autore.log)
  --samples-file PATH 제한 메시지 샘플 수집 파일    (기본: ~/.autore-samples.log)
  --state-file PATH   중단 시점 상태 파일          (기본: ~/.autore-state)
  --break-file PATH   중단 시점 화면 스냅샷 파일    (기본: ~/.autore-break.txt)
  --breaks-log PATH   중단 이력 파일               (기본: ~/.autore-breaks.log)
  --pid-file PATH     PID 파일                    (기본: ~/.autore.pid)
  --snapshot-lines N  스냅샷에 남길 화면 줄 수      (기본: 60)
  --log-max-bytes N   로그 회전 기준 바이트         (기본: 1048576, 0이면 회전 안 함)
  --telegram-token T  텔레그램 봇 토큰 (채팅 ID와 함께 설정 시 알림 활성화)
  --telegram-chat-id C 텔레그램 채팅 ID
  --notify-cmd CMD    범용 알림 훅 (\$1=메시지, AUTORE_EVENT 환경변수 전달)
  --no-auto-update    자동 업데이트 비활성화       (기본: 활성 — 시작 시 + 주기마다 확인)
  --auto-update-sec S 자동 업데이트 확인 주기      (기본: 86400)
  --dry-run           실제 전송 없이 로그만 기록

옵션 (update):
  --check             새 버전 확인만 (교체하지 않음)
  --allow-unverified  체크섬을 확인할 수 없어도 강제 업데이트 (권장하지 않음)

※ 기본 세션(claude)이 아니면 로그·상태 파일 경로에 세션명이 자동으로 붙어
  여러 세션을 동시에 감시해도 서로 덮어쓰지 않습니다 (예: ~/.autore-opencode.log)

환경변수로도 설정 가능: CLI_CMD, TARGET, POLL_SEC, BUFFER_SEC, FALLBACK_SEC,
RETRY_SAME_KEY_SEC, MAX_RESENDS, VERIFY_SEC, CLEAR_INPUT, RESUME_MESSAGE,
LOG_FILE, SAMPLES_FILE, PID_FILE, STATE_FILE, BREAK_FILE, BREAKS_LOG,
SNAPSHOT_LINES, LOG_MAX_BYTES, NOTIFY_CMD, TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID,
AUTO_UPDATE, AUTO_UPDATE_SEC (CLI 옵션이 우선)

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
  autore status            watcher state + interruption point + recent logs
  autore last              screen snapshot at last interruption + history
  autore logs [-f]         show logs (-f: follow)
  autore attach            attach to the AI CLI tmux session
  autore run [options]     foreground watcher (for debugging)
  autore update [--check]  update to the latest version (--check: check only)
  autore test-telegram     send a Telegram test message
  autore checksum          print the release SHA256 (to refresh autore.sh.sha256)
  autore --selftest        parser + state-record unit tests
  autore version           print version (same as --version)
  autore help              print this help (same as -h, --help)

Options (start / run):
  --session NAME      tmux session to watch            (default: claude)
  --cli CMD           AI CLI to launch on session create (default: claude, e.g. opencode)
  --target PANE       watch only this window/pane      (default: every pane, e.g. claude:0.1)
  --poll SEC          screen check interval            (default: 30)
  --buffer SEC        extra wait after reset time      (default: 90)
  --fallback SEC      retry delay when time parsing fails (default: 900)
  --retry SEC         resend interval for same limit message (default: 600)
  --max-resends N     max resends for same limit message (default: 2)
  --verify-sec SEC    wait for a screen reaction after sending (default: 15, 0 = off)
  --no-clear-input    do not clear the input line first (default: clears with C-u)
  --message TEXT      message typed after reset        (default: Keep going and continue)
  --log-file PATH     log file                         (default: ~/.autore.log)
  --samples-file PATH limit-message sample file        (default: ~/.autore-samples.log)
  --state-file PATH   interruption state file          (default: ~/.autore-state)
  --break-file PATH   interruption screen snapshot     (default: ~/.autore-break.txt)
  --breaks-log PATH   interruption history file        (default: ~/.autore-breaks.log)
  --pid-file PATH     PID file                         (default: ~/.autore.pid)
  --snapshot-lines N  screen lines kept in a snapshot  (default: 60)
  --log-max-bytes N   log rotation threshold in bytes  (default: 1048576, 0 = never)
  --telegram-token T  Telegram bot token (enables alerts with chat ID)
  --telegram-chat-id C Telegram chat ID
  --notify-cmd CMD    generic notify hook (\$1=message, AUTORE_EVENT env var)
  --no-auto-update    disable auto-update          (default: on — checks at start + every interval)
  --auto-update-sec S auto-update check interval   (default: 86400)
  --dry-run           log only, never send

Options (update):
  --check             only check for a new version
  --allow-unverified  update even when the checksum cannot be verified (not recommended)

Note: for any session other than the default (claude), the log/state file paths get the
  session name appended, so watching several sessions never mixes their state
  (e.g. ~/.autore-opencode.log)

Also configurable via env vars: CLI_CMD, TARGET, POLL_SEC, BUFFER_SEC, FALLBACK_SEC,
RETRY_SAME_KEY_SEC, MAX_RESENDS, VERIFY_SEC, CLEAR_INPUT, RESUME_MESSAGE,
LOG_FILE, SAMPLES_FILE, PID_FILE, STATE_FILE, BREAK_FILE, BREAKS_LOG,
SNAPSHOT_LINES, LOG_MAX_BYTES, NOTIFY_CMD, TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID,
AUTO_UPDATE, AUTO_UPDATE_SEC (CLI options take precedence)

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
    start|stop|status|attach|run|test-telegram|last|checksum) CMD="$1"; shift ;;
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
    --target)         need_value "$@"; TARGET="$2"; shift 2 ;;
    --poll)           need_value "$@"; POLL_SEC="$2"; shift 2 ;;
    --buffer)         need_value "$@"; BUFFER_SEC="$2"; shift 2 ;;
    --fallback)       need_value "$@"; FALLBACK_SEC="$2"; shift 2 ;;
    --retry)          need_value "$@"; RETRY_SAME_KEY_SEC="$2"; shift 2 ;;
    --max-resends)    need_value "$@"; MAX_RESENDS="$2"; shift 2 ;;
    --message)        need_value "$@"; RESUME_MESSAGE="$2"; shift 2 ;;
    --verify-sec)     need_value "$@"; VERIFY_SEC="$2"; shift 2 ;;
    --no-clear-input) CLEAR_INPUT=0; shift ;;
    --log-file)       need_value "$@"; LOG_FILE="$2"; LOG_FILE_SET=1; shift 2 ;;
    --samples-file)   need_value "$@"; SAMPLES_FILE="$2"; SAMPLES_FILE_SET=1; shift 2 ;;
    --state-file)     need_value "$@"; STATE_FILE="$2"; STATE_FILE_SET=1; shift 2 ;;
    --break-file)     need_value "$@"; BREAK_FILE="$2"; BREAK_FILE_SET=1; shift 2 ;;
    --breaks-log)     need_value "$@"; BREAKS_LOG="$2"; BREAKS_LOG_SET=1; shift 2 ;;
    --pid-file)       need_value "$@"; PID_FILE="$2"; PID_FILE_SET=1; shift 2 ;;
    --snapshot-lines) need_value "$@"; SNAPSHOT_LINES="$2"; shift 2 ;;
    --log-max-bytes)  need_value "$@"; LOG_MAX_BYTES="$2"; shift 2 ;;
    --telegram-token)    need_value "$@"; TELEGRAM_BOT_TOKEN="$2"; shift 2 ;;
    --telegram-chat-id)  need_value "$@"; TELEGRAM_CHAT_ID="$2"; shift 2 ;;
    --notify-cmd)     need_value "$@"; NOTIFY_CMD="$2"; shift 2 ;;
    --no-auto-update) AUTO_UPDATE=0; shift ;;
    --auto-update-sec) need_value "$@"; AUTO_UPDATE_SEC="$2"; shift 2 ;;
    --allow-unverified) ALLOW_UNVERIFIED=1; shift ;;
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

#--- 옵션 검증 -------------------------------------------------------------------
# 숫자여야 하는 값에 문자열이 들어오면 sleep이 매번 실패해 루프가 폭주하므로 미리 차단
require_num() { # <옵션 표기> <값> [최솟값]
  [[ $2 =~ ^[0-9]+$ ]] || { echo "$(t err_not_number "$1" "$2")" >&2; exit 1; }
  [[ -n ${3:-} ]] && (( 10#$2 < $3 )) && { echo "$(t err_too_small "$1" "$3")" >&2; exit 1; }
  return 0
}
require_num --poll            "$POLL_SEC" 1
require_num --buffer          "$BUFFER_SEC"
require_num --fallback        "$FALLBACK_SEC" 1
require_num --retry           "$RETRY_SAME_KEY_SEC" 1
require_num --max-resends     "$MAX_RESENDS"
require_num --verify-sec      "$VERIFY_SEC"
require_num --snapshot-lines  "$SNAPSHOT_LINES" 1
require_num --log-max-bytes   "$LOG_MAX_BYTES"
require_num --auto-update-sec "$AUTO_UPDATE_SEC" 1

#--- 파일 경로 확정 --------------------------------------------------------------
# 세션마다 상태가 섞이지 않도록, 기본 세션이 아니면 파일명에 세션명을 붙인다.
# (기본 세션 'claude'는 기존 경로를 그대로 사용 — 하위호환)
resolve_paths() {
  local sfx="" legacy=1
  if [[ $SESSION != claude ]]; then
    # 세션명에 /나 공백이 있어도 안전한 파일명이 되도록 치환
    sfx="-$(printf '%s' "$SESSION" | tr -c '[:alnum:]._-' '_')"
    legacy=0   # 세션 전용 경로에는 구버전(claude-auto-resume) 폴백을 적용하지 않는다
  fi
  # _pick <새 경로> <구 경로> — legacy=1일 때만 구 파일 폴백
  _pick() { if (( legacy )); then _legacy_file "$1" "$2"; else printf '%s\n' "$1"; fi; }
  (( LOG_FILE_SET ))     || LOG_FILE=$(_pick "$HOME/.autore${sfx}.log" "$HOME/.claude-auto-resume.log")
  (( SAMPLES_FILE_SET )) || SAMPLES_FILE=$(_pick "$HOME/.autore${sfx}-samples.log" "$HOME/.claude-auto-resume-samples.log")
  (( PID_FILE_SET ))     || PID_FILE=$(_pick "$HOME/.autore${sfx}.pid" "$HOME/.claude-auto-resume.pid")
  (( STATE_FILE_SET ))   || STATE_FILE="$HOME/.autore${sfx}-state"
  (( BREAK_FILE_SET ))   || BREAK_FILE="$HOME/.autore${sfx}-break.txt"
  (( BREAKS_LOG_SET ))   || BREAKS_LOG="$HOME/.autore${sfx}-breaks.log"
}
resolve_paths

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

# 파일이 기준 크기를 넘으면 .1로 밀어내고 새로 시작 (무한 증가 방지)
rotate_if_big() { # <file>
  (( LOG_MAX_BYTES > 0 )) || return 0
  [[ -f $1 ]] || return 0
  local size
  size=$(wc -c < "$1" 2>/dev/null) || return 0
  size=${size// /}
  [[ $size =~ ^[0-9]+$ ]] || return 0
  (( size > LOG_MAX_BYTES )) || return 0
  mv -f "$1" "$1.1" 2>/dev/null || return 0
  log "$(t log_rotated "$1" "$1.1")"
}

rotate_logs() { rotate_if_big "$LOG_FILE"; rotate_if_big "$SAMPLES_FILE"; rotate_if_big "$BREAKS_LOG"; }

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

# 범용 알림 훅 — Slack/Discord/ntfy/데스크톱 알림 등 무엇이든 연결 가능
# 실행 시: sh -c "$NOTIFY_CMD" autore "<메시지>"  ($1=메시지)
#   환경변수 AUTORE_EVENT / AUTORE_MESSAGE / AUTORE_SESSION / AUTORE_VERSION 전달
notify_cmd() { # <message> <event>
  [[ -n $NOTIFY_CMD ]] || return 0
  if AUTORE_EVENT="$2" AUTORE_MESSAGE="$1" AUTORE_SESSION="$SESSION" AUTORE_VERSION="$VERSION" \
     sh -c "$NOTIFY_CMD" autore "$1" >/dev/null 2>&1; then
    return 0
  fi
  log "$(t log_notify_failed)"
}

# 알림 한 번에 — 텔레그램 + 사용자 훅
notify() { # <message> [event]
  notify_telegram "$1"
  notify_cmd "$1" "${2:-event}"
}

#-------------------------------------------------------------------------------
# 중단 시점 기록
#
# 제한에 걸린 "그 순간"을 남겨, 나중에 어디서 멈췄는지 확인할 수 있게 한다.
#   - STATE_FILE : 상태 + 시각 (status / last 명령이 읽음, GNU date 불필요)
#   - BREAK_FILE : 중단 직전 화면 스냅샷 (무엇을 하다 멈췄는지)
#   - BREAKS_LOG : 중단 이력 1건 1줄
#-------------------------------------------------------------------------------
# human_dur <초> — "1시간 12분" / "12분" / "30초"
human_dur() {
  local s="${1:-0}"
  (( s < 0 )) && s=0
  if   (( s >= 3600 )); then t dur_h $((s / 3600)) $(((s % 3600) / 60))
  elif (( s >= 60 ));   then t dur_m $((s / 60))
  else                       t dur_s "$s"
  fi
}

# 상태 파일 필드 (read_state가 채움)
ST_STATE=""; ST_BREAK_EPOCH=0; ST_BREAK_AT=""; ST_RESET_AT=""
ST_RESUME_EPOCH=0; ST_RESUME_AT=""; ST_RESENDS=0; ST_MAX_RESENDS=0
ST_SESSION=""; ST_LAST_WORK=""

read_state() {
  [[ -f $STATE_FILE ]] || return 1
  local k v
  while IFS='=' read -r k v; do
    case "$k" in
      state)        ST_STATE="$v" ;;
      break_epoch)  ST_BREAK_EPOCH="${v:-0}" ;;
      break_at)     ST_BREAK_AT="$v" ;;
      reset_at)     ST_RESET_AT="$v" ;;
      resume_epoch) ST_RESUME_EPOCH="${v:-0}" ;;
      resume_at)    ST_RESUME_AT="$v" ;;
      resends)      ST_RESENDS="${v:-0}" ;;
      max_resends)  ST_MAX_RESENDS="${v:-0}" ;;
      session)      ST_SESSION="$v" ;;
      last_work)    ST_LAST_WORK="$v" ;;
    esac
  done < "$STATE_FILE"
  # 손상된 파일이 산술 연산을 깨뜨리지 않도록 숫자 필드 검증
  local n
  for n in ST_BREAK_EPOCH ST_RESUME_EPOCH ST_RESENDS ST_MAX_RESENDS; do
    [[ ${!n} =~ ^[0-9]+$ ]] || eval "$n=0"
  done
  [[ -n $ST_STATE ]]
}

# write_state <state> — 현재 ST_* 값으로 상태 파일 갱신 (값은 모두 한 줄 문자열)
write_state() {
  ST_STATE="$1"
  {
    printf 'state=%s\n'        "$ST_STATE"
    printf 'break_epoch=%s\n'  "$ST_BREAK_EPOCH"
    printf 'break_at=%s\n'     "$ST_BREAK_AT"
    printf 'reset_at=%s\n'     "$ST_RESET_AT"
    printf 'resume_epoch=%s\n' "$ST_RESUME_EPOCH"
    printf 'resume_at=%s\n'    "$ST_RESUME_AT"
    printf 'resends=%s\n'      "$ST_RESENDS"
    printf 'max_resends=%s\n'  "$MAX_RESENDS"
    printf 'session=%s\n'      "$SESSION"
    printf 'last_work=%s\n'    "$ST_LAST_WORK"
  } > "$STATE_FILE" 2>/dev/null || true
}

# 중단 직전 화면에서 "마지막 작업 줄" 추출 — 제한 메시지·장식 줄은 제외
extract_last_work() { # <snapshot>
  printf '%s\n' "$1" \
    | grep -viE "$LIMIT_REGEX" \
    | grep -vE '^[^[:alnum:]]*$' \
    | tail -n 1 \
    | cut -c1-160
}

# save_break <limit_block> — 스냅샷 저장 + ST_LAST_WORK 설정 (상태 파일은 호출자가 기록)
save_break() {
  local snap="" now_h
  now_h=$(date '+%F %T')
  snap=$(capture_pane | sed -e 's/[[:space:]]*$//' | grep -v '^$' | tail -n "$SNAPSHOT_LINES")
  [[ -z $snap ]] && snap="$1"
  ST_LAST_WORK=$(extract_last_work "$snap")
  {
    printf '%s\n' "$(t br_snap_header "$now_h" "$SESSION${PANE:+ $PANE}")"
    printf '%s\n' "--------------------------------------------------------------"
    printf '%s\n' "$snap"
  } > "$BREAK_FILE" 2>/dev/null || true
}

# 중단 이력 1줄 추가
append_break_log() {
  printf '%s | reset=%s | resume=%s | session=%s | %s\n' \
    "$ST_BREAK_AT" "${ST_RESET_AT:-$(t br_reset_unknown)}" "${ST_RESUME_AT:-?}" \
    "$SESSION" "$ST_LAST_WORK" >> "$BREAKS_LOG" 2>/dev/null || true
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

  # 기준 날짜는 실제 시계가 아니라 인자로 받은 now — 테스트 가능성과 결정성 확보
  epoch=$("$DATE" -d "$("$DATE" -d "@$now" '+%F') $(printf '%02d:%02d' "$hour" "$min")" +%s) || return 1
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

  # 날짜 지정 표현은 GNU date가 '실제 오늘'을 기준으로 해석하므로
  # 테스트 문구/기대값도 실제 오늘 기준으로 만들어 어느 날에 돌려도 통과하게 한다.
  local D0 D1 D4 M4 can_date=1
  D0=$("$DATE" '+%F')                          # 오늘
  D1=$("$DATE" -d 'tomorrow' '+%F')            # 내일
  D4=$("$DATE" -d 'today +4 days' '+%F')       # 4일 뒤 (주간 제한 시나리오)
  # 월 이름은 반드시 C 로케일로 생성 — GNU date의 -d 파서는 영어 월 이름만 이해하므로
  # 한국어 로케일에서 '%b'가 "7월"이 되면 테스트 입력 자체가 파싱 불가가 된다
  M4=$(LC_ALL=C "$DATE" -d 'today +4 days' '+%b %-d')   # "Jul 31" 형식
  # 환경에 따라 영어 월 표현을 못 읽는 date가 있으면 해당 항목은 건너뛴다 (업데이트 차단 방지)
  "$DATE" -d "$M4 3pm" +%s >/dev/null 2>&1 || can_date=0

  #--- 베어 시각 ---
  check "3pm 기본"       "Claude usage limit reached. Your limit will reset at 3pm" "$D0 09:54" "$D0 15:00"
  check "3:30pm 분 포함"  "Your limit will reset at 3:30pm"                          "$D0 09:54" "$D0 15:30"
  check "PM 대문자+tz"   "You've hit your limit · resets 6:30 PM (Asia/Seoul)"      "$D0 14:00" "$D0 18:30"
  check "24시간제"       "Your limit will reset at 15:00"                           "$D0 09:54" "$D0 15:00"
  check "12am 자정"      "Your limit will reset at 12am"                            "$D0 23:00" "$D1 00:00"
  check "12pm 정오"      "Your limit will reset at 12pm"                            "$D0 09:00" "$D0 12:00"
  check "자정 넘김"      "Your limit will reset at 1am"                             "$D0 23:50" "$D1 01:00"
  check "리셋 직후"      "Your limit will reset at 3pm"                             "$D0 15:04" "$D0 15:00"
  check "모순 시각 거부"  "Your limit will reset at 11am"                            "$D0 15:00" FAIL
  check "파싱 불가 거부"  "Claude usage limit reached"                               "$D0 15:00" FAIL
  #--- 날짜 지정 (주간 제한 등) ---
  if (( can_date )); then
    check "날짜 지정"    "Your weekly usage limit will reset on $M4 at 3pm"         "$D0 15:00" "$D4 15:00"
    check "날짜+PM+tz"  "Your limit will reset on $M4 at 3:00 PM (Asia/Seoul)"     "$D0 15:00" "$D4 15:00"
  else
    echo "SKIP: 날짜 지정 / 날짜+PM+tz (이 환경의 date가 영어 월 표현을 읽지 못함)"
  fi
  check "tomorrow"      "Your limit will reset tomorrow at 9am"                    "$D0 15:00" "$D1 09:00"
  check "날짜 모순 거부"  "Your limit will reset on Jul 88 at 3pm"                  "$D0 15:00" FAIL
  #--- 줄바꿈(화면 wrap) ---
  check "줄바꿈 메시지"   $'Your limit will reset at\n3:30pm'                        "$D0 09:54" "$D0 15:30"
  #--- 연말 연도 넘김 — 실제 오늘이 연말 8일 이내일 때만 검증 가능 ---
  if (( $("$DATE" -d "$D0 +8 days" '+%Y') > $("$DATE" '+%Y') )); then
    check "연도 넘김 날짜" "Your limit will reset on Jan 2 at 9am" "$D0 20:00" \
          "$("$DATE" -d "$("$DATE" '+%Y')-12-31 +2 days" '+%F') 09:00"
  else
    echo "SKIP: 연도 넘김 날짜 (연말에만 검증 가능)"
  fi

  #--- 중단 시점 기록 헬퍼 ---
  eq() { # <설명> <실제> <기대>
    if [[ $2 == "$3" ]]; then echo "PASS: $1"; else echo "FAIL: $1 (out=$2 exp=$3)"; fail=1; fi
  }
  eq "duration 초"    "$(TSFX=EN human_dur 45)"     "45s"
  eq "duration 분"    "$(TSFX=EN human_dur 600)"    "10m"
  eq "duration 시간"  "$(TSFX=EN human_dur 4320)"   "1h 12m"
  eq "duration 음수"  "$(TSFX=EN human_dur -5)"     "0s"
  eq "마지막 작업 줄" \
     "$(extract_last_work $'src/app.ts 수정 중\n────────\nClaude usage limit reached')" \
     "src/app.ts 수정 중"

  # 상태 파일 왕복 — 공백/특수문자가 섞인 값도 그대로 복원되는지
  local _tmp_state; _tmp_state=$(mktemp)
  ( STATE_FILE="$_tmp_state" SESSION="my session" MAX_RESENDS=2
    ST_BREAK_EPOCH=100 ST_BREAK_AT="2026-07-27 14:32:10" ST_RESET_AT="2026-07-27 15:00"
    ST_RESUME_EPOCH=200 ST_RESUME_AT="2026-07-27 15:01:30" ST_RESENDS=1
    ST_LAST_WORK="foo.ts:42 = bar()"
    write_state waiting
    read_state
    printf '%s|%s|%s|%s\n' "$ST_STATE" "$ST_BREAK_AT" "$ST_SESSION" "$ST_LAST_WORK"
  ) > "$_tmp_state.out"
  eq "상태 파일 왕복" "$(cat "$_tmp_state.out")" \
     "waiting|2026-07-27 14:32:10|my session|foo.ts:42 = bar()"
  rm -f "$_tmp_state" "$_tmp_state.out"

  #--- 제한 메시지 블록 추출 ---
  eq "제한 블록 추출" \
     "$(extract_limit_block $'작업 중...\nClaude usage limit reached\nreset at 3pm' | tr '\n' '/')" \
     "Claude usage limit reached/reset at 3pm/"
  eq "제한 없음"     "$(extract_limit_block $'정상 작업 중\n> 계속')" ""

  #--- 세션별 파일 경로 분리 ---
  ( SESSION="opencode" LOG_FILE_SET=0 SAMPLES_FILE_SET=0 PID_FILE_SET=0
    STATE_FILE_SET=0 BREAK_FILE_SET=0 BREAKS_LOG_SET=0
    resolve_paths; printf '%s|%s\n' "${LOG_FILE##*/}" "${STATE_FILE##*/}"
  ) > "$_tmp_state.p1"
  ( SESSION="a/b c" LOG_FILE_SET=0 SAMPLES_FILE_SET=0 PID_FILE_SET=0
    STATE_FILE_SET=0 BREAK_FILE_SET=0 BREAKS_LOG_SET=0
    resolve_paths; printf '%s\n' "${PID_FILE##*/}"
  ) > "$_tmp_state.p2"
  eq "세션별 경로"     "$(cat "$_tmp_state.p1")" ".autore-opencode.log|.autore-opencode-state"
  eq "경로 문자 치환"  "$(cat "$_tmp_state.p2")" ".autore-a_b_c.pid"
  rm -f "$_tmp_state.p1" "$_tmp_state.p2"

  #--- 숫자 옵션 검증 ---
  # require_num은 실패 시 exit하므로 서브셸로 감싸 종료코드만 확인
  eq "숫자 검증 통과"  "$( (require_num --poll 30 1)  >/dev/null 2>&1; echo $? )" "0"
  eq "숫자 검증 거부"  "$( (require_num --poll abc 1) >/dev/null 2>&1; echo $? )" "1"
  eq "최솟값 거부"     "$( (require_num --poll 0 1)   >/dev/null 2>&1; echo $? )" "1"

  if (( fail == 0 )); then echo "$(t st_summary_pass)"; else echo "$(t st_summary_fail)"; fi
  exit "$fail"
}

#-------------------------------------------------------------------------------
# 감시 루프
#-------------------------------------------------------------------------------
# 중단 가능한 sleep — sleep을 백그라운드로 두고 wait로 기다려야
# stop(SIGTERM) 신호가 즉시 처리된다 (foreground sleep은 최대 30초까지 지연)
SLEEP_PID=""
nap() { # <초>
  (( $1 > 0 )) || return 0
  sleep "$1" &
  SLEEP_PID=$!
  wait "$SLEEP_PID" 2>/dev/null
  SLEEP_PID=""
}

wait_until() { # <target_epoch> — 30초 단위로 끊어 대기 (세션 생존 확인)
  local target="$1" now
  while :; do
    now=$(date +%s)
    (( now >= target )) && return 0
    tmux has-session -t "$SESSION" 2>/dev/null || return 1
    nap $(( (target - now) < 30 ? (target - now) : 30 ))
  done
}

#--- 감시 대상 pane ---------------------------------------------------------------
# 세션에 여러 window/pane이 있으면 활성 pane만 보다가 제한 메시지를 놓칠 수 있어
# 전체 pane을 훑는다. --target으로 특정 pane을 고정할 수도 있다.
PANE=""   # 제한 메시지를 발견한 pane (전송·스냅샷 대상)

list_panes() {
  if [[ -n $TARGET ]]; then printf '%s\n' "$TARGET"; return 0; fi
  tmux list-panes -s -t "$SESSION" -F '#{pane_id}' 2>/dev/null || printf '%s\n' "$SESSION"
}

capture_pane() { # [pane] — 지정 pane(기본: 발견된 pane)의 화면 텍스트
  tmux capture-pane -p -t "${1:-${PANE:-$SESSION}}" 2>/dev/null
}

# 화면 텍스트에서 제한 메시지 + 아래 2줄 추출 (화면 wrap 대비)
extract_limit_block() { # <text>
  printf '%s\n' "$1" | tail -n "$TAIL_LINES" | awk -v re="$LIMIT_REGEX" '
    tolower($0) ~ re { buf=$0; n=2; next }
    n > 0            { buf=buf "\n" $0; n-- }
    END              { if (buf != "") print buf }'
}

# 현재 제한 메시지가 떠 있는 pane을 찾아 PANE / LIMIT_BLOCK 설정 (없으면 rc 1)
# 파이프 대신 히어독을 쓰는 이유: 서브셸이 생기면 PANE 값이 호출자에게 전달되지 않는다
LIMIT_BLOCK=""
find_limit_pane() {
  local p block
  LIMIT_BLOCK=""
  while IFS= read -r p; do
    [[ -n $p ]] || continue
    block=$(extract_limit_block "$(capture_pane "$p")")
    if [[ -n $block ]]; then PANE="$p"; LIMIT_BLOCK="$block"; return 0; fi
  done <<EOF
$(list_panes)
EOF
  return 1
}

send_resume() {
  if (( DRY_RUN )); then
    log "$(t log_dryrun_send "$RESUME_MESSAGE")"
    return 0
  fi
  local target="${PANE:-$SESSION}"
  # 사용자가 입력하다 만 텍스트 뒤에 메시지가 붙지 않도록 입력줄을 먼저 비운다
  (( CLEAR_INPUT )) && tmux send-keys -t "$target" C-u 2>/dev/null
  tmux send-keys -t "$target" -l -- "$RESUME_MESSAGE"
  sleep 0.5
  tmux send-keys -t "$target" Enter
}

# 재개 메시지를 보내기 전, 제한이 이미 풀렸는지(사용자가 직접 이어갔는지) 확인
limit_still_present() {
  local block
  block=$(extract_limit_block "$(capture_pane)")
  [[ -n $block ]]
}

# 전송 후 화면이 실제로 반응했는지 확인 — 반응이 없으면 경고 (자동 재전송은 기존 로직이 담당)
verify_resume() { # <전송 직전 화면>
  (( VERIFY_SEC > 0 )) || return 0
  (( DRY_RUN )) && return 0
  local before="$1" after
  nap "$VERIFY_SEC"
  after=$(capture_pane)
  if [[ $after == "$before" ]]; then
    log "$(t log_resume_noreact "$VERIFY_SEC")"
    notify "$(t tg_resume_noreact "$VERIFY_SEC")" resume_noreact
    return 1
  fi
  return 0
}

handle_limit() { # <limit_block>
  local block="$1" now target rc reset_desc resume_at tg

  # ① 중단 시점 기록 — 무엇을 하다 멈췄는지 화면 스냅샷으로 남긴다
  now=$(date +%s)
  ST_BREAK_EPOCH=$now
  ST_BREAK_AT=$(date '+%F %T')
  ST_RESET_AT=""; ST_RESUME_EPOCH=0; ST_RESUME_AT=""; ST_RESENDS=0
  save_break "$block"

  target=$(parse_reset_epoch "$block" "$now"); rc=$?
  collect_sample "$block" "$rc" "${target:-}"
  if (( rc == 0 )); then
    reset_desc=$("$DATE" -d "@$target" '+%m-%d %H:%M')
    ST_RESET_AT=$("$DATE" -d "@$target" '+%F %H:%M')
    target=$((target + BUFFER_SEC))
    resume_at=$("$DATE" -d "@$target" '+%H:%M:%S')
    ST_RESUME_EPOCH=$target
    ST_RESUME_AT=$("$DATE" -d "@$target" '+%F %H:%M:%S')
    write_state waiting
    append_break_log
    log "$(t log_limit_detected "$reset_desc" "$resume_at")"
    tg="$(t tg_limit "$reset_desc" "$resume_at")"
    [[ -n $ST_LAST_WORK ]] && tg+="$(t tg_lastwork "$ST_LAST_WORK")"
    notify "$tg" limit
    wait_until "$target" || { log "$(t log_session_gone)"; write_state stale; return 1; }
  else
    ST_RESUME_EPOCH=$((now + FALLBACK_SEC))
    ST_RESUME_AT=$("$DATE" -d "@$ST_RESUME_EPOCH" '+%F %H:%M:%S')
    write_state waiting
    append_break_log
    log "$(t log_limit_noparse "$rc" "$SAMPLES_FILE" "$FALLBACK_SEC")"
    tg="$(t tg_limit_noparse "$FALLBACK_SEC")"
    [[ -n $ST_LAST_WORK ]] && tg+="$(t tg_lastwork "$ST_LAST_WORK")"
    notify "$tg" limit_noparse
    wait_until "$ST_RESUME_EPOCH" || { log "$(t log_session_gone)"; write_state stale; return 1; }
  fi

  # 대기 중 사용자가 직접 이어갔다면 굳이 메시지를 넣지 않는다
  if ! limit_still_present; then
    log "$(t log_resume_skip)"
    ST_RESUME_EPOCH=$(date +%s); ST_RESUME_AT=$(date '+%F %H:%M:%S')
    write_state cleared
    notify "$(t tg_resume_skip)" resume_skipped
    return 0
  fi

  local screen_before
  screen_before=$(capture_pane)
  log "$(t log_resume_send "$RESUME_MESSAGE")"
  send_resume
  ST_RESUME_EPOCH=$(date +%s)
  ST_RESUME_AT=$(date '+%F %H:%M:%S')
  write_state resumed
  notify "$(t tg_resumed "$RESUME_MESSAGE")" resumed
  verify_resume "$screen_before"
  return 0
}

watch_loop() {
  require_date
  command -v tmux >/dev/null 2>&1 || { echo "$(t err_no_tmux)" >&2; exit 1; }
  # 대기 중인 sleep까지 정리해 stop 시 즉시 종료되도록
  trap '[[ -n $SLEEP_PID ]] && kill "$SLEEP_PID" 2>/dev/null; log "$(t log_watch_stop)"; exit 0' INT TERM
  rotate_logs

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
  notify "$(t tg_start "$VERSION" "$(hostname 2>/dev/null || echo '?')" "$SESSION")" started

  # 이전 감시가 대기 중에 죽었다면 그 대기는 이미 무효 — 기록은 남기되 상태만 정리
  if read_state && [[ $ST_STATE == waiting ]]; then write_state stale; fi

  local last_key="" last_action=0 resends=0
  local limit_block limit_key now
  local last_update_check=0   # 0 = 시작하자마자 1회 확인
  while :; do
    now=$(date +%s)
    if (( now - last_update_check >= AUTO_UPDATE_SEC )); then
      last_update_check=$now
      rotate_logs
      auto_update_tick   # 새 버전이면 교체 후 exec으로 재시작 (성공 시 돌아오지 않음)
    fi
    if ! tmux has-session -t "$SESSION" 2>/dev/null; then
      log "$(t log_session_wait "$SESSION" "$POLL_SEC")"
      nap "$POLL_SEC"; continue
    fi

    # 세션의 모든 pane을 훑어 제한 메시지가 있는 pane을 찾는다
    find_limit_pane
    limit_block="$LIMIT_BLOCK"

    if [[ -n $limit_block ]]; then
      limit_key=${limit_block%%$'\n'*}
      now=$(date +%s)
      if [[ $limit_key == "$last_key" ]]; then
        # 이미 처리한 제한 메시지 — 재개가 안 먹혔을 수 있으니 제한적으로 재전송
        if (( resends < MAX_RESENDS && now - last_action >= RETRY_SAME_KEY_SEC )); then
          log "$(t log_resend $((resends + 1)) "$MAX_RESENDS")"
          local screen_before; screen_before=$(capture_pane)
          send_resume
          notify "$(t tg_resend $((resends + 1)) "$MAX_RESENDS")" resend
          resends=$((resends + 1)); last_action=$now
          ST_RESENDS=$resends; write_state resumed
          verify_resume "$screen_before"
        fi
      else
        last_key="$limit_key"; resends=0
        handle_limit "$limit_block"
        last_action=$(date +%s)
      fi
    else
      if [[ -n $last_key ]]; then
        log "$(t log_limit_cleared)"
        write_state cleared   # 제한 해소 — 중단 기록은 이력으로 남는다
      fi
      last_key=""; resends=0
    fi
    nap "$POLL_SEC"
  done
}

#-------------------------------------------------------------------------------
# 서브커맨드
#-------------------------------------------------------------------------------
# PID 파일의 프로세스가 정말 이 감시 프로세스인지 확인.
# kill -0만 보면 OS가 재사용한 남의 PID를 '실행 중'으로 오판할 수 있다.
is_running() {
  [[ -f $PID_FILE ]] || return 1
  local pid args
  pid=$(cat "$PID_FILE" 2>/dev/null)
  [[ $pid =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  args=$(ps -p "$pid" -o args= 2>/dev/null) || return 0   # ps를 못 쓰면 기존 판정 유지
  [[ -z $args ]] && return 0
  case "$args" in
    *"$(basename -- "$SCRIPT_PATH")"*|*autore*|*claude-auto-resume*) return 0 ;;
  esac
  return 1
}

cmd_start() {
  command -v tmux >/dev/null 2>&1 || { echo "$(t err_no_tmux)" >&2; exit 1; }
  require_date
  command -v "$CLI_CMD" >/dev/null 2>&1 || \
    echo "$(t warn_cli_not_found "$CLI_CMD")" >&2
  if is_running; then
    echo "$(t out_already_running "$(cat "$PID_FILE")" "$SCRIPT_PATH")"
    exit 0
  fi
  # 동시에 두 번 start해도 하나만 뜨도록 잠금 (mkdir은 원자적)
  local lock="${PID_FILE}.lock"
  if ! mkdir "$lock" 2>/dev/null; then
    if is_running; then
      echo "$(t out_already_running "$(cat "$PID_FILE")" "$SCRIPT_PATH")"; exit 0
    fi
    rmdir "$lock" 2>/dev/null && mkdir "$lock" 2>/dev/null || {
      echo "$(t err_locked "$lock")" >&2; exit 1; }
  fi
  trap 'rmdir "$lock" 2>/dev/null' EXIT
  local extra=()
  (( DRY_RUN )) && extra+=(--dry-run)
  POLL_SEC="$POLL_SEC" BUFFER_SEC="$BUFFER_SEC" FALLBACK_SEC="$FALLBACK_SEC" \
  RETRY_SAME_KEY_SEC="$RETRY_SAME_KEY_SEC" MAX_RESENDS="$MAX_RESENDS" \
  RESUME_MESSAGE="$RESUME_MESSAGE" LOG_FILE="$LOG_FILE" SAMPLES_FILE="$SAMPLES_FILE" \
  PID_FILE="$PID_FILE" CLI_CMD="$CLI_CMD" LC_ALL="${LC_ALL:-${LANG:-}}" \
  STATE_FILE="$STATE_FILE" BREAK_FILE="$BREAK_FILE" BREAKS_LOG="$BREAKS_LOG" \
  SNAPSHOT_LINES="$SNAPSHOT_LINES" LOG_MAX_BYTES="$LOG_MAX_BYTES" \
  VERIFY_SEC="$VERIFY_SEC" CLEAR_INPUT="$CLEAR_INPUT" TARGET="$TARGET" \
  NOTIFY_CMD="$NOTIFY_CMD" ALLOW_UNVERIFIED="$ALLOW_UNVERIFIED" \
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
  if ! is_running; then
    rm -f "$PID_FILE"
    echo "$(t out_not_running)"
    return 0
  fi
  local pid i
  pid=$(cat "$PID_FILE")
  kill "$pid" 2>/dev/null
  # 종료를 실제로 확인 — 5초 안에 안 죽으면 SIGKILL
  for i in 1 2 3 4 5 6 7 8 9 10; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.5
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" 2>/dev/null
    sleep 0.5
    echo "$(t out_stopped_forced "$pid")"
  else
    echo "$(t out_stopped)"
  fi
  rm -f "$PID_FILE"
}

#-------------------------------------------------------------------------------
# tmux 세션 목록 — 몇 개가 떠 있고, AI CLI가 실제로 어느 pane·경로에서 도는지
#
# pane의 foreground 명령만 보면 부족하다 (Claude Code는 node로 보이는 경우가 많음).
# 그래서 pane 프로세스와 그 자손을 ps로 훑어 CLI 이름이 있는지 확인한다.
#-------------------------------------------------------------------------------
# pane_runs_cli <pane_pid> <ps_table> — pane 아래에서 CLI가 돌고 있으면 0
pane_runs_cli() {
  [[ -n $1 && -n $2 ]] || return 1
  printf '%s\n' "$2" | awk -v pp="$1" -v cli="$CLI_CMD" '
    {
      pid=$1; ppid=$2
      args=$0; sub(/^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+/, "", args)
      PAR[pid]=ppid; ARG[pid]=args
    }
    END {
      for (p in ARG) {
        if (index(tolower(ARG[p]), tolower(cli)) == 0) continue
        q=p
        for (i=0; i<8 && q != "" && q != "0"; i++) {   # 조상을 따라 올라가며 pane 프로세스인지 확인
          if (q == pp) { exit 0 }
          q=PAR[q]
        }
      }
      exit 1
    }'
}

print_sessions() { # <색상 변수는 인자로 받지 않고 전역 CLR_* 사용>
  local sess panes ps_table count name wins att found path mark dot
  command -v tmux >/dev/null 2>&1 || return 0
  sess=$(tmux list-sessions -F '#{session_name}|#{session_windows}|#{session_attached}' 2>/dev/null)
  count=$(printf '%s' "$sess" | grep -c . 2>/dev/null)
  [[ $count =~ ^[0-9]+$ ]] || count=0
  printf '\n%s%s%s%s\n' "$CLR_BOLD" "$CLR_CYAN" "$(t st_header_sessions "$count")" "$CLR_RESET"
  if (( count == 0 )); then
    printf '  %s%s%s\n' "$CLR_DIM" "$(t st_sess_none)" "$CLR_RESET"
    return 0
  fi
  panes=$(tmux list-panes -a -F '#{session_name}|#{window_index}.#{pane_index}|#{pane_current_path}|#{pane_pid}' 2>/dev/null)
  ps_table=$(ps -e -o pid=,ppid=,args= 2>/dev/null)

  while IFS='|' read -r name wins att; do
    [[ -n $name ]] || continue
    found=""; path=""
    while IFS='|' read -r p_name p_loc p_path p_pid; do
      [[ $p_name == "$name" ]] || continue
      if pane_runs_cli "$p_pid" "$ps_table"; then
        found="$name:$p_loc"; path="$p_path"; break
      fi
    done <<EOF
$panes
EOF
    # 감시 대상 세션 표시
    mark=""; dot="$CLR_DIM○$CLR_RESET"
    [[ $name == "$SESSION" ]] && { mark="  $CLR_CYAN$(t st_sess_watching)$CLR_RESET"; dot="$CLR_GREEN●$CLR_RESET"; }
    printf '  %s %s%-12s%s %s%s' "$dot" "$CLR_BOLD" "$name" "$CLR_RESET" "$CLR_DIM" "$( (( wins == 1 )) && t st_sess_window "$wins" || t st_sess_windows "$wins" )"
    [[ $att == 1 ]] && printf ' · %s' "$(t st_sess_attached)"
    printf '%s' "$CLR_RESET"
    if [[ -n $found ]]; then
      printf ' · %s%s%s → %s' "$CLR_GREEN" "$(t st_sess_cli_run "$CLI_CMD")" "$CLR_RESET" "$found"
      [[ -n $path ]] && printf ' %s(%s)%s' "$CLR_DIM" "${path/#$HOME/\~}" "$CLR_RESET"
    else
      printf ' · %s%s%s' "$CLR_DIM" "$(t st_sess_cli_none "$CLI_CMD")" "$CLR_RESET"
    fi
    printf '%s\n' "$mark"
  done <<EOF
$sess
EOF
}

# 색상 — 터미널 출력 시에만 적용 (파이프/리다이렉션 시 자동 해제, NO_COLOR 지원)
CLR_RESET=''; CLR_BOLD=''; CLR_DIM=''; CLR_GREEN=''; CLR_RED=''; CLR_YELLOW=''; CLR_CYAN=''
setup_colors() {
  if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
    CLR_RESET=$'\033[0m'; CLR_BOLD=$'\033[1m'; CLR_DIM=$'\033[2m'
    CLR_GREEN=$'\033[32m'; CLR_RED=$'\033[31m'; CLR_YELLOW=$'\033[33m'; CLR_CYAN=$'\033[36m'
  fi
}

cmd_status() {
  setup_colors
  local reset="$CLR_RESET" bold="$CLR_BOLD" dim="$CLR_DIM"
  local green="$CLR_GREEN" red="$CLR_RED" yellow="$CLR_YELLOW" cyan="$CLR_CYAN"

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

  # tmux 세션 — 몇 개가 떠 있고 AI CLI가 어디서 도는지
  print_sessions

  # 중단 시점 — 언제 어디서 멈췄고, 언제 이어졌는지
  printf '\n%s%s%s%s\n' "$bold" "$cyan" "$(t st_header_break)" "$reset"
  if read_state; then
    local now_e ago
    now_e=$(date +%s)
    ago="$(t dur_ago "$(human_dur $((now_e - ST_BREAK_EPOCH)))")"
    case "$ST_STATE" in
      waiting)
        printf '  %s%s%s%s%s %s(%s)%s\n' \
          "$yellow" "$(t st_br_paused)" "$reset" "$bold" "$ST_BREAK_AT" "$dim" "$ago" "$reset"
        printf '  %s%s%s\n' "$dim" "$(t st_br_reset)" "$reset${ST_RESET_AT:-$(t br_reset_unknown)}"
        if (( ST_RESUME_EPOCH > now_e )); then
          printf '  %s%s%s%s %s(%s)%s\n' "$dim" "$(t st_br_eta)" "$reset" "$ST_RESUME_AT" \
            "$green" "$(t dur_left "$(human_dur $((ST_RESUME_EPOCH - now_e)))")" "$reset"
        else
          printf '  %s%s%s%s %s%s%s\n' "$dim" "$(t st_br_eta)" "$reset" "$ST_RESUME_AT" \
            "$yellow" "$(t st_br_overdue)" "$reset"
        fi
        ;;
      resumed)
        printf '  %s%s%s%s%s %s(%s)%s\n' \
          "$green" "$(t st_br_resumed)" "$reset" "$bold" "$ST_RESUME_AT" "$dim" \
          "$(t st_br_downtime "$(human_dur $((ST_RESUME_EPOCH - ST_BREAK_EPOCH)))")" "$reset"
        printf '  %s%s%s%s %s(%s)%s\n' \
          "$dim" "$(t st_br_paused)" "$reset" "$ST_BREAK_AT" "$dim" "$ago" "$reset"
        (( ST_RESENDS > 0 )) && printf '  %s%s%s\n' \
          "$dim" "$(t st_br_resends "$ST_RESENDS" "$ST_MAX_RESENDS")" "$reset"
        ;;
      *)  # cleared / stale — 지난 중단 기록
        printf '  %s%s%s%s %s(%s)%s\n' \
          "$dim" "$(t st_br_cleared)" "$reset" "$ST_BREAK_AT" "$dim" "$ago" "$reset"
        [[ -n $ST_RESUME_AT ]] && printf '  %s%s%s%s\n' \
          "$dim" "$(t st_br_eta)" "$reset" "$ST_RESUME_AT"
        ;;
    esac
    [[ -n $ST_LAST_WORK ]] && printf '  %s%s%s%s\n' \
      "$dim" "$(t st_br_last)" "$reset" "$(printf '%s' "$ST_LAST_WORK" | cut -c1-70)"
    [[ -f $BREAK_FILE ]] && printf '  %s%s%s\n' "$dim" "$(t st_br_hint "$SCRIPT_PATH")" "$reset"
  else
    printf '  %s%s%s\n' "$dim" "$(t st_br_none)" "$reset"
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

# 마지막 중단 시점 스냅샷 + 중단 이력
cmd_last() {
  local reset='' bold='' dim='' cyan=''
  if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
    reset=$'\033[0m'; bold=$'\033[1m'; dim=$'\033[2m'; cyan=$'\033[36m'
  fi
  if [[ ! -f $BREAK_FILE ]]; then
    echo "$(t last_none "$BREAK_FILE")"
    exit 0
  fi
  printf '%s%s%s%s\n' "$bold" "$cyan" "$(t last_header)" "$reset"
  cat "$BREAK_FILE"
  if [[ -s $BREAKS_LOG ]]; then
    printf '\n%s%s%s%s\n' "$bold" "$cyan" "$(t last_hist 5)" "$reset"
    tail -n 5 "$BREAKS_LOG" | while IFS= read -r line; do
      printf '  %s%s%s\n' "$dim" "$line" "$reset"
    done
  fi
}

# 배포용 체크섬 출력 — 릴리스 시 `autore checksum > autore.sh.sha256`로 갱신
# (저장소에 커밋되는 LF 기준으로 계산해야 raw.githubusercontent 내용과 일치한다)
cmd_checksum() {
  local tmp sum
  tmp=$(mktemp)
  tr -d '\r' < "$SCRIPT_PATH" > "$tmp"
  sum=$(sha256_of "$tmp") || { rm -f "$tmp"; echo "$(t err_no_sha)" >&2; exit 1; }
  rm -f "$tmp"
  [[ -n $sum ]] || { echo "$(t err_no_sha)" >&2; exit 1; }
  printf '%s  autore.sh\n' "$sum"
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

#-------------------------------------------------------------------------------
# 무결성 검증 — 배포된 SHA256과 대조
#
# 저장소의 autore.sh.sha256 (내용: "<64자리 해시>  autore.sh")과 비교한다.
# 자동 업데이트는 검증 실패/불가 시 무조건 중단(fail-closed)하고,
# 수동 업데이트만 --allow-unverified로 강제할 수 있다.
#-------------------------------------------------------------------------------
sha256_of() { # <file> — 해시 출력 (도구가 없으면 rc 1)
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" 2>/dev/null | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 "$1" 2>/dev/null | awk '{print $NF}'
  else
    return 1
  fi
}

# verify_checksum <file> — 0=일치, 1=불일치, 2=검증 불가(해시 파일/도구 없음)
verify_checksum() {
  local local_sum remote_sum
  local_sum=$(sha256_of "$1") || return 2
  [[ -n $local_sum ]] || return 2
  remote_sum=$(curl -fsSL -m 15 "$REPO_RAW/autore.sh.sha256" 2>/dev/null | awk 'NR==1{print $1}')
  [[ $remote_sum =~ ^[0-9a-fA-F]{64}$ ]] || return 2
  [[ $(printf '%s' "$local_sum" | tr 'A-F' 'a-f') == $(printf '%s' "$remote_sum" | tr 'A-F' 'a-f') ]]
}

# fetch_remote <outfile> — 원격 스크립트 다운로드 후 버전 출력 (실패 시 rc 1)
fetch_remote() {
  curl -fsSL "$REPO_RAW/autore.sh" -o "$1" 2>/dev/null || return 1
  local rv
  rv=$(sed -n 's/^VERSION="\([^"]*\)".*/\1/p' "$1" | head -n 1)
  [[ -n $rv ]] || return 1
  printf '%s\n' "$rv"
}

# replace_with <file> — 검증(문법+자가진단) 후 백업과 함께 교체 (체크섬은 호출자가 먼저 확인)
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

  # 다운로드 파일 검증 ①: 배포 체크섬(SHA256)과 대조
  verify_checksum "$tmp"; local vrc=$?
  case $vrc in
    0) echo "$(t upd_verified)" ;;
    1) rm -f "$tmp"; echo "$(t upd_err_checksum)" >&2; exit 1 ;;
    *) if (( ALLOW_UNVERIFIED )); then
         echo "$(t upd_warn_unverified)" >&2
       else
         rm -f "$tmp"; echo "$(t upd_err_no_checksum)" >&2; exit 1
       fi ;;
  esac
  # 다운로드 파일 검증 ②: 문법 검사 + 자가진단 통과 시에만 교체
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
    # 자동 경로는 무조건 체크섬 검증 (확인 불가여도 중단 — fail-closed)
    if ! verify_checksum "$tmp"; then
      rm -f "$tmp"
      log "$(t log_autoupdate_checksum_fail)"
      return 0
    fi
    if replace_with "$tmp"; then
      rm -f "$tmp"
      log "$(t log_autoupdate_done "$rv")"
      notify "$(t tg_autoupdate "$VERSION" "$rv")" autoupdate
      # 처음 실행할 때 받은 인자를 그대로 넘겨 재시작 — 옵션이 초기화되지 않도록
      exec "$SCRIPT_PATH" "${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}"
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
  last)     cmd_last ;;
  checksum) cmd_checksum ;;
  logs)     cmd_logs ;;
  attach)   cmd_attach ;;
  update)   cmd_update ;;
  test-telegram) cmd_test_telegram ;;
esac
