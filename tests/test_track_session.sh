#!/usr/bin/env bash
# test_track_session.sh — track-session.sh 크로스플랫폼 하드닝 TDD
#
# 실행: bash tests/test_track_session.sh  (repo 루트 또는 어디서나)
#
# track-session.sh를 source하면 main 흐름은 실행되지 않고(sourcing guard) 함수만 노출된다.
# 테스트 대상 함수:
#   _file_mtime_ts FILE            → 'YYYY-MM-DD HH:MM' (mtime, 크로스플랫폼)
#   _compose_description TR CWD TEAM → 최종 DESCRIPTION (away_summary→last-prompt→basename + team)
#   _registry_upsert CWD SID TS DESC → $REGISTRY upsert (header 생성/dedup/50-cap)
#   _session_file_for_pid PID      → $SESSIONS_DIR에서 pid 매칭 파일 (declare -A 대체)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/../hooks/track-session.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export TRACK_SESSION_REGISTRY="$TMP/registry.md"
export TRACK_SESSION_SESSIONS_DIR="$TMP/sessions"
mkdir -p "$TRACK_SESSION_SESSIONS_DIR"

# shellcheck source=../hooks/track-session.sh
source "$HOOK"

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
ng(){ FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n      exp=[%s]\n      got=[%s]\n' "$1" "$2" "$3"; }
eq(){ if [ "$2" = "$3" ]; then ok "$1"; else ng "$1" "$2" "$3"; fi; }

echo "== _file_mtime_ts (oracle: 기존 GNU stat -c/date -d 와 동일) =="
f="$TMP/sample.txt"; : > "$f"; touch -d "2026-06-16 10:42:00" "$f"
mt="$(stat -c '%Y' "$f")"
oracle="$(date -d "@$mt" '+%Y-%m-%d %H:%M')"
eq "[1] mtime ts == GNU oracle" "$oracle" "$(_file_mtime_ts "$f")"
eq "[1b] 고정값 확인" "2026-06-16 10:42" "$(_file_mtime_ts "$f")"

echo "== _compose_description =="
# away_summary 우선 (timestamp 높은 것)
tr1="$TMP/tr1.jsonl"
cat > "$tr1" <<'JSONL'
{"type":"system","subtype":"away_summary","content":"old summary content here","timestamp":"2026-06-16T09:00:00"}
{"type":"user","message":{"content":"some user prompt that is long enough"}}
{"type":"system","subtype":"away_summary","content":"newest summary content here","timestamp":"2026-06-16T10:00:00"}
JSONL
eq "[2] away_summary(최신) 우선" "newest summary content here" "$(_compose_description "$tr1" "/x/projA" "")"

# away_summary 없음 → 마지막 user 프롬프트
tr2="$TMP/tr2.jsonl"
cat > "$tr2" <<'JSONL'
{"type":"user","message":{"content":"first user prompt here long enough"}}
{"type":"assistant","message":{"content":"reply"}}
{"type":"user","message":{"content":"latest user prompt here long enough"}}
JSONL
eq "[3] away_summary 없음 → 마지막 user 프롬프트" "latest user prompt here long enough" "$(_compose_description "$tr2" "/x/projB" "")"

# 빈 transcript → (basename CWD)
empty="$TMP/empty.jsonl"; : > "$empty"
eq "[4] 빈 transcript → (basename)" "(projC)" "$(_compose_description "$empty" "/x/projC" "")"

# team suffix 부착
eq "[5] team suffix 부착" "(projC) (MyTeam)" "$(_compose_description "$empty" "/x/projC" "MyTeam")"
eq "[5b] away_summary + team suffix" "newest summary content here (MyTeam)" "$(_compose_description "$tr1" "/x/projA" "MyTeam")"

# 부재 transcript(파일 없음) → 무크래시, basename fallback
eq "[6] 부재 transcript → basename" "(projD)" "$(_compose_description "$TMP/nope.jsonl" "/x/projD" "")"

echo "== _registry_upsert =="
rm -f "$TRACK_SESSION_REGISTRY"
_registry_upsert "/x/p1" "sid-1111-aaaa" "2026-06-16 10:00" "desc one"
ok_hdr=$(grep -c '^| Path | Session ID' "$TRACK_SESSION_REGISTRY")
eq "[7] header 자동 생성" "1" "$ok_hdr"
eq "[7b] 행 1개" "1" "$(grep -c 'sid-1111-aaaa' "$TRACK_SESSION_REGISTRY")"

# 같은 sid 재삽입 → dedup (1개 유지)
_registry_upsert "/x/p1" "sid-1111-aaaa" "2026-06-16 10:05" "desc updated"
eq "[8] 동일 sid dedup → 1개" "1" "$(grep -c 'sid-1111-aaaa' "$TRACK_SESSION_REGISTRY")"
eq "[8b] 최신 desc 반영" "1" "$(grep -c 'desc updated' "$TRACK_SESSION_REGISTRY")"

# 50-cap: 60개 삽입 → 최대 50개 데이터행
rm -f "$TRACK_SESSION_REGISTRY"
for i in $(seq 1 60); do _registry_upsert "/x/p$i" "sid-cap-$(printf '%04d' "$i")" "2026-06-16 10:00" "d$i"; done
data_rows=$(grep -c '`sid-cap-' "$TRACK_SESSION_REGISTRY")
eq "[9] 50-cap (60삽입→50유지)" "50" "$data_rows"
# 가장 오래된 것(sid-cap-0001~0010)은 제거됨
eq "[9b] 오래된 행 제거" "0" "$(grep -c 'sid-cap-0001' "$TRACK_SESSION_REGISTRY")"
eq "[9c] 최신 행 유지" "1" "$(grep -c 'sid-cap-0060' "$TRACK_SESSION_REGISTRY")"

echo "== _build_pid_map + _session_file_for_pid (declare -A 대체, single-pass) =="
printf '{"pid":12345,"sessionId":"sess-aaaa","cwd":"/x/p","name":"T"}' > "$TRACK_SESSION_SESSIONS_DIR/a.json"
printf '{"pid":67890,"sessionId":"sess-bbbb","cwd":"/y/q"}' > "$TRACK_SESSION_SESSIONS_DIR/b.json"
_PID_MAP="$(_build_pid_map)"   # 1회 구축 (원본 'collect once' 의미 복원)
eq "[10] _build_pid_map: pid 2개 수집" "2" "$(printf '%s\n' "$_PID_MAP" | grep -c $'\t')"
eq "[10a] pid 매칭 파일" "$TRACK_SESSION_SESSIONS_DIR/a.json" "$(_session_file_for_pid 12345)"
eq "[10b] 다른 pid" "$TRACK_SESSION_SESSIONS_DIR/b.json" "$(_session_file_for_pid 67890)"
eq "[10c] 미존재 pid → 빈 값" "" "$(_session_file_for_pid 99999)"
# 맵 비었을 때(빈 sessions) 안전
_PID_MAP=""
eq "[10d] 빈 맵 → 빈 값" "" "$(_session_file_for_pid 12345)"

echo
printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
