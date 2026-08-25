#!/usr/bin/env bash
set -euo pipefail

BRANCH="${HERDR_HARNESS_BRANCH:-feat/herdr-hermes-team-harness}"
REPO_HTTPS="${HERDR_HARNESS_REPO_HTTPS:-https://github.com/csorodrigo/hermes-agent.git}"
LOCAL_HARNESS="${HERDR_HARNESS_DIR:-$HOME/.cache/herdr-hermes-harness}"
DEVICE_STORE="${HERDRM_DEVICE_STORE:-$HOME/Library/Application Support/HerdrM/devices.json}"
STAMP="$(date +%Y%m%d-%H%M%S)"
REPORT="${HERDR_REMEDIATION_REPORT:-$HOME/Desktop/herdr-remediation-$STAMP.log}"

# Canonical one-device-per-remote-account inventory. These aliases were selected
# from the uploaded fleet audit because they use the same working endpoints but
# avoid the duplicate/ControlMaster aliases that were red in HerdrM.
FLEET=(
  "Papiro-antigravity|Papiro|fleet-papiro"
  "wedo-giordanni|Wedo|fleet-wedo"
  "wedo-backup|Wedo Backup|fleet-wedo-backup"
  "lucrando-ch-ops|Lucrando CH Ops|fleet-lucrando"
  "dobra-gate|Dobra Gate|fleet-dobra"
)

usage() {
  cat <<'EOF'
Repair and validate the audited Herdr/Hermes/HerdrM fleet.

This script:
  - backs up and deduplicates the HerdrM device inventory;
  - keeps one canonical SSH alias per remote Unix account;
  - installs the Hermes herdr_harness plugin/controller/profile remotely;
  - preserves existing Herdr servers and active external coding processes;
  - ensures a persistent Herdr supervisor where systemd user service is absent;
  - creates Spaces for discovered Git repositories;
  - starts one visible Hermes control agent per remote account (Codex fallback);
  - validates socket, harness, profile, workspace and agent state;
  - reopens HerdrM and writes a full report to the Desktop.

No production repository, branch, service or existing coding process is deleted.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "ERROR: run this command on the Mac that owns the HerdrM inventory." >&2
  exit 1
fi
for binary in git python3 ssh curl osascript open; do
  command -v "$binary" >/dev/null 2>&1 || {
    echo "ERROR: missing local dependency: $binary" >&2
    exit 1
  }
done

mkdir -p "$(dirname "$REPORT")"
: > "$REPORT"
log() { printf '%s\n' "$*" | tee -a "$REPORT"; }

log "Herdr fleet remediation"
log "Started: $(date -Iseconds)"
log "Branch: $BRANCH"
log ""

log "Closing HerdrM before rewriting devices.json..."
osascript -e 'tell application "HerdrM" to quit' >/dev/null 2>&1 || true
for _ in $(jot 30 1 30); do
  pgrep -x HerdrM >/dev/null 2>&1 || break
  sleep 0.5
done
if pgrep -x HerdrM >/dev/null 2>&1; then
  log "ERROR: HerdrM is still running. Quit it completely and retry."
  exit 1
fi

log "Preparing local harness checkout..."
mkdir -p "$(dirname "$LOCAL_HARNESS")"
if [[ -d "$LOCAL_HARNESS/.git" ]]; then
  git -C "$LOCAL_HARNESS" fetch origin "$BRANCH" 2>&1 | tee -a "$REPORT"
  git -C "$LOCAL_HARNESS" checkout -B "$BRANCH" "origin/$BRANCH" 2>&1 | tee -a "$REPORT"
else
  rm -rf "$LOCAL_HARNESS"
  git clone --branch "$BRANCH" --single-branch "$REPO_HTTPS" "$LOCAL_HARNESS" 2>&1 | tee -a "$REPORT"
fi

log "Backing up and canonicalizing HerdrM inventory..."
python3 - "$DEVICE_STORE" "${FLEET[@]}" <<'PY' 2>&1 | tee -a "$REPORT"
import json, os, shutil, sys, uuid
from datetime import datetime, timezone
from pathlib import Path

store = Path(sys.argv[1]).expanduser()
entries = sys.argv[2:]
store.parent.mkdir(parents=True, exist_ok=True)
try:
    current = json.loads(store.read_text(encoding="utf-8")) if store.exists() else []
except Exception as exc:
    raise SystemExit(f"cannot parse {store}: {exc}")
if not isinstance(current, list):
    raise SystemExit(f"{store} must contain a JSON array")

def is_local(item):
    return isinstance(item, dict) and isinstance(item.get("kind"), dict) and "local" in item["kind"]

def target(item):
    if not isinstance(item, dict): return None
    kind = item.get("kind")
    if not isinstance(kind, dict): return None
    ssh = kind.get("ssh")
    if not isinstance(ssh, dict): return None
    value = ssh.get("target")
    return value if isinstance(value, str) else None

local = next((x for x in current if is_local(x)), {
    "id": "00000000-0000-0000-0000-000000000001",
    "name": "Local",
    "kind": {"local": {}},
    "osID": "macos",
})
remotes = []
for spec in entries:
    ssh_alias, display, _profile = spec.split("|", 2)
    existing = next((x for x in current if (target(x) or "").casefold() == ssh_alias.casefold()), None)
    if existing is None:
        existing = {
            "id": str(uuid.uuid5(uuid.NAMESPACE_URL, f"herdrm:{ssh_alias.casefold()}")),
            "name": display,
            "kind": {"ssh": {"target": ssh_alias}},
        }
    else:
        existing = dict(existing)
        existing["name"] = display
        existing["kind"] = {"ssh": {"target": ssh_alias}}
    remotes.append(existing)

if store.exists():
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    backup = store.with_name(f"{store.name}.bak-remediation-{stamp}")
    shutil.copy2(store, backup)
    os.chmod(backup, 0o600)
    print(f"backup={backup}")
payload = json.dumps([local, *remotes], indent=2, sort_keys=True, ensure_ascii=False) + "\n"
tmp = store.with_name(f".{store.name}.{os.getpid()}.tmp")
tmp.write_text(payload, encoding="utf-8")
os.chmod(tmp, 0o600)
os.replace(tmp, store)
os.chmod(store, 0o600)
print(f"devices={1 + len(remotes)}")
for item in remotes:
    print(f"device={item['name']} target={item['kind']['ssh']['target']}")
PY

failures=0
for spec in "${FLEET[@]}"; do
  IFS='|' read -r target display profile <<< "$spec"
  log ""
  log "================================================================================"
  log "REMOTE: $display ($target) profile=$profile"
  log "--------------------------------------------------------------------------------"

  set +e
  ssh \
    -o BatchMode=yes \
    -o ConnectTimeout=12 \
    -o ServerAliveInterval=5 \
    -o ServerAliveCountMax=2 \
    "$target" \
    "bash -s -- '$profile' '$BRANCH' '$REPO_HTTPS'" <<'REMOTE' 2>&1 | tee -a "$REPORT"
set -euo pipefail
PROFILE="$1"
BRANCH="$2"
REPO_HTTPS="$3"
HARNESS_DIR="$HOME/.cache/herdr-hermes-harness"
WORKTREES_ROOT="$HOME/.local/share/herdr-worktrees/$PROFILE"
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$HOME/.grok/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

say() { printf '[%s] %s\n' "$PROFILE" "$*"; }
for binary in git python3 ssh herdr hermes; do
  command -v "$binary" >/dev/null 2>&1 || {
    say "ERROR missing binary: $binary"
    exit 1
  }
done

say "identity user=$(id -un) host=$(hostname) home=$HOME"
say "updating harness checkout"
mkdir -p "$(dirname "$HARNESS_DIR")"
if [[ -d "$HARNESS_DIR/.git" ]]; then
  git -C "$HARNESS_DIR" fetch origin "$BRANCH"
  git -C "$HARNESS_DIR" checkout -B "$BRANCH" "origin/$BRANCH"
else
  rm -rf "$HARNESS_DIR"
  git clone --branch "$BRANCH" --single-branch "$REPO_HTTPS" "$HARNESS_DIR"
fi

say "installing plugin, controller and profile without replacing the existing Herdr service"
bash "$HARNESS_DIR/scripts/bootstrap_herdr_harness.sh" \
  --mode server \
  --profile "$PROFILE" \
  --session default \
  --repo-dir "$HARNESS_DIR" \
  --worktrees-root "$WORKTREES_ROOT" \
  --base-ref main \
  --skip-service

say "configuring Hermes process environment"
mkdir -p "$HOME/.hermes"
ENV_FILE="$HOME/.hermes/.env"
touch "$ENV_FILE"
chmod 0600 "$ENV_FILE"
python3 - "$ENV_FILE" "$PROFILE" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
profile = sys.argv[2]
updates = {
    "HERDR_HARNESS_PROFILE": profile,
    "HERDR_HARNESS_AUTO_ENABLE": "1",
}
lines = path.read_text(encoding="utf-8").splitlines() if path.exists() else []
out = []
seen = set()
for line in lines:
    if "=" in line and not line.lstrip().startswith("#"):
        key = line.split("=", 1)[0].strip()
        if key in updates:
            out.append(f"{key}={updates[key]}")
            seen.add(key)
            continue
    out.append(line)
for key, value in updates.items():
    if key not in seen:
        out.append(f"{key}={value}")
path.write_text("\n".join(out).rstrip() + "\n", encoding="utf-8")
PY

say "ensuring Herdr persistence"
persistence="unknown"
if command -v systemctl >/dev/null 2>&1; then
  uid="$(id -u)"
  export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$uid}"
  export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"
  if systemctl --user is-active --quiet herdr-server.service 2>/dev/null; then
    persistence="systemd-active"
  else
    if command -v loginctl >/dev/null 2>&1; then
      loginctl enable-linger "$(id -un)" >/dev/null 2>&1 \
        || sudo -n loginctl enable-linger "$(id -un)" >/dev/null 2>&1 \
        || true
    fi
    mkdir -p "$HOME/.config/systemd/user"
    cat > "$HOME/.config/systemd/user/herdr-server.service" <<EOF
[Unit]
Description=Herdr watch-first headless server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$(command -v herdr) server
Restart=always
RestartSec=3
Environment=PATH=$HOME/.local/bin:$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin

[Install]
WantedBy=default.target
EOF
    if systemctl --user daemon-reload >/dev/null 2>&1 \
      && systemctl --user enable herdr-server.service >/dev/null 2>&1; then
      if herdr status --json >/dev/null 2>&1; then
        persistence="systemd-enabled-existing-server"
      elif systemctl --user start herdr-server.service >/dev/null 2>&1; then
        persistence="systemd-started"
      fi
    fi
  fi
fi

if [[ "$persistence" == "unknown" ]]; then
  mkdir -p "$HOME/.local/bin" "$HOME/.local/state/herdr"
  cat > "$HOME/.local/bin/herdr-watch-supervisor" <<'SUP'
#!/bin/sh
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
mkdir -p "$HOME/.local/state/herdr"
while :; do
  if herdr status --json >/dev/null 2>&1; then
    sleep 15
    continue
  fi
  herdr server >> "$HOME/.local/state/herdr/server.log" 2>&1 || true
  sleep 3
done
SUP
  chmod 0755 "$HOME/.local/bin/herdr-watch-supervisor"
  if command -v crontab >/dev/null 2>&1; then
    current="$(crontab -l 2>/dev/null || true)"
    marker='herdr-watch-supervisor'
    if ! printf '%s\n' "$current" | grep -Fq "$marker"; then
      { printf '%s\n' "$current"; printf '@reboot %s/.local/bin/herdr-watch-supervisor >/dev/null 2>&1 &\n' "$HOME"; } | crontab -
    fi
    if ! pgrep -u "$(id -u)" -f "$HOME/.local/bin/herdr-watch-supervisor" >/dev/null 2>&1; then
      nohup "$HOME/.local/bin/herdr-watch-supervisor" >/dev/null 2>&1 &
    fi
    persistence="cron-supervisor"
  else
    say "ERROR neither systemd user service nor crontab is available for reboot persistence"
    exit 1
  fi
fi
say "persistence=$persistence"

say "importing Git repositories as Herdr Spaces"
python3 - "$HARNESS_DIR" <<'PY'
from pathlib import Path
import json, os, subprocess, sys

harness = Path(sys.argv[1]).resolve()
home = Path.home().resolve()
prune = {
    ".git", "node_modules", ".npm", ".cargo", ".rustup", ".cache",
    ".local", ".antigravity-ide-server", ".vscode-server", "Library",
}

def run(*args):
    return subprocess.run(args, text=True, capture_output=True)

def extract_workspaces(value):
    if isinstance(value, dict):
        if isinstance(value.get("workspaces"), list):
            return value["workspaces"]
        for child in value.values():
            found = extract_workspaces(child)
            if found is not None: return found
    return None

listed = run("herdr", "workspace", "list")
try:
    value = json.loads(listed.stdout)
except Exception:
    value = {}
existing = set()
for item in extract_workspaces(value) or []:
    if not isinstance(item, dict): continue
    for key in ("cwd", "path", "working_directory", "worktree_path"):
        candidate = item.get(key)
        if isinstance(candidate, str):
            try: existing.add(str(Path(candidate).resolve()))
            except Exception: pass

candidates = {str(harness)}
for root, dirs, files in os.walk(home):
    current = Path(root)
    try:
        depth = len(current.relative_to(home).parts)
    except Exception:
        depth = 99
    has_git_dir = ".git" in dirs
    has_git_file = ".git" in files
    if has_git_dir or has_git_file:
        candidates.add(str(current.resolve()))
    dirs[:] = [d for d in dirs if d not in prune and not d.startswith(".Trash")]
    if depth >= 6:
        dirs[:] = []
    if len(candidates) >= 50:
        break

# Add working directories of currently running coding processes when available.
proc = Path("/proc")
if proc.is_dir():
    for entry in proc.iterdir():
        if not entry.name.isdigit(): continue
        try:
            cmd = (entry / "cmdline").read_bytes().replace(b"\0", b" ").decode(errors="ignore")
            if not any(token in cmd for token in ("codex", "claude", "hermes", "opencode", "gemini")):
                continue
            cwd = (entry / "cwd").resolve()
            if str(cwd).startswith(str(home)):
                candidates.add(str(cwd))
        except Exception:
            pass

created = 0
for raw in sorted(candidates):
    path = Path(raw)
    if not path.is_dir() or raw in existing:
        continue
    label = path.name or "home"
    result = run("herdr", "workspace", "create", "--cwd", raw, "--label", label, "--no-focus")
    if result.returncode == 0:
        created += 1
        existing.add(raw)
print(json.dumps({"spaces_existing_or_created": len(existing), "spaces_created": created}, indent=2))
PY

say "starting a visible control agent"
python3 - "$HARNESS_DIR" <<'PY'
from pathlib import Path
import json, subprocess, sys, time

harness = str(Path(sys.argv[1]).resolve())

def run(args, timeout=120):
    return subprocess.run(args, text=True, capture_output=True, timeout=timeout)

def walk(value):
    yield value
    if isinstance(value, dict):
        for child in value.values(): yield from walk(child)
    elif isinstance(value, list):
        for child in value: yield from walk(child)

def parse(text):
    try: return json.loads(text)
    except Exception: return {}

def first_id(value, keys):
    for item in walk(value):
        if not isinstance(item, dict): continue
        for key in keys:
            candidate = item.get(key)
            if isinstance(candidate, str) and candidate: return candidate
            if isinstance(candidate, dict) and isinstance(candidate.get("id"), str): return candidate["id"]
    return None

agents = parse(run(["herdr", "agent", "list"]).stdout)
for item in walk(agents):
    if isinstance(item, dict) and item.get("name") in {"hermesctl", "codexctl"}:
        print(json.dumps({"control_agent": item.get("name"), "created": False}, indent=2))
        raise SystemExit(0)

workspaces = parse(run(["herdr", "workspace", "list"]).stdout)
workspace_id = None
for item in walk(workspaces):
    if not isinstance(item, dict): continue
    cwd = item.get("cwd") or item.get("path") or item.get("working_directory")
    if isinstance(cwd, str):
        try:
            if str(Path(cwd).resolve()) == harness:
                workspace_id = item.get("workspace_id") or item.get("id")
                break
        except Exception:
            pass
if not workspace_id:
    created = parse(run(["herdr", "workspace", "create", "--cwd", harness, "--label", "herdr-harness", "--no-focus"]).stdout)
    workspace_id = first_id(created, ("workspace_id", "workspace"))
    pane_id = first_id(created, ("pane_id", "root_pane"))
else:
    panes = parse(run(["herdr", "pane", "list", "--workspace", str(workspace_id)]).stdout)
    pane_id = first_id(panes, ("pane_id", "pane"))
if not pane_id:
    raise SystemExit("could not resolve a shell pane for the control agent")

attempts = []
for name, kind in (("hermesctl", "hermes"), ("codexctl", "codex")):
    result = run(["herdr", "agent", "start", name, "--kind", kind, "--pane", str(pane_id), "--timeout", "90000"], timeout=110)
    attempts.append({"name": name, "kind": kind, "returncode": result.returncode, "stdout": result.stdout[-2000:], "stderr": result.stderr[-2000:]})
    current = parse(run(["herdr", "agent", "list"]).stdout)
    if any(isinstance(x, dict) and x.get("name") == name for x in walk(current)):
        print(json.dumps({"control_agent": name, "created": True, "attempts": attempts}, indent=2))
        raise SystemExit(0)
    run(["herdr", "pane", "send-keys", str(pane_id), "ctrl+c"])
    time.sleep(2)
raise SystemExit(json.dumps({"error": "no control agent became visible", "attempts": attempts}, indent=2))
PY

say "final remote validation"
test -f "$HOME/.hermes/plugins/herdr-harness/plugin.yaml"
test -f "$HOME/.hermes/plugins/herdr-harness/__init__.py"
test -f "$HOME/.hermes/plugins/herdr-harness/controller.py"
test -x "$HOME/.local/bin/herdr-hermesctl"
test -f "$HOME/.config/herdr-harness/$PROFILE.ini"
test -S "$HOME/.config/herdr/herdr.sock"
herdr status --json >/dev/null
python3 - <<'PY'
import json, subprocess

def load(args):
    p = subprocess.run(args, text=True, capture_output=True)
    if p.returncode: raise SystemExit(p.stderr or p.stdout)
    return json.loads(p.stdout)

def count_key(value, key):
    if isinstance(value, dict):
        if isinstance(value.get(key), list): return len(value[key])
        for child in value.values():
            found = count_key(child, key)
            if found is not None: return found
    return None
spaces = count_key(load(["herdr", "workspace", "list"]), "workspaces") or 0
agents = count_key(load(["herdr", "agent", "list"]), "agents") or 0
if spaces < 1: raise SystemExit("validation failed: zero Herdr workspaces")
if agents < 1: raise SystemExit("validation failed: zero Herdr agents")
print(json.dumps({"ok": True, "workspaces": spaces, "agents": agents}, indent=2))
PY
say "REMOTE PASS"
REMOTE
  remote_rc=${PIPESTATUS[0]}
  set -e
  if [[ $remote_rc -ne 0 ]]; then
    log "REMOTE FAIL: $display ($target), exit=$remote_rc"
    failures=$((failures + 1))
  else
    log "REMOTE PASS: $display ($target)"
  fi
done

log ""
log "Running HerdrM SSH/socket doctor against the canonical inventory..."
set +e
python3 "$LOCAL_HARNESS/scripts/configure_herdrm.py" doctor 2>&1 | tee -a "$REPORT"
doctor_rc=${PIPESTATUS[0]}
set -e
if [[ $doctor_rc -ne 0 ]]; then
  failures=$((failures + 1))
fi

log ""
log "Reopening HerdrM..."
open -a HerdrM
sleep 8

log ""
log "Running final read-only fleet audit..."
set +e
bash "$LOCAL_HARNESS/scripts/audit_herdr_fleet.command" 2>&1 | tee -a "$REPORT"
audit_rc=${PIPESTATUS[0]}
set -e
if [[ $audit_rc -ne 0 ]]; then
  failures=$((failures + 1))
fi

log ""
log "Finished: $(date -Iseconds)"
log "Report: $REPORT"
if [[ $failures -eq 0 ]]; then
  log "FINAL RESULT: PASS — canonical SSH devices, remote harnesses, Spaces and control agents validated."
  open -R "$REPORT"
  exit 0
fi
log "FINAL RESULT: FAIL — $failures validation stage(s) need attention. See the report above."
open -R "$REPORT"
exit 1
