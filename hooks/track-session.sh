#!/usr/bin/env bash
# Claude Code Stop Hook — 세션 자동 트래킹 (크로스플랫폼: macOS/Ubuntu)
# stdin은 비어있음. PPID + 환경변수 + sessions/*.json 으로 세션 정보 획득.
#
# 크로스플랫폼: GNU 전용(stat -c/date -d @/tac/declare -A)을 python3 one-liner와
# bash 3.2 호환 함수로 대체. python3는 이미 의존성이므로 신규 런타임 의존성 0.
# hook은 settings.json에 `bash <abs>/track-session.sh`로 등록되어 macOS stock
# /bin/bash(3.2)로도 실행될 수 있으므로 associative array를 쓰지 않는다.
#
# 테스트: tests/test_track_session.sh가 source하여 함수 단위로 검증
#   (TRACK_SESSION_REGISTRY / TRACK_SESSION_SESSIONS_DIR override + sourcing guard)

REGISTRY="${TRACK_SESSION_REGISTRY:-$HOME/.claude/session-registry.md}"
SESSIONS_DIR="${TRACK_SESSION_SESSIONS_DIR:-$HOME/.claude/sessions}"

# ── 크로스플랫폼 helper ───────────────────────────────────────────────────────

# 파일 mtime → 'YYYY-MM-DD HH:MM' (로컬 시간).
# GNU `stat -c '%Y'` + `date -d "@.."` 를 python3 one-liner로 대체(Mac/Ubuntu 동일).
_file_mtime_ts() {
  python3 -c "import os,sys,datetime as d;print(d.datetime.fromtimestamp(os.stat(sys.argv[1]).st_mtime).strftime('%Y-%m-%d %H:%M'))" "$1" 2>/dev/null
}

# pid → 매칭 session 파일 경로 (declare -A 대체, bash 3.2 호환). 없으면 빈 값.
_session_file_for_pid() {
  local pid="$1" sf p
  for sf in "$SESSIONS_DIR"/*.json; do
    [ -f "$sf" ] || continue
    p=$(jq -r '.pid // empty' "$sf" 2>/dev/null)
    if [ "$p" = "$pid" ]; then
      printf '%s' "$sf"
      return 0
    fi
  done
}

# away_summary(최신 timestamp) 추출 → 정제된 한 줄, 없으면 빈 값.
_desc_from_away_summary() {
  local transcript="$1"
  [ -f "$transcript" ] || return 0
  grep '"subtype":"away_summary"' "$transcript" 2>/dev/null | python3 -c "
import sys, json, re
best_ts, best_text = '', ''
for line in sys.stdin:
    try:
        d = json.loads(line)
        if d.get('type') != 'system' or d.get('subtype') != 'away_summary':
            continue
        c = (d.get('content') or '').strip()
        if not c:
            continue
        ts = d.get('timestamp', '')
        if ts >= best_ts:
            best_ts, best_text = ts, c
    except Exception:
        continue
if best_text:
    best_text = re.sub(r'\s*\((?:disable recaps|turn off recaps)[^)]*\)\s*\$', '', best_text).strip()
    best_text = re.sub(r'\[Image[^\]]*\]\s*', '', best_text).strip()
    best_text = ' '.join(best_text.split()).replace('|', '/')
    if len(best_text) > 5:
        print(best_text[:80])
" 2>/dev/null
}

# 마지막(가장 최근) user 프롬프트 → 정제된 한 줄, 없으면 빈 값.
# GNU `tac` 제거: python에서 reversed()로 최신 줄부터 탐색(Mac/Ubuntu 동일).
_desc_from_last_prompt() {
  local transcript="$1"
  [ -f "$transcript" ] || return 0
  grep '"type":"user"' "$transcript" 2>/dev/null | python3 -c "
import sys, json, re
skip = ('[Request interrupted', '<system-reminder', '<command-', '<local-command', '<command-message', '/exit', '<task-notification', 'Base directory for this skill', 'Implement the following plan')
found = False
for line in reversed(sys.stdin.readlines()):
    if found:
        break
    try:
        data = json.loads(line)
        content = data.get('message',{}).get('content','')
        if isinstance(content, list):
            for c in content:
                if c.get('type') != 'text':
                    continue
                text = c.get('text','').strip()
                if any(text.startswith(p) for p in skip):
                    continue
                text = re.sub(r'\[Image[^\]]*\]\s*', '', text).strip()
                if len(text) > 5:
                    text = ' '.join(text.split()).replace('|', '/')
                    print(text[:80])
                    found = True
                    break
        elif isinstance(content, str) and len(content.strip()) > 5:
            text = content.strip()
            if any(text.startswith(p) for p in skip):
                continue
            text = re.sub(r'\[Image[^\]]*\]\s*', '', text).strip()
            if len(text) > 5:
                text = ' '.join(text.split()).replace('|', '/')
                print(text[:80])
                found = True
    except Exception:
        continue
" 2>/dev/null
}

# 최종 description: away_summary → 마지막 user 프롬프트 → (basename CWD), + team suffix.
_compose_description() {
  local transcript="$1" cwd="$2" team="$3" desc
  desc="$(_desc_from_away_summary "$transcript")"
  [ -z "$desc" ] && desc="$(_desc_from_last_prompt "$transcript")"
  [ -z "$desc" ] && desc="(${cwd##*/})"
  [ -n "$team" ] && desc="${desc} (${team})"
  printf '%s' "$desc"
}

# registry upsert: header 자동 생성 + 동일 sid dedup + append + 최대 50건 유지.
_registry_upsert() {
  local cwd="$1" sid="$2" ts="$3" desc="$4"
  if [ ! -f "$REGISTRY" ]; then
    cat > "$REGISTRY" << 'HEADER'
# Claude Code Session Registry

| Path | Session ID | Last Chat | Description |
|---|---|---|---|
HEADER
  fi
  # 동일 SESSION_ID 행 제거 (fixed-string 매칭으로 정규식 오해석 방지)
  if grep -Fq -- "$sid" "$REGISTRY" 2>/dev/null; then
    grep -Fv -- "$sid" "$REGISTRY" > "${REGISTRY}.tmp" && mv "${REGISTRY}.tmp" "$REGISTRY"
  fi
  printf '| %s | `%s` | %s | %s |\n' "$cwd" "$sid" "$ts" "$desc" >> "$REGISTRY"
  # 최대 50건 유지 (header 3줄 + 데이터 50줄)
  local header_lines=3 max_entries=50 total
  total=$(wc -l < "$REGISTRY")
  if [ "$total" -gt $((header_lines + max_entries)) ]; then
    head -n "$header_lines" "$REGISTRY" > "${REGISTRY}.tmp"
    tail -n "$max_entries" "$REGISTRY" >> "${REGISTRY}.tmp"
    mv "${REGISTRY}.tmp" "$REGISTRY"
  fi
}

# ── Hook 본체 ─────────────────────────────────────────────────────────────────
_track_session_main() {
  local SESSION_ID="" SESSION_FILE="" TEAM_NAME="" CURRENT_PID CWD
  local PROJECT_HASH TRANSCRIPT TIMESTAMP DESCRIPTION i

  # 1. 현재 PID부터 부모를 따라 올라가며 sessions/*.json의 pid와 매칭 (최대 10단계)
  CURRENT_PID=$$
  for ((i = 0; i < 10; i++)); do
    CURRENT_PID=$(ps -o ppid= -p "$CURRENT_PID" 2>/dev/null | tr -d ' ')
    [ -z "$CURRENT_PID" ] && break
    SESSION_FILE="$(_session_file_for_pid "$CURRENT_PID")"
    if [ -n "$SESSION_FILE" ]; then
      SESSION_ID=$(jq -r '.sessionId // empty' "$SESSION_FILE" 2>/dev/null)
      TEAM_NAME=$(jq -r '.name // empty' "$SESSION_FILE" 2>/dev/null)
      break
    fi
  done

  [ -z "$SESSION_ID" ] && return 0

  # 2. CWD: 환경변수 CLAUDE_PROJECT_DIR 또는 sessions/*.json의 cwd
  CWD="${CLAUDE_PROJECT_DIR:-}"
  if [ -z "$CWD" ] && [ -n "$SESSION_FILE" ]; then
    CWD=$(jq -r '.cwd // empty' "$SESSION_FILE" 2>/dev/null)
  fi
  [ -z "$CWD" ] && return 0

  # 3. Transcript 경로 유추: cwd → project hash → transcript
  PROJECT_HASH=$(printf '%s' "$CWD" | sed 's|/|-|g')
  TRANSCRIPT="$HOME/.claude/projects/${PROJECT_HASH}/${SESSION_ID}.jsonl"

  # 4. 마지막 대화 시간 (transcript mtime, 없으면 현재 시각)
  TIMESTAMP=""
  if [ -f "$TRANSCRIPT" ]; then
    TIMESTAMP="$(_file_mtime_ts "$TRANSCRIPT")"
  fi
  [ -z "$TIMESTAMP" ] && TIMESTAMP=$(date '+%Y-%m-%d %H:%M')

  # 5. Description + 6. Registry upsert
  DESCRIPTION="$(_compose_description "$TRANSCRIPT" "$CWD" "$TEAM_NAME")"
  _registry_upsert "$CWD" "$SESSION_ID" "$TIMESTAMP" "$DESCRIPTION"
}

# Sourcing guard: 직접 실행(bash track-session.sh) 시에만 main. 테스트는 source만.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  _track_session_main
  exit 0
fi
