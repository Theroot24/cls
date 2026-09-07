#!/usr/bin/env bash
# test_install.sh — install.sh 함수 단위 TDD (temp HOME 격리)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
export CLS_HOME="$REPO"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP"
mkdir -p "$HOME/.claude"

# shellcheck source=../install.sh
source "$REPO/install.sh"

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
ng(){ FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s  %s\n' "$1" "${2:-}"; }
eq(){ if [ "$2" = "$3" ]; then ok "$1"; else ng "$1" "exp=[$2] got=[$3]"; fi; }
yes(){ if eval "$2"; then ok "$1"; else ng "$1" "$2"; fi; }
no(){ if eval "$2"; then ng "$1" "unexpected: $2"; else ok "$1"; fi; }

SDIR="$HOME/.claude/scripts"
SETTINGS="$HOME/.claude/settings.json"
OURCMD="bash $SDIR/track-session.sh"

echo "== preflight (happy path) =="
yes "[0] python3/jq 있으면 preflight 통과" "cls_preflight >/dev/null 2>&1"

echo "== alias 마커블록 멱등 =="
RC="$HOME/.bashrc"
printf "alias cls='python3 ~/.claude/scripts/session-picker.py'\n" > "$RC"  # legacy bare (마커 없음)
cls_inject_alias "$RC"
eq "[1] 마커블록 1개" "1" "$(grep -c '>>> cls >>>' "$RC")"
eq "[1b] alias cls 총 2개 (legacy + 마커)" "2" "$(grep -cE '^alias cls=' "$RC")"
yes "[2] 백업 생성됨" "[ -f '$RC.cls.bak' ]"
eq  "[2b] rc 백업 권한 600" "600" "$(stat -c '%a' "$RC.cls.bak")"
cls_inject_alias "$RC"  # 재실행
eq "[3] 재실행 마커블록 여전히 1개" "1" "$(grep -c '>>> cls >>>' "$RC")"
eq "[3b] 재실행 alias cls 여전히 2개 (누적 없음)" "2" "$(grep -cE '^alias cls=' "$RC")"
yes "[4] legacy bare alias 보존(마커 밖)" "awk -v s='# >>> cls >>>' -v e='# <<< cls <<<' '\$0==s{k=1} k&&\$0==e{k=0;next} !k{print}' '$RC' | grep -qE '^alias cls='"

echo "== symlink + 백업 =="
# A: 타깃 부재 → symlink, 백업 없음
cls_symlink_scripts
yes "[5] session-picker symlink → repo" "[ \"\$(readlink '$SDIR/session-picker.py')\" = '$REPO/bin/session-picker.py' ]"
no  "[5b] 부재 타깃엔 백업 안 만듦" "[ -e '$SDIR/session-picker.py.cls.bak' ]"
# B: 기존 실파일(foreign) → 백업 + symlink
rm -rf "$SDIR"; mkdir -p "$SDIR"; printf 'foreign-content\n' > "$SDIR/track-session.sh"
cls_symlink_scripts
yes "[6] foreign 파일 백업됨" "grep -q foreign-content '$SDIR/track-session.sh.cls.bak'"
eq  "[6c] symlink 백업 권한 600" "600" "$(stat -c '%a' "$SDIR/track-session.sh.cls.bak")"
yes "[6b] symlink로 교체" "[ -L '$SDIR/track-session.sh' ]"
# C: 이미 우리 symlink → 추가 백업 없음 (멱등)
rm -f "$SDIR"/*.cls.bak
cls_symlink_scripts
no  "[7] 우리 symlink면 백업 안 함(멱등)" "[ -e '$SDIR/track-session.sh.cls.bak' ]"

echo "== settings.json 병합 =="
rm -f "$SETTINGS"
cls_merge_settings
eq "[8] 부재→seed+our hook 1개" "1" "$(jq -r --arg c "$OURCMD" '[.hooks.Stop[]?.hooks[]?|select(.command==$c)]|length' "$SETTINGS")"
yes "[8b] settings 백업 생성" "[ -f '$SETTINGS.cls.bak' ]"
eq  "[8c] settings 백업 권한 600" "600" "$(stat -c '%a' "$SETTINGS.cls.bak")"
# 무관 enforce hook 보존
ENF="bash $SDIR/other-hook.sh"
printf '{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"%s","timeout":900000}]}]}}' "$ENF" > "$SETTINGS"
cls_merge_settings
eq "[9] enforce 보존" "1" "$(jq -r --arg c "$ENF" '[.hooks.Stop[]?.hooks[]?|select(.command==$c)]|length' "$SETTINGS")"
eq "[9b] our hook 추가" "1" "$(jq -r --arg c "$OURCMD" '[.hooks.Stop[]?.hooks[]?|select(.command==$c)]|length' "$SETTINGS")"
cls_merge_settings  # 재실행
eq "[9c] 재실행 our hook 여전히 1개(멱등)" "1" "$(jq -r --arg c "$OURCMD" '[.hooks.Stop[]?.hooks[]?|select(.command==$c)]|length' "$SETTINGS")"

echo "== 백업 권한 에러 케이스 =="
# E1: 원본이 이미 600이어도 백업은 600 (더 느슨해지지 않는다)
rm -f "$SETTINGS" "$SETTINGS.cls.bak"
printf '{"env":{"K":"V"}}' > "$SETTINGS"; chmod 600 "$SETTINGS"
cls_merge_settings
eq "[10] 원본이 이미 600 → 백업도 600" "600" "$(stat -c '%a' "$SETTINGS.cls.bak")"

# E2: cp -P가 만든 .bak이 symlink일 때 chmod가 링크 대상(원본)을 바꾸면 안 된다
#     (Linux엔 lchmod가 없어 chmod는 링크를 따라간다 → 실파일 가드 필요)
rm -rf "$SDIR"; mkdir -p "$SDIR"
printf 'victim\n' > "$HOME/victim.txt"; chmod 644 "$HOME/victim.txt"
ln -s "$HOME/victim.txt" "$SDIR/track-session.sh"
cls_symlink_scripts
eq "[11] symlink 백업 시 링크 대상 원본 모드 불변" "644" "$(stat -c '%a' "$HOME/victim.txt")"

echo
printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
