#!/usr/bin/env python3
"""Audit opencode permission evaluations from local log files.

The shell wrapper owns dependency checks and broad CLI convention. This module
keeps the parsing, temporal correlation, aggregation, and output formatting in
Python so commands and paths with shell metacharacters remain data, not syntax.
"""

from __future__ import annotations

import argparse
import bisect
import json
import os
import re
import sys
from dataclasses import dataclass
from datetime import date, datetime, timedelta
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

DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
LOG_FILENAME_RE = re.compile(r"^(\d{4}-\d{2}-\d{2})T.*\.log$")


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


def _read_log_lines(paths: Iterable[Path]) -> tuple[dict[str, str], list[PromptMarker], list[PermissionEvent]]:
    session_agents: dict[str, str] = {}
    prompts: list[PromptMarker] = []
    permissions: list[PermissionEvent] = []
    sequence = 0

    for path in paths:
        try:
            with path.open("r", encoding="utf-8", errors="replace") as handle:
                for raw_line in handle:
                    sequence += 1
                    line = raw_line.rstrip("\n")
                    source = str(path)

                    session_agent = parse_session_agent_line(line, source=source, sequence=sequence)
                    if session_agent and session_agent.session_id not in session_agents:
                        session_agents[session_agent.session_id] = session_agent.agent

                    prompt = parse_prompt_line(line, source=source, sequence=sequence)
                    if prompt:
                        prompts.append(prompt)

                    permission = parse_permission_line(line, source=source, sequence=sequence)
                    if permission:
                        permissions.append(permission)
        except OSError as exc:
            _warn(f"skipping unreadable log file {path}: {exc}")

    prompts.sort(key=lambda item: (item.timestamp, item.sequence))
    permissions.sort(key=lambda item: (item.timestamp, item.sequence))
    return session_agents, prompts, permissions


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
) -> dict[str, Any]:
    """Build a schema-versioned permission audit report."""

    if action_filter not in {"ask", "deny", "all"}:
        raise ValueError("action_filter must be ask, deny, or all")

    start = _parse_date(start_date)
    end = _parse_date(end_date)
    if end < start:
        raise ValueError("end date must be on or after start date")

    paths = discover_log_files(Path(log_dir).expanduser(), start_date, end_date)
    session_agents, prompts, permissions = _read_log_lines(paths)

    agent_filter_normalized = agent_filter.casefold() if agent_filter else None
    filtered_events: list[tuple[PermissionEvent, str | None, str | None]] = []
    for event in permissions:
        event_day = _event_date(event.timestamp)
        if event_day is None or event_day < start or event_day > end:
            continue
        if action_filter != "all" and event.action != action_filter:
            continue

        prompt = _correlate(event, prompts)
        session_id = prompt.session_id if prompt else None
        agent = session_agents.get(session_id) if session_id else None

        if agent_filter_normalized is not None:
            if agent is None or agent.casefold() != agent_filter_normalized:
                continue

        filtered_events.append((event, agent, session_id))

    aggregate: dict[tuple[str, str, str | None], dict[str, Any]] = {}
    for event, agent, session_id in filtered_events:
        key = (event.permission, event.pattern, event.action)
        entry = aggregate.setdefault(
            key,
            {
                "permission": event.permission,
                "pattern": event.pattern,
                "matched_rule": event.matched_rule,
                "action": event.action,
                "count": 0,
                "agents": set(),
                "session_ids": set(),
                "first_seen": event.timestamp,
                "last_seen": event.timestamp,
            },
        )
        entry["count"] += 1
        entry["agents"].add(agent)
        if session_id is not None:
            entry["session_ids"].add(session_id)
        if event.timestamp < entry["first_seen"]:
            entry["first_seen"] = event.timestamp
        if event.timestamp > entry["last_seen"]:
            entry["last_seen"] = event.timestamp

    entries: list[dict[str, Any]] = []
    for entry in aggregate.values():
        normalized = dict(entry)
        normalized["agents"] = _sort_agents(entry["agents"])
        normalized["session_ids"] = _sort_session_ids(entry["session_ids"])
        entries.append(normalized)
    entries.sort(key=lambda item: (-item["count"], item["permission"], item["pattern"], item["action"] or ""))

    total_ask = sum(1 for event, _, _ in filtered_events if event.action == "ask")
    total_deny = sum(1 for event, _, _ in filtered_events if event.action == "deny")

    return {
        "version": 1,
        "date_range": {"start": start_date, "end": end_date},
        "filters": {"action": action_filter, "agent": agent_filter},
        "summary": {
            "total_events": len(filtered_events),
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
            f"Total: {summary['total_events']} events, {summary['unique_patterns']} unique patterns",
        ]
    )
    return "\n".join(lines)


def _default_today() -> str:
    return date.today().isoformat()


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Audit opencode permission decisions from local logs.")
    parser.add_argument("--start", default=_default_today(), help="Start date, YYYY-MM-DD (default: today)")
    parser.add_argument("--end", default=_default_today(), help="End date, YYYY-MM-DD (default: today)")
    parser.add_argument("--action", choices=("ask", "deny", "all"), default="ask", help="Permission decision filter")
    parser.add_argument("--agent", default=None, help="Agent name filter, case-insensitive")
    output = parser.add_mutually_exclusive_group()
    output.add_argument("--json", action="store_true", dest="json_output", help="Emit JSON (default)")
    output.add_argument("--human", action="store_true", help="Emit a human-readable table")
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    try:
        report = audit_logs(
            Path(os.environ.get("OPENCODE_LOG_DIR", "~/.local/share/opencode/log/")).expanduser(),
            args.start,
            args.end,
            action_filter=args.action,
            agent_filter=args.agent,
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
