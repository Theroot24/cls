# cls — Claude Code Session Picker

터미널에서 `cls`를 치면 Claude Code 세션 목록을 curses TUI로 보여주고, 화살표로 선택해 `claude --resume`으로 다시 이어서 작업할 수 있는 도구입니다.

macOS / Ubuntu 어디서나 **clone → `./install.sh` → `cls`** 로 동일하게 동작합니다.

```
 Claude Code Sessions
 ↑↓ Navigate   ⏎ Resume   q Quit
 ──────────────────────────────────────────────
   Project                  Last Chat          Session ID    Description
 ▸ ~/D/w/example/cls        2026-06-16 11:58   0a1b2c3d…     update parser logic
   ~/D/w/example/project-a  2026-06-16 10:50   1f2e3d4c…     (project-a)
```

## Quick Start

```bash
git clone <this-repo> cls
cd cls
./install.sh
# 새 터미널을 열거나
source ~/.bashrc      # (zsh면 source ~/.zshrc)
cls
```

## 의존성

| 도구 | 용도 | macOS | Ubuntu |
|---|---|---|---|
| `python3` (+ `curses`) | TUI 본체 + 트래킹 hook | 시스템 python3에 포함 | `apt install python3` (curses 별도면 `apt install python3-curses`) |
| `jq` | sessions/settings JSON 파싱 | `brew install jq` | `apt install jq` |
| `claude` | resume 실행 (`claude --resume`) | Claude Code 설치 시 제공 | 동일 |

`./install.sh`가 시작 시 위 의존성을 점검하고, 누락 시 안내합니다.

## 동작 원리

`install.sh`는 **symlink 전략**으로 설치합니다:

1. **alias 주입** — rc 파일(`~/.bashrc` 또는 zsh면 `~/.zshrc`)에 마커블록(`# >>> cls >>>` … `# <<< cls <<<`)으로 `alias cls='python3 ~/.claude/scripts/session-picker.py'`를 멱등 주입.
2. **symlink** — repo의 `bin/session-picker.py`, `hooks/track-session.sh`, `hooks/backfill-sessions.sh`를 `~/.claude/scripts/`로 symlink. 기존 동일 이름 파일이 있으면 `<파일>.cls.bak`로 백업 후 교체.
3. **Stop hook 등록** — `~/.claude/settings.json`의 `Stop` hook에 `track-session.sh`를 멱등 병합(무관한 다른 hook은 정확 명령 일치로 보존).
4. **registry 시딩** — `backfill-sessions.sh` 실행.

세션 목록 데이터는 `~/.claude/session-registry.md`에 마크다운 표로 누적되며, Claude Code 세션이 끝날 때마다 **Stop hook**(`track-session.sh`)이 한 줄씩 upsert합니다(최대 50건).

> **단일 진실 소스**: alias와 settings.json은 안정적인 `~/.claude/scripts/*` 경로를 가리키고, 그 경로는 repo를 symlink합니다. 따라서 repo에서 `git pull`하면 별도 재설치 없이 즉시 반영됩니다.

## 크로스플랫폼(macOS) 대응

`track-session.sh`의 GNU 전용 부분은 전부 이식 가능하게 교체되어 macOS/Ubuntu에서 동일하게 동작합니다:

- `stat -c '%Y'` + `date -d @` → `python3` one-liner (mtime 포맷)
- `tac` → `python3`의 `reversed()` (최신 user 프롬프트 탐색)
- `declare -A` (bash 4+ 연관배열) → bash 3.2 호환 함수 — macOS 기본 `/bin/bash`(3.2)에서도 크래시 없음
- resume는 `claude` 바이너리를 직접 찾아 exec(셸 비의존, injection 방어). 못 찾으면 사용자 로그인 셸(`$SHELL -ic`)로 폴백.

python3는 이미 의존성이므로 신규 런타임 의존성은 없습니다. macOS에서 `coreutils`를 별도 설치할 필요가 없습니다.

## 한계 / 주의사항

- **registry는 과거 세션을 일괄 import하지 않습니다.** `backfill-sessions.sh`는 설치 시점의 활성 세션 정도만 등록합니다. 목록은 이후 Claude Code를 사용하며 **세션 종료 시마다 자동으로 채워집니다.**
- **세션 목록은 호스트별(per-host)입니다.** 레지스트리에는 해당 머신의 절대경로가 기록되며, 다른 호스트에서 동일 세션을 resume할 수는 없습니다(세션 데이터는 머신 로컬).
- **클론을 옮기면 재설치가 필요합니다.** symlink가 repo 경로를 가리키므로, 클론을 이동/이름변경한 경우 `./install.sh`를 다시 실행해 symlink를 갱신하세요(alias·settings.json은 안정 경로라 수동 편집 불필요).

## 제거

```bash
./uninstall.sh
```

- alias 마커블록 제거, `track-session.sh` Stop hook만 제거(다른 hook 보존), 우리 symlink 제거 후 `.cls.bak` 백업 복원.
- `~/.claude/session-registry.md`, `~/.claude/sessions/`, `~/.claude/projects/` 등 사용자 데이터와 clone은 **삭제하지 않습니다.**

## 개발 / 테스트

```bash
# Python (순수 함수 + resume builder)
python3 -m unittest tests.test_session_picker

# Shell (hook 하드닝 / settings 병합 / install / uninstall)
bash tests/test_track_session.sh
bash tests/test_settings_merge.sh
bash tests/test_install.sh
bash tests/test_uninstall.sh
```

모든 셸 테스트는 임시 `HOME`에서 격리 실행되어 실제 환경에 영향을 주지 않습니다.

## 구조

```
cls/
├── install.sh / uninstall.sh   # 설치/제거 (멱등, 백업)
├── bin/session-picker.py       # cls TUI 본체 (curses)
├── hooks/
│   ├── track-session.sh        # Stop hook — registry 갱신 (크로스플랫폼)
│   └── backfill-sessions.sh    # registry 부트스트랩
├── lib/merge.jq                # settings.json Stop hook 멱등 병합
└── tests/                      # TDD 테스트
```
