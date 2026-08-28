#!/usr/bin/env python3
"""Read-only aggregator for the team kanban board.

Python 3 stdlib only. Serves the frozen contract in
docs/plans/board-api-contract.md:

    GET /                     -> index.html from this directory
    GET /api/team?team=<name> -> aggregated team JSON
    GET /api/teams            -> team switcher list
    anything else             -> 404; non-GET -> 405

Protocol boundary (docs/plans/2026-08-28-team-kanban-board.md sections 3, 5, 6):
this process opens only the control-plane files below. It never opens
``artifacts/`` and never writes, creates, or executes anything under ``.teams/``.
Receipt fields go through the same whitelist that ``teamctl.sh show_receipt``
enforces; a single bad field invalidates the whole receipt, which is then
reported as ``invalid-receipt:<id>`` in ``warnings`` and never echoed verbatim.
"""

import argparse
import json
import os
import re
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

BOARD_DIR = os.path.dirname(os.path.abspath(__file__))
INDEX_HTML = os.path.join(BOARD_DIR, "index.html")

# Mirrors valid_team_name / valid_task_id in teamctl.sh.
NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
# Mirrors the blocker whitelist in show_receipt.
BLOCKER_RE = re.compile(r"^(none|[A-Za-z0-9][A-Za-z0-9._-]*)$")

RECEIPT_STATUS = ("completed", "blocked", "failed")
RECEIPT_VERDICT = ("pass", "fail", "unverified", "not_applicable")
RECEIPT_NEXT = ("verify", "rework", "deliver", "await_user", "none")
WORKTREE_STATUS = ("working", "blocked", "review", "merged", "closed")

TITLE_LIMIT = 120
FEED_LIMIT = 20


def valid_name(value):
    return isinstance(value, str) and bool(NAME_RE.match(value))


# ---------------------------------------------------------------------------
# Low level readers. Every one of them tolerates a missing or unreadable file:
# the control directory is written concurrently by teamctl.sh and half-written
# rows must degrade, never crash the board.
# ---------------------------------------------------------------------------


def read_text(path, limit=1 << 20):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            return handle.read(limit)
    except OSError:
        return None


def read_rows(path, columns):
    """Parse a tab-separated append-only board file into fixed-width rows."""
    text = read_text(path)
    if text is None:
        return []
    rows = []
    for line in text.splitlines():
        if not line.strip():
            continue
        fields = line.split("\t")
        if len(fields) < columns:
            continue
        rows.append(fields[:columns])
    return rows


def read_meta(team_dir):
    """Parse team-meta.env without shell-evaluating it.

    teamctl.sh writes this file with ``printf %q``, so values may carry
    ``'...'`` or ``$'...'`` quoting. Best-effort unquoting only; this file is
    written by teamctl.sh but still treated as untrusted input.
    """
    path = os.path.join(team_dir, "team-meta.env")
    text = read_text(path)
    if text is None:
        # The frozen contract names this file `team.meta`; the shipped
        # implementation writes `team-meta.env`. Accept both.
        text = read_text(os.path.join(team_dir, "team.meta"))
    meta = {}
    if text is None:
        return meta
    for line in text.splitlines():
        if "=" not in line:
            continue
        key, _, value = line.partition("=")
        key = key.strip()
        if not key:
            continue
        value = value.strip()
        if value.startswith("$'") and value.endswith("'") and len(value) > 2:
            value = value[2:-1]
        elif value.startswith("'") and value.endswith("'") and len(value) > 1:
            value = value[1:-1]
        elif value.startswith('"') and value.endswith('"') and len(value) > 1:
            value = value[1:-1]
        meta[key] = value
    return meta


def clean_text(value, limit=TITLE_LIMIT):
    """Collapse a file-sourced string into a bounded single-line plain value."""
    if value is None:
        return None
    value = "".join(ch for ch in value if ch == " " or ch.isprintable())
    value = " ".join(value.split())
    if not value:
        return None
    if len(value) > limit:
        value = value[: limit - 1] + "…"
    return value


# ---------------------------------------------------------------------------
# Team discovery
# ---------------------------------------------------------------------------


def list_teams(teams_root):
    """Same rule as `teamctl.sh teams`: a directory holding team metadata."""
    teams = []
    try:
        entries = sorted(os.listdir(teams_root))
    except OSError:
        return teams
    for name in entries:
        if not valid_name(name):
            continue
        team_dir = os.path.join(teams_root, name)
        if not os.path.isdir(team_dir):
            continue
        if not (
            os.path.isfile(os.path.join(team_dir, "team-meta.env"))
            or os.path.isfile(os.path.join(team_dir, "team.meta"))
        ):
            continue
        meta = read_meta(team_dir)
        teams.append(
            {
                "name": name,
                "status": clean_text(meta.get("TEAM_STATUS")) or "unknown",
            }
        )
    return teams


# ---------------------------------------------------------------------------
# Receipt validation — the whitelist half of teamctl.sh show_receipt.
# ---------------------------------------------------------------------------


def receipt_value(lines, key):
    prefix = key + ": "
    for line in lines:
        if line.startswith(prefix):
            return line[len(prefix) :]
    return None


def parse_receipt(receipts_dir, task_id, owner):
    """Return (receipt_dict | None, complete_bool).

    ``complete`` says the `DONE <id>` sentinel is present, which is what the
    column mapping keys on. A complete-but-invalid receipt returns
    ``(None, True)`` so the caller can record ``invalid-receipt:<id>`` and still
    keep the task out of ``doing``.
    """
    text = read_text(os.path.join(receipts_dir, task_id + ".md"), limit=1 << 16)
    if text is None:
        return None, False
    lines = text.splitlines()
    while lines and not lines[-1].strip():
        lines.pop()
    if not lines or lines[-1] != "DONE " + task_id:
        return None, False

    fields = {
        "task_id": receipt_value(lines, "task_id"),
        "worker": receipt_value(lines, "worker"),
        "status": receipt_value(lines, "status"),
        "verdict": receipt_value(lines, "verdict"),
        "blocker": receipt_value(lines, "blocker"),
        "next": receipt_value(lines, "next"),
        "artifact": receipt_value(lines, "artifact"),
    }

    if fields["task_id"] != task_id:
        return None, True
    # show_receipt requires the receipt worker to equal the board.tsv owner.
    if not owner or fields["worker"] != owner:
        return None, True
    if fields["status"] not in RECEIPT_STATUS:
        return None, True
    if fields["verdict"] not in RECEIPT_VERDICT:
        return None, True
    if fields["next"] not in RECEIPT_NEXT:
        return None, True
    if not fields["blocker"] or not BLOCKER_RE.match(fields["blocker"]):
        return None, True
    if not valid_artifact(fields["artifact"], task_id):
        return None, True

    return (
        {
            "status": fields["status"],
            "verdict": fields["verdict"],
            "blocker": fields["blocker"],
            "next": fields["next"],
            "artifact": fields["artifact"],
        },
        True,
    )


def valid_artifact(value, task_id):
    """`none`, or a path whose tail is `artifacts/<task-id>.md`.

    show_receipt compares against the absolute `$TEAM_DIR/artifacts/<id>.md`.
    The board cannot do that: under the sandbox `--teams-root` is a remapped
    path that will not equal the absolute path a worker wrote into the receipt.
    Matching the tail keeps the same shape guarantee without the path identity.
    The value is only ever echoed as a string; this process never opens it.
    """
    if value is None:
        return False
    if value == "none":
        return True
    if "\t" in value or "\n" in value or "\r" in value:
        return False
    if any(not (ch == " " or ch.isprintable()) for ch in value):
        return False
    return value.endswith("artifacts/" + task_id + ".md")


# ---------------------------------------------------------------------------
# Lineage
# ---------------------------------------------------------------------------


def build_flow_lineage(flow_rows, known_tasks):
    """parent chains from flow.tsv: epoch_ts, task_id, worker, parent|-.

    Returns {task_id: [{"task":..,"worker":..}, ...]} covering the ancestors of
    each task plus the task itself. Returns {} when flow.tsv gives us nothing
    usable, which makes the caller fall back to the id-prefix heuristic.
    """
    parent = {}
    worker_of = {}
    order = []
    for row in flow_rows:
        _ts, task_id, worker, parent_id = row[0], row[1], row[2], row[3]
        if not valid_name(task_id) or task_id not in known_tasks:
            continue
        if not valid_name(worker):
            continue
        if task_id not in worker_of:
            order.append(task_id)
        worker_of[task_id] = worker
        if valid_name(parent_id) and parent_id != task_id:
            parent[task_id] = parent_id
        else:
            parent.pop(task_id, None)
    if not worker_of:
        return {}

    def ancestors(task_id):
        chain = []
        seen = set()
        cursor = task_id
        while cursor and cursor not in seen:
            seen.add(cursor)
            chain.append(cursor)
            cursor = parent.get(cursor)
        chain.reverse()
        return chain

    lineage = {}
    for task_id in order:
        lineage[task_id] = [
            {"task": node, "worker": worker_of.get(node)} for node in ancestors(task_id)
        ]
    return lineage


def heuristic_root(task_id, known_tasks):
    """Weak recovery when flow.tsv is absent: strip `-` suffixes.

    `T5-verify` -> `T5` when `T5` is itself a known task id. Longest matching
    prefix wins, so `T5-a-b` prefers root `T5-a` over `T5`. A task with no such
    prefix is its own root.
    """
    parts = task_id.split("-")
    for cut in range(len(parts) - 1, 0, -1):
        candidate = "-".join(parts[:cut])
        if candidate in known_tasks:
            return candidate
    return task_id


def build_heuristic_lineage(known_tasks, order, owners):
    """Group tasks by heuristic root, ordered the way they were dispatched.

    ``order`` must put dispatched tasks in board.tsv row order and never-
    dispatched contracts after them, so a relay chain reads root -> successor.
    The root itself is forced to the head of its own group even if it was never
    dispatched.
    """
    groups = {}
    for task_id in order:
        groups.setdefault(heuristic_root(task_id, known_tasks), []).append(task_id)
    lineage = {}
    for root, members in groups.items():
        if root in members and members[0] != root:
            members = [root] + [t for t in members if t != root]
        chain = [{"task": t, "worker": owners.get(t)} for t in members]
        for index, task_id in enumerate(members):
            lineage[task_id] = chain[: index + 1]
    return lineage


# ---------------------------------------------------------------------------
# Aggregation
# ---------------------------------------------------------------------------


def resolve_mode(team_dir):
    """mode.md holds the scenario snapshot; expose only its first heading."""
    text = read_text(os.path.join(team_dir, "mode.md"), limit=1 << 16)
    if text is None:
        return None
    for line in text.splitlines():
        value = clean_text(line.lstrip("# ").strip(), 60)
        if value:
            return value
    return None


def build_team(teams_root, team_name):
    team_dir = os.path.join(teams_root, team_name)
    warnings = []
    meta = read_meta(team_dir)

    # --- roster -------------------------------------------------------------
    # workers.tsv: name, pane. agents.tsv: role, name, runtime, session, dir,
    # pane, lifecycle. agents.tsv carries the runtime, workers.tsv is the seat.
    agent_rows = read_rows(os.path.join(team_dir, "agents.tsv"), 7)
    worker_rows = read_rows(os.path.join(team_dir, "workers.tsv"), 2)

    agent_by_name = {}
    agent_order = []
    for role, name, runtime, _session, _dir, _pane, lifecycle in agent_rows:
        if not valid_name(name):
            continue
        if name not in agent_by_name:
            agent_order.append(name)
        agent_by_name[name] = {
            "role": role if role in ("leader", "worker") else "worker",
            "runtime": clean_text(runtime, 40),
            "lifecycle": clean_text(lifecycle, 40),
        }

    roster_names = []
    for name, _pane in worker_rows:
        if valid_name(name) and name not in roster_names:
            roster_names.append(name)
    for name in agent_order:
        if name not in roster_names:
            roster_names.append(name)

    # --- board / worktrees / flow -------------------------------------------
    board_rows = read_rows(os.path.join(team_dir, "board.tsv"), 2)
    worktree_rows = read_rows(os.path.join(team_dir, "worktrees.tsv"), 6)
    flow_rows = read_rows(os.path.join(team_dir, "flow.tsv"), 4)

    # show_receipt takes the FIRST board.tsv row for an id as the owner.
    owners = {}
    dispatch_order = []
    for task_id, worker in board_rows:
        if not valid_name(task_id) or not valid_name(worker):
            continue
        if task_id not in owners:
            owners[task_id] = worker
            dispatch_order.append(task_id)

    # Latest row per worker wins, matching _latest_worktree_rows.
    worktrees = {}
    for worker, _pane, mr, _dir, branch, status in worktree_rows:
        if not valid_name(worker):
            continue
        worktrees[worker] = {
            "mr": clean_text(mr, 40),
            "branch": clean_text(branch, 80),
            "status": status if status in WORKTREE_STATUS else None,
        }

    # --- tasks --------------------------------------------------------------
    # Task ids come only from listing tasks/ and from validated board/flow rows.
    # Never from a query parameter.
    tasks_dir = os.path.join(team_dir, "tasks")
    contract_ids = []
    try:
        for entry in sorted(os.listdir(tasks_dir)):
            if not entry.endswith(".md"):
                continue
            task_id = entry[:-3]
            if valid_name(task_id):
                contract_ids.append(task_id)
    except OSError:
        pass

    task_order = list(contract_ids)
    for task_id in dispatch_order:
        if task_id not in task_order:
            task_order.append(task_id)
    known_tasks = set(task_order)

    # flow.tsv is authoritative where it covers a task; anything it misses
    # (older tasks, a leader that omitted --parent) degrades to the id-prefix
    # heuristic and is labelled as such per task.
    flow_lineage = build_flow_lineage(flow_rows, known_tasks)
    # Dispatched tasks first, in board.tsv row order: that is the only ordering
    # signal the control plane has when flow.tsv is absent.
    heuristic_order = list(dispatch_order)
    heuristic_order += [t for t in task_order if t not in owners]
    heuristic_lineage = build_heuristic_lineage(known_tasks, heuristic_order, owners)

    receipts_dir = os.path.join(team_dir, "receipts")
    tasks = []
    receipts_feed = []
    attention = []
    engaged_workers = set(owners.values())
    for row in flow_rows:
        if valid_name(row[2]):
            engaged_workers.add(row[2])

    receipt_by_task = {}
    for task_id in task_order:
        owner = owners.get(task_id)
        receipt, complete = parse_receipt(receipts_dir, task_id, owner)
        if complete and receipt is None:
            warnings.append("invalid-receipt:" + task_id)
        receipt_by_task[task_id] = (receipt, complete)

    for task_id in task_order:
        owner = owners.get(task_id)
        receipt, complete = receipt_by_task[task_id]
        worktree = worktrees.get(owner) if owner else None
        badges = []

        # Column mapping, plan section 3.
        if owner is None:
            column = "todo"
        elif receipt is not None and receipt["status"] == "completed":
            column = "done"
        elif receipt is not None and receipt["status"] in ("blocked", "failed"):
            column = "blocked"
            badges.append("receipt:" + receipt["status"])
        elif worktree is not None and worktree["status"] == "blocked":
            column = "blocked"
            badges.append("worktree:blocked")
        elif complete:
            # Sentinel present but the receipt failed validation: it is no
            # longer in flight, yet nothing can be asserted about its outcome.
            column = "blocked"
        else:
            column = "doing"

        if (
            column == "blocked"
            and receipt is not None
            and worktree is not None
            and worktree["status"] == "blocked"
            and "worktree:blocked" not in badges
        ):
            badges.append("worktree:blocked")

        if receipt is not None and receipt["verdict"] == "fail":
            badges.append("verdict:fail")

        chain = flow_lineage.get(task_id)
        lineage_source = "flow"
        if not chain:
            lineage_source = "heuristic"
            chain = heuristic_lineage.get(task_id) or [
                {"task": task_id, "worker": owner}
            ]
            badges.append("heuristic-lineage")

        title = None
        contract_text = read_text(
            os.path.join(tasks_dir, task_id + ".md"), limit=1 << 16
        )
        if contract_text is not None:
            for line in contract_text.splitlines():
                title = clean_text(line.lstrip("# ").strip())
                if title:
                    break

        tasks.append(
            {
                "id": task_id,
                "title": title,
                "column": column,
                "owner": owner,
                "badges": badges,
                "receipt": receipt,
                "worktree": worktree,
                "lineage": {"chain": chain, "source": lineage_source},
            }
        )

        if receipt is not None and (
            receipt["status"] in ("blocked", "failed") or receipt["next"] == "await_user"
        ):
            attention.append(task_id)

        if receipt is not None:
            try:
                mtime = int(os.path.getmtime(os.path.join(receipts_dir, task_id + ".md")))
            except OSError:
                mtime = 0
            receipts_feed.append(
                {
                    "task": task_id,
                    "worker": owner,
                    "mtime": mtime,
                    "fields": {
                        "status": receipt["status"],
                        "verdict": receipt["verdict"],
                        "blocker": receipt["blocker"],
                        "next": receipt["next"],
                    },
                }
            )

    # A completed verify task with verdict:fail routes its lineage predecessor
    # back to rework.
    by_id = {task["id"]: task for task in tasks}
    for task in tasks:
        receipt = task["receipt"]
        if receipt is None or receipt["verdict"] != "fail":
            continue
        chain = task["lineage"]["chain"]
        if len(chain) < 2:
            continue
        target = by_id.get(chain[-2]["task"])
        if target is not None and "rework" not in target["badges"]:
            target["badges"].append("rework")

    roster = []
    for name in roster_names:
        agent = agent_by_name.get(name, {})
        roster.append(
            {
                "worker": name,
                "runtime": agent.get("runtime"),
                "role": agent.get("role", "worker"),
                "registered_at": None,  # agents.tsv carries no timestamp
                "new": name not in engaged_workers,
            }
        )

    receipts_feed.sort(key=lambda item: item["mtime"], reverse=True)

    return {
        "team": {
            "name": team_name,
            "status": clean_text(meta.get("TEAM_STATUS")) or "unknown",
            "mode": resolve_mode(team_dir),
            "session": clean_text(meta.get("TEAM_TMUX_SESSION")),
        },
        "roster": roster,
        "tasks": tasks,
        "attention": attention,
        "receipts_feed": receipts_feed[:FEED_LIMIT],
        "generated_at": int(time.time()),
        "warnings": warnings,
    }


# ---------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------


class BoardHandler(BaseHTTPRequestHandler):
    server_version = "teamboard/1.0"
    teams_root = None

    def log_message(self, fmt, *args):  # keep the console quiet
        pass

    def _send(self, code, body, content_type):
        payload = body if isinstance(body, bytes) else body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(payload)

    def _json(self, code, obj):
        self._send(
            code,
            json.dumps(obj, ensure_ascii=False),
            "application/json; charset=utf-8",
        )

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path
        query = parse_qs(parsed.query)

        if path == "/":
            # Read per request: index.html is produced separately and may land
            # after this process starts. serve.py never writes it.
            html = read_text(INDEX_HTML, limit=1 << 22)
            if html is None:
                self._send(
                    503,
                    "board/index.html is not available\n",
                    "text/plain; charset=utf-8",
                )
                return
            self._send(200, html, "text/html; charset=utf-8")
            return

        if path == "/api/teams":
            self._json(200, {"teams": list_teams(self.teams_root)})
            return

        if path == "/api/team":
            teams = list_teams(self.teams_root)
            names = [team["name"] for team in teams]
            requested = query.get("team", [None])[0]
            if requested is None:
                if len(names) == 1:
                    requested = names[0]
                else:
                    self._json(400, {"error": "team_required", "teams": names})
                    return
            # Validate before any path join: this is untrusted input and a
            # traversal vector.
            if not valid_name(requested) or requested not in names:
                self._json(400, {"error": "team_required", "teams": names})
                return
            self._json(200, build_team(self.teams_root, requested))
            return

        self._json(404, {"error": "not_found"})

    def do_HEAD(self):
        self.do_GET()

    def _reject(self):
        self._json(405, {"error": "method_not_allowed"})

    do_POST = _reject
    do_PUT = _reject
    do_PATCH = _reject
    do_DELETE = _reject
    do_OPTIONS = _reject


def main(argv=None):
    parser = argparse.ArgumentParser(description="team kanban board (read-only)")
    parser.add_argument("--teams-root", required=True, help="path to .teams/")
    parser.add_argument("--port", type=int, default=8737, help="0 picks a free port")
    parser.add_argument("--host", default="127.0.0.1")
    args = parser.parse_args(argv)

    teams_root = os.path.abspath(args.teams_root)
    if not os.path.isdir(teams_root):
        print("teams root is not a directory: " + teams_root, file=sys.stderr)
        return 1

    handler = type("BoundBoardHandler", (BoardHandler,), {"teams_root": teams_root})
    httpd = ThreadingHTTPServer((args.host, args.port), handler)
    httpd.daemon_threads = True
    print(
        "board listening on http://%s:%d (teams-root=%s)"
        % (args.host, httpd.server_address[1], teams_root),
        flush=True,
    )
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
