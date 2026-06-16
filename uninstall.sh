#!/usr/bin/env bash
# uninstall.sh — cls 제거 (install.sh의 역순, 사용자 데이터 비파괴)
#
# - alias 마커블록 제거 (legacy bare alias는 무변경)
# - settings.json에서 canonical Stop hook만 제거 (무관 hook 보존)
# - 우리 symlink 제거 + .cls.bak 백업 복원
# - registry/sessions/projects 등 사용자 데이터는 절대 삭제 안 함
# - repo(clone)도 그대로 둠
set -uo pipefail

CLS_HOME="${CLS_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
# install.sh의 헬퍼(_claude_dir/_scripts_dir/_settings_file/_cls_links/MARK_*/cls_detect_rc) 재사용.
# install.sh의 sourcing guard가 main 실행을 막는다.
# shellcheck source=install.sh
source "$CLS_HOME/install.sh"

# ── alias 마커블록 제거 ──────────────────────────────────────────────────────
cls_remove_alias() {
  local rc="$1" tmp
  [ -f "$rc" ] || return 0
  tmp="$(mktemp "${rc}.cls.XXXXXX")"
  awk -v s="$MARK_START" -v e="$MARK_END" '
    $0==s {skip=1} skip && $0==e {skip=0; next} !skip {print}
  ' "$rc" > "$tmp"
  mv -f "$tmp" "$rc"
}

# ── settings.json에서 canonical hook 제거 ────────────────────────────────────
cls_unmerge_settings() {
  local settings cmd tmp
  settings="$(_settings_file)"
  [ -s "$settings" ] || return 0
  cmd="bash $(_scripts_dir)/track-session.sh"
  tmp="$(mktemp "${settings}.cls.XXXXXX")"
  if jq --arg cmd "$cmd" --arg mode remove -f "$CLS_HOME/lib/merge.jq" "$settings" > "$tmp" 2>/dev/null \
       && [ -s "$tmp" ] && jq -e . "$tmp" >/dev/null 2>&1; then
    mv -f "$tmp" "$settings"
    return 0
  else
    rm -f "$tmp"
    echo "cls: settings.json 정리 실패 — 원본 유지" >&2
    return 1
  fi
}

# ── 우리 symlink 제거 + 백업 복원 ────────────────────────────────────────────
cls_restore_scripts() {
  local sdir src name target
  sdir="$(_scripts_dir)"
  while IFS='|' read -r src name; do
    [ -n "$name" ] || continue
    target="$sdir/$name"
    # repo를 가리키는 우리 symlink만 제거 (사용자 자체 파일은 건드리지 않음)
    if [ -L "$target" ] && [ "$(readlink "$target")" = "$CLS_HOME/$src" ]; then
      rm -f "$target"
    fi
    # install이 남긴 백업이 있으면 원복
    if [ -e "$target.cls.bak" ] || [ -L "$target.cls.bak" ]; then
      mv -f "$target.cls.bak" "$target"
    fi
  done < <(_cls_links)
}

cls_uninstall_main() {
  local rc
  rc="$(cls_detect_rc)"
  cls_remove_alias "$rc"
  cls_unmerge_settings || true
  cls_restore_scripts
  echo "cls 제거 완료. registry/sessions/projects 등 사용자 데이터는 보존됨."
  echo "  repo($CLS_HOME)는 그대로 둡니다. 'source $rc' 또는 셸 재시작으로 alias 해제."
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  cls_uninstall_main "$@"
fi
