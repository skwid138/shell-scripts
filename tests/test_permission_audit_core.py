#!/usr/bin/env python3
"""Unit tests for agent/permission_audit_core.py."""

from __future__ import annotations

import contextlib
import io
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
FIXTURE_DIR = Path(__file__).resolve().parent / "fixtures" / "permission-audit"
sys.path.insert(0, str(REPO_ROOT / "agent"))

import permission_audit_core as core  # noqa: E402


class PermissionAuditParsingTest(unittest.TestCase):
    def test_parse_asking_record_json_parses_patterns_with_inner_brackets(self) -> None:
        line = (
            'INFO 2026-06-05T10:00:00.123Z +1ms service=permission id=per_abc '
            'permission=bash patterns=["printf \\\"[value]\\\"", "cat <<\\\"EOF\\\"\\nline asking\\nEOF"] asking'
        )

        event = core.parse_asking_record(line, source="fixture.log", sequence=1)

        self.assertIsNotNone(event)
        assert event is not None
        self.assertEqual(event.timestamp, "2026-06-05T10:00:00.123Z")
        self.assertEqual(event.permission, "bash")
        self.assertEqual(event.patterns, ['printf "[value]"', 'cat <<"EOF"\nline asking\nEOF'])

    def test_complete_asking_record_waits_for_parseable_json_before_asking_suffix(self) -> None:
        lines = [
            'INFO 2026-06-05T10:00:00.123Z +1ms service=permission id=per_abc permission=bash patterns=["cat <<EOF',
            'body line ending asking',
            'EOF"] asking',
        ]

        records = list(core.reassemble_log_records(lines, source="fixture.log"))
        event = core.parse_asking_record(records[0].text, source="fixture.log", sequence=1)

        self.assertEqual(len(records), 1)
        self.assertEqual(records[0].text, "\n".join(lines))
        self.assertIsNotNone(event)
        assert event is not None
        self.assertEqual(event.patterns, ["cat <<EOF\nbody line ending asking\nEOF"])
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

    def test_parse_permission_line_documents_action_json_delimiter_limitation(self) -> None:
        # Known limitation: the log format does not quote or length-prefix the
        # pattern field. If the command text itself contains the delimiter shape
        # ` action={...} evaluated`, PERM_RE treats that embedded JSON as the
        # permission action payload. This documents current behavior; do not
        # change the regex as part of this edge-case characterization.
        line = (
            'INFO 2026-05-21T10:00:06 +1ms service=permission permission=bash '
            'pattern=printf " action={"foo":"bar"} evaluated " '
            'action={"permission":"bash","pattern":"~/code/scripts/agent/*","action":"ask"} evaluated'
        )

        event = core.parse_permission_line(line, source="fixture.log", sequence=8)

        self.assertIsNotNone(event)
        assert event is not None
        self.assertEqual(event.timestamp, "2026-05-21T10:00:06")
        self.assertEqual(event.permission, "bash")
        self.assertEqual(event.pattern, 'printf "')
        self.assertIsNone(event.matched_rule)
        self.assertIsNone(event.action)

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
    def test_decisions_source_maps_once_reply_to_allow_entry(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            decisions_path = Path(tmpdir) / "decisions.log"
            decisions_path.write_text(
                json.dumps(
                    {
                        "ts": "2026-06-05T10:00:00.000Z",
                        "sessionID": "ses_1",
                        "callID": "call_1",
                        "requestID": "req_1",
                        "permission": "bash -lc pwd",
                        "patterns": ["bash -lc pwd"],
                        "always": ["bash -lc *"],
                        "reply": "once",
                        "askedTs": "2026-06-05T09:59:59.000Z",
                    }
                )
                + "\n",
                encoding="utf-8",
            )

            report = core.audit_decisions(decisions_path, "2026-06-05", "2026-06-05", plugin_log_path=None)

        self.assertEqual(report["version"], 2)
        self.assertEqual(report["source"], "decisions")
        self.assertTrue(report["decisions_log_present"])
        self.assertEqual(report["summary"]["total_events"], 1)
        self.assertEqual(report["summary"]["allow_count"], 1)
        self.assertEqual(report["summary"]["deny_count"], 0)
        self.assertEqual(report["summary"]["unknown_count"], 0)
        self.assertEqual(report["summary"]["unique_permissions"], 1)
        self.assertEqual(report["sources"], {"decisions": 1})
        self.assertEqual(report["entries"][0]["permission"], "bash -lc pwd")
        self.assertEqual(report["entries"][0]["action"], "allow")
        self.assertEqual(report["entries"][0]["reply"], "once")
        self.assertEqual(report["entries"][0]["patterns"], ["bash -lc pwd"])
        self.assertEqual(report["entries"][0]["always"], ["bash -lc *"])

    def test_decisions_source_reads_committed_decisions_fixture(self) -> None:
        decisions_path = FIXTURE_DIR / "decisions.log"

        report = core.audit_decisions(decisions_path, "2026-06-05", "2026-06-05", plugin_log_path=None)

        self.assertTrue(report["decisions_log_present"])
        self.assertEqual(report["summary"]["total_events"], 1)
        self.assertEqual(report["summary"]["allow_count"], 1)
        self.assertEqual(report["summary"]["deny_count"], 0)
        self.assertEqual(report["summary"]["unknown_count"], 0)
        self.assertEqual(report["sources"], {"decisions": 1})
        self.assertEqual(len(report["entries"]), 1)
        entry = report["entries"][0]
        self.assertEqual(entry["permission"], "bash -lc pwd")
        self.assertEqual(entry["action"], "allow")
        self.assertEqual(entry["reply"], "once")
        self.assertEqual(entry["patterns"], ["bash -lc pwd"])
        self.assertEqual(entry["always"], ["bash -lc *"])

    def test_decisions_aggregate_by_permission_and_reply_with_ordered_unions(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            decisions_path = Path(tmpdir) / "decisions.log"
            records = [
                {
                    "ts": "2026-06-05T10:00:00.000Z",
                    "sessionID": "ses_1",
                    "callID": "call_1",
                    "requestID": "req_1",
                    "permission": "bash -lc deploy",
                    "patterns": ["bash *", "deploy"],
                    "always": ["bash *"],
                    "reply": "once",
                    "askedTs": "2026-06-05T09:59:59.000Z",
                },
                {
                    "ts": "2026-06-05T10:01:00.000Z",
                    "sessionID": "ses_2",
                    "callID": "call_2",
                    "requestID": "req_2",
                    "permission": "bash -lc deploy",
                    "patterns": ["deploy", "bash -lc deploy"],
                    "always": ["bash *", "bash -lc *"],
                    "reply": "once",
                    "askedTs": "2026-06-05T10:00:59.000Z",
                },
                {
                    "ts": "2026-06-05T10:02:00.000Z",
                    "sessionID": "ses_3",
                    "callID": "call_3",
                    "requestID": "req_3",
                    "permission": "bash -lc deploy",
                    "patterns": ["deploy"],
                    "always": [],
                    "reply": "always",
                    "askedTs": "2026-06-05T10:01:59.000Z",
                },
                {
                    "ts": "2026-06-05T10:03:00.000Z",
                    "sessionID": "ses_4",
                    "callID": "call_4",
                    "requestID": "req_4",
                    "permission": "bash -lc rm -rf /tmp/nope",
                    "patterns": ["rm -rf *"],
                    "always": [],
                    "reply": "reject",
                    "askedTs": "2026-06-05T10:02:59.000Z",
                },
            ]
            decisions_path.write_text("\n".join(json.dumps(record) for record in records) + "\n", encoding="utf-8")

            report = core.audit_decisions(decisions_path, "2026-06-05", "2026-06-05", plugin_log_path=None)

        by_key = {(entry["permission"], entry["reply"]): entry for entry in report["entries"]}
        self.assertEqual(by_key[("bash -lc deploy", "once")]["count"], 2)
        self.assertEqual(by_key[("bash -lc deploy", "once")]["patterns"], ["bash *", "deploy", "bash -lc deploy"])
        self.assertEqual(by_key[("bash -lc deploy", "once")]["always"], ["bash *", "bash -lc *"])
        self.assertEqual(by_key[("bash -lc deploy", "always")]["action"], "allow")
        self.assertEqual(by_key[("bash -lc rm -rf /tmp/nope", "reject")]["action"], "deny")
        self.assertEqual(report["summary"]["total_events"], 4)
        self.assertEqual(report["summary"]["allow_count"], 3)
        self.assertEqual(report["summary"]["deny_count"], 1)
        self.assertEqual(report["summary"]["unknown_count"], 0)
        self.assertEqual(report["summary"]["unique_permissions"], 2)

    def test_decisions_agent_join_uses_call_id_then_session_fallback_without_null_mass_match(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            decisions_path = Path(tmpdir) / "decisions.log"
            plugin_path = Path(tmpdir) / "audit.log"
            decisions = [
                {
                    "ts": "2026-06-05T10:00:00.000Z",
                    "sessionID": "ses_direct",
                    "callID": "call_direct",
                    "requestID": "req_1",
                    "permission": "direct",
                    "patterns": [],
                    "always": [],
                    "reply": "once",
                    "askedTs": "2026-06-05T09:59:59.000Z",
                },
                {
                    "ts": "2026-06-05T10:01:00.000Z",
                    "sessionID": "ses_ambiguous_call",
                    "callID": "call_ambiguous",
                    "requestID": "req_2",
                    "permission": "ambiguous-call",
                    "patterns": [],
                    "always": [],
                    "reply": "once",
                    "askedTs": "2026-06-05T10:00:59.000Z",
                },
                {
                    "ts": "2026-06-05T10:02:00.000Z",
                    "sessionID": "ses_fallback",
                    "callID": None,
                    "requestID": "req_3",
                    "permission": "session-fallback",
                    "patterns": [],
                    "always": [],
                    "reply": "once",
                    "askedTs": "2026-06-05T10:01:59.000Z",
                },
                {
                    "ts": "2026-06-05T10:03:00.000Z",
                    "sessionID": "ses_ambiguous_session",
                    "callID": "call_missing",
                    "requestID": "req_4",
                    "permission": "ambiguous-session",
                    "patterns": [],
                    "always": [],
                    "reply": "once",
                    "askedTs": "2026-06-05T10:02:59.000Z",
                },
                {
                    "ts": "2026-06-05T10:04:00.000Z",
                    "sessionID": "ses_no_match",
                    "callID": "call_no_match",
                    "requestID": "req_5",
                    "permission": "no-match",
                    "patterns": [],
                    "always": [],
                    "reply": "once",
                    "askedTs": "2026-06-05T10:03:59.000Z",
                },
                {
                    "ts": "2026-06-05T10:05:00.000Z",
                    "sessionID": "ses_null_guard",
                    "callID": None,
                    "requestID": "req_6",
                    "permission": "null-guard",
                    "patterns": [],
                    "always": [],
                    "reply": "once",
                    "askedTs": "2026-06-05T10:04:59.000Z",
                },
            ]
            plugin_records = [
                {"ts": "2026-06-05T10:00:00.000Z", "sessionID": "ses_direct", "agent": "aragorn", "callID": "call_direct", "command_node_text": "direct"},
                {"ts": "2026-06-05T10:01:00.000Z", "sessionID": "ses_ambiguous_call", "agent": "gandalf", "callID": "call_ambiguous", "command_node_text": "ambiguous-call-a"},
                {"ts": "2026-06-05T10:01:00.100Z", "sessionID": "ses_ambiguous_call", "agent": "legolas", "callID": "call_ambiguous", "command_node_text": "ambiguous-call-b"},
                {"ts": "2026-06-05T10:02:00.000Z", "sessionID": "ses_fallback", "agent": "radagast", "callID": "call_other", "command_node_text": "session-fallback"},
                {"ts": "2026-06-05T10:03:00.000Z", "sessionID": "ses_ambiguous_session", "agent": "gandalf", "callID": "call_a", "command_node_text": "ambiguous-session-a"},
                {"ts": "2026-06-05T10:03:00.100Z", "sessionID": "ses_ambiguous_session", "agent": "saruman", "callID": "call_b", "command_node_text": "ambiguous-session-b"},
                {"ts": "2026-06-05T10:05:00.000Z", "sessionID": "ses_other", "agent": "wrong", "callID": None, "command_node_text": "null-guard"},
            ]
            decisions_path.write_text("\n".join(json.dumps(record) for record in decisions) + "\n", encoding="utf-8")
            plugin_path.write_text("\n".join(json.dumps(record) for record in plugin_records) + "\n", encoding="utf-8")

            report = core.audit_decisions(decisions_path, "2026-06-05", "2026-06-05", plugin_log_path=plugin_path)

        agents = {entry["permission"]: entry["agents"] for entry in report["entries"]}
        self.assertEqual(agents["direct"], ["aragorn"])
        self.assertEqual(agents["ambiguous-call"], ["ambiguous"])
        self.assertEqual(agents["session-fallback"], ["radagast"])
        self.assertEqual(agents["ambiguous-session"], ["unknown"])
        self.assertEqual(agents["no-match"], ["unknown (no audit match)"])
        self.assertEqual(agents["null-guard"], ["unknown (no audit match)"])

    def test_decisions_action_filter_counts_post_filter_and_preserves_identity(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            decisions_path = Path(tmpdir) / "decisions.log"
            records = [
                {"ts": "2026-06-05T10:00:00.000Z", "sessionID": "ses_1", "callID": "call_1", "requestID": "req_1", "permission": "allow-once", "patterns": [], "always": [], "reply": "once", "askedTs": "2026-06-05T09:59:59.000Z"},
                {"ts": "2026-06-05T10:01:00.000Z", "sessionID": "ses_2", "callID": "call_2", "requestID": "req_2", "permission": "allow-always", "patterns": [], "always": [], "reply": "always", "askedTs": "2026-06-05T10:00:59.000Z"},
                {"ts": "2026-06-05T10:02:00.000Z", "sessionID": "ses_3", "callID": "call_3", "requestID": "req_3", "permission": "deny", "patterns": [], "always": [], "reply": "reject", "askedTs": "2026-06-05T10:01:59.000Z"},
                {"ts": "2026-06-05T10:03:00.000Z", "sessionID": "ses_4", "callID": "call_4", "requestID": "req_4", "permission": "mystery", "patterns": [], "always": [], "reply": "later", "askedTs": "2026-06-05T10:02:59.000Z"},
            ]
            decisions_path.write_text("\n".join(json.dumps(record) for record in records) + "\n", encoding="utf-8")

            allow_report = core.audit_decisions(decisions_path, "2026-06-05", "2026-06-05", action_filter="allow", plugin_log_path=None)
            with contextlib.redirect_stderr(io.StringIO()):
                deny_report = core.audit_decisions(decisions_path, "2026-06-05", "2026-06-05", action_filter="deny", plugin_log_path=None)
            all_report = core.audit_decisions(decisions_path, "2026-06-05", "2026-06-05", action_filter="all", plugin_log_path=None)

        self.assertEqual({entry["action"] for entry in allow_report["entries"]}, {"allow"})
        self.assertEqual(allow_report["summary"]["total_events"], 2)
        self.assertEqual(deny_report["summary"]["total_events"], 1)
        self.assertEqual(deny_report["summary"]["deny_count"], 1)
        self.assertEqual(all_report["summary"], {"total_events": 4, "allow_count": 2, "deny_count": 1, "unknown_count": 1, "unique_permissions": 4})
        self.assertEqual(
            all_report["summary"]["total_events"],
            all_report["summary"]["allow_count"] + all_report["summary"]["deny_count"] + all_report["summary"]["unknown_count"],
        )

    def test_decisions_absent_file_differs_from_present_empty_range(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            missing_path = Path(tmpdir) / "missing-decisions.log"
            present_path = Path(tmpdir) / "decisions.log"
            present_path.write_text(
                json.dumps(
                    {
                        "ts": "2026-06-04T10:00:00.000Z",
                        "sessionID": "ses_1",
                        "callID": "call_1",
                        "requestID": "req_1",
                        "permission": "outside range",
                        "patterns": [],
                        "always": [],
                        "reply": "once",
                        "askedTs": "2026-06-04T09:59:59.000Z",
                    }
                )
                + "\n",
                encoding="utf-8",
            )

            with contextlib.redirect_stderr(io.StringIO()) as stderr:
                missing_report = core.audit_decisions(missing_path, "2026-06-05", "2026-06-05", plugin_log_path=None)
            present_report = core.audit_decisions(present_path, "2026-06-05", "2026-06-05", plugin_log_path=None)

        self.assertFalse(missing_report["decisions_log_present"])
        self.assertIn(core.MISSING_DECISIONS_CAVEAT, missing_report["caveats"])
        self.assertIn(core.MISSING_DECISIONS_CAVEAT, stderr.getvalue())
        self.assertEqual(missing_report["sources"], {"decisions": 0})
        self.assertTrue(present_report["decisions_log_present"])
        self.assertNotIn(core.MISSING_DECISIONS_CAVEAT, present_report["caveats"])
        self.assertEqual(present_report["sources"], {"decisions": 0})

    def test_decisions_drift_records_are_kept_or_caveated_without_silent_drop(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            decisions_path = Path(tmpdir) / "decisions.log"
            lines = [
                json.dumps(
                    {
                        "ts": "2026-06-05T10:00:00.000Z",
                        "sessionID": "ses_1",
                        "callID": 123,
                        "requestID": "req_1",
                        "patterns": "not-array",
                        "always": {"not": "array"},
                        "reply": "later",
                        "askedTs": "2026-06-05T09:59:59.000Z",
                    }
                ),
                json.dumps(
                    {
                        "ts": "not-a-date",
                        "sessionID": "ses_2",
                        "callID": "call_2",
                        "requestID": "req_2",
                        "permission": "undated",
                        "patterns": [],
                        "always": [],
                        "reply": "once",
                        "askedTs": "2026-06-05T09:59:59.000Z",
                    }
                ),
                "{not-json",
            ]
            decisions_path.write_text("\n".join(lines) + "\n", encoding="utf-8")

            with contextlib.redirect_stderr(io.StringIO()) as stderr:
                report = core.audit_decisions(decisions_path, "2026-06-05", "2026-06-05", plugin_log_path=None)

        self.assertIn("skipping malformed decisions JSON", stderr.getvalue())
        self.assertEqual(report["summary"]["total_events"], 1)
        self.assertEqual(report["summary"]["unknown_count"], 1)
        entry = report["entries"][0]
        self.assertEqual(entry["permission"], "(missing permission)")
        self.assertEqual(entry["action"], "unknown")
        self.assertEqual(entry["patterns"], [])
        self.assertEqual(entry["always"], [])
        self.assertIn("unknown decisions reply values were kept as action=unknown", report["caveats"])
        self.assertIn('missing permission fields were kept as "(missing permission)"', report["caveats"])
        self.assertIn("1 decisions records had unparseable ts values and were excluded from date-filtered counts", report["caveats"])

    def test_decisions_action_filter_suppresses_filtered_out_drift_caveats(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            decisions_path = Path(tmpdir) / "decisions.log"
            decisions_path.write_text(
                json.dumps(
                    {
                        "ts": "2026-06-05T10:00:00.000Z",
                        "sessionID": "ses_1",
                        "callID": "call_1",
                        "requestID": "req_1",
                        "patterns": [],
                        "always": [],
                        "reply": "later",
                        "askedTs": "2026-06-05T09:59:59.000Z",
                    }
                )
                + "\n",
                encoding="utf-8",
            )

            report = core.audit_decisions(
                decisions_path,
                "2026-06-05",
                "2026-06-05",
                action_filter="allow",
                plugin_log_path=None,
            )

        self.assertEqual(report["summary"]["total_events"], 0)
        self.assertEqual(report["summary"]["unknown_count"], 0)
        self.assertNotIn("unknown decisions reply values were kept as action=unknown", report["caveats"])
        self.assertNotIn('missing permission fields were kept as "(missing permission)"', report["caveats"])

    def test_human_output_formats_v2_decisions_report_without_v1_keys(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            decisions_path = Path(tmpdir) / "decisions.log"
            decisions_path.write_text(
                json.dumps(
                    {
                        "ts": "2026-06-05T10:00:00.000Z",
                        "sessionID": "ses_1",
                        "callID": "call_1",
                        "requestID": "req_1",
                        "permission": "bash -lc pwd",
                        "patterns": ["bash -lc pwd"],
                        "always": ["bash -lc *"],
                        "reply": "reject",
                        "askedTs": "2026-06-05T09:59:59.000Z",
                    }
                )
                + "\n",
                encoding="utf-8",
            )
            with contextlib.redirect_stderr(io.StringIO()):
                report = core.audit_decisions(decisions_path, "2026-06-05", "2026-06-05", action_filter="deny", plugin_log_path=None)

        human = core.format_human(report)

        self.assertIn("Permission Audit: 2026-06-05 to 2026-06-05 (source=decisions, action=deny)", human)
        self.assertIn("Permission | Action/Reply", human)
        self.assertIn("bash -lc pwd", human)
        self.assertIn("deny/reject", human)
        self.assertIn("allow=0, deny=1, unknown=0, unique permissions=1", human)
        self.assertIn(core.STATIC_BLINDNESS_CAVEAT, human)
        self.assertIn(core.DENY_STATIC_BLINDNESS_WARNING, human)

    def test_main_dispatches_decisions_source_and_rejects_source_action_mismatches(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            decisions_path = Path(tmpdir) / "decisions.log"
            decisions_path.write_text(
                json.dumps(
                    {
                        "ts": "2026-06-05T10:00:00.000Z",
                        "sessionID": "ses_1",
                        "callID": "call_1",
                        "requestID": "req_1",
                        "permission": "bash -lc pwd",
                        "patterns": [],
                        "always": [],
                        "reply": "once",
                        "askedTs": "2026-06-05T09:59:59.000Z",
                    }
                )
                + "\n",
                encoding="utf-8",
            )

            stdout = io.StringIO()
            with contextlib.redirect_stdout(stdout):
                status = core.main([
                    "--start",
                    "2026-06-05",
                    "--end",
                    "2026-06-05",
                    "--source",
                    "decisions",
                    "--action",
                    "all",
                    "--decisions-log",
                    str(decisions_path),
                    "--json",
                ])

        payload = json.loads(stdout.getvalue())
        self.assertEqual(status, 0)
        self.assertEqual(payload["version"], 2)
        self.assertEqual(payload["source"], "decisions")
        with contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit) as decisions_ask:
                core.main(["--source", "decisions", "--action", "ask"])
        self.assertEqual(decisions_ask.exception.code, 2)
        with contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit) as native_allow:
                core.main(["--source", "native", "--action", "allow"])
        self.assertEqual(native_allow.exception.code, 2)

    def test_python_help_discloses_decisions_static_blindness(self) -> None:
        help_text = core.build_parser().format_help()

        self.assertIn(
            "Decisions output is an interactive-prompt audit; static allow and deny rules that never prompt are not captured — not a comprehensive policy audit.",
            help_text,
        )

    def test_xdg_data_home_controls_decisions_and_plugin_audit_defaults(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            previous = os.environ.get("XDG_DATA_HOME")
            os.environ["XDG_DATA_HOME"] = tmpdir
            try:
                self.assertEqual(
                    core._default_decisions_log(),
                    Path(tmpdir) / "opencode" / "permission-audit-plugin" / "decisions.log",
                )
                self.assertEqual(
                    core._default_plugin_audit_log(),
                    Path(tmpdir) / "opencode" / "permission-audit-plugin" / "audit.log",
                )
            finally:
                if previous is None:
                    os.environ.pop("XDG_DATA_HOME", None)
                else:
                    os.environ["XDG_DATA_HOME"] = previous

    def test_decisions_date_filter_uses_reply_ts_not_asked_ts(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            decisions_path = Path(tmpdir) / "decisions.log"
            decisions_path.write_text(
                json.dumps(
                    {
                        "ts": "2026-06-05T00:00:01.000Z",
                        "sessionID": "ses_1",
                        "callID": "call_1",
                        "requestID": "req_1",
                        "permission": "reply in range",
                        "patterns": [],
                        "always": [],
                        "reply": "once",
                        "askedTs": "2026-06-04T23:59:59.000Z",
                    }
                )
                + "\n",
                encoding="utf-8",
            )

            report = core.audit_decisions(decisions_path, "2026-06-05", "2026-06-05", plugin_log_path=None)

        self.assertEqual(report["summary"]["total_events"], 1)
        self.assertEqual(report["entries"][0]["first_seen"], "2026-06-05T00:00:01.000Z")

    def test_asking_events_report_prompt_and_pattern_counts_separately(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            log_path = Path(tmpdir) / "2026-06-05T100000.log"
            log_path.write_text(
                'INFO 2026-06-05T10:00:00.123Z +1ms service=permission id=per_one '
                'permission=bash patterns=["~/code/scripts/agent/foo.sh", "pwd"] asking\n',
                encoding="utf-8",
            )

            report = core.audit_logs(
                tmpdir,
                "2026-06-05",
                "2026-06-05",
                action_filter="ask",
                plugin_log_path=None,
            )

        self.assertEqual(report["summary"]["prompt_event_count"], 1)
        self.assertEqual(report["summary"]["pattern_occurrence_count"], 2)
        self.assertEqual({entry["pattern"] for entry in report["entries"]}, {"~/code/scripts/agent/foo.sh", "pwd"})
        self.assertEqual({tuple(entry["agents"]) for entry in report["entries"]}, {("unknown (pre-plugin)",)})

    def test_malformed_asking_pattern_json_counts_prompt_as_unparseable(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            log_path = Path(tmpdir) / "2026-06-05T100000.log"
            log_path.write_text(
                "INFO 2026-06-05T10:00:00.123Z +1ms service=permission id=per_bad "
                "permission=bash patterns=[not-json] asking\n",
                encoding="utf-8",
            )

            with contextlib.redirect_stderr(io.StringIO()) as stderr:
                report = core.audit_logs(
                    tmpdir,
                    "2026-06-05",
                    "2026-06-05",
                    action_filter="ask",
                    plugin_log_path=None,
                )

        self.assertIn("malformed permission asking patterns JSON", stderr.getvalue())
        self.assertEqual(report["summary"]["prompt_event_count"], 1)
        self.assertEqual(report["summary"]["pattern_occurrence_count"], 1)
        self.assertEqual(report["entries"][0]["pattern"], "unparseable")

    def test_plugin_audit_log_attributes_asking_events_by_exact_prior_command_text(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            log_path = Path(tmpdir) / "2026-06-05T100000.log"
            plugin_path = Path(tmpdir) / "audit.log"
            log_path.write_text(
                'INFO 2026-06-05T10:00:01.000Z +1ms service=permission id=per_one '
                'permission=bash patterns=["/Users/hunter/code/scripts/agent/foo.sh --json"] asking\n',
                encoding="utf-8",
            )
            plugin_path.write_text(
                json.dumps(
                    {
                        "ts": "2026-06-05T10:00:00.900Z",
                        "sessionID": "ses_1",
                        "agent": "aragorn",
                        "callID": "call_1",
                        "command_node_text": "/Users/hunter/code/scripts/agent/foo.sh --json",
                    }
                )
                + "\n",
                encoding="utf-8",
            )

            report = core.audit_logs(
                tmpdir,
                "2026-06-05",
                "2026-06-05",
                action_filter="ask",
                agent_filter="ARAGORN",
                plugin_log_path=plugin_path,
            )

        self.assertEqual(report["summary"]["prompt_event_count"], 1)
        self.assertEqual(report["entries"][0]["agents"], ["aragorn"])

    def test_plugin_audit_join_handles_naive_opencode_utc_timestamps(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            log_path = Path(tmpdir) / "2026-06-05T155129.log"
            plugin_path = Path(tmpdir) / "audit.log"
            command = "/Users/hunter/code/scripts/agent/foo.sh --json"
            log_path.write_text(
                f'INFO 2026-06-05T15:51:31 +1ms service=permission id=per_one permission=bash patterns=[{json.dumps(command)}] asking\n',
                encoding="utf-8",
            )
            plugin_path.write_text(
                json.dumps(
                    {
                        "ts": "2026-06-05T15:51:30.500Z",
                        "sessionID": "ses_utc",
                        "agent": "aragorn",
                        "callID": "call_utc",
                        "command_node_text": command,
                    }
                )
                + "\n",
                encoding="utf-8",
            )

            report = core.audit_logs(
                tmpdir,
                "2026-06-05",
                "2026-06-05",
                action_filter="ask",
                plugin_log_path=plugin_path,
            )

        self.assertEqual(report["summary"]["prompt_event_count"], 1)
        self.assertEqual(report["entries"][0]["agents"], ["aragorn"])
        self.assertEqual(report["entries"][0]["session_ids"], ["ses_utc"])

    def test_plugin_audit_join_ignores_records_outside_window(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            log_path = Path(tmpdir) / "2026-06-05T155129.log"
            plugin_path = Path(tmpdir) / "audit.log"
            command = "/Users/hunter/code/scripts/agent/foo.sh --json"
            log_path.write_text(
                f'INFO 2026-06-05T15:51:31 +1ms service=permission id=per_one permission=bash patterns=[{json.dumps(command)}] asking\n',
                encoding="utf-8",
            )
            plugin_path.write_text(
                json.dumps(
                    {
                        "ts": "2026-06-05T15:51:20.000Z",
                        "sessionID": "ses_old",
                        "agent": "aragorn",
                        "callID": "call_old",
                        "command_node_text": command,
                    }
                )
                + "\n",
                encoding="utf-8",
            )

            report = core.audit_logs(
                tmpdir,
                "2026-06-05",
                "2026-06-05",
                action_filter="ask",
                plugin_log_path=plugin_path,
            )

        self.assertEqual(report["summary"]["prompt_event_count"], 1)
        self.assertEqual(report["entries"][0]["agents"], ["unknown (pre-plugin)"])
        self.assertEqual(report["entries"][0]["session_ids"], [])

    def test_mixed_legacy_evaluated_and_asking_prompts_are_both_counted(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            log_path = Path(tmpdir) / "2026-06-05T100000.log"
            log_path.write_text(
                "\n".join(
                    [
                        "INFO 2026-06-05T10:00:00 +1ms service=permission permission=bash "
                        'pattern=legacy-only.sh action={"permission":"bash","pattern":"*","action":"ask"} evaluated',
                        "INFO 2026-06-05T10:01:00 +1ms service=permission permission=bash "
                        'pattern=new-format.sh action={"permission":"bash","pattern":"*","action":"ask"} evaluated',
                        'INFO 2026-06-05T10:01:00 +1ms service=permission id=per_one permission=bash patterns=["new-format.sh"] asking',
                    ]
                )
                + "\n",
                encoding="utf-8",
            )

            report = core.audit_logs(
                tmpdir,
                "2026-06-05",
                "2026-06-05",
                action_filter="ask",
                plugin_log_path=None,
            )

        self.assertEqual(report["summary"]["prompt_event_count"], 1)
        self.assertEqual(report["summary"]["pattern_occurrence_count"], 2)
        self.assertEqual({entry["pattern"] for entry in report["entries"]}, {"legacy-only.sh", "new-format.sh"})

    def test_plugin_audit_ambiguous_when_same_command_has_multiple_candidates_in_window(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            log_path = Path(tmpdir) / "2026-06-05T100000.log"
            plugin_path = Path(tmpdir) / "audit.log"
            command = "/Users/hunter/code/scripts/agent/foo.sh"
            log_path.write_text(
                f'INFO 2026-06-05T10:00:01.000Z +1ms service=permission id=per_one permission=bash patterns=[{json.dumps(command)}] asking\n',
                encoding="utf-8",
            )
            plugin_path.write_text(
                "\n".join(
                    [
                        json.dumps(
                            {
                                "ts": "2026-06-05T10:00:00.800Z",
                                "sessionID": "ses_1",
                                "agent": "gandalf",
                                "callID": "call_1",
                                "command_node_text": command,
                            }
                        ),
                        json.dumps(
                            {
                                "ts": "2026-06-05T10:00:00.900Z",
                                "sessionID": "ses_2",
                                "agent": "aragorn",
                                "callID": "call_2",
                                "command_node_text": command,
                            }
                        ),
                    ]
                )
                + "\n",
                encoding="utf-8",
            )

            report = core.audit_logs(
                tmpdir,
                "2026-06-05",
                "2026-06-05",
                action_filter="ask",
                plugin_log_path=plugin_path,
            )

        self.assertEqual(report["entries"][0]["agents"], ["ambiguous"])

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

    def test_large_scale_fixture_preserves_permission_agent_attribution(self) -> None:
        fixture = FIXTURE_DIR / "2026-05-21T120000.log"
        lines = fixture.read_text(encoding="utf-8").splitlines()
        self.assertEqual(sum("service=session id=ses_scale_" in line for line in lines), 42)
        self.assertEqual(sum("service=session.prompt session.id=ses_scale_" in line for line in lines), 42)

        report = core.audit_logs(
            FIXTURE_DIR,
            start_date="2026-05-21",
            end_date="2026-05-21",
            action_filter="ask",
        )

        scale_entries = {
            entry["pattern"]: entry
            for entry in report["entries"]
            if entry["pattern"].startswith("/tmp/scale-")
            or entry["pattern"].startswith("~/code/scripts/agent/scale-")
            or entry["pattern"].startswith("/Users/hunter/.config/opencode/scale-")
            or entry["pattern"].startswith("printf scale-")
        }
        self.assertEqual(
            {pattern: entry["agents"] for pattern, entry in scale_entries.items()},
            {
                "/tmp/scale-gandalf-01.txt": ["gandalf"],
                "~/code/scripts/agent/scale-legolas.sh": ["legolas"],
                "/Users/hunter/.config/opencode/scale-aragorn.json": ["aragorn"],
                "/tmp/scale-saruman-review.txt": ["saruman"],
                "printf scale-radagast": ["radagast"],
            },
        )
        unique_agents = {agent for entry in scale_entries.values() for agent in entry["agents"]}
        self.assertEqual(unique_agents, {"gandalf", "aragorn", "legolas", "saruman", "radagast"})
        self.assertEqual(len(unique_agents), 5)

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
            action_filter="deny",
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
        self.assertEqual(
            report["summary"],
            {
                "total_events": 0,
                "prompt_event_count": 0,
                "pattern_occurrence_count": 0,
                "total_ask": 0,
                "total_deny": 0,
                "unique_patterns": 0,
            },
        )
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
