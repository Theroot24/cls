#!/usr/bin/env bash
# test_settings_merge.sh — lib/merge.jq 멱등 upsert/remove TDD
#
# 실행: bash tests/test_settings_merge.sh
#
# merge.jq: --arg cmd "<canonical command>" --arg mode "add"|"remove"
#   add    → Stop의 matcher=="" 그룹에 정확히 $cmd 1개 보장(멱등). 다른 hook 보존.
#   remove → 모든 Stop 그룹에서 정확히 $cmd 제거. 다른 hook 보존.
# 핵심(Finding 1): substring 아닌 **정확 명령 문자열 일치** → 무관 hook 클로버 방지.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MERGE="$SCRIPT_DIR/../lib/merge.jq"
CMD="bash /home/test/.claude/scripts/track-session.sh"
ENFORCE="bash /home/test/.claude/scripts/other-hook.sh"
OTHER="bash /other/track-session.sh"          # 무관 — 정확 매칭이면 안 건드림
BACKFILL="bash /home/test/.claude/scripts/backfill-sessions.sh"

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
ng(){ FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n      %s\n' "$1" "$2"; }

merge(){ printf '%s' "$1" | jq -c --arg cmd "$CMD" --arg mode "$2" -f "$MERGE" 2>/dev/null; }
# 특정 command 문자열의 Stop 내 등장 횟수
count_cmd(){ printf '%s' "$1" | jq -r --arg c "$2" '[.hooks.Stop[]?.hooks[]? | select((.command//"")==$c)] | length' 2>/dev/null; }

assert_count(){ local got; got="$(count_cmd "$2" "$3")"; if [ "$got" = "$4" ]; then ok "$1"; else ng "$1" "exp count $4, got $got"; fi; }
assert_jq_fail(){ if printf '%s' "$2" | jq --arg cmd "$CMD" --arg mode add -f "$MERGE" >/dev/null 2>&1; then ng "$1" "jq가 성공함(실패해야 함)"; else ok "$1"; fi; }

echo "== add: 빈/누락 구조 =="
r="$(merge '{}' add)"
assert_count "[1] 빈 {} → our hook 1개" "$r" "$CMD" "1"

r="$(merge '{"hooks":{}}' add)"
assert_count "[2] .hooks 있고 Stop 없음 → 생성" "$r" "$CMD" "1"

r="$(merge '{"hooks":{"Stop":[]}}' add)"
assert_count "[3] Stop 빈 배열 → 그룹 생성" "$r" "$CMD" "1"

r="$(merge '{"hooks":{"Stop":[{"matcher":""}]}}' add)"
assert_count "[4] 그룹 hooks 키 없음 → 처리" "$r" "$CMD" "1"

echo "== add: 무관 hook 보존 (Finding 1 핵심) =="
INP_ENFORCE='{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"bash /home/test/.claude/scripts/other-hook.sh","timeout":900000}]}]}}'
r="$(merge "$INP_ENFORCE" add)"
assert_count "[5] other-hook 보존" "$r" "$ENFORCE" "1"
assert_count "[5b] our hook 추가됨" "$r" "$CMD" "1"

INP_OTHER='{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"bash /other/track-session.sh","timeout":5000}]}]}}'
r="$(merge "$INP_OTHER" add)"
assert_count "[6] 무관 /other/track-session.sh 보존 (정확매칭)" "$r" "$OTHER" "1"
assert_count "[6b] our hook도 추가" "$r" "$CMD" "1"

INP_BF='{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"bash /home/test/.claude/scripts/backfill-sessions.sh","timeout":5000}]}]}}'
r="$(merge "$INP_BF" add)"
assert_count "[7] backfill-sessions 보존" "$r" "$BACKFILL" "1"

echo "== add: non-empty matcher 그룹 보존 =="
INP_NE='{"hooks":{"Stop":[{"matcher":"SomeTool","hooks":[{"type":"command","command":"bash /x.sh"}]}]}}'
r="$(merge "$INP_NE" add)"
assert_count "[8] our hook 추가(빈 matcher 그룹 신설)" "$r" "$CMD" "1"
assert_count "[8b] SomeTool 그룹 hook 보존" "$r" "bash /x.sh" "1"

echo "== add: 멱등 (중복 금지) =="
r1="$(merge "$INP_ENFORCE" add)"; r2="$(merge "$r1" add)"
assert_count "[9] 우리 hook 기존 → dedup 1개" "$r2" "$CMD" "1"
assert_count "[9b] enforce 여전히 1개" "$r2" "$ENFORCE" "1"
r3="$(merge "$r2" add)"
assert_count "[9c] 3회 실행도 1개" "$r3" "$CMD" "1"

echo "== remove: 정확히 our hook만 제거, 나머지 보존 =="
both='{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"bash /home/test/.claude/scripts/track-session.sh","timeout":5000},{"type":"command","command":"bash /home/test/.claude/scripts/other-hook.sh","timeout":900000}]}]}}'
r="$(merge "$both" remove)"
assert_count "[10] our hook 제거됨" "$r" "$CMD" "0"
assert_count "[10b] enforce 보존" "$r" "$ENFORCE" "1"

r="$(merge "$INP_OTHER" remove)"
assert_count "[11] 무관 /other 제거 안 함 (정확매칭)" "$r" "$OTHER" "1"

echo "== malformed → jq 실패 (install이 원본 보존) =="
assert_jq_fail "[12] 잘못된 JSON → jq 비정상 종료" 'not a json'

echo
printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
