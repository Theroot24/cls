#!/usr/bin/env bash
# test_uninstall.sh — uninstall.sh 함수 단위 TDD (비파괴성 + 복원)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
export CLS_HOME="$REPO"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP"
mkdir -p "$HOME/.claude/scripts"

# shellcheck source=../uninstall.sh
source "$REPO/uninstall.sh"

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
ng(){ FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s  %s\n' "$1" "${2:-}"; }
eq(){ if [ "$2" = "$3" ]; then ok "$1"; else ng "$1" "exp=[$2] got=[$3]"; fi; }
yes(){ if eval "$2"; then ok "$1"; else ng "$1" "$2"; fi; }
no(){ if eval "$2"; then ng "$1" "unexpected: $2"; else ok "$1"; fi; }

SDIR="$HOME/.claude/scripts"
SETTINGS="$HOME/.claude/settings.json"
OURCMD="bash $SDIR/track-session.sh"
ENF="bash $SDIR/other-hook.sh"

# --- 설치된 상태를 install 함수로 구성 ---
RC="$HOME/.bashrc"
printf "alias cls='python3 ~/.claude/scripts/session-picker.py'\n" > "$RC"  # legacy bare
cls_inject_alias "$RC"
# foreign track-session.sh → 백업 생성 + symlink
printf 'foreign-original\n' > "$SDIR/track-session.sh"
cls_symlink_scripts
# settings: enforce + our hook
printf '{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"%s","timeout":900000}]}]}}' "$ENF" > "$SETTINGS"
cls_merge_settings
# 사용자 데이터 (보존 대상)
printf '# registry\n' > "$HOME/.claude/session-registry.md"
mkdir -p "$HOME/.claude/sessions" "$HOME/.claude/projects"
printf '{"pid":1}' > "$HOME/.claude/sessions/x.json"

echo "== uninstall 실행 =="
cls_uninstall_main >/dev/null 2>&1

echo "== 검증 =="
no  "[1] alias 마커블록 제거됨" "grep -q '>>> cls >>>' '$RC'"
yes "[1b] legacy bare alias 보존" "grep -qE '^alias cls=' '$RC'"
eq  "[2] our Stop hook 제거됨" "0" "$(jq -r --arg c "$OURCMD" '[.hooks.Stop[]?.hooks[]?|select(.command==$c)]|length' "$SETTINGS")"
eq  "[2b] 무관 enforce hook 보존" "1" "$(jq -r --arg c "$ENF" '[.hooks.Stop[]?.hooks[]?|select(.command==$c)]|length' "$SETTINGS")"
yes "[3] 우리 symlink 제거 + foreign 원복" "[ ! -L '$SDIR/track-session.sh' ] && grep -q foreign-original '$SDIR/track-session.sh'"
no  "[3b] 백업 파일 소진(복원됨)" "[ -e '$SDIR/track-session.sh.cls.bak' ]"
yes "[4] registry 보존(비파괴)" "[ -f '$HOME/.claude/session-registry.md' ]"
yes "[4b] sessions/projects 보존" "[ -f '$HOME/.claude/sessions/x.json' ] && [ -d '$HOME/.claude/projects' ]"
yes "[5] repo 보존" "[ -f '$REPO/install.sh' ]"

# 멱등: uninstall 2회
cls_uninstall_main >/dev/null 2>&1
yes "[6] uninstall 재실행 안전(no-op)" "[ -f '$SETTINGS' ]"

echo
printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
