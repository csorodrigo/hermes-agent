#!/usr/bin/env python3
"""Configure HerdrM SSH devices without storing SSH credentials.

HerdrM keeps its device inventory in a JSON file under the current macOS
user's Application Support directory. This helper adds/removes OpenSSH targets
while preserving existing entries and using the native HerdrM Codable shape.
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import re
import shlex
import subprocess
import sys
import tempfile
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable

LOCAL_DEVICE_ID = "00000000-0000-0000-0000-000000000001"
DEFAULT_STORE = Path.home() / "Library" / "Application Support" / "HerdrM" / "devices.json"
DEFAULT_SSH_CONFIG = Path.home() / ".ssh" / "config"
CONTROL_CHARS_RE = re.compile(r"[\x00-\x1f\x7f]")
WILDCARD_CHARS = frozenset("*?[]!")


class HerdrMConfigError(RuntimeError):
    """Raised when a device inventory cannot be safely modified."""


def local_device() -> dict[str, Any]:
    return {
        "id": LOCAL_DEVICE_ID,
        "name": "Local",
        "kind": {"local": {}},
        "osID": "macos",
    }


def is_local(device: Any) -> bool:
    return (
        isinstance(device, dict)
        and isinstance(device.get("kind"), dict)
        and "local" in device["kind"]
    )


def ssh_target(device: Any) -> str | None:
    if not isinstance(device, dict):
        return None
    kind = device.get("kind")
    if not isinstance(kind, dict):
        return None
    ssh = kind.get("ssh")
    if not isinstance(ssh, dict):
        return None
    target = ssh.get("target")
    return target if isinstance(target, str) and target else None


def validate_text(value: str, *, label: str) -> str:
    value = value.strip()
    if not value:
        raise HerdrMConfigError(f"{label} cannot be empty")
    if CONTROL_CHARS_RE.search(value):
        raise HerdrMConfigError(f"{label} contains a control character")
    return value


def normalize_devices(value: Any) -> list[dict[str, Any]]:
    if not isinstance(value, list):
        raise HerdrMConfigError("HerdrM devices.json must contain a JSON array")
    devices = [item for item in value if isinstance(item, dict)]
    locals_ = [item for item in devices if is_local(item)]
    remotes = [item for item in devices if not is_local(item)]
    primary_local = locals_[0] if locals_ else local_device()
    primary_local.setdefault("id", LOCAL_DEVICE_ID)
    primary_local.setdefault("name", "Local")
    primary_local.setdefault("kind", {"local": {}})
    return [primary_local, *remotes]


def load_devices(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        return [local_device()]
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise HerdrMConfigError(f"cannot read {path}: {exc}") from exc
    return normalize_devices(value)


def atomic_save(path: Path, devices: list[dict[str, Any]]) -> Path | None:
    path.parent.mkdir(parents=True, exist_ok=True)
    try:
        os.chmod(path.parent, 0o700)
    except OSError:
        pass

    backup: Path | None = None
    if path.exists():
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        backup = path.with_name(f"{path.name}.bak-{stamp}")
        backup.write_bytes(path.read_bytes())
        try:
            os.chmod(backup, 0o600)
        except OSError:
            pass

    payload = (
        json.dumps(
            normalize_devices(devices),
            indent=2,
            sort_keys=True,
            ensure_ascii=False,
        )
        + "\n"
    )
    fd, temp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=str(path.parent))
    temp_path = Path(temp_name)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temp_path, 0o600)
        os.replace(temp_path, path)
    finally:
        if temp_path.exists():
            temp_path.unlink()
    return backup


def upsert_device(
    devices: list[dict[str, Any]],
    *,
    name: str,
    target: str,
) -> tuple[list[dict[str, Any]], bool]:
    name = validate_text(name, label="device name")
    target = validate_text(target, label="SSH target")
    normalized = normalize_devices(devices)

    for device in normalized:
        if ssh_target(device) == target:
            changed = device.get("name") != name
            device["name"] = name
            return normalized, changed

    for device in normalized:
        if not is_local(device) and device.get("name") == name:
            existing = ssh_target(device) or "unknown target"
            raise HerdrMConfigError(
                f"device name {name!r} is already used by {existing!r}; choose another name"
            )

    normalized.append(
        {
            "id": str(uuid.uuid4()),
            "name": name,
            "kind": {"ssh": {"target": target}},
        }
    )
    return normalized, True


def remove_devices(
    devices: list[dict[str, Any]],
    *,
    name: str | None = None,
    target: str | None = None,
) -> tuple[list[dict[str, Any]], int]:
    if not name and not target:
        raise HerdrMConfigError("remove requires --name or --target")
    kept: list[dict[str, Any]] = []
    removed = 0
    for device in normalize_devices(devices):
        if is_local(device):
            kept.append(device)
            continue
        matches_name = name is not None and device.get("name") == name
        matches_target = target is not None and ssh_target(device) == target
        if matches_name or matches_target:
            removed += 1
        else:
            kept.append(device)
    return kept, removed


def parse_ssh_aliases(path: Path, *, seen: set[Path] | None = None) -> list[str]:
    """Return concrete OpenSSH Host aliases, following Include directives."""
    seen = seen or set()
    expanded = path.expanduser()
    try:
        resolved = expanded.resolve()
    except OSError:
        resolved = expanded.absolute()
    if resolved in seen or not expanded.exists():
        return []
    seen.add(resolved)

    aliases: list[str] = []
    try:
        lines = expanded.read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        raise HerdrMConfigError(f"cannot read SSH config {expanded}: {exc}") from exc

    for raw in lines:
        try:
            tokens = shlex.split(raw, comments=True, posix=True)
        except ValueError:
            continue
        if not tokens:
            continue
        directive = tokens[0].lower()
        if directive == "include":
            for pattern in tokens[1:]:
                include = Path(os.path.expandvars(os.path.expanduser(pattern)))
                if not include.is_absolute():
                    include = expanded.parent / include
                for match in sorted(glob.glob(str(include))):
                    aliases.extend(parse_ssh_aliases(Path(match), seen=seen))
            continue
        if directive != "host":
            continue
        for alias in tokens[1:]:
            if alias and not any(char in alias for char in WILDCARD_CHARS):
                aliases.append(alias)

    return list(dict.fromkeys(aliases))


def probe_target(
    target: str,
    *,
    ssh_binary: str = "ssh",
    timeout: int = 12,
) -> dict[str, Any]:
    target = validate_text(target, label="SSH target")
    command = [
        ssh_binary,
        "-o",
        "BatchMode=yes",
        "-o",
        "ConnectTimeout=8",
        "-o",
        "ServerAliveInterval=5",
        "-o",
        "ServerAliveCountMax=1",
        target,
        (
            "command -v herdr >/dev/null 2>&1 && "
            "test -S \"$HOME/.config/herdr/herdr.sock\" && "
            "herdr status --json >/dev/null 2>&1"
        ),
    ]
    try:
        completed = subprocess.run(
            command,
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        return {"ok": False, "target": target, "error": str(exc)}
    return {
        "ok": completed.returncode == 0,
        "target": target,
        "returncode": completed.returncode,
        "stderr": completed.stderr.strip()[-1000:],
    }


def device_summary(device: dict[str, Any]) -> dict[str, Any]:
    return {
        "id": device.get("id", ""),
        "name": device.get("name", ""),
        "kind": "local" if is_local(device) else "ssh",
        "target": ssh_target(device) or "",
    }


def print_result(body: dict[str, Any]) -> None:
    print(json.dumps(body, indent=2, ensure_ascii=False))


def command_add(args: argparse.Namespace, store: Path) -> int:
    if args.probe:
        probe = probe_target(
            args.target,
            ssh_binary=args.ssh_binary,
            timeout=args.probe_timeout,
        )
        if not probe["ok"]:
            print_result({"ok": False, "probe": probe, "store": str(store)})
            return 1
    devices, changed = upsert_device(
        load_devices(store),
        name=args.name,
        target=args.target,
    )
    backup = atomic_save(store, devices) if changed or not store.exists() else None
    print_result(
        {
            "ok": True,
            "changed": changed,
            "store": str(store),
            "backup": str(backup) if backup else "",
            "restart_herdrm": True,
            "device": next(
                device_summary(item)
                for item in devices
                if ssh_target(item) == args.target
            ),
        }
    )
    return 0


def command_sync(args: argparse.Namespace, store: Path) -> int:
    aliases = parse_ssh_aliases(Path(args.ssh_config))
    include_re = re.compile(args.include) if args.include else None
    exclude_re = re.compile(args.exclude) if args.exclude else None
    aliases = [
        alias
        for alias in aliases
        if (include_re is None or include_re.search(alias))
        and (exclude_re is None or not exclude_re.search(alias))
    ]

    devices = load_devices(store)
    added: list[str] = []
    unchanged: list[str] = []
    failed: list[dict[str, Any]] = []
    for alias in aliases:
        if args.probe:
            probe = probe_target(
                alias,
                ssh_binary=args.ssh_binary,
                timeout=args.probe_timeout,
            )
            if not probe["ok"]:
                failed.append(probe)
                continue
        devices, changed = upsert_device(
            devices,
            name=f"{args.name_prefix}{alias}",
            target=alias,
        )
        (added if changed else unchanged).append(alias)

    backup = atomic_save(store, devices) if added or not store.exists() else None
    ok = not (args.strict and failed)
    print_result(
        {
            "ok": ok,
            "store": str(store),
            "backup": str(backup) if backup else "",
            "discovered": aliases,
            "added_or_updated": added,
            "unchanged": unchanged,
            "unreachable_or_not_running_herdr": failed,
            "restart_herdrm": bool(added),
        }
    )
    return 0 if ok else 1


def command_remove(args: argparse.Namespace, store: Path) -> int:
    devices, removed = remove_devices(
        load_devices(store),
        name=args.name,
        target=args.target,
    )
    backup = atomic_save(store, devices) if removed else None
    print_result(
        {
            "ok": True,
            "removed": removed,
            "store": str(store),
            "backup": str(backup) if backup else "",
            "restart_herdrm": bool(removed),
        }
    )
    return 0


def command_list(args: argparse.Namespace, store: Path) -> int:
    devices = load_devices(store)
    print_result(
        {
            "ok": True,
            "store": str(store),
            "devices": [device_summary(item) for item in devices],
        }
    )
    return 0


def command_doctor(args: argparse.Namespace, store: Path) -> int:
    results = []
    for device in load_devices(store):
        target = ssh_target(device)
        if target:
            results.append(
                probe_target(
                    target,
                    ssh_binary=args.ssh_binary,
                    timeout=args.probe_timeout,
                )
            )
    ok = all(item["ok"] for item in results)
    print_result({"ok": ok, "store": str(store), "probes": results})
    return 0 if ok else 1


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="configure_herdrm.py",
        description=(
            "Manage HerdrM SSH devices using OpenSSH aliases. Credentials remain in "
            "OpenSSH/ssh-agent/Keychain; this file stores targets only."
        ),
    )
    parser.add_argument(
        "--store",
        default=os.getenv("HERDRM_DEVICE_STORE", str(DEFAULT_STORE)),
    )
    parser.add_argument("--ssh-binary", default="ssh")
    parser.add_argument("--probe-timeout", type=int, default=12)
    sub = parser.add_subparsers(dest="command", required=True)

    add = sub.add_parser("add", help="add or update one SSH device")
    add.add_argument("--name", required=True)
    add.add_argument("--target", required=True)
    add.add_argument("--probe", action="store_true")

    sync = sub.add_parser(
        "sync-ssh-config",
        help="import concrete Host aliases from ~/.ssh/config",
    )
    sync.add_argument("--ssh-config", default=str(DEFAULT_SSH_CONFIG))
    sync.add_argument("--include", help="regular expression applied to aliases")
    sync.add_argument("--exclude", help="regular expression applied to aliases")
    sync.add_argument("--name-prefix", default="")
    sync.add_argument(
        "--probe",
        action="store_true",
        help="only add aliases with a running default Herdr socket",
    )
    sync.add_argument(
        "--strict",
        action="store_true",
        help="exit non-zero when any probe fails",
    )

    remove = sub.add_parser(
        "remove",
        help="remove SSH devices; the Local device is never removed",
    )
    remove_group = remove.add_mutually_exclusive_group(required=True)
    remove_group.add_argument("--name")
    remove_group.add_argument("--target")

    sub.add_parser("list", help="show the configured device inventory")
    sub.add_parser("doctor", help="probe every configured SSH device")
    return parser


def main(argv: Iterable[str] | None = None) -> int:
    args = build_parser().parse_args(list(argv) if argv is not None else None)
    store = Path(args.store).expanduser()
    try:
        if args.command == "add":
            return command_add(args, store)
        if args.command == "sync-ssh-config":
            return command_sync(args, store)
        if args.command == "remove":
            return command_remove(args, store)
        if args.command == "list":
            return command_list(args, store)
        if args.command == "doctor":
            return command_doctor(args, store)
        raise HerdrMConfigError(f"unsupported command: {args.command}")
    except (HerdrMConfigError, re.error) as exc:
        print_result({"ok": False, "error": str(exc), "store": str(store)})
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
