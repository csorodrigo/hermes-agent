"""Standard-library controller for a local or SSH-hosted Herdr session."""

from __future__ import annotations

import argparse
import configparser
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any, Iterable, Sequence

PROFILE_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
TARGET_RE = re.compile(r"^[A-Za-z0-9_.:@%+\[\]-]+$")
ID_RE = re.compile(r"^[A-Za-z0-9:._-]+$")
REF_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._/@+-]{0,199}$")
AGENT_RE = re.compile(r"^[a-z][a-z0-9_-]{0,31}$")
READ_SOURCES = ("visible", "recent", "recent-unwrapped", "detection")
AGENT_STATES = ("idle", "working", "blocked", "done", "unknown")


class HarnessError(RuntimeError):
    pass


@dataclass(frozen=True)
class HarnessConfig:
    profile: str
    target: str
    session: str
    repo: str
    worktrees_root: str
    base_ref: str
    herdr_binary: str
    ssh_binary: str
    ssh_port: int | None
    ssh_key: str
    ssh_control_path: str
    ssh_control_persist: int
    timeout_ms: int

    @property
    def remote(self) -> bool:
        return bool(self.target)


def default_config_path(profile: str) -> Path:
    return Path.home() / ".config" / "herdr-harness" / f"{profile}.ini"


def first(*values: Any, default: str = "") -> str:
    for value in values:
        if value is not None and str(value).strip():
            return str(value).strip()
    return default


def positive_int(value: Any, *, name: str, default: int | None = None) -> int | None:
    if value is None or not str(value).strip():
        return default
    try:
        parsed = int(str(value))
    except ValueError as exc:
        raise HarnessError(f"{name} must be an integer") from exc
    if parsed <= 0:
        raise HarnessError(f"{name} must be greater than zero")
    return parsed


def read_profile(path: Path) -> dict[str, str]:
    if not path.exists():
        return {}
    parser = configparser.ConfigParser(interpolation=None)
    try:
        parser.read(path, encoding="utf-8")
    except configparser.Error as exc:
        raise HarnessError(f"cannot parse {path}: {exc}") from exc
    if "harness" not in parser:
        raise HarnessError(f"{path} must contain a [harness] section")
    return {key: value.strip() for key, value in parser["harness"].items()}


def validate_ref(value: str, name: str = "ref") -> str:
    if not REF_RE.fullmatch(value) or ".." in value or value.endswith("/"):
        raise HarnessError(f"invalid {name}")
    return value


def validate_id(value: str, name: str) -> str:
    if not value or not ID_RE.fullmatch(value):
        raise HarnessError(f"invalid {name}")
    return value


def load_config(args: argparse.Namespace) -> HarnessConfig:
    profile = first(args.profile, os.getenv("HERDR_HARNESS_PROFILE"), default="default")
    if not PROFILE_RE.fullmatch(profile):
        raise HarnessError("invalid profile name")
    profile_path = Path(args.config).expanduser() if args.config else default_config_path(profile)
    data = read_profile(profile_path)

    target = first(args.target, os.getenv("HERDR_SSH_TARGET"), data.get("target"))
    if target and not TARGET_RE.fullmatch(target):
        raise HarnessError("invalid SSH target; use an OpenSSH alias or user@host")

    session = first(
        args.session,
        os.getenv("HERDR_SESSION"),
        data.get("session"),
        default=f"hermes-{profile}",
    )
    if not PROFILE_RE.fullmatch(session):
        raise HarnessError("invalid Herdr session name")

    repo = first(
        args.repo,
        os.getenv("HERDR_REPO"),
        data.get("repo"),
        default=str(Path.home() / "src" / profile),
    )
    worktrees_root = first(
        args.worktrees_root,
        os.getenv("HERDR_WORKTREES_ROOT"),
        data.get("worktrees_root"),
        default=str(Path.home() / "worktrees" / profile),
    )
    if target:
        if not repo.startswith("/") or not worktrees_root.startswith("/"):
            raise HarnessError("repo and worktrees_root must be absolute paths in SSH mode")
    else:
        repo = os.path.expanduser(repo)
        worktrees_root = os.path.expanduser(worktrees_root)

    base_ref = validate_ref(
        first(args.base_ref, os.getenv("HERDR_BASE_REF"), data.get("base_ref"), default="main"),
        "base_ref",
    )
    ssh_port = positive_int(
        first(args.ssh_port, os.getenv("HERDR_SSH_PORT"), data.get("ssh_port")),
        name="ssh_port",
    )
    control_persist = positive_int(
        first(
            args.ssh_control_persist,
            os.getenv("HERDR_SSH_CONTROL_PERSIST"),
            data.get("ssh_control_persist"),
        ),
        name="ssh_control_persist",
        default=600,
    )
    timeout_ms = positive_int(
        first(args.timeout_ms, os.getenv("HERDR_TIMEOUT_MS"), data.get("timeout_ms")),
        name="timeout_ms",
        default=120000,
    )

    return HarnessConfig(
        profile=profile,
        target=target,
        session=session,
        repo=repo,
        worktrees_root=worktrees_root,
        base_ref=base_ref,
        herdr_binary=first(
            args.herdr_binary,
            os.getenv("HERDR_BINARY"),
            data.get("herdr_binary"),
            default="herdr",
        ),
        ssh_binary=first(
            args.ssh_binary,
            os.getenv("HERDR_SSH_BINARY"),
            data.get("ssh_binary"),
            default="ssh",
        ),
        ssh_port=ssh_port,
        ssh_key=os.path.expanduser(
            first(args.ssh_key, os.getenv("HERDR_SSH_KEY"), data.get("ssh_key"))
        ),
        ssh_control_path=os.path.expanduser(
            first(
                args.ssh_control_path,
                os.getenv("HERDR_SSH_CONTROL_PATH"),
                data.get("ssh_control_path"),
                default=str(Path.home() / ".ssh" / "herdr-%C"),
            )
        ),
        ssh_control_persist=int(control_persist or 600),
        timeout_ms=int(timeout_ms or 120000),
    )


class Runner:
    def __init__(self, config: HarnessConfig, *, verbose: bool = False):
        self.config = config
        self.verbose = verbose

    def ssh_prefix(self, *, tty: bool = False) -> list[str]:
        cfg = self.config
        if not cfg.remote:
            raise HarnessError("SSH target is not configured")
        if not shutil.which(cfg.ssh_binary):
            raise HarnessError(f"SSH client not found: {cfg.ssh_binary}")
        Path(cfg.ssh_control_path).expanduser().parent.mkdir(parents=True, exist_ok=True)
        command = [
            cfg.ssh_binary,
            "-o", "BatchMode=yes",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-o", "ControlMaster=auto",
            "-o", f"ControlPersist={cfg.ssh_control_persist}",
            "-o", f"ControlPath={cfg.ssh_control_path}",
        ]
        if tty:
            command.append("-t")
        if cfg.ssh_port:
            command.extend(["-p", str(cfg.ssh_port)])
        if cfg.ssh_key:
            command.extend(["-i", cfg.ssh_key])
        command.append(cfg.target)
        return command

    def host(
        self,
        argv: Sequence[str],
        *,
        timeout_ms: int | None = None,
        interactive: bool = False,
    ) -> subprocess.CompletedProcess[str]:
        if not argv:
            raise HarnessError("empty command")
        if self.config.remote:
            command = self.ssh_prefix(tty=interactive)
            command.append(shlex.join([str(item) for item in argv]))
        else:
            command = [str(item) for item in argv]
        if self.verbose:
            print(f"+ {shlex.join(command)}", file=sys.stderr)
        try:
            return subprocess.run(
                command,
                capture_output=not interactive,
                text=True,
                timeout=None if interactive else (timeout_ms or self.config.timeout_ms) / 1000,
                check=False,
            )
        except subprocess.TimeoutExpired as exc:
            raise HarnessError("command timed out") from exc
        except OSError as exc:
            raise HarnessError(f"failed to execute {command[0]}: {exc}") from exc

    def shell(self, command: str, *, timeout_ms: int | None = None) -> subprocess.CompletedProcess[str]:
        return self.host(["sh", "-lc", command], timeout_ms=timeout_ms)

    def herdr(
        self,
        args: Sequence[str],
        *,
        scoped: bool = True,
        timeout_ms: int | None = None,
    ) -> subprocess.CompletedProcess[str]:
        command = [self.config.herdr_binary]
        if scoped:
            command.extend(["--session", self.config.session])
        command.extend(str(item) for item in args)
        return self.host(command, timeout_ms=timeout_ms)


def parse_json(text: str) -> Any | None:
    try:
        return json.loads(text.strip()) if text.strip() else None
    except json.JSONDecodeError:
        return None


def payload(result: subprocess.CompletedProcess[str]) -> dict[str, Any]:
    body: dict[str, Any] = {"ok": result.returncode == 0, "returncode": result.returncode}
    parsed = parse_json(result.stdout)
    if parsed is not None:
        body["result"] = parsed
    elif result.stdout.strip():
        body["stdout"] = result.stdout.rstrip()
    if result.stderr.strip():
        body["stderr"] = result.stderr.rstrip()
    return body


def emit(result: subprocess.CompletedProcess[str], *, as_json: bool = False) -> int:
    if as_json or parse_json(result.stdout) is not None:
        print(json.dumps(payload(result), indent=2, ensure_ascii=False))
    else:
        if result.stdout:
            print(result.stdout, end="" if result.stdout.endswith("\n") else "\n")
        if result.stderr:
            print(result.stderr, end="" if result.stderr.endswith("\n") else "\n", file=sys.stderr)
    return result.returncode


def walk(value: Any) -> Iterable[Any]:
    yield value
    if isinstance(value, dict):
        for child in value.values():
            yield from walk(child)
    elif isinstance(value, list):
        for child in value:
            yield from walk(child)


def find_identifier(value: Any, keys: Sequence[str]) -> str | None:
    for item in walk(value):
        if not isinstance(item, dict):
            continue
        for key in keys:
            candidate = item.get(key)
            if isinstance(candidate, str) and candidate:
                return candidate
            if isinstance(candidate, dict):
                nested = candidate.get("id")
                if isinstance(nested, str) and nested:
                    return nested
    return None


def find_workspace(value: Any, cwd: str) -> dict[str, Any] | None:
    target = os.path.normpath(cwd)
    for item in walk(value):
        if not isinstance(item, dict):
            continue
        for key in ("cwd", "path", "working_directory", "worktree_path"):
            candidate = item.get(key)
            if isinstance(candidate, str) and os.path.normpath(candidate) == target:
                return item
    return None


def task_slug(value: str) -> str:
    slug = re.sub(r"[^A-Za-z0-9._-]+", "-", value).strip("-.")[:80]
    if not slug:
        raise HarnessError("task name must contain a letter or number")
    return slug


def doctor(runner: Runner) -> int:
    cfg = runner.config
    checks: list[dict[str, Any]] = []

    def add(name: str, result: subprocess.CompletedProcess[str], *, optional: bool = False) -> None:
        checks.append({"name": name, "optional": optional, **payload(result)})

    if cfg.remote:
        checks.append({
            "name": "local_ssh",
            "optional": False,
            "ok": bool(shutil.which(cfg.ssh_binary)),
            "path": shutil.which(cfg.ssh_binary) or "",
        })
        checks.append({
            "name": "local_herdr_client",
            "optional": True,
            "ok": bool(shutil.which(cfg.herdr_binary)),
            "path": shutil.which(cfg.herdr_binary) or "",
            "purpose": "remote attach with local clipboard bridging",
        })

    add("herdr", runner.host([cfg.herdr_binary, "--version"]))
    add("git", runner.host(["git", "--version"]))
    add("python3", runner.host(["python3", "--version"]))
    add("session", runner.herdr(["status", "--json"]))
    quoted = shlex.quote(cfg.repo)
    add(
        "repo",
        runner.shell(
            f"test -d {quoted} && git -C {quoted} rev-parse --show-toplevel && "
            f"git -C {quoted} status --short --branch"
        ),
    )
    for binary in ("codex", "claude", "hermes", "opencode"):
        add(f"agent_{binary}", runner.shell(f"command -v {shlex.quote(binary)}"), optional=True)

    required = [check for check in checks if not check.get("optional")]
    ok = all(bool(check.get("ok")) for check in required)
    config_body = asdict(cfg)
    config_body["ssh_key"] = "configured" if cfg.ssh_key else ""
    print(json.dumps({"ok": ok, "config": config_body, "checks": checks}, indent=2))
    return 0 if ok else 1


def workspace_ensure(runner: Runner, label: str) -> int:
    listed = runner.herdr(["workspace", "list"])
    if listed.returncode != 0:
        return emit(listed, as_json=True)
    current = find_workspace(parse_json(listed.stdout), runner.config.repo)
    if current:
        print(json.dumps({"ok": True, "created": False, "workspace": current}, indent=2))
        return 0
    created = runner.herdr([
        "workspace", "create",
        "--cwd", runner.config.repo,
        "--label", label,
        "--no-focus",
    ])
    body = payload(created)
    body["created"] = created.returncode == 0
    print(json.dumps(body, indent=2))
    return created.returncode


def task_create(runner: Runner, args: argparse.Namespace) -> int:
    cfg = runner.config
    slug = task_slug(args.task)
    branch = validate_ref(args.branch or f"agent/{slug}", "branch")
    base = validate_ref(args.base or cfg.base_ref, "base")
    path = args.path or os.path.join(cfg.worktrees_root, slug)
    if cfg.remote and not path.startswith("/"):
        raise HarnessError("task path must be absolute in SSH mode")
    if not cfg.remote:
        path = os.path.expanduser(path)
    mkdir = runner.host(["mkdir", "-p", os.path.dirname(path) or cfg.worktrees_root])
    if mkdir.returncode != 0:
        return emit(mkdir, as_json=True)
    created = runner.herdr([
        "worktree", "create",
        "--cwd", cfg.repo,
        "--branch", branch,
        "--base", base,
        "--path", path,
        "--label", args.label or slug,
        "--no-focus",
    ], timeout_ms=args.operation_timeout_ms)
    body = payload(created)
    parsed = parse_json(created.stdout)
    body["task"] = {"name": args.task, "branch": branch, "base": base, "path": path}
    body["workspace_id"] = find_identifier(parsed, ("workspace_id", "workspace"))
    body["pane_id"] = find_identifier(parsed, ("pane_id", "root_pane"))
    print(json.dumps(body, indent=2, ensure_ascii=False))
    return created.returncode


def attach(runner: Runner, via_ssh: bool) -> int:
    cfg = runner.config
    if cfg.remote and not via_ssh:
        if not shutil.which(cfg.herdr_binary):
            raise HarnessError("install local Herdr or use attach --via-ssh")
        command = [cfg.herdr_binary, "--remote", cfg.target, "--session", cfg.session]
    elif cfg.remote:
        command = runner.ssh_prefix(tty=True)
        command.append(shlex.join([cfg.herdr_binary, "--session", cfg.session]))
    else:
        command = [cfg.herdr_binary, "--session", cfg.session]
    if runner.verbose:
        print(f"+ {shlex.join(command)}", file=sys.stderr)
    os.execvp(command[0], command)
    return 127


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="herdr-hermesctl")
    parser.add_argument("--profile")
    parser.add_argument("--config")
    parser.add_argument("--target")
    parser.add_argument("--session")
    parser.add_argument("--repo")
    parser.add_argument("--worktrees-root")
    parser.add_argument("--base-ref")
    parser.add_argument("--herdr-binary")
    parser.add_argument("--ssh-binary")
    parser.add_argument("--ssh-port", type=int)
    parser.add_argument("--ssh-key")
    parser.add_argument("--ssh-control-path")
    parser.add_argument("--ssh-control-persist", type=int)
    parser.add_argument("--timeout-ms", type=int)
    parser.add_argument("--json", action="store_true")
    parser.add_argument("-v", "--verbose", action="store_true")
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("config-show")
    sub.add_parser("doctor")
    attach_parser = sub.add_parser("attach")
    attach_parser.add_argument("--via-ssh", action="store_true")
    sub.add_parser("version")
    sub.add_parser("status")
    sub.add_parser("session-list")
    sub.add_parser("workspace-list")
    ensure = sub.add_parser("workspace-ensure")
    ensure.add_argument("--label", default="")
    create_workspace = sub.add_parser("workspace-create")
    create_workspace.add_argument("--cwd", default="")
    create_workspace.add_argument("--label", default="")
    sub.add_parser("worktree-list")

    create_task = sub.add_parser("task-create")
    create_task.add_argument("task")
    create_task.add_argument("--branch")
    create_task.add_argument("--base")
    create_task.add_argument("--path")
    create_task.add_argument("--label")
    create_task.add_argument("--operation-timeout-ms", type=int, default=120000)
    remove_task = sub.add_parser("task-remove")
    remove_task.add_argument("workspace_id")
    remove_task.add_argument("--force", action="store_true")

    pane_list = sub.add_parser("pane-list")
    pane_list.add_argument("--workspace")
    pane_read = sub.add_parser("pane-read")
    pane_read.add_argument("pane_id")
    pane_read.add_argument("--lines", type=int, default=200)
    pane_read.add_argument("--source", choices=READ_SOURCES, default="recent-unwrapped")
    pane_split = sub.add_parser("pane-split")
    pane_split.add_argument("pane_id")
    pane_split.add_argument("--direction", choices=("right", "down"), default="right")
    pane_split.add_argument("--cwd")
    pane_run = sub.add_parser("pane-run")
    pane_run.add_argument("pane_id")
    pane_run.add_argument("shell_command", nargs=argparse.REMAINDER)
    pane_wait = sub.add_parser("pane-wait")
    pane_wait.add_argument("pane_id")
    matcher = pane_wait.add_mutually_exclusive_group(required=True)
    matcher.add_argument("--match")
    matcher.add_argument("--regex")
    pane_wait.add_argument("--wait-timeout-ms", type=int, default=120000)
    pane_wait.add_argument("--lines", type=int, default=200)
    pane_wait.add_argument("--source", choices=READ_SOURCES, default="recent-unwrapped")

    sub.add_parser("agent-list")
    agent_get = sub.add_parser("agent-get")
    agent_get.add_argument("target")
    agent_start = sub.add_parser("agent-start")
    agent_start.add_argument("name")
    agent_start.add_argument("kind")
    agent_start.add_argument("pane_id")
    agent_start.add_argument("--start-timeout-ms", type=int, default=30000)
    agent_start.add_argument("agent_args", nargs=argparse.REMAINDER)
    agent_prompt = sub.add_parser("agent-prompt")
    agent_prompt.add_argument("target")
    agent_prompt.add_argument("prompt", nargs="+")
    agent_prompt.add_argument("--wait-timeout-ms", type=int, default=120000)
    agent_read = sub.add_parser("agent-read")
    agent_read.add_argument("target")
    agent_read.add_argument("--lines", type=int, default=200)
    agent_read.add_argument("--source", choices=READ_SOURCES, default="recent-unwrapped")
    agent_wait = sub.add_parser("agent-wait")
    agent_wait.add_argument("target")
    agent_wait.add_argument("--until", action="append", choices=AGENT_STATES)
    agent_wait.add_argument("--wait-timeout-ms", type=int, default=120000)
    agent_keys = sub.add_parser("agent-keys")
    agent_keys.add_argument("target")
    agent_keys.add_argument("keys", nargs="+")
    raw = sub.add_parser("raw")
    raw.add_argument("herdr_args", nargs=argparse.REMAINDER)
    return parser


def dispatch(args: argparse.Namespace, cfg: HarnessConfig) -> int:
    runner = Runner(cfg, verbose=args.verbose)
    cmd = args.command
    if cmd == "config-show":
        body = asdict(cfg)
        body["ssh_key"] = "configured" if cfg.ssh_key else ""
        print(json.dumps(body, indent=2))
        return 0
    if cmd == "doctor":
        return doctor(runner)
    if cmd == "attach":
        return attach(runner, args.via_ssh)
    if cmd == "version":
        return emit(runner.herdr(["--version"], scoped=False), as_json=args.json)
    if cmd == "status":
        return emit(runner.herdr(["status", "--json"]), as_json=True)
    if cmd == "session-list":
        return emit(runner.herdr(["session", "list", "--json"], scoped=False), as_json=True)
    if cmd == "workspace-list":
        return emit(runner.herdr(["workspace", "list"]), as_json=args.json)
    if cmd == "workspace-ensure":
        return workspace_ensure(runner, args.label or cfg.profile)
    if cmd == "workspace-create":
        cwd = args.cwd or cfg.repo
        return emit(runner.herdr([
            "workspace", "create", "--cwd", cwd,
            "--label", args.label or Path(cwd).name or cfg.profile,
            "--no-focus",
        ]), as_json=True)
    if cmd == "worktree-list":
        return emit(runner.herdr(["worktree", "list", "--cwd", cfg.repo]), as_json=args.json)
    if cmd == "task-create":
        return task_create(runner, args)
    if cmd == "task-remove":
        command = ["worktree", "remove", "--workspace", validate_id(args.workspace_id, "workspace id")]
        if args.force:
            command.append("--force")
        return emit(runner.herdr(command), as_json=True)
    if cmd == "pane-list":
        command = ["pane", "list"]
        if args.workspace:
            command.extend(["--workspace", validate_id(args.workspace, "workspace id")])
        return emit(runner.herdr(command), as_json=args.json)
    if cmd == "pane-read":
        return emit(runner.herdr([
            "pane", "read", validate_id(args.pane_id, "pane id"),
            "--source", args.source, "--lines", str(args.lines),
        ]), as_json=args.json)
    if cmd == "pane-split":
        command = [
            "pane", "split", validate_id(args.pane_id, "pane id"),
            "--direction", args.direction, "--no-focus",
        ]
        if args.cwd:
            command.extend(["--cwd", args.cwd])
        return emit(runner.herdr(command), as_json=True)
    if cmd == "pane-run":
        tokens = list(args.shell_command)
        if tokens and tokens[0] == "--":
            tokens = tokens[1:]
        shell_command = " ".join(tokens).strip()
        if not shell_command:
            raise HarnessError("pane-run requires a command")
        return emit(runner.herdr([
            "pane", "run", validate_id(args.pane_id, "pane id"), shell_command,
        ]), as_json=args.json)
    if cmd == "pane-wait":
        command = [
            "pane", "wait-output", validate_id(args.pane_id, "pane id"),
            "--source", args.source, "--lines", str(args.lines),
            "--timeout", str(args.wait_timeout_ms),
        ]
        command.extend(["--match", args.match] if args.match is not None else ["--regex", args.regex])
        return emit(runner.herdr(command, timeout_ms=args.wait_timeout_ms + 10000), as_json=args.json)
    if cmd == "agent-list":
        return emit(runner.herdr(["agent", "list"]), as_json=args.json)
    if cmd == "agent-get":
        return emit(runner.herdr(["agent", "get", validate_id(args.target, "agent target")]), as_json=args.json)
    if cmd == "agent-start":
        if not AGENT_RE.fullmatch(args.name):
            raise HarnessError("invalid agent name")
        command = [
            "agent", "start", args.name, "--kind", args.kind,
            "--pane", validate_id(args.pane_id, "pane id"),
            "--timeout", str(args.start_timeout_ms),
        ]
        native = list(args.agent_args)
        if native and native[0] == "--":
            native = native[1:]
        if native:
            command.extend(["--", *native])
        return emit(runner.herdr(command, timeout_ms=args.start_timeout_ms + 10000), as_json=True)
    if cmd == "agent-prompt":
        target = validate_id(args.target, "agent target")
        return emit(runner.herdr([
            "agent", "prompt", target, " ".join(args.prompt), "--wait",
            "--timeout", str(args.wait_timeout_ms),
        ], timeout_ms=args.wait_timeout_ms + 10000), as_json=args.json)
    if cmd == "agent-read":
        return emit(runner.herdr([
            "agent", "read", validate_id(args.target, "agent target"),
            "--source", args.source, "--lines", str(args.lines),
        ]), as_json=args.json)
    if cmd == "agent-wait":
        command = [
            "agent", "wait", validate_id(args.target, "agent target"),
            "--timeout", str(args.wait_timeout_ms),
        ]
        for state in args.until or []:
            command.extend(["--until", state])
        return emit(runner.herdr(command, timeout_ms=args.wait_timeout_ms + 10000), as_json=args.json)
    if cmd == "agent-keys":
        return emit(runner.herdr([
            "agent", "send-keys", validate_id(args.target, "agent target"), *args.keys,
        ]), as_json=args.json)
    if cmd == "raw":
        raw = list(args.herdr_args)
        if raw and raw[0] == "--":
            raw = raw[1:]
        if not raw:
            raise HarnessError("raw requires Herdr arguments")
        return emit(runner.herdr(raw), as_json=args.json)
    raise HarnessError(f"unsupported command: {cmd}")


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        return dispatch(args, load_config(args))
    except HarnessError as exc:
        print(json.dumps({"ok": False, "error": str(exc)}), file=sys.stderr)
        return 2
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
