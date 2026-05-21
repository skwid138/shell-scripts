#!/usr/bin/env python3
"""Unit tests for agent/permission_audit_core.py."""

from __future__ import annotations

import contextlib
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
FIXTURE_DIR = Path(__file__).resolve().parent / "fixtures" / "permission-audit"
sys.path.insert(0, str(REPO_ROOT / "agent"))

import permission_audit_core as core  # noqa: E402


class PermissionAuditParsingTest(unittest.TestCase):
    def test_parse_permission_line_handles_complex_patterns(self) -> None:
        line = (
            'INFO 2026-05-21T10:00:06 +1ms service=permission permission=bash '
            'pattern=printf "a=b" | sed "s/ action=/x/" action={"permission":"bash",'
            '"pattern":"~/code/scripts/agent/*","action":"ask"} evaluated'
        )

        event = core.parse_permission_line(line, source="fixture.log", sequence=7)

        self.assertIsNotNone(event)
        assert event is not None
        self.assertEqual(event.timestamp, "2026-05-21T10:00:06")
        self.assertEqual(event.permission, "bash")
        self.assertEqual(event.pattern, 'printf "a=b" | sed "s/ action=/x/"')
        self.assertEqual(event.matched_rule, "~/code/scripts/agent/*")
        self.assertEqual(event.action, "ask")

    def test_parse_all_correlation_regex_line_types(self) -> None:
        direct = core.parse_session_agent_line(
            "INFO 2026-05-21T10:00:00 +1ms service=session id=ses_direct title=Main agent=gandalf created",
            source="fixture.log",
            sequence=1,
        )
        subagent = core.parse_session_agent_line(
            "INFO 2026-05-21T10:01:00 +1ms service=session id=ses_sub title=Research (@legolas subagent) created",
            source="fixture.log",
            sequence=2,
        )
        council = core.parse_session_agent_line(
            "INFO 2026-05-21T10:02:00 +1ms service=session id=ses_council title=council: openai/gpt-5.5 created",
            source="fixture.log",
            sequence=3,
        )
        llm = core.parse_session_agent_line(
            "INFO 2026-05-21T10:03:00 +1ms service=llm providerID=openai modelID=gpt session.id=ses_resume path=x agent=aragorn",
            source="fixture.log",
            sequence=4,
        )
        prompt = core.parse_prompt_line(
            "INFO 2026-05-21T10:04:00 +1ms service=session.prompt session.id=ses_resume step=3 loop",
            source="fixture.log",
            sequence=5,
        )

        self.assertEqual(direct.agent, "gandalf")
        self.assertEqual(subagent.agent, "legolas")
        self.assertEqual(council.agent, "council")
        self.assertEqual(llm.agent, "aragorn")
        self.assertEqual(prompt.session_id, "ses_resume")

    def test_invalid_permission_json_is_skipped(self) -> None:
        line = (
            "INFO 2026-05-21T10:00:06 +1ms service=permission permission=bash "
            "pattern=foo action={not-json} evaluated"
        )
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertIsNone(core.parse_permission_line(line, source="fixture.log", sequence=1))


class PermissionAuditBehaviorTest(unittest.TestCase):
    def test_temporal_correlation_handles_single_multi_and_resumed_sessions(self) -> None:
        report = core.audit_logs(
            FIXTURE_DIR,
            start_date="2026-05-21",
            end_date="2026-05-21",
            action_filter="all",
        )

        by_pattern = {entry["pattern"]: entry for entry in report["entries"]}

        self.assertEqual(by_pattern["/Users/hunter/code/scripts/lib/common.sh action= substring"]["agents"], ["legolas"])
        self.assertEqual(by_pattern["/Users/hunter/.config/opencode/opencode.json"]["agents"], ["aragorn"])
        self.assertEqual(by_pattern["/tmp/before-prompt.txt"]["agents"], [None])
        self.assertEqual(by_pattern["/tmp/same-millisecond.txt"]["agents"], ["legolas"])

    def test_aggregation_counts_unique_agents_and_sessions(self) -> None:
        report = core.audit_logs(
            FIXTURE_DIR,
            start_date="2026-05-21",
            end_date="2026-05-21",
            action_filter="ask",
        )

        entry = next(
            item
            for item in report["entries"]
            if item["pattern"] == "~/code/scripts/agent/jira-fetch-ticket.sh --all BIXB-20084"
        )
        self.assertEqual(entry["count"], 2)
        self.assertEqual(entry["agents"], ["gandalf", "legolas"])
        self.assertEqual(entry["session_ids"], ["ses_gandalf", "ses_legolas"])
        self.assertEqual(entry["first_seen"], "2026-05-21T10:00:06")
        self.assertEqual(entry["last_seen"], "2026-05-21T10:01:06")

    def test_date_filtering_uses_line_timestamps_and_previous_day_prefilter(self) -> None:
        report = core.audit_logs(
            FIXTURE_DIR,
            start_date="2026-05-21",
            end_date="2026-05-21",
            action_filter="all",
        )
        patterns = {entry["pattern"] for entry in report["entries"]}

        self.assertIn("/tmp/overnight.txt", patterns)
        self.assertNotIn("/tmp/previous-day.txt", patterns)
        self.assertNotIn("/tmp/next-day.txt", patterns)

    def test_action_filter_uses_inner_json_action_key(self) -> None:
        ask_report = core.audit_logs(FIXTURE_DIR, "2026-05-21", "2026-05-21", action_filter="ask")
        deny_report = core.audit_logs(FIXTURE_DIR, "2026-05-21", "2026-05-21", action_filter="deny")

        self.assertTrue(all(entry["action"] == "ask" for entry in ask_report["entries"]))
        self.assertEqual({entry["action"] for entry in deny_report["entries"]}, {"deny"})
        self.assertEqual(deny_report["summary"]["total_deny"], 1)

    def test_agent_filter_is_case_insensitive(self) -> None:
        report = core.audit_logs(
            FIXTURE_DIR,
            start_date="2026-05-21",
            end_date="2026-05-21",
            action_filter="all",
            agent_filter="ARAGORN",
        )

        self.assertEqual(report["summary"]["total_events"], 1)
        self.assertEqual(report["entries"][0]["agents"], ["aragorn"])

    def test_empty_log_directory_returns_empty_schema_compliant_report(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            report = core.audit_logs(Path(tmpdir), "2026-05-21", "2026-05-21")

        self.assertEqual(report["version"], 1)
        self.assertEqual(report["date_range"], {"start": "2026-05-21", "end": "2026-05-21"})
        self.assertEqual(report["filters"], {"action": "ask", "agent": None})
        self.assertEqual(report["summary"], {"total_events": 0, "total_ask": 0, "total_deny": 0, "unique_patterns": 0})
        self.assertEqual(report["entries"], [])
        json.dumps(report)

    def test_human_output_format_contains_table_and_totals(self) -> None:
        report = core.audit_logs(FIXTURE_DIR, "2026-05-21", "2026-05-21", action_filter="ask")

        human = core.format_human(report)

        self.assertIn("Permission Audit: 2026-05-21 to 2026-05-21 (action=ask)", human)
        self.assertIn("# | Permission | Pattern", human)
        self.assertIn("Total:", human)
        self.assertIn("unique patterns", human)


if __name__ == "__main__":
    unittest.main()
