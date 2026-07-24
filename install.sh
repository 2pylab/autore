#!/usr/bin/env bash
#===============================================================================
# claude-auto-resume 설치기 — Linux / macOS
#
#   ./install.sh                  ~/.local/bin에 설치
#   ./install.sh --system         /usr/local/bin에 설치 (sudo 필요할 수 있음)
#   ./install.sh --prefix=PATH    지정 경로에 설치
#   ./install.sh --uninstall      제거
#===============================================================================
set -euo pipefail

NAME="claude-auto-resume"
PREFIX="$HOME/.local/bin"
UNINSTALL=0

usage() {
  sed -n '2,11p' "$0"
  exit "${1:-0}"
}

for arg in "$@"; do
  case "$arg" in
    --prefix=*)  PREFIX="${arg#*=}" ;;
    --system)    PREFIX="/usr/local/bin" ;;
    --uninstall) UNINSTALL=1 ;;
    -h|--help)   usage 0 ;;
    *) echo "알 수 없는 옵션: $arg" >&2; usage 1 ;;
  esac
done

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" >/dev/null 2>&1 && pwd -P)
SRC="$SCRIPT_DIR/claude-auto-resume.sh"
REPO_RAW="https://raw.githubusercontent.com/2pylab/claude-auto-resume/main"

say() { printf '%s\n' "$*"; }

# curl 파이프 실행(curl ... | bash) 등으로 본체 스크립트가 곁에 없으면 저장소에서 다운로드
if [[ ! -f $SRC ]] && (( ! UNINSTALL )); then
  command -v curl >/dev/null 2>&1 || { say "오류: 다운로드에 curl이 필요합니다" >&2; exit 1; }
  TMP_DIR=$(mktemp -d)
  trap 'rm -rf "$TMP_DIR"' EXIT
  say "본체 스크립트 다운로드 중: $REPO_RAW/claude-auto-resume.sh"
  curl -fsSL "$REPO_RAW/claude-auto-resume.sh" -o "$TMP_DIR/claude-auto-resume.sh"
  SRC="$TMP_DIR/claude-auto-resume.sh"
fi

#--- 제거 ------------------------------------------------------------------------
if (( UNINSTALL )); then
  if [[ -f "$PREFIX/$NAME" ]]; then
    rm -f "$PREFIX/$NAME"
    say "✓ 제거 완료: $PREFIX/$NAME"
  else
    say "설치되어 있지 않음: $PREFIX/$NAME"
  fi
  exit 0
fi

#--- 의존성 검사 -------------------------------------------------------------------
os=$(uname -s)
ok=1
say "== 의존성 검사 =="
if command -v tmux >/dev/null 2>&1; then
  say "✓ tmux $(tmux -V)"
else
  say "✗ tmux 없음"; ok=0
fi
if date --version >/dev/null 2>&1; then
  say "✓ GNU date ($(date --version | head -n 1))"
elif command -v gdate >/dev/null 2>&1 && gdate --version >/dev/null 2>&1; then
  say "✓ GNU date ($(gdate --version | head -n 1))"
else
  say "✗ GNU date 없음"; ok=0
fi
if command -v curl >/dev/null 2>&1; then
  say "✓ curl (텔레그램 알림용, 선택)"
else
  say "- curl 없음 (텔레그램 알림을 쓰려면 필요, 선택 사항)"
fi

if (( ! ok )); then
  say ""
  if [[ $os == Darwin ]]; then
    say "macOS 설치: brew install tmux coreutils"
  else
    say "Debian/Ubuntu: sudo apt install tmux coreutils"
    say "Fedora:        sudo dnf install tmux coreutils"
    say "Arch:          sudo pacman -S tmux coreutils"
  fi
  exit 1
fi

#--- 설치 -------------------------------------------------------------------------
NEW_VER=$(sed -n 's/^VERSION="\([^"]*\)".*/\1/p' "$SRC" | head -n 1)
OLD_VER=""
[[ -f $PREFIX/$NAME ]] && \
  OLD_VER=$(sed -n 's/^VERSION="\([^"]*\)".*/\1/p' "$PREFIX/$NAME" | head -n 1)

mkdir -p "$PREFIX"
cp "$SRC" "$PREFIX/$NAME"
chmod +x "$PREFIX/$NAME"
say ""
if [[ -z $OLD_VER ]]; then
  say "✓ 설치 완료: $PREFIX/$NAME (v$NEW_VER)"
elif [[ $OLD_VER != "$NEW_VER" ]]; then
  say "✓ 업데이트 완료: v$OLD_VER → v$NEW_VER"
  say "  앞으로는 'claude-auto-resume update' 명령으로 간편하게 업데이트할 수 있습니다"
else
  say "✓ 재설치 완료: $PREFIX/$NAME (v$NEW_VER)"
fi
if "$PREFIX/$NAME" --selftest >/dev/null 2>&1; then
  say "✓ 파서 자가진단 통과"
else
  say "⚠ 자가진단 실패 — '$PREFIX/$NAME --selftest'로 확인해주세요"
fi
case ":$PATH:" in
  *":$PREFIX:"*) ;;
  *)
    say ""
    say "⚠ PATH에 $PREFIX 가 없습니다. 셸 설정(~/.bashrc 등)에 추가하세요:"
    say "    export PATH=\"$PREFIX:\$PATH\""
    ;;
esac
say ""
say "시작하기:  $NAME start"
say "세션 접속:  $NAME attach"
