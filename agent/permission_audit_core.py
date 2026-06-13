#!/usr/bin/env python3
"""Audit opencode permission evaluations and prompt events from local log files.

The shell wrapper owns dependency checks and broad CLI convention. This module
keeps the parsing, temporal correlation, aggregation, and output formatting in
Python so commands and paths with shell metacharacters remain data, not syntax.
opencode v1.15.13 keeps only about 10 log files, does not retain useful
permission prompt rows in SQLite, and cannot reliably recover pre-plugin agent
attribution from logs alone.
"""

from __future__ import annotations

import argparse
import bisect
import json
import os
import re
import sys
from dataclasses import dataclass
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Iterable


PERM_RE = re.compile(
    r"INFO\s+(\S+)\s+\+\S+\s+service=permission\s+permission=(\S+)\s+pattern=(.*?)\s+action=(\{[^}]+\})\s+evaluated"
)
SESSION_RE = re.compile(
    r"INFO\s+(\S+)\s+\+\S+\s+service=session\s+id=(ses_\S+)\s+.*?agent=(\S+)\s+.*?created$"
)
SUBAGENT_RE = re.compile(
    r"INFO\s+(\S+)\s+\+\S+\s+service=session\s+id=(ses_\S+)\s+.*?title=.*?\(@([\w-]+)\s+subagent\).*?created$"
)
LLM_RE = re.compile(
    r"INFO\s+(\S+)\s+\+\S+\s+service=llm\s+.*?session\.id=(ses_\S+)\s+.*?agent=([\w-]+)"
)
PROMPT_RE = re.compile(
    r"INFO\s+(\S+)\s+\+\S+\s+service=session\.prompt\s+session\.id=(ses_\S+)\s+step=\d+"
)
ASKING_RE = re.compile(
    r"INFO\s+(\S+)\s+\+\S+\s+service=permission\s+id=per_\S+\s+permission=(\S+)\s+patterns=(.*)\sasking\s*$",
    re.DOTALL,
)

DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
LOG_FILENAME_RE = re.compile(r"^(\d{4}-\d{2}-\d{2})T.*\.log$")


def _xdg_data_home() -> Path:
    return Path(os.environ.get("XDG_DATA_HOME", "~/.local/share")).expanduser()


def _default_plugin_audit_log() -> Path:
    return _xdg_data_home() / "opencode" / "permission-audit-plugin" / "audit.log"


def _default_decisions_log() -> Path:
    return _xdg_data_home() / "opencode" / "permission-audit-plugin" / "decisions.log"


DEFAULT_PLUGIN_AUDIT_LOG = _default_plugin_audit_log()
DEFAULT_DECISIONS_LOG = _default_decisions_log()
PLUGIN_JOIN_WINDOW = timedelta(seconds=5)
STATIC_BLINDNESS_CAVEAT = (
    "interactive-prompt audit; static allow and deny rules that never prompt are not captured — "
    "not a comprehensive policy audit"
)
MISSING_DECISIONS_CAVEAT = (
    "decisions.log not found — the command-normalizer plugin may not be built or running; "
    "run its build and restart opencode"
)
DENY_STATIC_BLINDNESS_WARNING = "static deny-rule auto-blocks are not captured by the decisions source"
SELF_AUDIT_EXCLUSION_CAVEAT = (
    "self-referential permission-audit records were excluded by --exclude-self; "
    "matching is a simple substring check for permission-audit.sh or permission_audit_core in patterns[]/always[] "
    "without path, alias, casing, or symlink normalization, so auditing the auditor can be a false positive"
)
SELF_AUDIT_MARKERS = ("permission-audit.sh", "permission_audit_core")


@dataclass(frozen=True)
class LogRecord:
    text: str
    source: str
    sequence: int


@dataclass(frozen=True)
class PermissionEvent:
    timestamp: str
    permission: str
    pattern: str
    matched_rule: str | None
    action: str | None
    source: str
    sequence: int


@dataclass(frozen=True)
class AskingEvent:
    timestamp: str
    permission: str
    patterns: list[str]
    source: str
    sequence: int


@dataclass(frozen=True)
class SessionAgent:
    timestamp: str
    session_id: str
    agent: str
    source: str
    sequence: int


@dataclass(frozen=True)
class PromptMarker:
    timestamp: str
    session_id: str
    source: str
    sequence: int


@dataclass(frozen=True)
class PluginAuditRecord:
    timestamp: str
    timestamp_value: datetime
    session_id: str | None
    agent: str | None
    call_id: str | None
    command_node_text: str
    source: str
    sequence: int


@dataclass(frozen=True)
class DecisionRecord:
    timestamp: str | None
    timestamp_value: datetime | None
    session_id: str | None
    call_id: str | None
    permission: str
    patterns: list[str]
    always: list[str]
    reply: str
    source: str
    sequence: int


def _warn(message: str) -> None:
    print(f"Warning: {message}", file=sys.stderr)


def _parse_date(value: str) -> date:
    if not DATE_RE.match(value):
        raise ValueError(f"invalid date: {value}")
    return datetime.strptime(value, "%Y-%m-%d").date()


def _event_date(timestamp: str) -> date | None:
    try:
        return _parse_date(timestamp[:10])
    except ValueError:
        return None


def _parse_timestamp(value: str) -> datetime | None:
    try:
        normalized = value[:-1] + "+00:00" if value.endswith("Z") else value
        return datetime.fromisoformat(normalized)
    except ValueError:
        return None


def _utc_aware_for_plugin_join(value: datetime) -> datetime:
    # Real opencode INFO timestamps are offset-naive but UTC-aligned: the log
    # filename/line timestamp matches UTC while the filesystem mtime is local
    # time with the corresponding offset. The plugin writes new Date().toISOString()
    # (UTC with Z), so naive opencode values must be tagged as UTC for the 5s
    # same-prompt join window to compare safely and align genuine matches.
    if value.tzinfo is None or value.utcoffset() is None:
        return value.replace(tzinfo=timezone.utc)
    return value.astimezone(timezone.utc)


def _json_array_state(payload: str) -> tuple[bool, bool]:
    """Return (started, balanced) for a JSON-array-looking payload.

    The scanner is intentionally small: it tracks quotes, escapes, and square
    bracket depth so a heredoc body line ending in `` asking`` cannot terminate
    a multiline permission prompt before the ``patterns=[...]`` array is closed.
    """

    depth = 0
    in_string = False
    escaped = False
    started = False
    for char in payload:
        if escaped:
            escaped = False
            continue
        if in_string:
            if char == "\\":
                escaped = True
            elif char == '"':
                in_string = False
            continue
        if char == '"':
            in_string = True
        elif char == "[":
            depth += 1
            started = True
        elif char == "]" and started:
            depth -= 1
            if depth < 0:
                return started, False
    return started, started and depth == 0 and not in_string and not escaped


def _escape_raw_newlines_in_json_strings(payload: str) -> str:
    repaired: list[str] = []
    in_string = False
    escaped = False
    for char in payload:
        if escaped:
            repaired.append(char)
            escaped = False
            continue
        if in_string:
            if char == "\\":
                repaired.append(char)
                escaped = True
            elif char == '"':
                repaired.append(char)
                in_string = False
            elif char == "\n":
                repaired.append("\\n")
            else:
                repaired.append(char)
            continue
        repaired.append(char)
        if char == '"':
            in_string = True
    return "".join(repaired)


def _asking_payload_candidate(text: str) -> str | None:
    if not text.rstrip().endswith(" asking"):
        return None
    marker = " patterns="
    index = text.find(marker)
    if index < 0:
        return None
    return text[index + len(marker) : text.rfind(" asking")]


def _is_complete_asking_record(text: str) -> bool:
    payload = _asking_payload_candidate(text)
    if payload is None:
        return False
    _, balanced = _json_array_state(payload)
    return balanced


def reassemble_log_records(lines: Iterable[str], *, source: str) -> Iterable[LogRecord]:
    """Yield logical log records, reassembling multiline permission prompts.

    opencode currently retains only ten log files, so multiline reassembly must
    be tolerant: malformed or drifted records warn and remain isolated instead
    of aborting the audit.
    """

    buffer: list[str] = []
    start_sequence = 0
    for sequence, raw_line in enumerate(lines, start=1):
        line = raw_line.rstrip("\n")
        if buffer:
            buffer.append(line)
            text = "\n".join(buffer)
            if _is_complete_asking_record(text):
                yield LogRecord(text, source, start_sequence)
                buffer = []
            continue

        if "service=permission" in line and "patterns=" in line:
            if _is_complete_asking_record(line):
                yield LogRecord(line, source, sequence)
            else:
                buffer = [line]
                start_sequence = sequence
            continue

        yield LogRecord(line, source, sequence)

    if buffer:
        text = "\n".join(buffer)
        if text.rstrip().endswith(" asking"):
            yield LogRecord(text, source, start_sequence)
        else:
            _warn(f"skipping unterminated permission asking record in {source}:{start_sequence}")


def parse_permission_line(line: str, *, source: str, sequence: int) -> PermissionEvent | None:
    """Parse one permission evaluation log line.

    Invalid action JSON is treated as a non-match and skipped with a warning so
    one malformed line cannot break the whole audit.
    """

    match = PERM_RE.search(line)
    if not match:
        return None

    timestamp, permission, pattern, action_json = match.groups()
    try:
        action_payload = json.loads(action_json)
    except json.JSONDecodeError as exc:
        _warn(f"skipping malformed permission action JSON in {source}: {exc}")
        return None

    return PermissionEvent(
        timestamp=timestamp,
        permission=permission,
        pattern=pattern,
        matched_rule=action_payload.get("pattern"),
        action=action_payload.get("action"),
        source=source,
        sequence=sequence,
    )


def parse_asking_record(text: str, *, source: str, sequence: int) -> AskingEvent | None:
    """Parse one permission prompt ``asking`` record.

    ``patterns`` is a JSON string array emitted by opencode. Do not extract it
    with a non-greedy bracket regex: command text can contain brackets, escaped
    quotes, and heredoc bodies. Malformed JSON still represents one prompt, so
    it is bucketed as ``unparseable`` rather than skipped.
    """

    if "service=permission" not in text or "patterns=" not in text or not text.rstrip().endswith(" asking"):
        return None
    match = ASKING_RE.search(text)
    if not match:
        _warn(f"skipping unrecognized permission asking record in {source}:{sequence}")
        return None
    timestamp, permission, patterns_json = match.groups()
    try:
        patterns = json.loads(patterns_json)
    except json.JSONDecodeError as exc:
        try:
            patterns = json.loads(_escape_raw_newlines_in_json_strings(patterns_json))
        except json.JSONDecodeError:
            _warn(f"malformed permission asking patterns JSON in {source}:{sequence}: {exc}")
            return AskingEvent(timestamp, permission, ["unparseable"], source, sequence)
    if not isinstance(patterns, list) or not all(isinstance(item, str) for item in patterns):
        _warn(f"malformed permission asking patterns JSON in {source}:{sequence}: expected string array")
        return AskingEvent(timestamp, permission, ["unparseable"], source, sequence)
    return AskingEvent(timestamp, permission, patterns, source, sequence)


def _parse_council_session_line(line: str, *, source: str, sequence: int) -> SessionAgent | None:
    if "service=session" not in line or "title=council:" not in line or not line.rstrip().endswith("created"):
        return None

    parts = line.split()
    if len(parts) < 6 or parts[0] != "INFO":
        return None

    session_id = None
    for part in parts:
        if part.startswith("id=ses_"):
            session_id = part.removeprefix("id=")
            break
    if session_id is None:
        return None
    return SessionAgent(parts[1], session_id, "council", source, sequence)


def parse_session_agent_line(line: str, *, source: str, sequence: int) -> SessionAgent | None:
    """Parse a line that can map a session id to an agent name."""

    # Try subagent title first, per plan, before the generic agent= variant.
    for regex in (SUBAGENT_RE, SESSION_RE, LLM_RE):
        match = regex.search(line)
        if match:
            timestamp, session_id, agent = match.groups()
            return SessionAgent(timestamp, session_id, agent, source, sequence)
    return _parse_council_session_line(line, source=source, sequence=sequence)


def parse_prompt_line(line: str, *, source: str, sequence: int) -> PromptMarker | None:
    match = PROMPT_RE.search(line)
    if not match:
        return None
    timestamp, session_id = match.groups()
    return PromptMarker(timestamp, session_id, source, sequence)


def discover_log_files(log_dir: Path, start_date: str, end_date: str) -> list[Path]:
    """Return candidate log files using the filename date pre-filter."""

    start = _parse_date(start_date)
    end = _parse_date(end_date)
    if end < start:
        raise ValueError("end date must be on or after start date")

    if not log_dir.is_dir():
        return []

    filename_start = start - timedelta(days=1)
    files: list[Path] = []
    for path in log_dir.glob("*.log"):
        match = LOG_FILENAME_RE.match(path.name)
        if not match:
            continue
        file_date = _parse_date(match.group(1))
        if filename_start <= file_date <= end:
            files.append(path)
    return sorted(files, key=lambda item: item.name)


def _read_log_lines(paths: Iterable[Path]) -> tuple[dict[str, str], list[PromptMarker], list[PermissionEvent], list[AskingEvent]]:
    session_agents: dict[str, str] = {}
    prompts: list[PromptMarker] = []
    permissions: list[PermissionEvent] = []
    asking_events: list[AskingEvent] = []
    sequence = 0

    for path in paths:
        try:
            with path.open("r", encoding="utf-8", errors="replace") as handle:
                source = str(path)
                for record in reassemble_log_records(handle, source=source):
                    sequence += 1
                    line = record.text

                    session_agent = parse_session_agent_line(line, source=source, sequence=sequence)
                    if session_agent and session_agent.session_id not in session_agents:
                        session_agents[session_agent.session_id] = session_agent.agent

                    prompt = parse_prompt_line(line, source=source, sequence=sequence)
                    if prompt:
                        prompts.append(prompt)

                    permission = parse_permission_line(line, source=source, sequence=sequence)
                    if permission:
                        permissions.append(permission)

                    asking_event = parse_asking_record(line, source=source, sequence=sequence)
                    if asking_event:
                        asking_events.append(asking_event)
        except OSError as exc:
            _warn(f"skipping unreadable log file {path}: {exc}")

    prompts.sort(key=lambda item: (item.timestamp, item.sequence))
    permissions.sort(key=lambda item: (item.timestamp, item.sequence))
    asking_events.sort(key=lambda item: (item.timestamp, item.sequence))
    return session_agents, prompts, permissions, asking_events


def _read_plugin_audit_log(path: Path | None) -> list[PluginAuditRecord]:
    if path is None:
        return []
    expanded = path.expanduser()
    if not expanded.is_file():
        return []

    records: list[PluginAuditRecord] = []
    try:
        with expanded.open("r", encoding="utf-8", errors="replace") as handle:
            for sequence, raw_line in enumerate(handle, start=1):
                line = raw_line.strip()
                if not line:
                    continue
                try:
                    payload = json.loads(line)
                except json.JSONDecodeError as exc:
                    _warn(f"skipping malformed plugin audit JSON in {expanded}:{sequence}: {exc}")
                    continue
                timestamp = payload.get("ts")
                command_node_text = payload.get("command_node_text")
                timestamp_value = _parse_timestamp(timestamp) if isinstance(timestamp, str) else None
                if timestamp_value is None or not isinstance(command_node_text, str):
                    _warn(f"skipping malformed plugin audit record in {expanded}:{sequence}")
                    continue
                timestamp_value = _utc_aware_for_plugin_join(timestamp_value)
                session_id = payload.get("sessionID")
                agent = payload.get("agent")
                call_id = payload.get("callID")
                records.append(
                    PluginAuditRecord(
                        timestamp=timestamp,
                        timestamp_value=timestamp_value,
                        session_id=session_id if isinstance(session_id, str) else None,
                        agent=agent if isinstance(agent, str) else None,
                        call_id=call_id if isinstance(call_id, str) else None,
                        command_node_text=command_node_text,
                        source=str(expanded),
                        sequence=sequence,
                    )
                )
    except OSError as exc:
        _warn(f"skipping unreadable plugin audit log {expanded}: {exc}")
    records.sort(key=lambda item: (item.timestamp_value, item.sequence))
    return records


def _as_string_list(value: Any) -> list[str]:
    if not isinstance(value, list):
        return []
    return [item for item in value if isinstance(item, str)]


def _decision_action(reply: str) -> str:
    if reply in {"once", "always"}:
        return "allow"
    if reply == "reject":
        return "deny"
    return "unknown"


def _is_self_referential_decision(record: DecisionRecord) -> bool:
    haystacks = [*record.patterns, *record.always]
    return any(marker in value for value in haystacks for marker in SELF_AUDIT_MARKERS)


def _read_decisions_log(path: Path | None) -> tuple[bool, list[DecisionRecord]]:
    if path is None:
        return False, []
    expanded = path.expanduser()
    if not expanded.is_file():
        return False, []

    records: list[DecisionRecord] = []
    try:
        with expanded.open("r", encoding="utf-8", errors="replace") as handle:
            for sequence, raw_line in enumerate(handle, start=1):
                line = raw_line.strip()
                if not line:
                    continue
                try:
                    payload = json.loads(line)
                except json.JSONDecodeError as exc:
                    _warn(f"skipping malformed decisions JSON in {expanded}:{sequence}: {exc}")
                    continue
                timestamp = payload.get("ts")
                timestamp_value = _parse_timestamp(timestamp) if isinstance(timestamp, str) else None
                if timestamp_value is not None:
                    timestamp_value = _utc_aware_for_plugin_join(timestamp_value)
                session_id = payload.get("sessionID")
                call_id = payload.get("callID")
                permission = payload.get("permission")
                reply = payload.get("reply")
                records.append(
                    DecisionRecord(
                        timestamp=timestamp if isinstance(timestamp, str) else None,
                        timestamp_value=timestamp_value,
                        session_id=session_id if isinstance(session_id, str) else None,
                        call_id=call_id if isinstance(call_id, str) else None,
                        permission=permission if isinstance(permission, str) else "(missing permission)",
                        patterns=_as_string_list(payload.get("patterns")),
                        always=_as_string_list(payload.get("always")),
                        reply=reply if isinstance(reply, str) else "(missing reply)",
                        source=str(expanded),
                        sequence=sequence,
                    )
                )
    except OSError as exc:
        _warn(f"skipping unreadable decisions log {expanded}: {exc}")
    records.sort(key=lambda item: (item.timestamp_value or datetime.max.replace(tzinfo=timezone.utc), item.sequence))
    return True, records


def _order_preserving_union(existing: list[str], incoming: list[str]) -> None:
    seen = set(existing)
    for item in incoming:
        if item not in seen:
            existing.append(item)
            seen.add(item)


def _plugin_agent_indexes(
    plugin_records: list[PluginAuditRecord],
    *,
    start: date,
    end: date,
) -> tuple[dict[tuple[str, str], set[str]], dict[str, set[str]]]:
    by_call: dict[tuple[str, str], set[str]] = {}
    by_session: dict[str, set[str]] = {}
    for record in plugin_records:
        record_day = record.timestamp_value.date()
        if record_day < start or record_day > end or record.session_id is None:
            continue
        agent = record.agent or "unknown"
        by_session.setdefault(record.session_id, set()).add(agent)
        if record.call_id is not None:
            by_call.setdefault((record.session_id, record.call_id), set()).add(agent)
    return by_call, by_session


def _attribute_decision_agent(
    record: DecisionRecord,
    *,
    by_call: dict[tuple[str, str], set[str]],
    by_session: dict[str, set[str]],
) -> str:
    if record.session_id is None:
        return "unknown (no audit match)"
    if record.call_id is not None:
        agents = by_call.get((record.session_id, record.call_id))
        if agents:
            return next(iter(agents)) if len(agents) == 1 else "ambiguous"
    session_agents = by_session.get(record.session_id)
    if not session_agents:
        return "unknown (no audit match)"
    return next(iter(session_agents)) if len(session_agents) == 1 else "unknown"


def audit_decisions(
    decisions_log_path: str | Path | None,
    start_date: str,
    end_date: str,
    *,
    action_filter: str = "all",
    agent_filter: str | None = None,
    exclude_self: bool = False,
    plugin_log_path: str | Path | None = DEFAULT_PLUGIN_AUDIT_LOG,
) -> dict[str, Any]:
    """Build a v3 report from durable command-normalizer decisions records."""

    if action_filter not in {"allow", "deny", "all"}:
        raise ValueError("action_filter must be allow, deny, or all for source decisions")

    start = _parse_date(start_date)
    end = _parse_date(end_date)
    if end < start:
        raise ValueError("end date must be on or after start date")

    present, records = _read_decisions_log(Path(decisions_log_path) if decisions_log_path is not None else None)
    plugin_records = _read_plugin_audit_log(Path(plugin_log_path) if plugin_log_path is not None else None)
    agents_by_call, agents_by_session = _plugin_agent_indexes(plugin_records, start=start, end=end)
    caveats = [STATIC_BLINDNESS_CAVEAT]
    if not present:
        caveats.append(MISSING_DECISIONS_CAVEAT)
        _warn(MISSING_DECISIONS_CAVEAT)

    filtered_events: list[dict[str, Any]] = []
    undated_count = 0
    self_logged_excluded = 0
    agent_filter_normalized = agent_filter.casefold() if agent_filter else None

    for record in records:
        if record.timestamp_value is None or record.timestamp is None:
            undated_count += 1
            continue
        event_day = record.timestamp_value.date()
        if event_day < start or event_day > end:
            continue
        if exclude_self and _is_self_referential_decision(record):
            self_logged_excluded += 1
            continue
        action = _decision_action(record.reply)
        if action_filter != "all" and action != action_filter:
            continue
        agent = _attribute_decision_agent(record, by_call=agents_by_call, by_session=agents_by_session)
        if agent_filter_normalized is not None and agent.casefold() != agent_filter_normalized:
            continue
        filtered_events.append(
            {
                "timestamp": record.timestamp,
                "permission": record.permission,
                "action": action,
                "reply": record.reply,
                "agent": agent,
                "session_id": record.session_id,
                "patterns": record.patterns,
                "always": record.always,
            }
        )

    if undated_count:
        caveats.append(f"{undated_count} decisions records had unparseable ts values and were excluded from date-filtered counts")
    if exclude_self:
        caveats.append(f"{self_logged_excluded} {SELF_AUDIT_EXCLUSION_CAVEAT}")
    if action_filter == "deny":
        caveats.append(DENY_STATIC_BLINDNESS_WARNING)
        _warn(DENY_STATIC_BLINDNESS_WARNING)

    rule_aggregate: dict[tuple[str, str], dict[str, Any]] = {}
    invocation_aggregate: dict[tuple[str, tuple[str, ...], str], dict[str, Any]] = {}
    for event in filtered_events:
        invocation_key = (event["permission"], tuple(event["patterns"]), event["reply"])
        invocation = invocation_aggregate.setdefault(
            invocation_key,
            {
                "permission": event["permission"],
                "patterns": list(event["patterns"]),
                "always": [],
                "action": event["action"],
                "reply": event["reply"],
                "count": 0,
                "agents": set(),
                "session_ids": set(),
                "first_seen": event["timestamp"],
                "last_seen": event["timestamp"],
            },
        )
        invocation["count"] += 1
        invocation["agents"].add(event["agent"])
        if event["session_id"] is not None:
            invocation["session_ids"].add(event["session_id"])
        _order_preserving_union(invocation["always"], event["always"])
        if event["timestamp"] < invocation["first_seen"]:
            invocation["first_seen"] = event["timestamp"]
        if event["timestamp"] > invocation["last_seen"]:
            invocation["last_seen"] = event["timestamp"]

        deduped_always: list[str] = []
        _order_preserving_union(deduped_always, event["always"])
        for glob in deduped_always:
            rule_key = (event["permission"], glob)
            rule = rule_aggregate.setdefault(
                rule_key,
                {
                    "permission": event["permission"],
                    "glob": glob,
                    "count": 0,
                    "reply_breakdown": {},
                    "actions": {"allow": 0, "deny": 0, "unknown": 0},
                    "agents": set(),
                    "session_ids": set(),
                    "first_seen": event["timestamp"],
                    "last_seen": event["timestamp"],
                },
            )
            rule["count"] += 1
            rule["reply_breakdown"][event["reply"]] = rule["reply_breakdown"].get(event["reply"], 0) + 1
            rule["actions"][event["action"]] += 1
            rule["agents"].add(event["agent"])
            if event["session_id"] is not None:
                rule["session_ids"].add(event["session_id"])
            if event["timestamp"] < rule["first_seen"]:
                rule["first_seen"] = event["timestamp"]
            if event["timestamp"] > rule["last_seen"]:
                rule["last_seen"] = event["timestamp"]

    rules: list[dict[str, Any]] = []
    for rule in rule_aggregate.values():
        normalized = dict(rule)
        normalized["agents"] = _sort_agents(rule["agents"])
        normalized["session_ids"] = _sort_session_ids(rule["session_ids"])
        rules.append(normalized)
    rules.sort(key=lambda item: (-item["count"], item["permission"], item["glob"]))

    invocations: list[dict[str, Any]] = []
    for invocation in invocation_aggregate.values():
        normalized = dict(invocation)
        normalized["agents"] = _sort_agents(invocation["agents"])
        normalized["session_ids"] = _sort_session_ids(invocation["session_ids"])
        invocations.append(normalized)
    invocations.sort(key=lambda item: (-item["count"], item["permission"], item["patterns"], item["reply"]))

    allow_count = sum(1 for event in filtered_events if event["action"] == "allow")
    deny_count = sum(1 for event in filtered_events if event["action"] == "deny")
    unknown_count = sum(1 for event in filtered_events if event["action"] == "unknown")
    total_events = allow_count + deny_count + unknown_count
    if unknown_count:
        caveats.append("unknown decisions reply values were kept as action=unknown")
    if any(event["permission"] == "(missing permission)" for event in filtered_events):
        caveats.append('missing permission fields were kept as "(missing permission)"')

    return {
        "version": 3,
        "date_range": {"start": start_date, "end": end_date},
        "filters": {"action": action_filter, "agent": agent_filter, "exclude_self": exclude_self},
        "source": "decisions",
        "decisions_log_present": present,
        "summary": {
            "total_events": total_events,
            "allow_count": allow_count,
            "deny_count": deny_count,
            "unknown_count": unknown_count,
            "unique_rules": len(rules),
            "unique_invocations": len(invocations),
            "self_logged_excluded": self_logged_excluded,
        },
        "sources": {"decisions": total_events},
        "caveats": caveats,
        "rules": rules,
        "invocations": invocations,
    }


def _attribute_from_plugin(
    *,
    pattern: str,
    asking_timestamp: str,
    plugin_records: list[PluginAuditRecord],
) -> tuple[str, str | None]:
    # Known limitation: plugin command_node_text can include trailing shell
    # redirections that opencode's permission asking pattern may omit. Do not
    # normalize those here without a source-verified AST contract; an exact-text
    # miss degrades safely to unknown, while a guessed match could misattribute
    # a prompt to the wrong agent.
    parsed_asking_time = _parse_timestamp(asking_timestamp)
    if parsed_asking_time is None:
        return "unknown (pre-plugin)", None
    asking_time = _utc_aware_for_plugin_join(parsed_asking_time)

    candidates = [
        record
        for record in plugin_records
        if record.command_node_text == pattern
        and record.timestamp_value <= asking_time
        and asking_time - record.timestamp_value <= PLUGIN_JOIN_WINDOW
    ]
    if not candidates:
        return "unknown (pre-plugin)", None
    if len(candidates) > 1:
        return "ambiguous", None
    candidate = candidates[0]
    return candidate.agent or "unknown", candidate.session_id


def _correlate(event: PermissionEvent, prompts: list[PromptMarker]) -> PromptMarker | None:
    if not prompts:
        return None
    prompt_keys = [(prompt.timestamp, prompt.sequence) for prompt in prompts]
    index = bisect.bisect_right(prompt_keys, (event.timestamp, event.sequence)) - 1
    if index < 0:
        return None
    return prompts[index]


def _sort_agents(values: set[str | None]) -> list[str | None]:
    return sorted(values, key=lambda value: (value is None, value or ""))


def _sort_session_ids(values: set[str]) -> list[str]:
    return sorted(values)


def audit_logs(
    log_dir: str | Path,
    start_date: str,
    end_date: str,
    *,
    action_filter: str = "ask",
    agent_filter: str | None = None,
    plugin_log_path: str | Path | None = DEFAULT_PLUGIN_AUDIT_LOG,
) -> dict[str, Any]:
    """Build a schema-versioned permission audit report."""

    if action_filter not in {"ask", "deny", "all"}:
        raise ValueError("action_filter must be ask, deny, or all")

    start = _parse_date(start_date)
    end = _parse_date(end_date)
    if end < start:
        raise ValueError("end date must be on or after start date")

    paths = discover_log_files(Path(log_dir).expanduser(), start_date, end_date)
    session_agents, prompts, permissions, asking_events = _read_log_lines(paths)
    plugin_records = _read_plugin_audit_log(Path(plugin_log_path) if plugin_log_path is not None else None)

    agent_filter_normalized = agent_filter.casefold() if agent_filter else None
    filtered_events: list[dict[str, Any]] = []
    prompt_event_count = 0
    asking_identity_keys = {
        (asking_event.timestamp, asking_event.permission, pattern)
        for asking_event in asking_events
        for pattern in asking_event.patterns
    }

    if action_filter in {"ask", "all"}:
        for asking_event in asking_events:
            event_day = _event_date(asking_event.timestamp)
            if event_day is None or event_day < start or event_day > end:
                continue

            included_prompt = False
            for pattern in asking_event.patterns:
                agent, session_id = _attribute_from_plugin(
                    pattern=pattern,
                    asking_timestamp=asking_event.timestamp,
                    plugin_records=plugin_records,
                )
                if agent_filter_normalized is not None and agent.casefold() != agent_filter_normalized:
                    continue
                filtered_events.append(
                    {
                        "timestamp": asking_event.timestamp,
                        "permission": asking_event.permission,
                        "pattern": pattern,
                        "matched_rule": None,
                        "action": "ask",
                        "agent": agent,
                        "session_id": session_id,
                    }
                )
                included_prompt = True
            if included_prompt:
                prompt_event_count += 1

    for event in permissions:
        event_day = _event_date(event.timestamp)
        if event_day is None or event_day < start or event_day > end:
            continue
        if action_filter != "all" and event.action != action_filter:
            continue
        if event.action == "ask" and (event.timestamp, event.permission, event.pattern) in asking_identity_keys:
            continue

        prompt = _correlate(event, prompts)
        session_id = prompt.session_id if prompt else None
        agent = session_agents.get(session_id) if session_id else None

        if agent_filter_normalized is not None:
            if agent is None or agent.casefold() != agent_filter_normalized:
                continue

        filtered_events.append(
            {
                "timestamp": event.timestamp,
                "permission": event.permission,
                "pattern": event.pattern,
                "matched_rule": event.matched_rule,
                "action": event.action,
                "agent": agent,
                "session_id": session_id,
            }
        )

    aggregate: dict[tuple[str, str, str | None], dict[str, Any]] = {}
    for event in filtered_events:
        key = (event["permission"], event["pattern"], event["action"])
        entry = aggregate.setdefault(
            key,
            {
                "permission": event["permission"],
                "pattern": event["pattern"],
                "matched_rule": event["matched_rule"],
                "action": event["action"],
                "count": 0,
                "agents": set(),
                "session_ids": set(),
                "first_seen": event["timestamp"],
                "last_seen": event["timestamp"],
            },
        )
        entry["count"] += 1
        entry["agents"].add(event["agent"])
        if event["session_id"] is not None:
            entry["session_ids"].add(event["session_id"])
        if event["timestamp"] < entry["first_seen"]:
            entry["first_seen"] = event["timestamp"]
        if event["timestamp"] > entry["last_seen"]:
            entry["last_seen"] = event["timestamp"]

    entries: list[dict[str, Any]] = []
    for entry in aggregate.values():
        normalized = dict(entry)
        normalized["agents"] = _sort_agents(entry["agents"])
        normalized["session_ids"] = _sort_session_ids(entry["session_ids"])
        entries.append(normalized)
    entries.sort(key=lambda item: (-item["count"], item["permission"], item["pattern"], item["action"] or ""))

    total_ask = sum(1 for event in filtered_events if event["action"] == "ask")
    total_deny = sum(1 for event in filtered_events if event["action"] == "deny")
    pattern_occurrence_count = len(filtered_events)

    return {
        "version": 1,
        "date_range": {"start": start_date, "end": end_date},
        "filters": {"action": action_filter, "agent": agent_filter},
        "summary": {
            "total_events": pattern_occurrence_count,
            "prompt_event_count": prompt_event_count,
            "pattern_occurrence_count": pattern_occurrence_count,
            "total_ask": total_ask,
            "total_deny": total_deny,
            "unique_patterns": len(entries),
        },
        "entries": entries,
    }


def _truncate(value: Any, width: int) -> str:
    text = "null" if value is None else str(value)
    if len(text) <= width:
        return text.ljust(width)
    if width <= 1:
        return "…"
    return text[: width - 1] + "…"


def format_human(report: dict[str, Any]) -> str:
    """Render a compact table for interactive use."""

    if report.get("version") == 3:
        return _format_human_v3(report)

    start = report["date_range"]["start"]
    end = report["date_range"]["end"]
    filters = report["filters"]
    agent_suffix = f", agent={filters['agent']}" if filters.get("agent") else ""
    lines = [
        f"Permission Audit: {start} to {end} (action={filters['action']}{agent_suffix})",
        "",
        " # | Permission | Pattern                                          | Rule          | Count | Agents",
        "---|------------|--------------------------------------------------|---------------|-------|--------",
    ]
    for index, entry in enumerate(report["entries"], start=1):
        agents = ", ".join("null" if agent is None else str(agent) for agent in entry["agents"])
        lines.append(
            f"{index:2d} | "
            f"{_truncate(entry['permission'], 10)} | "
            f"{_truncate(entry['pattern'], 48)} | "
            f"{_truncate(entry.get('matched_rule'), 13)} | "
            f"{entry['count']:5d} | "
            f"{agents}"
        )
    summary = report["summary"]
    lines.extend(
        [
            "",
            "Total: "
            f"{summary['prompt_event_count']} prompt events, "
            f"{summary['pattern_occurrence_count']} pattern occurrences, "
            f"{summary['unique_patterns']} unique patterns",
        ]
    )
    return "\n".join(lines)


def _format_human_v3(report: dict[str, Any]) -> str:
    start = report["date_range"]["start"]
    end = report["date_range"]["end"]
    filters = report["filters"]
    agent_suffix = f", agent={filters['agent']}" if filters.get("agent") else ""
    exclude_suffix = ", exclude_self=true" if filters.get("exclude_self") else ""
    lines = [
        f"Permission Audit: {start} to {end} (source=decisions, action={filters['action']}{agent_suffix}{exclude_suffix})",
        "",
        "Rules",
        " # | Permission | Glob | Count | Replies | Actions | Agents | First | Last",
        "---|------------|------|-------|---------|---------|--------|-------|-----",
    ]
    if report["rules"]:
        for index, entry in enumerate(report["rules"], start=1):
            agents = ", ".join("null" if agent is None else str(agent) for agent in entry["agents"])
            replies = ", ".join(f"{reply}:{count}" for reply, count in entry.get("reply_breakdown", {}).items())
            actions = ", ".join(f"{action}:{count}" for action, count in entry.get("actions", {}).items())
            lines.append(
                f"{index:2d} | "
                f"{_truncate(entry['permission'], 40)} | "
                f"{entry['glob']} | "
                f"{entry['count']:5d} | "
                f"{replies} | "
                f"{actions} | "
                f"{agents} | "
                f"{entry['first_seen']} | "
                f"{entry['last_seen']}"
            )
    else:
        lines.append("(none)")

    lines.extend(
        [
            "",
            "Invocations",
            " # | Permission | Patterns | Always | Action | Reply | Count | Agents | First | Last",
            "---|------------|----------|--------|--------|-------|-------|--------|-------|-----",
        ]
    )
    if report["invocations"]:
        for index, entry in enumerate(report["invocations"], start=1):
            agents = ", ".join("null" if agent is None else str(agent) for agent in entry["agents"])
            patterns = ", ".join(entry.get("patterns", []))
            always = ", ".join(entry.get("always", []))
            lines.append(
                f"{index:2d} | "
                f"{_truncate(entry['permission'], 40)} | "
                f"{patterns} | "
                f"{always} | "
                f"{entry['action']} | "
                f"{entry['reply']} | "
                f"{entry['count']:5d} | "
                f"{agents} | "
                f"{entry['first_seen']} | "
                f"{entry['last_seen']}"
            )
    else:
        lines.append("(none)")
    summary = report["summary"]
    lines.extend(
        [
            "",
            "Total: "
            f"{summary['total_events']} events, "
            f"allow={summary['allow_count']}, "
            f"deny={summary['deny_count']}, "
            f"unknown={summary['unknown_count']}, "
            f"unique rules={summary['unique_rules']}, "
            f"unique invocations={summary['unique_invocations']}, "
            f"self logged excluded={summary['self_logged_excluded']}",
            f"Sources: decisions={report['sources']['decisions']}",
            f"decisions.log present: {str(report['decisions_log_present']).lower()}",
        ]
    )
    if report.get("caveats"):
        lines.extend(["", "Caveats:"])
        lines.extend(f"- {caveat}" for caveat in report["caveats"])
    return "\n".join(lines)


def _default_today() -> str:
    return date.today().isoformat()


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        formatter_class=argparse.RawDescriptionHelpFormatter,
        description=(
            "Audit opencode permission prompts from local logs. opencode retains only about "
            "10 log files; pre-plugin agent attribution is not reliably recoverable; "
            "SQLite permission/event tables are empty in v1.15.13."
        ),
        epilog=(
            "Output:\n"
            "  JSON object with schema depending on --source. Decisions output is an interactive-prompt audit; "
            "static allow and deny rules that never prompt are not captured — not a comprehensive policy audit."
        )
    )
    parser.add_argument("--start", default=_default_today(), help="Start date, YYYY-MM-DD (default: today)")
    parser.add_argument("--end", default=_default_today(), help="End date, YYYY-MM-DD (default: today)")
    parser.add_argument("--source", choices=("decisions", "native"), default="decisions", help="Audit source (default: decisions)")
    parser.add_argument("--action", choices=("ask", "allow", "deny", "all"), default=None, help="Permission decision filter")
    parser.add_argument("--agent", default=None, help="Agent name filter, case-insensitive")
    parser.add_argument("--decisions-log", default=None, help="Override decisions.log path")
    parser.add_argument(
        "--exclude-self",
        action="store_true",
        help="Exclude decision records whose patterns[] or always[] mention permission-audit.sh or permission_audit_core",
    )
    output = parser.add_mutually_exclusive_group()
    output.add_argument("--json", action="store_true", dest="json_output", help="Emit JSON (default)")
    output.add_argument("--human", action="store_true", help="Emit a human-readable table")
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    action = args.action if args.action is not None else ("ask" if args.source == "native" else "all")

    if args.source == "native" and action == "allow":
        parser.error("--source native does not support --action allow")
    if args.source == "decisions" and action == "ask":
        parser.error("--source decisions does not support --action ask")

    try:
        if args.source == "native":
            report = audit_logs(
                Path(os.environ.get("OPENCODE_LOG_DIR", "~/.local/share/opencode/log/")).expanduser(),
                args.start,
                args.end,
                action_filter=action,
                agent_filter=args.agent,
            )
        else:
            decisions_path = args.decisions_log or os.environ.get("OPENCODE_DECISIONS_LOG") or DEFAULT_DECISIONS_LOG
            report = audit_decisions(
                decisions_path,
                args.start,
                args.end,
                action_filter=action,
                agent_filter=args.agent,
                exclude_self=args.exclude_self,
            )
    except ValueError as exc:
        parser.error(str(exc))

    if args.human:
        print(format_human(report))
    else:
        json.dump(report, sys.stdout, indent=2)
        print()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
