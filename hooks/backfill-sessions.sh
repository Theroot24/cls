#!/bin/bash
# 기존 세션 일괄 등록
SESSIONS_DIR="$HOME/.claude/sessions"
TRACK_SCRIPT="$HOME/.claude/scripts/track-session.sh"

count=0
for sf in "$SESSIONS_DIR"/*.json; do
    [ -f "$sf" ] || continue

    sid=$(jq -r '.sessionId // empty' "$sf" 2>/dev/null)
    cwd=$(jq -r '.cwd // empty' "$sf" 2>/dev/null)
    [ -z "$sid" ] || [ -z "$cwd" ] && continue

    # cwd → project hash → transcript 경로
    project_hash=$(echo "$cwd" | sed 's|/|-|g')
    transcript="$HOME/.claude/projects/${project_hash}/${sid}.jsonl"

    # transcript 없으면 skip
    [ -f "$transcript" ] || continue

    echo "{\"session_id\":\"$sid\",\"transcript_path\":\"$transcript\",\"cwd\":\"$cwd\"}" | bash "$TRACK_SCRIPT"
    count=$((count + 1))
done

echo "Backfilled $count sessions → ~/.claude/session-registry.md"
