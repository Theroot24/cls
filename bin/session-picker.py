#!/usr/bin/env python3
"""Claude Code Session Picker — Interactive TUI"""
import curses
import json
import os
import re
import shlex
import shutil
import sys
import time
from typing import Optional

REGISTRY = os.path.expanduser("~/.claude/session-registry.md")
PROJECTS_DIR = os.path.expanduser("~/.claude/projects")

# track-session.sh:75 이식 (bash 내 `\$` → Python `$`, end-of-string anchor)
TAIL_PAREN_RE = re.compile(r'\s*\((?:disable recaps|turn off recaps)[^)]*\)\s*$')
# track-session.sh:76
IMG_TOKEN_RE = re.compile(r'\[Image[^\]]*\]\s*')
# track-session.sh:125 가 부착하는 ` (TEAM_NAME)` suffix 추출
TEAM_SUFFIX_RE = re.compile(r'\s*\(([^()]+)\)\s*$')


def _jsonl_path(cwd: str, session_id: str) -> str:
    return f"{PROJECTS_DIR}/{cwd.replace('/', '-')}/{session_id}.jsonl"


def _split_team_suffix(desc: str) -> tuple[str, str]:
    m = TEAM_SUFFIX_RE.search(desc)
    if not m:
        return desc, ""
    base = desc[: m.start()].rstrip()
    return base, " (" + m.group(1) + ")"


def _process_away_summary(content: str) -> Optional[str]:
    s = TAIL_PAREN_RE.sub("", content).strip()
    s = IMG_TOKEN_RE.sub("", s).strip()
    s = " ".join(s.split()).replace("|", "/")
    if len(s) <= 5:
        return None
    return s[:80]


def _latest_away_summary(path: str) -> Optional[str]:
    if not os.path.isfile(path):
        return None
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            lines = f.readlines()
    except Exception:
        return None
    for line in reversed(lines):
        if '"away_summary"' not in line:
            continue
        try:
            d = json.loads(line)
        except Exception:
            continue
        if d.get("type") != "system" or d.get("subtype") != "away_summary":
            continue
        content = (d.get("content") or "").strip()
        if not content:
            continue
        return _process_away_summary(content)
    return None


def _mtime_is_stale(path: str, last_chat: str) -> bool:
    """파일 mtime이 registry last_chat 이전이면 스캔 생략 (변화 없음).

    last_chat 포맷: 'YYYY-MM-DD HH:MM' (로컬 시간, track-session.sh:50).
    """
    try:
        last_epoch = time.mktime(time.strptime(last_chat.strip(), "%Y-%m-%d %H:%M"))
        file_mtime = os.stat(path).st_mtime
    except Exception:
        return False
    return file_mtime <= last_epoch + 60  # 1분 슬랙


def _overlay_away_summary(sessions: list) -> None:
    for s in sessions:
        try:
            path = _jsonl_path(s["path"], s["id"])
            if not os.path.isfile(path):
                continue
            if _mtime_is_stale(path, s["last_chat"]):
                continue
            new_base = _latest_away_summary(path)
            if not new_base:
                continue
            _, team_suffix = _split_team_suffix(s["desc"])
            s["desc"] = new_base + team_suffix
        except Exception:
            continue

def shorten_path(full_path):
    """긴 경로를 ~ 기준 상대경로로 축약
    /home/user/Documents/workspace/example/project-a → ~/D/w/e/project-a
    /home/.../project-a/service-b → ~/D/w/e/project-a/service-b
    """
    home = os.path.expanduser('~')
    if full_path.startswith(home):
        rel = full_path[len(home):]
        parts = rel.strip('/').split('/')
        # 마지막 2개는 유지, 나머지는 첫 글자로 축약
        if len(parts) > 2:
            short = '/'.join(p[0] for p in parts[:-2])
            return f"~/{short}/{'/'.join(parts[-2:])}"
        return f"~/{'/'.join(parts)}"
    # home 밖이면 마지막 2개만
    parts = full_path.rstrip('/').split('/')
    return '/'.join(parts[-2:]) if len(parts) >= 2 else full_path

def parse_registry():
    if not os.path.exists(REGISTRY):
        return []
    sessions = []
    with open(REGISTRY) as f:
        for line in f:
            # | path | `session-id` | timestamp | description |
            m = re.match(r'\| ([^|]+) \| `([^`]+)` \| ([^|]+) \| ([^|]*) \|', line.strip())
            if m:
                sessions.append({
                    'path': m.group(1).strip(),
                    'id': m.group(2).strip(),
                    'last_chat': m.group(3).strip(),
                    'desc': m.group(4).strip(),
                })
    sessions.sort(key=lambda s: s['last_chat'], reverse=True)
    return sessions

def main(stdscr):
    curses.curs_set(0)
    curses.use_default_colors()
    curses.init_pair(1, curses.COLOR_BLACK, curses.COLOR_CYAN)
    curses.init_pair(2, curses.COLOR_CYAN, -1)
    curses.init_pair(3, curses.COLOR_GREEN, -1)

    sessions = parse_registry()
    try:
        _overlay_away_summary(sessions)
    except Exception:
        pass  # overlay 실패 시에도 기존 desc로 정상 동작
    if not sessions:
        stdscr.addstr(0, 0, "  No sessions found. Run Claude Code first.")
        stdscr.getch()
        return None

    # Project 컬럼 폭: 가장 긴 경로 기준 동적 계산 (최소 22, 최대 50)
    short_paths = {s['id']: shorten_path(s['path']) for s in sessions}
    path_col_w = max(len(p) for p in short_paths.values())
    path_col_w = max(22, min(path_col_w + 2, 50))

    current = 0
    scroll_offset = 0

    while True:
        stdscr.clear()
        h, w = stdscr.getmaxyx()

        # Header
        title = " Claude Code Sessions "
        stdscr.addstr(0, (w - len(title)) // 2, title, curses.A_BOLD | curses.color_pair(2))
        stdscr.addstr(1, 2, "↑↓ Navigate   ⏎ Resume   q Quit", curses.A_DIM)
        stdscr.addstr(2, 0, "─" * min(w, 120))

        # Column header
        col_hdr = f"  {'Project':<{path_col_w}} {'Last Chat':<18} {'Session ID':<12} {'Description'}"
        stdscr.addstr(3, 0, col_hdr[:w-1], curses.A_DIM | curses.A_UNDERLINE)

        # Scroll handling
        visible = h - 5  # header(4) + bottom margin(1)
        if current < scroll_offset:
            scroll_offset = current
        elif current >= scroll_offset + visible:
            scroll_offset = current - visible + 1

        # Session list
        for i in range(scroll_offset, min(len(sessions), scroll_offset + visible)):
            s = sessions[i]
            y = (i - scroll_offset) + 4

            short_path = short_paths[s['id']]

            if i == current:
                attr = curses.color_pair(1) | curses.A_BOLD
                stdscr.addstr(y, 0, " " * min(w, 120), attr)
                prefix = "▸ "
            else:
                attr = curses.A_NORMAL
                prefix = "  "

            line = f"{prefix}{short_path:<{path_col_w}} {s['last_chat']:<18} {s['id'][:8]}…   {s['desc']}"
            stdscr.addstr(y, 0, line[:w-1], attr)

        # Footer: 선택된 세션의 전체 경로 표시
        footer = f" Path: {sessions[current]['path']}"
        stdscr.addstr(h-1, 0, footer[:w-1], curses.A_DIM | curses.color_pair(3))

        stdscr.refresh()

        key = stdscr.getch()
        if key == curses.KEY_UP and current > 0:
            current -= 1
        elif key == curses.KEY_DOWN and current < len(sessions) - 1:
            current += 1
        elif key in (curses.KEY_ENTER, 10, 13):
            return sessions[current]
        elif key in (ord('q'), ord('Q'), 27):
            return None

# 세션 ID 검증 (resume injection 방어) — registry id 형식: hex + dash
_SESSION_ID_RE = re.compile(r'[0-9a-fA-F-]{8,64}')


def _valid_session_id(sid: str) -> bool:
    return bool(_SESSION_ID_RE.fullmatch(sid or ''))


def _resolve_claude():
    """claude 바이너리 경로를 PATH 보강 후 탐색. 못 찾으면 None.

    macOS(zsh 기본)에서 ~/.local/bin·Homebrew 경로를 PATH에 보강해
    bash -ic 의존 없이도 claude를 찾는다.
    """
    extra = [
        os.path.expanduser('~/.local/bin'),
        os.path.expanduser('~/.claude/local/bin'),
        '/opt/homebrew/bin',
        '/usr/local/bin',
    ]
    path = os.environ.get('PATH', '')
    augmented = os.pathsep.join(([path] if path else []) + extra)
    return shutil.which('claude', path=augmented)


def build_resume_argv(session_id, *, shell=None, resolver=None):
    """`claude --resume <id>` 실행용 argv 생성 (크로스플랫폼 + injection 방어).

    - session_id 형식 위반 시 ValueError (exec 도달 차단).
    - claude 바이너리를 찾으면 셸 없이 직접 exec → injection 불가 (사용자 승인 방식).
    - 못 찾으면 사용자 로그인 셸($SHELL)의 `-ic`로 대체(기존 bash -ic 동작 보존,
      단 zsh-Mac 호환). session_id는 shlex.quote로 이중 방어.
    - os.execvp는 현재 os.environ(cls를 띄운 인터랙티브 셸 환경)을 상속하므로
      직접 exec에서도 claude가 PATH·env를 그대로 받아 기존 동작과 동등.
    """
    if not _valid_session_id(session_id):
        raise ValueError(f"invalid session id: {session_id!r}")
    resolve = resolver if resolver is not None else _resolve_claude
    claude = resolve()
    if claude:
        return [claude, '--resume', session_id]
    sh = shell or os.environ.get('SHELL') or '/bin/bash'
    return [sh, '-ic', f'claude --resume {shlex.quote(session_id)}']


if __name__ == '__main__':
    selected = curses.wrapper(main)
    if selected:
        path = selected['path']
        if not os.path.isdir(path):
            print(f"Error: directory not found: {path}")
            sys.exit(1)
        try:
            argv = build_resume_argv(selected['id'])
        except ValueError as e:
            print(f"Error: {e}")
            sys.exit(1)
        os.chdir(path)
        os.execvp(argv[0], argv)
