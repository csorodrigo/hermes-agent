#!/usr/bin/env bash
set -euo pipefail

BRANCH="${HERDR_HARNESS_BRANCH:-feat/herdr-hermes-team-harness}"
REPO_HTTPS="${HERDR_HARNESS_REPO_HTTPS:-https://github.com/csorodrigo/hermes-agent.git}"
LOCAL_HARNESS="${HERDR_HARNESS_DIR:-$HOME/.cache/herdr-hermes-harness}"
STAMP="$(date +%Y%m%d-%H%M%S)"
REPORT="${HERDR_CURATE_REPORT:-$HOME/Desktop/herdr-curate-$STAMP.log}"

# One canonical SSH endpoint per remote Unix account.
FLEET=(
  "Papiro-antigravity|Papiro|fleet-papiro"
  "wedo-giordanni|Wedo|fleet-wedo"
  "wedo-backup|Wedo Backup|fleet-wedo-backup"
  "lucrando-ch-ops|Lucrando CH Ops|fleet-lucrando"
  "dobra-gate|Dobra Gate|fleet-dobra"
)

usage() {
  cat <<'EOF'
Curate the HerdrM fleet after the initial broad repository discovery.

The command is intentionally conservative:
  - it never deletes repositories, worktrees, branches or files;
  - it stops only placeholder agents named hermesctl/codexctl;
  - it preserves workspaces that host any other live agent;
  - it closes empty remote workspaces created by the fleet remediation;
  - it leaves exactly one Control space per otherwise-idle remote account;
  - it starts Codex as the visible control agent only when Codex becomes ready;
  - it removes local empty spaces whose labels were generated from fleet names;
  - it adds the harness environment to active user-level Hermes services and
    restarts only those Hermes services so an existing Discord gateway reloads
    the installed plugin.

Closing a Herdr workspace removes only Herdr UI/session state. It does not remove
the directory on disk.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "ERROR: run this command on the Mac that owns HerdrM." >&2
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

log "Herdr space curation"
log "Started: $(date -Iseconds)"
log "Branch: $BRANCH"
log ""

log "Closing HerdrM while session state is curated..."
osascript -e 'tell application "HerdrM" to quit' >/dev/null 2>&1 || true
for _ in $(jot 30 1 30); do
  pgrep -x HerdrM >/dev/null 2>&1 || break
  sleep 0.5
done
if pgrep -x HerdrM >/dev/null 2>&1; then
  log "ERROR: HerdrM is still running. Quit it completely and retry."
  exit 1
fi

log "Preparing the local harness checkout..."
mkdir -p "$(dirname "$LOCAL_HARNESS")"
if [[ -d "$LOCAL_HARNESS/.git" ]]; then
  git -C "$LOCAL_HARNESS" fetch origin "$BRANCH" 2>&1 | tee -a "$REPORT"
  git -C "$LOCAL_HARNESS" checkout -B "$BRANCH" "origin/$BRANCH" 2>&1 | tee -a "$REPORT"
else
  rm -rf "$LOCAL_HARNESS"
  git clone --branch "$BRANCH" --single-branch "$REPO_HTTPS" "$LOCAL_HARNESS" 2>&1 | tee -a "$REPORT"
fi

log "Curating fleet-labelled spaces accidentally created in the Local device..."
python3 - <<'PY' 2>&1 | tee -a "$REPORT"
import json
import subprocess
import time
from pathlib import Path

FLEET_PREFIXES = (
    "papiro", "wedo", "lucrando ch ops", "dobra gate", "fleet-",
)
PLACEHOLDERS = {"hermesctl", "codexctl"}


def run(args, timeout=60):
    return subprocess.run(args, text=True, capture_output=True, timeout=timeout)


def load(args):
    result = run(args)
    if result.returncode:
        return {}
    try:
        return json.loads(result.stdout)
    except Exception:
        return {}


def walk(value):
    yield value
    if isinstance(value, dict):
        for child in value.values():
            yield from walk(child)
    elif isinstance(value, list):
        for child in value:
            yield from walk(child)


def collect(value, list_key):
    for item in walk(value):
        if isinstance(item, dict) and isinstance(item.get(list_key), list):
            return [x for x in item[list_key] if isinstance(x, dict)]
    return []


def workspace_id(item):
    for key in ("workspace_id", "id"):
        value = item.get(key)
        if isinstance(value, str) and value:
            return value
    return None


def agent_workspace(item):
    value = item.get("workspace_id")
    return value if isinstance(value, str) else None


def agent_name(item):
    value = item.get("name") or item.get("agent_name")
    return value if isinstance(value, str) else ""

agents = collect(load(["herdr", "agent", "list"]), "agents")
placeholder_workspaces = set()
for agent in agents:
    if agent_name(agent) not in PLACEHOLDERS:
        continue
    target = agent_name(agent) or agent.get("pane_id")
    if target:
        run(["herdr", "agent", "send-keys", str(target), "ctrl+c"])
    ws = agent_workspace(agent)
    if ws:
        placeholder_workspaces.add(ws)
time.sleep(2)

agents = collect(load(["herdr", "agent", "list"]), "agents")
active_workspaces = {agent_workspace(x) for x in agents if agent_workspace(x)}
workspaces = collect(load(["herdr", "workspace", "list"]), "workspaces")
closed = []
kept = []
for workspace in workspaces:
    wid = workspace_id(workspace)
    if not wid:
        continue
    label = str(workspace.get("label") or workspace.get("name") or "")
    cwd = str(workspace.get("cwd") or workspace.get("path") or "")
    generated = label.casefold().startswith(FLEET_PREFIXES)
    generated = generated or wid in placeholder_workspaces
    try:
        generated = generated or Path(cwd).resolve().is_relative_to(
            (Path.home() / ".cache" / "herdr-hermes-harness").resolve()
        )
    except (AttributeError, ValueError, OSError):
        generated = generated or cwd.startswith(str(Path.home() / ".cache" / "herdr-hermes-harness"))
    if generated and wid not in active_workspaces:
        result = run(["herdr", "workspace", "close", wid])
        if result.returncode == 0:
            closed.append({"id": wid, "label": label, "cwd": cwd})
        else:
            kept.append({"id": wid, "label": label, "reason": (result.stderr or result.stdout).strip()})
print(json.dumps({"ok": True, "local_closed": closed, "local_kept": kept}, indent=2, ensure_ascii=False))
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
    "bash -s -- '$display' '$profile'" <<'REMOTE' 2>&1 | tee -a "$REPORT"
set -euo pipefail
DISPLAY_NAME="$1"
PROFILE="$2"
HARNESS_DIR="$HOME/.cache/herdr-hermes-harness"
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$HOME/.grok/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

say() { printf '[%s] %s\n' "$PROFILE" "$*"; }
for binary in python3 herdr; do
  command -v "$binary" >/dev/null 2>&1 || {
    say "ERROR missing binary: $binary"
    exit 1
  }
done

test -d "$HARNESS_DIR" || {
  say "ERROR harness checkout is missing: $HARNESS_DIR"
  exit 1
}

say "curating auto-imported spaces and replacing the temporary Hermes setup agent"
python3 - "$DISPLAY_NAME" "$HARNESS_DIR" <<'PY'
import json
import subprocess
import sys
import time
from pathlib import Path

display = sys.argv[1]
harness = str(Path(sys.argv[2]).resolve())
PLACEHOLDERS = {"hermesctl", "codexctl"}


def run(args, timeout=120):
    return subprocess.run(args, text=True, capture_output=True, timeout=timeout)


def parse(text):
    try:
        return json.loads(text)
    except Exception:
        return {}


def load(args):
    result = run(args)
    return parse(result.stdout), result


def walk(value):
    yield value
    if isinstance(value, dict):
        for child in value.values():
            yield from walk(child)
    elif isinstance(value, list):
        for child in value:
            yield from walk(child)


def collect(value, list_key):
    for item in walk(value):
        if isinstance(item, dict) and isinstance(item.get(list_key), list):
            return [x for x in item[list_key] if isinstance(x, dict)]
    return []


def first_id(value, keys):
    for item in walk(value):
        if not isinstance(item, dict):
            continue
        for key in keys:
            candidate = item.get(key)
            if isinstance(candidate, str) and candidate:
                return candidate
            if isinstance(candidate, dict):
                nested = candidate.get("id") or candidate.get(f"{key}_id")
                if isinstance(nested, str) and nested:
                    return nested
    return None


def workspace_id(item):
    for key in ("workspace_id", "id"):
        value = item.get(key)
        if isinstance(value, str) and value:
            return value
    return None


def agent_workspace(item):
    value = item.get("workspace_id")
    return value if isinstance(value, str) else None


def agent_name(item):
    value = item.get("name") or item.get("agent_name")
    return value if isinstance(value, str) else ""


def agent_status(item):
    value = item.get("status") or item.get("state")
    if isinstance(value, str):
        return value.casefold()
    if isinstance(value, dict):
        for key in ("status", "state", "kind"):
            nested = value.get(key)
            if isinstance(nested, str):
                return nested.casefold()
    return "unknown"

# Stop only the placeholders created by the broad remediation. A process that
# predates Herdr is not attached to these named agents and is never touched.
agents, _ = load(["herdr", "agent", "list"])
placeholder_workspaces = set()
for agent in collect(agents, "agents"):
    name = agent_name(agent)
    if name not in PLACEHOLDERS:
        continue
    target = name or agent.get("pane_id")
    if target:
        run(["herdr", "agent", "send-keys", str(target), "ctrl+c"])
    ws = agent_workspace(agent)
    if ws:
        placeholder_workspaces.add(ws)
time.sleep(3)

# A setup wizard may retain the agent for a moment. It is safe to close only
# its own pane because the name is reserved by this remediation.
agents, _ = load(["herdr", "agent", "list"])
for agent in collect(agents, "agents"):
    if agent_name(agent) not in PLACEHOLDERS:
        continue
    pane = agent.get("pane_id") or agent.get("id")
    if isinstance(pane, str) and pane:
        run(["herdr", "pane", "close", pane])
time.sleep(2)

agents, _ = load(["herdr", "agent", "list"])
remaining_agents = collect(agents, "agents")
active_workspaces = {agent_workspace(x) for x in remaining_agents if agent_workspace(x)}

# Before the remediation audit every remote account had zero Herdr workspaces.
# Therefore every empty workspace now present came from the broad discovery and
# can be closed without touching its directory. Workspaces hosting any other
# live agent are preserved.
workspaces, _ = load(["herdr", "workspace", "list"])
closed = []
kept = []
for workspace in collect(workspaces, "workspaces"):
    wid = workspace_id(workspace)
    if not wid:
        continue
    label = str(workspace.get("label") or workspace.get("name") or "")
    cwd = str(workspace.get("cwd") or workspace.get("path") or "")
    if wid in active_workspaces:
        kept.append({"id": wid, "label": label, "cwd": cwd, "reason": "hosts a live non-placeholder agent"})
        continue
    result = run(["herdr", "workspace", "close", wid])
    if result.returncode == 0:
        closed.append({"id": wid, "label": label, "cwd": cwd})
    else:
        raise SystemExit(json.dumps({
            "error": "could not close an empty auto-imported workspace",
            "workspace_id": wid,
            "label": label,
            "stderr": result.stderr,
            "stdout": result.stdout,
        }, indent=2))

# Keep one intentional control surface per account. Real project spaces are
# created later, on demand, by New Space or task-create.
created, result = load([
    "herdr", "workspace", "create",
    "--cwd", harness,
    "--label", f"Controle — {display}",
    "--no-focus",
])
if result.returncode:
    raise SystemExit(result.stderr or result.stdout)
workspace = first_id(created, ("workspace_id", "workspace"))
pane = first_id(created, ("pane_id", "root_pane"))
if not workspace or not pane:
    raise SystemExit("could not resolve the curated control workspace or pane")

# The existing Hermes Discord gateway is a service, not a terminal agent. Do not
# launch a second bare Hermes CLI: that was the provider picker seen in HerdrM.
# Codex is used only as a visible, ready coding control terminal.
start = run([
    "herdr", "agent", "start", "codexctl",
    "--kind", "codex",
    "--pane", pane,
    "--timeout", "90000",
], timeout=110)
if start.returncode:
    run(["herdr", "workspace", "close", workspace])
    raise SystemExit(json.dumps({
        "error": "Codex control agent did not become ready",
        "stdout": start.stdout[-3000:],
        "stderr": start.stderr[-3000:],
    }, indent=2))

agents, _ = load(["herdr", "agent", "list"])
control = next((x for x in collect(agents, "agents") if agent_name(x) == "codexctl"), None)
if control is None:
    raise SystemExit("codexctl was not present after a successful agent start")
state = agent_status(control)
if state in {"blocked", "unknown"}:
    run(["herdr", "agent", "send-keys", "codexctl", "ctrl+c"])
    raise SystemExit(f"codexctl is not ready; state={state}")

print(json.dumps({
    "ok": True,
    "closed_empty_spaces": closed,
    "preserved_live_spaces": kept,
    "control_workspace": workspace,
    "control_agent": "codexctl",
    "control_state": state,
}, indent=2, ensure_ascii=False))
PY

say "making the installed harness visible to existing user-level Hermes services"
restarted=0
if command -v systemctl >/dev/null 2>&1; then
  uid="$(id -u)"
  export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$uid}"
  export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"
  if systemctl --user list-units --type=service --state=running --no-legend >/dev/null 2>&1; then
    while IFS= read -r unit; do
      [[ -n "$unit" ]] || continue
      [[ "$unit" == herdr-*.service ]] && continue
      exec_start="$(systemctl --user show "$unit" -p ExecStart --value 2>/dev/null || true)"
      case "$exec_start" in
        *hermes*|*Hermes*)
          dropin="$HOME/.config/systemd/user/$unit.d"
          mkdir -p "$dropin"
          cat > "$dropin/herdr-harness.conf" <<EOF
[Service]
Environment=HERDR_HARNESS_PROFILE=$PROFILE
Environment=HERDR_HARNESS_AUTO_ENABLE=1
EOF
          systemctl --user daemon-reload
          systemctl --user restart "$unit"
          systemctl --user is-active --quiet "$unit"
          say "restarted existing Hermes service: $unit"
          restarted=$((restarted + 1))
          ;;
      esac
    done < <(systemctl --user list-units --type=service --state=running --no-legend | awk '{print $1}')
  fi
fi
if [[ $restarted -eq 0 ]]; then
  if pgrep -u "$(id -u)" -af '(^|[ /])hermes([ /]|$)' >/dev/null 2>&1; then
    say "existing Hermes process detected, but no safe user-level service supervisor was identified; process left untouched"
  else
    say "no separate running Hermes service detected for restart"
  fi
fi

say "validating curated state"
test -S "$HOME/.config/herdr/herdr.sock"
test -f "$HOME/.hermes/plugins/herdr-harness/plugin.yaml"
test -x "$HOME/.local/bin/herdr-hermesctl"
test -f "$HOME/.config/herdr-harness/$PROFILE.ini"
python3 - <<'PY'
import json
import subprocess

def load(args):
    p = subprocess.run(args, text=True, capture_output=True)
    if p.returncode:
        raise SystemExit(p.stderr or p.stdout)
    return json.loads(p.stdout)

def walk(value):
    yield value
    if isinstance(value, dict):
        for child in value.values(): yield from walk(child)
    elif isinstance(value, list):
        for child in value: yield from walk(child)

def collect(value, key):
    for item in walk(value):
        if isinstance(item, dict) and isinstance(item.get(key), list):
            return [x for x in item[key] if isinstance(x, dict)]
    return []
spaces = collect(load(["herdr", "workspace", "list"]), "workspaces")
agents = collect(load(["herdr", "agent", "list"]), "agents")
control = [x for x in agents if x.get("name") == "codexctl"]
if not control:
    raise SystemExit("validation failed: codexctl is missing")
if len(spaces) > 1 + len([x for x in agents if x.get("name") != "codexctl"]):
    raise SystemExit(f"validation failed: unexpected workspace count {len(spaces)}")
print(json.dumps({"ok": True, "spaces": len(spaces), "agents": len(agents)}, indent=2))
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
log "Reopening HerdrM..."
open -a HerdrM
sleep 8

log ""
log "Running HerdrM device doctor..."
set +e
python3 "$LOCAL_HARNESS/scripts/configure_herdrm.py" doctor 2>&1 | tee -a "$REPORT"
doctor_rc=${PIPESTATUS[0]}
set -e
if [[ $doctor_rc -ne 0 ]]; then
  failures=$((failures + 1))
fi

log ""
log "Finished: $(date -Iseconds)"
log "Report: $REPORT"
if [[ $failures -eq 0 ]]; then
  log "FINAL RESULT: PASS — spaces curated, setup wizards removed, Codex controls ready and existing Hermes services preserved/reloaded where safely supervised."
  open -R "$REPORT"
  exit 0
fi
log "FINAL RESULT: FAIL — $failures host or validation stage(s) need attention."
open -R "$REPORT"
exit 1
