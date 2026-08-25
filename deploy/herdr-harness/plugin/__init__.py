"""Hermes plugin exposing Herdr as a persistent team coding harness."""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Any

TOOL_NAME = "herdr_harness"
MAX_OUTPUT = 200_000
AUTO_TOOLSETS = (
    "hermes-cli",
    "hermes-acp",
    "hermes-discord",
    "hermes-slack",
    "hermes-telegram",
    "hermes-whatsapp",
    "hermes-signal",
    "hermes-email",
    "hermes-sms",
)


def truthy(name: str, default: bool = False) -> bool:
    value = os.getenv(name)
    if value is None:
        return default
    return value.strip().lower() in {"1", "true", "yes", "on"}


def controller_path() -> Path | None:
    configured = os.getenv("HERDR_HARNESS_CTL")
    candidates = (
        Path(configured).expanduser() if configured else None,
        Path.home() / ".local" / "bin" / "herdr-hermesctl",
        Path(__file__).with_name("controller.py"),
    )
    for candidate in candidates:
        if candidate is not None and candidate.is_file():
            return candidate
    return None


def available() -> bool:
    return controller_path() is not None


def error(message: str, **extra: Any) -> str:
    return json.dumps({"ok": False, "error": message, **extra}, ensure_ascii=False)


def required(args: dict[str, Any], *names: str) -> str | None:
    missing = [name for name in names if args.get(name) in (None, "", [])]
    return f"missing required parameter(s): {', '.join(missing)}" if missing else None


def option(command: list[str], flag: str, value: Any) -> None:
    if value is not None and value != "":
        command.extend([flag, str(value)])


def guard(command: str) -> dict[str, Any]:
    """Run the normal Hermes guard without inheriting container exemptions.

    The harness can target SSH through a profile even when the ordinary Hermes
    terminal backend is Docker/Modal. Passing that backend here would skip the
    guard entirely, so harness commands always use the host/SSH risk policy.
    """
    try:
        from tools.approval import check_all_command_guards

        return check_all_command_guards(command, "ssh")
    except Exception as exc:
        return {
            "approved": False,
            "message": f"security guard failed closed: {type(exc).__name__}: {exc}",
        }


def build_args(args: dict[str, Any]) -> tuple[list[str] | None, dict[str, Any] | None]:
    action = str(args.get("action", "")).strip()
    profile = str(args.get("profile") or os.getenv("HERDR_HARNESS_PROFILE") or "default")
    prefix = ["--profile", profile, "--json"]

    simple = {
        "doctor": "doctor",
        "status": "status",
        "session_list": "session-list",
        "workspace_list": "workspace-list",
        "worktree_list": "worktree-list",
        "agent_list": "agent-list",
    }
    if action in simple:
        return [*prefix, simple[action]], None

    if action == "workspace_ensure":
        command = [*prefix, "workspace-ensure"]
        option(command, "--label", args.get("label"))
        return command, None

    if action == "task_create":
        missing = required(args, "task")
        if missing:
            return None, {"error": missing}
        command = [*prefix, "task-create", str(args["task"])]
        for field, flag in (
            ("branch", "--branch"),
            ("base", "--base"),
            ("path", "--path"),
            ("label", "--label"),
            ("timeout_ms", "--operation-timeout-ms"),
        ):
            option(command, flag, args.get(field))
        return command, None

    if action == "task_remove":
        missing = required(args, "workspace_id")
        if missing:
            return None, {"error": missing}
        if args.get("force"):
            return None, {
                "error": (
                    "forced worktree removal is not available through the Hermes tool; "
                    "inspect the worktree and use herdr-hermesctl manually"
                )
            }
        return [*prefix, "task-remove", str(args["workspace_id"])], None

    if action == "pane_list":
        command = [*prefix, "pane-list"]
        option(command, "--workspace", args.get("workspace_id"))
        return command, None

    if action == "pane_read":
        missing = required(args, "pane_id")
        if missing:
            return None, {"error": missing}
        command = [*prefix, "pane-read", str(args["pane_id"])]
        option(command, "--source", args.get("source"))
        option(command, "--lines", args.get("lines"))
        return command, None

    if action == "pane_split":
        missing = required(args, "pane_id")
        if missing:
            return None, {"error": missing}
        command = [*prefix, "pane-split", str(args["pane_id"])]
        option(command, "--direction", args.get("direction"))
        option(command, "--cwd", args.get("cwd"))
        return command, None

    if action == "pane_run":
        missing = required(args, "pane_id", "command")
        if missing:
            return None, {"error": missing}
        decision = guard(str(args["command"]))
        if not decision.get("approved"):
            return None, decision
        return [*prefix, "pane-run", str(args["pane_id"]), str(args["command"])], None

    if action == "pane_wait":
        missing = required(args, "pane_id")
        if missing:
            return None, {"error": missing}
        if not args.get("match") and not args.get("regex"):
            return None, {"error": "pane_wait requires match or regex"}
        command = [*prefix, "pane-wait", str(args["pane_id"])]
        if args.get("match"):
            command.extend(["--match", str(args["match"])])
        else:
            command.extend(["--regex", str(args["regex"])])
        option(command, "--source", args.get("source"))
        option(command, "--lines", args.get("lines"))
        option(command, "--wait-timeout-ms", args.get("timeout_ms"))
        return command, None

    if action == "agent_get":
        missing = required(args, "target")
        return (
            [*prefix, "agent-get", str(args["target"])] if not missing else None,
            {"error": missing} if missing else None,
        )

    if action == "agent_start":
        missing = required(args, "agent_name", "agent_kind", "pane_id")
        if missing:
            return None, {"error": missing}
        # argparse.REMAINDER must be the final positional. Put options before
        # name/kind/pane so --start-timeout-ms is not forwarded to the agent.
        command = [*prefix, "agent-start"]
        option(command, "--start-timeout-ms", args.get("start_timeout_ms"))
        command.extend(
            [
                str(args["agent_name"]),
                str(args["agent_kind"]),
                str(args["pane_id"]),
            ]
        )
        native = [str(item) for item in (args.get("agent_args") or [])]
        if native:
            command.extend(["--", *native])
        return command, None

    if action == "agent_prompt":
        missing = required(args, "target", "prompt")
        if missing:
            return None, {"error": missing}
        command = [*prefix, "agent-prompt", str(args["target"]), str(args["prompt"])]
        option(command, "--wait-timeout-ms", args.get("timeout_ms"))
        return command, None

    if action == "agent_read":
        missing = required(args, "target")
        if missing:
            return None, {"error": missing}
        command = [*prefix, "agent-read", str(args["target"])]
        option(command, "--source", args.get("source"))
        option(command, "--lines", args.get("lines"))
        return command, None

    if action == "agent_wait":
        missing = required(args, "target")
        if missing:
            return None, {"error": missing}
        command = [*prefix, "agent-wait", str(args["target"])]
        for state in args.get("until") or []:
            command.extend(["--until", str(state)])
        option(command, "--wait-timeout-ms", args.get("timeout_ms"))
        return command, None

    if action == "agent_keys":
        missing = required(args, "target", "keys")
        if missing:
            return None, {"error": missing}
        return [
            *prefix,
            "agent-keys",
            str(args["target"]),
            *[str(item) for item in args["keys"]],
        ], None

    return None, {"error": f"unsupported action: {action}"}


def handle(args: dict[str, Any], **_: Any) -> str:
    controller = controller_path()
    if controller is None:
        return error("Herdr harness controller is not installed")
    command_args, blocked = build_args(args)
    if blocked:
        return json.dumps({"ok": False, **blocked}, ensure_ascii=False)
    assert command_args is not None

    requested_timeout_ms = int(args.get("timeout_ms") or 120000)
    if args.get("action") == "agent_start":
        requested_timeout_ms = max(
            requested_timeout_ms,
            int(args.get("start_timeout_ms") or 0),
        )
    timeout_seconds = max(15, min((requested_timeout_ms / 1000) + 30, 660))
    try:
        completed = subprocess.run(
            [sys.executable, str(controller), *command_args],
            capture_output=True,
            text=True,
            timeout=timeout_seconds,
            check=False,
        )
    except subprocess.TimeoutExpired:
        return error(f"Herdr harness command timed out after {timeout_seconds:.0f}s")
    except OSError as exc:
        return error(f"failed to start Herdr harness controller: {exc}")

    stdout = completed.stdout[-MAX_OUTPUT:].strip()
    stderr = completed.stderr[-MAX_OUTPUT:].strip()
    parsed: Any = None
    for candidate in (stdout, stderr):
        if not candidate:
            continue
        try:
            parsed = json.loads(candidate)
            break
        except json.JSONDecodeError:
            continue
    if isinstance(parsed, dict):
        parsed.setdefault("controller_returncode", completed.returncode)
        if stderr and stderr != stdout:
            parsed.setdefault("controller_stderr", stderr)
        return json.dumps(parsed, ensure_ascii=False)
    return json.dumps(
        {
            "ok": completed.returncode == 0,
            "controller_returncode": completed.returncode,
            "stdout": stdout,
            "stderr": stderr,
        },
        ensure_ascii=False,
    )


def auto_enable() -> None:
    if not truthy("HERDR_HARNESS_AUTO_ENABLE", default=True):
        return
    try:
        from toolsets import TOOLSETS

        for toolset_name in AUTO_TOOLSETS:
            toolset = TOOLSETS.get(toolset_name)
            tools = toolset.get("tools") if isinstance(toolset, dict) else None
            if isinstance(tools, list) and TOOL_NAME not in tools:
                tools.append(TOOL_NAME)
    except Exception:
        return


SCHEMA = {
    "name": TOOL_NAME,
    "description": (
        "Operate Herdr as a persistent coding harness locally or through SSH. "
        "Create an isolated Git worktree per task, inspect panes, start supported coding agents, "
        "submit prompts, wait for lifecycle states, and read output. Never assign two active agents "
        "to the same worktree."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "action": {
                "type": "string",
                "enum": [
                    "doctor",
                    "status",
                    "session_list",
                    "workspace_list",
                    "workspace_ensure",
                    "worktree_list",
                    "task_create",
                    "task_remove",
                    "pane_list",
                    "pane_read",
                    "pane_split",
                    "pane_run",
                    "pane_wait",
                    "agent_list",
                    "agent_get",
                    "agent_start",
                    "agent_prompt",
                    "agent_read",
                    "agent_wait",
                    "agent_keys",
                ],
            },
            "profile": {"type": "string"},
            "task": {"type": "string"},
            "workspace_id": {"type": "string"},
            "pane_id": {"type": "string"},
            "target": {"type": "string", "description": "Agent name or pane ID."},
            "branch": {"type": "string"},
            "base": {"type": "string"},
            "path": {"type": "string"},
            "cwd": {"type": "string"},
            "label": {"type": "string"},
            "direction": {"type": "string", "enum": ["right", "down"]},
            "command": {"type": "string"},
            "match": {"type": "string"},
            "regex": {"type": "string"},
            "source": {
                "type": "string",
                "enum": ["visible", "recent", "recent-unwrapped", "detection"],
            },
            "lines": {"type": "integer", "minimum": 1, "maximum": 5000},
            "agent_name": {"type": "string"},
            "agent_kind": {"type": "string"},
            "agent_args": {"type": "array", "items": {"type": "string"}},
            "prompt": {"type": "string"},
            "keys": {"type": "array", "items": {"type": "string"}},
            "until": {
                "type": "array",
                "items": {
                    "type": "string",
                    "enum": ["idle", "working", "blocked", "done", "unknown"],
                },
            },
            "start_timeout_ms": {"type": "integer", "minimum": 1000, "maximum": 300000},
            "timeout_ms": {"type": "integer", "minimum": 1000, "maximum": 600000},
        },
        "required": ["action"],
        "additionalProperties": False,
    },
}


def register(ctx: Any) -> None:
    auto_enable()
    ctx.register_tool(
        name=TOOL_NAME,
        toolset="herdr",
        schema=SCHEMA,
        handler=handle,
        check_fn=available,
        description=SCHEMA["description"],
        emoji="🐏",
    )
