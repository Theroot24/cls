"""session-picker.py 순수 함수 + resume builder 테스트 (TDD).

실행: python3 -m unittest tests.test_session_picker  (repo 루트에서)
또는: python3 -m unittest discover -s tests

shorten_path 등은 docstring이 아니라 **실제 출력**을 pin한다(docstring은 부정확).
build_resume_argv / _valid_session_id 는 Phase 2에서 신규 추가되는 함수.
"""
import importlib.util
import json
import os
import tempfile
import unittest
from pathlib import Path

SP_PATH = Path(__file__).resolve().parent.parent / "bin" / "session-picker.py"


def load_module():
    spec = importlib.util.spec_from_file_location("session_picker", SP_PATH)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


sp = load_module()


class TestShortenPath(unittest.TestCase):
    def setUp(self):
        self._home = os.environ.get("HOME")
        os.environ["HOME"] = "/home/testuser"

    def tearDown(self):
        if self._home is not None:
            os.environ["HOME"] = self._home

    def test_deep_workspace_keeps_last_two_verbatim(self):
        # 실제 동작: 마지막 2개 segment는 그대로, 나머지는 첫 글자
        self.assertEqual(
            sp.shorten_path("/home/testuser/Documents/workspace/example/project-a"),
            "~/D/w/example/project-a",
        )

    def test_deeper_workspace(self):
        self.assertEqual(
            sp.shorten_path("/home/testuser/Documents/workspace/example/project-a/service-b"),
            "~/D/w/e/project-a/service-b",
        )

    def test_home_itself(self):
        self.assertEqual(sp.shorten_path("/home/testuser"), "~/")

    def test_one_level(self):
        self.assertEqual(sp.shorten_path("/home/testuser/a"), "~/a")

    def test_two_level(self):
        self.assertEqual(sp.shorten_path("/home/testuser/a/b"), "~/a/b")

    def test_outside_home_keeps_last_two(self):
        self.assertEqual(sp.shorten_path("/var/log/x"), "log/x")

    def test_outside_home_single(self):
        self.assertEqual(sp.shorten_path("/etc"), "/etc")

    def test_prefix_bug_documented(self):
        # 알려진 버그: 'testuser-backup'을 home 하위로 오인 (display 전용, 무해)
        # 현재 동작을 문서화 — 수정은 본 plan scope 밖
        self.assertEqual(sp.shorten_path("/home/testuser-backup/x"), "~/-backup/x")


class TestProcessAwaySummary(unittest.TestCase):
    def test_too_short_returns_none(self):
        self.assertIsNone(sp._process_away_summary("hi"))

    def test_strips_recap_tail(self):
        self.assertEqual(
            sp._process_away_summary("this is a real summary (disable recaps now)"),
            "this is a real summary",
        )

    def test_strips_image_token(self):
        self.assertEqual(sp._process_away_summary("a [Image #1] b cde fgh"), "a b cde fgh")

    def test_pipe_replaced_with_slash(self):
        self.assertEqual(
            sp._process_away_summary("x|y|z is a long enough text here"),
            "x/y/z is a long enough text here",
        )

    def test_truncates_to_80(self):
        out = sp._process_away_summary("w" * 200)
        self.assertEqual(len(out), 80)


class TestSplitTeamSuffix(unittest.TestCase):
    def test_with_team(self):
        self.assertEqual(sp._split_team_suffix("foo bar (TeamX)"), ("foo bar", " (TeamX)"))

    def test_without_paren(self):
        self.assertEqual(sp._split_team_suffix("no paren here"), ("no paren here", ""))

    def test_last_paren_only(self):
        self.assertEqual(sp._split_team_suffix("a (b) (c)"), ("a (b)", " (c)"))


class TestLatestAwaySummary(unittest.TestCase):
    def _write_jsonl(self, lines):
        f = tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False, encoding="utf-8")
        for obj in lines:
            f.write(json.dumps(obj) + "\n")
        f.close()
        self.addCleanup(os.unlink, f.name)
        return f.name

    def test_missing_file_returns_none(self):
        self.assertIsNone(sp._latest_away_summary("/nonexistent/path.jsonl"))

    def test_last_wins(self):
        path = self._write_jsonl([
            {"type": "system", "subtype": "away_summary", "content": "first summary line here"},
            {"type": "user", "message": {"content": "noise"}},
            {"type": "system", "subtype": "away_summary", "content": "second summary line here"},
        ])
        self.assertEqual(sp._latest_away_summary(path), "second summary line here")

    def test_non_json_lines_skipped(self):
        path = self._write_jsonl([
            {"type": "system", "subtype": "away_summary", "content": "valid summary content"},
        ])
        with open(path, "a") as fh:
            fh.write("not json at all\n")
        self.assertEqual(sp._latest_away_summary(path), "valid summary content")

    def test_wrong_type_skipped(self):
        path = self._write_jsonl([
            {"type": "assistant", "subtype": "away_summary", "content": "should be ignored x"},
        ])
        self.assertIsNone(sp._latest_away_summary(path))


class TestParseRegistry(unittest.TestCase):
    def _write_registry(self, body):
        f = tempfile.NamedTemporaryFile("w", suffix=".md", delete=False, encoding="utf-8")
        f.write(body)
        f.close()
        self.addCleanup(os.unlink, f.name)
        return f.name

    def setUp(self):
        self._orig = sp.REGISTRY

    def tearDown(self):
        sp.REGISTRY = self._orig

    def test_missing_file_returns_empty(self):
        sp.REGISTRY = "/nonexistent/registry.md"
        self.assertEqual(sp.parse_registry(), [])

    def test_parses_rows_and_sorts_desc(self):
        sp.REGISTRY = self._write_registry(
            "# Claude Code Session Registry\n\n"
            "| Path | Session ID | Last Chat | Description |\n"
            "|---|---|---|---|\n"
            "| /a/b | `id-1111-2222` | 2026-06-01 10:00 | older |\n"
            "| /c/d | `id-3333-4444` | 2026-06-02 11:00 | newer |\n"
        )
        rows = sp.parse_registry()
        self.assertEqual(len(rows), 2)
        # last_chat 내림차순
        self.assertEqual(rows[0]["id"], "id-3333-4444")
        self.assertEqual(rows[0]["desc"], "newer")
        self.assertEqual(rows[1]["path"], "/a/b")

    def test_header_and_malformed_skipped(self):
        sp.REGISTRY = self._write_registry(
            "# header\n| Path | Session ID | Last Chat | Description |\n"
            "|---|---|---|---|\n"
            "malformed line without pipes\n"
            "| /x/y | `sid-abcd-1234` | 2026-06-01 09:00 | ok |\n"
        )
        rows = sp.parse_registry()
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["id"], "sid-abcd-1234")

    def test_empty_desc_allowed(self):
        sp.REGISTRY = self._write_registry(
            "|---|---|---|---|\n| /p | `sid-0000-1111` | 2026-06-01 08:00 |  |\n"
        )
        rows = sp.parse_registry()
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["desc"], "")


# ===== 신규 함수 (Phase 2 Red) =====

class TestValidSessionId(unittest.TestCase):
    def test_valid_uuid(self):
        self.assertTrue(sp._valid_session_id("0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d"))

    def test_valid_short_hex(self):
        self.assertTrue(sp._valid_session_id("abcd1234"))

    def test_empty_invalid(self):
        self.assertFalse(sp._valid_session_id(""))

    def test_injection_semicolon(self):
        self.assertFalse(sp._valid_session_id("abc; rm -rf ~"))

    def test_injection_subshell(self):
        self.assertFalse(sp._valid_session_id("$(rm -rf /)"))

    def test_injection_backtick(self):
        self.assertFalse(sp._valid_session_id("`whoami`"))

    def test_space_invalid(self):
        self.assertFalse(sp._valid_session_id("aa bb"))


class TestBuildResumeArgv(unittest.TestCase):
    SID = "0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d"

    def test_direct_exec_when_claude_found(self):
        argv = sp.build_resume_argv(self.SID, resolver=lambda: "/usr/local/bin/claude")
        # 셸 없이 claude 직접 exec → injection 불가
        self.assertEqual(argv, ["/usr/local/bin/claude", "--resume", self.SID])

    def test_shell_fallback_when_not_found(self):
        argv = sp.build_resume_argv(self.SID, resolver=lambda: None, shell="/bin/zsh")
        self.assertEqual(argv[0], "/bin/zsh")
        self.assertEqual(argv[1], "-ic")
        self.assertIn("claude --resume", argv[2])
        self.assertIn(self.SID, argv[2])

    def test_invalid_session_id_raises(self):
        # injection 시도 → ValueError (exec 도달 안 함)
        with self.assertRaises(ValueError):
            sp.build_resume_argv("abc; rm -rf ~", resolver=lambda: "/usr/local/bin/claude")

    def test_fallback_quotes_session_id(self):
        # 폴백 경로도 shlex.quote로 이중 방어 (정상 UUID는 quote 불필요하지만 형식 검증)
        argv = sp.build_resume_argv(self.SID, resolver=lambda: None, shell="/bin/bash")
        import shlex
        self.assertEqual(argv[2], f"claude --resume {shlex.quote(self.SID)}")


if __name__ == "__main__":
    unittest.main()
