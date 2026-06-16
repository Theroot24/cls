#!/usr/bin/env bash
# install.sh — cls 설치 (symlink 전략, 멱등, 백업 보존)
#
# 동작:
#   0. CLS_HOME = repo 루트 (이 스크립트 위치)
#   1. preflight: python3(+curses)/jq/claude 확인, macOS BSD 도구 경고
#   2. shell 감지 → rc 파일 (.zshrc/.bashrc), $CLS_SHELL override
#   3. alias 마커블록 멱등 주입 (~/.bashrc:160 류 legacy bare alias는 무변경)
#   4. mkdir ~/.claude/scripts + (비-repo 타깃 백업) + symlink 3개
#   5. settings.json Stop hook 멱등 병합 (무관 hook 보존, temp→validate→backup→atomic mv)
#   6. backfill-sessions.sh 실행 (registry 시딩 — 활성 세션만; 한계는 README)
#   7. 다음 단계 안내
#
# 테스트: HOME override + CLS_HOME override + sourcing guard로 함수 단위 검증.
set -uo pipefail

CLS_HOME="${CLS_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

MARK_START="# >>> cls >>>"
MARK_END="# <<< cls <<<"

_claude_dir()   { printf '%s' "${CLS_CLAUDE_DIR:-$HOME/.claude}"; }
_scripts_dir()  { printf '%s' "$(_claude_dir)/scripts"; }
_settings_file(){ printf '%s' "$(_claude_dir)/settings.json"; }

# 설치 대상: repo 내 소스 → ~/.claude/scripts 의 symlink 이름
# 형식: "<repo 상대경로>|<scripts 내 파일명>"
_cls_links() {
  printf '%s\n' \
    "bin/session-picker.py|session-picker.py" \
    "hooks/track-session.sh|track-session.sh" \
    "hooks/backfill-sessions.sh|backfill-sessions.sh"
}

# ── 1. preflight ─────────────────────────────────────────────────────────────
cls_preflight() {
  local rc=0
  if ! command -v python3 >/dev/null 2>&1; then
    echo "cls: python3 미설치 (필수)" >&2; rc=1
  elif ! python3 -c 'import curses' >/dev/null 2>&1; then
    echo "cls: python3 curses 모듈 없음 (Ubuntu: apt install python3-curses)" >&2; rc=1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "cls: jq 미설치 (필수 — macOS: brew install jq / Ubuntu: apt install jq)" >&2; rc=1
  fi
  if ! command -v claude >/dev/null 2>&1; then
    echo "cls: 경고 — claude CLI를 PATH에서 찾지 못함. resume 시 PATH 확인 필요" >&2
  fi
  # macOS BSD 도구 경고 (track-session.sh는 python3로 대체했으므로 치명적 아님)
  if [ "$(uname -s 2>/dev/null)" = "Darwin" ]; then
    echo "cls: macOS 감지 — track-session.sh는 python3 기반이라 coreutils 불필요" >&2
  fi
  return $rc
}

# ── 2. rc 파일 감지 ──────────────────────────────────────────────────────────
cls_detect_rc() {
  local shell_name rc
  shell_name="${CLS_SHELL:-$(basename "${SHELL:-bash}")}"
  case "$shell_name" in
    zsh)  rc="${ZDOTDIR:-$HOME}/.zshrc" ;;
    bash)
      if [ "$(uname -s 2>/dev/null)" = "Darwin" ]; then rc="$HOME/.bash_profile"; else rc="$HOME/.bashrc"; fi ;;
    *)
      if [ "$(uname -s 2>/dev/null)" = "Darwin" ]; then rc="$HOME/.zshrc"; else rc="$HOME/.bashrc"; fi ;;
  esac
  printf '%s' "$rc"
}

# ── 3. alias 마커블록 멱등 주입 ──────────────────────────────────────────────
cls_inject_alias() {
  local rc="$1" tmp
  [ -e "$rc" ] || : > "$rc"
  # 1회성 백업
  [ -f "$rc.cls.bak" ] || cp -p "$rc" "$rc.cls.bak" 2>/dev/null || true
  tmp="$(mktemp "${rc}.cls.XXXXXX")"
  # 기존 마커블록 제거 (멱등) — 마커 사이 범위 삭제
  awk -v s="$MARK_START" -v e="$MARK_END" '
    $0==s {skip=1} skip && $0==e {skip=0; next} !skip {print}
  ' "$rc" > "$tmp"
  # 신규 블록 append
  {
    printf '%s\n' "$MARK_START"
    printf '%s\n' "# Managed by cls installer — do not edit between these markers."
    printf '%s\n' "alias cls='python3 ~/.claude/scripts/session-picker.py'"
    printf '%s\n' "$MARK_END"
  } >> "$tmp"
  mv -f "$tmp" "$rc"
}

# ── 4. mkdir + 백업 + symlink ────────────────────────────────────────────────
# 타깃이 'repo를 가리키는 우리 symlink'가 아니면 백업 후 교체.
cls_symlink_scripts() {
  local sdir entry src name target
  sdir="$(_scripts_dir)"
  mkdir -p "$sdir"
  while IFS='|' read -r src name; do
    [ -n "$name" ] || continue
    target="$sdir/$name"
    if [ -L "$target" ] && [ "$(readlink "$target")" = "$CLS_HOME/$src" ]; then
      :  # 이미 우리 symlink → 백업 불필요 (멱등)
    elif [ -e "$target" ] || [ -L "$target" ]; then
      cp -P "$target" "$target.cls.bak" 2>/dev/null || true  # 기존 파일/타 symlink 백업
    fi
    ln -sf "$CLS_HOME/$src" "$target"
  done < <(_cls_links)
}

# ── 5. settings.json 병합 ────────────────────────────────────────────────────
cls_merge_settings() {
  local settings cmd tmp
  settings="$(_settings_file)"
  cmd="bash $(_scripts_dir)/track-session.sh"
  mkdir -p "$(_claude_dir)"
  # 부재/빈 파일 → {} 시드
  if [ ! -s "$settings" ]; then printf '{}' > "$settings"; fi
  # 1회성 백업
  [ -f "$settings.cls.bak" ] || cp -p "$settings" "$settings.cls.bak" 2>/dev/null || true
  tmp="$(mktemp "${settings}.cls.XXXXXX")"
  if jq --arg cmd "$cmd" --arg mode add -f "$CLS_HOME/lib/merge.jq" "$settings" > "$tmp" 2>/dev/null \
       && [ -s "$tmp" ] && jq -e . "$tmp" >/dev/null 2>&1; then
    mv -f "$tmp" "$settings"
    return 0
  else
    rm -f "$tmp"
    echo "cls: settings.json 병합 실패 — 원본 유지 ($settings)" >&2
    return 1
  fi
}

# ── main ─────────────────────────────────────────────────────────────────────
cls_install_main() {
  local rc
  cls_preflight || { echo "cls: 필수 의존성 누락 — 설치 중단" >&2; return 1; }
  rc="$(cls_detect_rc)"
  cls_inject_alias "$rc"
  cls_symlink_scripts
  cls_merge_settings || true
  # registry 시딩 (활성 세션만 — 한계는 README)
  bash "$CLS_HOME/hooks/backfill-sessions.sh" >/dev/null 2>&1 || true
  echo "cls 설치 완료."
  echo "  - alias: $rc (새 셸 또는 'source $rc' 후 cls 사용)"
  echo "  - scripts: $(_scripts_dir)/ (symlink → $CLS_HOME)"
  echo "  - settings: $(_settings_file) (Stop hook 등록)"
  echo "  - 백업: <파일>.cls.bak"
  echo "  registry는 이후 Claude Code를 사용하며 자동으로 채워집니다 (과거 세션 일괄 import 아님)."
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  cls_install_main "$@"
fi
