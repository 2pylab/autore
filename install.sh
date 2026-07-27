#!/usr/bin/env bash
#===============================================================================
# autore installer - Linux / macOS
#
#   ./install.sh                  install into ~/.local/bin
#   ./install.sh --system         install into /usr/local/bin (may need sudo)
#   ./install.sh --prefix=PATH    install into the given directory
#   ./install.sh --uninstall      uninstall
#
# Output language follows the OS locale (Korean/English), same as autore itself.
#===============================================================================
set -euo pipefail

NAME="autore"
PREFIX="$HOME/.local/bin"
UNINSTALL=0

#--- Locale detection - Korean locale prints Korean, everything else English ------
case "${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}" in
  ko*) TSFX=KO ;;
  *)   TSFX=EN ;;
esac

# t <key> [printf args...] - print a message in the current locale (falls back to Korean, then to the key)
t() {
  local v="MSG_${TSFX}_$1" fmt
  fmt="${!v:-}"
  if [[ -z $fmt && $TSFX != KO ]]; then v="MSG_KO_$1"; fmt="${!v:-}"; fi
  [[ -z $fmt ]] && fmt="$1"
  shift
  if (($#)); then printf "$fmt" "$@"; else printf '%s' "$fmt"; fi
}

#--- Message catalog (Korean / English) ------------------------------------------
MSG_KO_err_unknown_opt="알 수 없는 옵션: %s"
MSG_EN_err_unknown_opt="unknown option: %s"
MSG_KO_err_no_curl="오류: 다운로드에 curl이 필요합니다"
MSG_EN_err_no_curl="error: curl is required to download the script"
MSG_KO_downloading="본체 스크립트 다운로드 중: %s"
MSG_EN_downloading="downloading the main script: %s"

MSG_KO_rm_done="✓ 제거 완료: %s"
MSG_EN_rm_done="✓ removed: %s"
MSG_KO_rm_absent="설치되어 있지 않음: %s"
MSG_EN_rm_absent="not installed: %s"
MSG_KO_rm_legacy="✓ 구버전 제거: %s"
MSG_EN_rm_legacy="✓ removed old version: %s"

MSG_KO_dep_header="== 의존성 검사 =="
MSG_EN_dep_header="== dependency check =="
MSG_KO_dep_missing="✗ %s 없음"
MSG_EN_dep_missing="✗ %s missing"
MSG_KO_dep_curl_ok="✓ curl (텔레그램 알림용, 선택)"
MSG_EN_dep_curl_ok="✓ curl (optional, for Telegram alerts)"
MSG_KO_dep_curl_none="- curl 없음 (텔레그램 알림을 쓰려면 필요, 선택 사항)"
MSG_EN_dep_curl_none="- curl missing (optional; only needed for Telegram alerts)"
MSG_KO_dep_hint_mac="macOS 설치: brew install tmux coreutils"
MSG_EN_dep_hint_mac="macOS: brew install tmux coreutils"

MSG_KO_inst_done="✓ 설치 완료: %s (v%s)"
MSG_EN_inst_done="✓ installed: %s (v%s)"
MSG_KO_inst_updated="✓ 업데이트 완료: v%s → v%s"
MSG_EN_inst_updated="✓ updated: v%s → v%s"
MSG_KO_inst_update_hint="  앞으로는 'autore update' 명령으로 간편하게 업데이트할 수 있습니다"
MSG_EN_inst_update_hint="  from now on, 'autore update' keeps it up to date"
MSG_KO_inst_reinstalled="✓ 재설치 완료: %s (v%s)"
MSG_EN_inst_reinstalled="✓ reinstalled: %s (v%s)"
MSG_KO_legacy_cleaned="✓ 구버전 정리: %s 삭제"
MSG_EN_legacy_cleaned="✓ cleaned up the old install: removed %s"

MSG_KO_selftest_ok="✓ 파서 자가진단 통과"
MSG_EN_selftest_ok="✓ self-test passed"
MSG_KO_selftest_fail="⚠ 자가진단 실패 — '%s --selftest'로 확인해주세요"
MSG_EN_selftest_fail="⚠ self-test failed — check it with '%s --selftest'"
MSG_KO_path_warn="⚠ PATH에 %s 가 없습니다. 셸 설정(~/.bashrc 등)에 추가하세요:"
MSG_EN_path_warn="⚠ %s is not in PATH. Add it to your shell config (~/.bashrc etc.):"
MSG_KO_start_hint="시작하기:   %s start"
MSG_EN_start_hint="Get started: %s start"
MSG_KO_attach_hint="세션 접속:   %s attach"
MSG_EN_attach_hint="Attach:      %s attach"

say() { printf '%s\n' "$*"; }

usage() {
  if [[ $TSFX == KO ]]; then
    cat <<EOF
autore 설치기 — Linux / macOS

사용법:
  ./install.sh                  ~/.local/bin에 설치
  ./install.sh --system         /usr/local/bin에 설치 (sudo 필요할 수 있음)
  ./install.sh --prefix=PATH    지정 경로에 설치
  ./install.sh --uninstall      제거
  ./install.sh --help           이 도움말 출력 (-h 도 동일)

출력 언어: OS 로케일 자동 감지 (한국어/English)
EOF
  else
    cat <<EOF
autore installer - Linux / macOS

Usage:
  ./install.sh                  install into ~/.local/bin
  ./install.sh --system         install into /usr/local/bin (may need sudo)
  ./install.sh --prefix=PATH    install into the given directory
  ./install.sh --uninstall      uninstall
  ./install.sh --help           print this help (same as -h)

Language: auto-detected from the OS locale (Korean/English)
EOF
  fi
  exit "${1:-0}"
}

for arg in "$@"; do
  case "$arg" in
    --prefix=*)  PREFIX="${arg#*=}" ;;
    --system)    PREFIX="/usr/local/bin" ;;
    --uninstall) UNINSTALL=1 ;;
    -h|--help)   usage 0 ;;
    *) say "$(t err_unknown_opt "$arg")" >&2; usage 1 ;;
  esac
done

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" >/dev/null 2>&1 && pwd -P)
SRC="$SCRIPT_DIR/autore.sh"
REPO_RAW="https://raw.githubusercontent.com/2pylab/autore/main"

# When the main script is not next to us (e.g. piped install: curl ... | bash), fetch it from the repo
if [[ ! -f $SRC ]] && (( ! UNINSTALL )); then
  command -v curl >/dev/null 2>&1 || { say "$(t err_no_curl)" >&2; exit 1; }
  TMP_DIR=$(mktemp -d)
  trap 'rm -rf "$TMP_DIR"' EXIT
  say "$(t downloading "$REPO_RAW/autore.sh")"
  curl -fsSL "$REPO_RAW/autore.sh" -o "$TMP_DIR/autore.sh"
  SRC="$TMP_DIR/autore.sh"
fi

#--- Uninstall -------------------------------------------------------------------
if (( UNINSTALL )); then
  if [[ -f "$PREFIX/$NAME" ]]; then
    rm -f "$PREFIX/$NAME"
    say "$(t rm_done "$PREFIX/$NAME")"
  else
    say "$(t rm_absent "$PREFIX/$NAME")"
  fi
  # Also remove a leftover install of the old claude-auto-resume
  if [[ -f "$PREFIX/claude-auto-resume" ]]; then
    rm -f "$PREFIX/claude-auto-resume"
    say "$(t rm_legacy "$PREFIX/claude-auto-resume")"
  fi
  exit 0
fi

#--- Dependency check ------------------------------------------------------------
os=$(uname -s)
ok=1
say "$(t dep_header)"
if command -v tmux >/dev/null 2>&1; then
  say "✓ tmux $(tmux -V)"
else
  say "$(t dep_missing tmux)"; ok=0
fi
if date --version >/dev/null 2>&1; then
  say "✓ GNU date ($(date --version | head -n 1))"
elif command -v gdate >/dev/null 2>&1 && gdate --version >/dev/null 2>&1; then
  say "✓ GNU date ($(gdate --version | head -n 1))"
else
  say "$(t dep_missing 'GNU date')"; ok=0
fi
if command -v curl >/dev/null 2>&1; then
  say "$(t dep_curl_ok)"
else
  say "$(t dep_curl_none)"
fi

if (( ! ok )); then
  say ""
  if [[ $os == Darwin ]]; then
    say "$(t dep_hint_mac)"
  else
    say "Debian/Ubuntu: sudo apt install tmux coreutils"
    say "Fedora:        sudo dnf install tmux coreutils"
    say "Arch:          sudo pacman -S tmux coreutils"
  fi
  exit 1
fi

#--- Install ---------------------------------------------------------------------
NEW_VER=$(sed -n 's/^VERSION="\([^"]*\)".*/\1/p' "$SRC" | head -n 1)
OLD_VER=""
[[ -f $PREFIX/$NAME ]] && \
  OLD_VER=$(sed -n 's/^VERSION="\([^"]*\)".*/\1/p' "$PREFIX/$NAME" | head -n 1)

mkdir -p "$PREFIX"
cp "$SRC" "$PREFIX/$NAME"
chmod +x "$PREFIX/$NAME"
# Clean up an old claude-auto-resume install if one is still around
if [[ -f "$PREFIX/claude-auto-resume" ]]; then
  rm -f "$PREFIX/claude-auto-resume"
  say "$(t legacy_cleaned "$PREFIX/claude-auto-resume")"
fi
say ""
if [[ -z $OLD_VER ]]; then
  say "$(t inst_done "$PREFIX/$NAME" "$NEW_VER")"
elif [[ $OLD_VER != "$NEW_VER" ]]; then
  say "$(t inst_updated "$OLD_VER" "$NEW_VER")"
  say "$(t inst_update_hint)"
else
  say "$(t inst_reinstalled "$PREFIX/$NAME" "$NEW_VER")"
fi
if "$PREFIX/$NAME" --selftest >/dev/null 2>&1; then
  say "$(t selftest_ok)"
else
  say "$(t selftest_fail "$PREFIX/$NAME")"
fi
case ":$PATH:" in
  *":$PREFIX:"*) ;;
  *)
    say ""
    say "$(t path_warn "$PREFIX")"
    say "    export PATH=\"$PREFIX:\$PATH\""
    ;;
esac
say ""
say "$(t start_hint "$NAME")"
say "$(t attach_hint "$NAME")"
