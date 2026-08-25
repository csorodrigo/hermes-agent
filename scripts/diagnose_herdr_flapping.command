#!/usr/bin/env bash
set -uo pipefail

filter_local_processes() {
  local mode="$1"
  awk -v mode="$mode" '
    mode == "app" && tolower($5) ~ /\/herdrm$/ {
      print
      next
    }
    mode == "tunnel" && $5 == "/usr/bin/ssh" && index($0, "herdrm-tunnels") {
      print
    }
  '
}

process_filter_self_test() {
  local fixture app_lines tunnel_lines
  fixture='65737     1  13:23:12 S    /Applications/herdrm.app/Contents/MacOS/herdrm
61864 65737   02:34:55 S    /usr/bin/ssh -N -L /tmp/herdrm-tunnels/73775.sock:/home/wedo/.config/herdr/herdr.sock wedo-backup
70000 65737      00:01 S    /usr/bin/ssh example.invalid
70001 65737      00:01 S    /usr/bin/awk index($0, "herdrm-tunnels")'
  app_lines="$(printf '%s\n' "$fixture" | filter_local_processes app)"
  tunnel_lines="$(printf '%s\n' "$fixture" | filter_local_processes tunnel)"

  if [ "$(printf '%s\n' "$app_lines" | wc -l | tr -d ' ')" != "1" ] \
    || [ "$(printf '%s\n' "$tunnel_lines" | wc -l | tr -d ' ')" != "1" ] \
    || [[ "$app_lines" != *"/Applications/herdrm.app/Contents/MacOS/herdrm"* ]] \
    || [[ "$tunnel_lines" != *"wedo-backup"* ]]; then
    echo "process_filter_self_test=fail" >&2
    return 1
  fi
  echo "process_filter_self_test=pass"
}

if [ "${1:-}" = "--self-test" ]; then
  process_filter_self_test
  exit $?
fi

# Non-destructive stability collector for HerdrM + remote Herdr servers.
# Default: observe for 180 seconds. Override with:
#   HERDR_FLAP_SECONDS=300 HERDR_FLAP_INTERVAL=5 ./diagnose_herdr_flapping.command

DURATION="${HERDR_FLAP_SECONDS:-180}"
INTERVAL="${HERDR_FLAP_INTERVAL:-3}"
DEVICE_STORE="${HERDRM_DEVICE_STORE:-$HOME/Library/Application Support/HerdrM/devices.json}"
STAMP="$(date '+%Y%m%d-%H%M%S')"
OUT="${HERDR_FLAP_REPORT:-$HOME/Desktop/herdr-flapping-$STAMP.log}"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/herdr-flap.XXXXXX")"

FLEET=(
  "Papiro-antigravity|Papiro"
  "wedo-giordanni|Wedo"
  "wedo-backup|Wedo Backup"
  "lucrando-ch-ops|Lucrando CH Ops"
  "dobra-gate|Dobra Gate"
)

case "$DURATION" in
  ''|*[!0-9]*) echo "ERROR: HERDR_FLAP_SECONDS must be an integer." >&2; exit 2 ;;
esac
case "$INTERVAL" in
  ''|*[!0-9]*) echo "ERROR: HERDR_FLAP_INTERVAL must be an integer." >&2; exit 2 ;;
esac
if [ "$DURATION" -lt 30 ] || [ "$INTERVAL" -lt 1 ]; then
  echo "ERROR: use at least 30 seconds and an interval of at least 1 second." >&2
  exit 2
fi
if [ "$(uname -s)" != "Darwin" ]; then
  echo "ERROR: run this collector on the Mac where HerdrM is open." >&2
  exit 1
fi

mkdir -p "$(dirname "$OUT")"
: > "$OUT"

PIDS=()
cleanup() {
  for pid in "${PIDS[@]:-}"; do
    kill "$pid" >/dev/null 2>&1 || true
  done
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT HUP INT TERM

emit() {
  printf '%s\n' "$*" | tee -a "$OUT"
}

now() {
  date '+%Y-%m-%dT%H:%M:%S%z'
}

emit "HerdrM stability capture"
emit "Started: $(now)"
emit "Duration: ${DURATION}s"
emit "Sampling interval (remote): ${INTERVAL}s"
emit "Report: $OUT"
emit ""

emit "================================================================================"
emit "MAC / APP INVENTORY"
emit "--------------------------------------------------------------------------------"
sw_vers 2>&1 | tee -a "$OUT" || true
uname -a 2>&1 | tee -a "$OUT" || true

APP_PATH=""
for candidate in "/Applications/HerdrM.app" "$HOME/Applications/HerdrM.app"; do
  if [ -d "$candidate" ]; then
    APP_PATH="$candidate"
    break
  fi
done
if [ -n "$APP_PATH" ]; then
  emit "HerdrM.app=$APP_PATH"
  /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$APP_PATH/Contents/Info.plist" 2>/dev/null \
    | sed 's/^/HerdrM.version=/' | tee -a "$OUT" || true
  /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
    "$APP_PATH/Contents/Info.plist" 2>/dev/null \
    | sed 's/^/HerdrM.build=/' | tee -a "$OUT" || true
else
  emit "HerdrM.app=not-found-in-standard-locations"
fi

if command -v herdr >/dev/null 2>&1; then
  command -v herdr | sed 's/^/local.herdr.path=/' | tee -a "$OUT"
  herdr --version 2>&1 | sed 's/^/local.herdr.version=/' | tee -a "$OUT" || true
  herdr status --json 2>&1 | sed 's/^/local.herdr.status=/' | tee -a "$OUT" || true
else
  emit "local.herdr.path=missing"
fi

emit ""
emit "HerdrM device inventory (credentials are not printed):"
python3 - "$DEVICE_STORE" <<'PY' 2>&1 | tee -a "$OUT"
import json
import sys
from pathlib import Path

path = Path(sys.argv[1]).expanduser()
print(f"device_store={path}")
if not path.exists():
    print("device_store_status=missing")
    raise SystemExit(0)
try:
    payload = json.loads(path.read_text(encoding="utf-8"))
except Exception as exc:
    print(f"device_store_status=invalid error={exc!r}")
    raise SystemExit(0)
if not isinstance(payload, list):
    print(f"device_store_status=unexpected_type type={type(payload).__name__}")
    raise SystemExit(0)

print(f"device_store_status=ok count={len(payload)}")
for item in payload:
    if not isinstance(item, dict):
        print(f"device=invalid value={item!r}")
        continue
    name = item.get("name")
    ident = item.get("id")
    kind = item.get("kind")
    if isinstance(kind, dict) and "local" in kind:
        print(f"device name={name!r} id={ident!r} kind=local")
    elif isinstance(kind, dict) and isinstance(kind.get("ssh"), dict):
        print(
            f"device name={name!r} id={ident!r} kind=ssh "
            f"target={kind['ssh'].get('target')!r} osID={item.get('osID')!r}"
        )
    else:
        print(f"device name={name!r} id={ident!r} kind=unknown")
PY

emit ""
emit "================================================================================"
emit "EFFECTIVE SSH CONFIG"
emit "--------------------------------------------------------------------------------"
for spec in "${FLEET[@]}"; do
  IFS='|' read -r target display <<< "$spec"
  emit "[$display] target=$target"
  ssh -G "$target" 2>/dev/null \
    | awk '
      $1=="hostname" ||
      $1=="user" ||
      $1=="port" ||
      $1=="controlmaster" ||
      $1=="controlpath" ||
      $1=="controlpersist" ||
      $1=="serveraliveinterval" ||
      $1=="serveralivecountmax" ||
      $1=="tcpkeepalive" ||
      $1=="proxyjump" ||
      $1=="identityfile" { print "  " $0 }
    ' | tee -a "$OUT"
done

local_sampler() {
  local local_out="$TMP_ROOT/local-sampler.log"
  local end_epoch
  end_epoch=$(( $(date +%s) + DURATION ))
  : > "$local_out"

  while [ "$(date +%s)" -lt "$end_epoch" ]; do
    {
      echo "@@ LOCAL_SAMPLE $(now)"
      echo "-- HerdrM process"
      process_snapshot="$(ps -axo pid=,ppid=,etime=,state=,command= 2>/dev/null)"
      app_snapshot="$(printf '%s\n' "$process_snapshot" | filter_local_processes app)"
      if [ -n "$app_snapshot" ]; then
        printf '%s\n' "$app_snapshot"
      else
        echo "none"
      fi

      echo "-- HerdrM SSH Unix-socket tunnels"
      printf '%s\n' "$process_snapshot" | filter_local_processes tunnel || true

      echo "-- forwarded local sockets"
      tunnel_dir="${TMPDIR:-/tmp}"
      tunnel_dir="${tunnel_dir%/}/herdrm-tunnels"
      if [ -d "$tunnel_dir" ]; then
        find "$tunnel_dir" -maxdepth 1 -type s -print 2>/dev/null | sort
      else
        echo "none directory=$tunnel_dir"
      fi
      echo
    } >> "$local_out" 2>&1
    sleep 1
  done
}

remote_sampler() {
  local target="$1"
  local display="$2"
  local safe
  safe="$(printf '%s' "$target" | tr -c 'A-Za-z0-9._-' '_')"
  local remote_out="$TMP_ROOT/remote-$safe.log"

  ssh \
    -o BatchMode=yes \
    -o ConnectTimeout=12 \
    -o ServerAliveInterval=5 \
    -o ServerAliveCountMax=2 \
    "$target" \
    "bash -s -- '$DURATION' '$INTERVAL' '$display' '$target'" > "$remote_out" 2>&1 <<'REMOTE'
set +e
DURATION="$1"
INTERVAL="$2"
DISPLAY_NAME="$3"
TARGET_NAME="$4"
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$HOME/.grok/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

uid="$(id -u)"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$uid}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"

timestamp() {
  date '+%Y-%m-%dT%H:%M:%S%z'
}

echo "REMOTE_CAPTURE display=$DISPLAY_NAME target=$TARGET_NAME"
echo "started=$(timestamp)"
echo "identity user=$(id -un) uid=$(id -u) host=$(hostname) home=$HOME"
printf 'herdr_path='
command -v herdr || true
herdr --version 2>&1 | sed 's/^/herdr_version=/' || true
echo "duration=${DURATION}s interval=${INTERVAL}s"
echo

end_epoch=$(( $(date +%s) + DURATION ))
sample=0
while [ "$(date +%s)" -lt "$end_epoch" ]; do
  sample=$((sample + 1))
  echo "@@ REMOTE_SAMPLE n=$sample at=$(timestamp)"

  if [ -S "$HOME/.config/herdr/herdr.sock" ]; then
    echo "socket=present"
  elif [ -e "$HOME/.config/herdr/herdr.sock" ]; then
    echo "socket=stale-or-not-socket"
  else
    echo "socket=missing"
  fi

  status_output="$(herdr status --json 2>&1)"
  status_rc=$?
  echo "herdr_status_rc=$status_rc"
  printf '%s\n' "$status_output" | sed 's/^/herdr_status=/'

  echo "-- relevant processes"
  ps -eo pid=,ppid=,lstart=,etime=,stat=,args= 2>/dev/null \
    | awk '
      /[h]erdr-watch-supervisor/ ||
      /[h]erdr([[:space:]].*)?[[:space:]]server([[:space:]]|$)/
    ' || true

  echo "-- systemd user state"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl --user show herdr-server.service \
      -p LoadState \
      -p ActiveState \
      -p SubState \
      -p MainPID \
      -p NRestarts \
      -p Result \
      -p ExecMainCode \
      -p ExecMainStatus \
      -p ExecMainStartTimestamp \
      -p ActiveEnterTimestamp 2>&1 | sed 's/^/herdr-server.service /'

    units="$(
      systemctl --user list-unit-files --type=service --no-legend 2>/dev/null \
        | awk '$1 ~ /^herdr-.*\.service$/ && $1 != "herdr-server.service" {print $1}'
    )"
    for unit in $units; do
      echo "unit=$unit"
      systemctl --user show "$unit" \
        -p LoadState \
        -p ActiveState \
        -p SubState \
        -p MainPID \
        -p NRestarts \
        -p Result \
        -p ExecMainStatus \
        -p ExecMainStartTimestamp 2>&1 | sed "s/^/$unit /"
    done
  else
    echo "systemctl=missing"
  fi

  if command -v loginctl >/dev/null 2>&1; then
    loginctl show-user "$(id -un)" -p Linger 2>&1 | sed 's/^/loginctl /'
  fi

  echo
  sleep "$INTERVAL"
done

echo "@@ REMOTE_FINAL at=$(timestamp)"
echo "-- systemd unit files"
if command -v systemctl >/dev/null 2>&1; then
  systemctl --user list-unit-files --type=service --no-legend 2>&1 \
    | awk '/^herdr-.*\.service/ || /^herdr-server\.service/ {print}' || true

  echo "-- herdr-server.service definition"
  systemctl --user cat herdr-server.service 2>&1 || true

  echo "-- herdr-server.service journal (last 30 minutes)"
  journalctl --user -u herdr-server.service --since '-30 minutes' \
    --no-pager -n 400 2>&1 || true

  units="$(
    systemctl --user list-unit-files --type=service --no-legend 2>/dev/null \
      | awk '$1 ~ /^herdr-.*\.service$/ && $1 != "herdr-server.service" {print $1}'
  )"
  for unit in $units; do
    echo "-- $unit definition"
    systemctl --user cat "$unit" 2>&1 || true
    echo "-- $unit journal (last 30 minutes)"
    journalctl --user -u "$unit" --since '-30 minutes' \
      --no-pager -n 400 2>&1 || true
  done
fi

echo "-- fallback supervisor log"
tail -n 400 "$HOME/.local/state/herdr/server.log" 2>&1 || true

echo "-- current socket metadata"
ls -la "$HOME/.config/herdr/herdr.sock" 2>&1 || true
echo "finished=$(timestamp)"
REMOTE

  rc=$?
  {
    echo
    echo "ssh_sampler_exit=$rc target=$target display=$display"
  } >> "$remote_out"
  return 0
}

emit ""
emit "================================================================================"
emit "LIVE CAPTURE"
emit "--------------------------------------------------------------------------------"
emit "Keep HerdrM open. The collector is read-only and will observe the current flapping for ${DURATION}s."

local_sampler &
PIDS+=("$!")

for spec in "${FLEET[@]}"; do
  IFS='|' read -r target display <<< "$spec"
  remote_sampler "$target" "$display" &
  PIDS+=("$!")
done

for pid in "${PIDS[@]}"; do
  wait "$pid" || true
done
PIDS=()

emit ""
emit "================================================================================"
emit "LOCAL HERDRM / SSH TIMELINE"
emit "--------------------------------------------------------------------------------"
cat "$TMP_ROOT/local-sampler.log" >> "$OUT" 2>/dev/null || true

for spec in "${FLEET[@]}"; do
  IFS='|' read -r target display <<< "$spec"
  safe="$(printf '%s' "$target" | tr -c 'A-Za-z0-9._-' '_')"
  emit ""
  emit "================================================================================"
  emit "REMOTE TIMELINE: $display ($target)"
  emit "--------------------------------------------------------------------------------"
  cat "$TMP_ROOT/remote-$safe.log" >> "$OUT" 2>/dev/null || emit "remote_log=missing"
done

emit ""
emit "================================================================================"
emit "MACOS UNIFIED LOG: HerdrM"
emit "--------------------------------------------------------------------------------"
minutes=$(( (DURATION + 299) / 60 + 5 ))
/usr/bin/log show \
  --style compact \
  --last "${minutes}m" \
  --predicate 'process == "HerdrM" OR process == "herdrm"' 2>&1 >> "$OUT" || true

emit ""
emit "================================================================================"
emit "AUTOMATIC SUMMARY"
emit "--------------------------------------------------------------------------------"
python3 - "$TMP_ROOT" "${FLEET[@]}" <<'PY' 2>&1 | tee -a "$OUT"
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
specs = sys.argv[2:]

local = (root / "local-sampler.log").read_text(encoding="utf-8", errors="replace") \
    if (root / "local-sampler.log").exists() else ""
samples = local.count("@@ LOCAL_SAMPLE")
herdrm_missing = len(re.findall(r"-- HerdrM process\nnone(?:\n|$)", local))
tunnel_pids = set()
for line in local.splitlines():
    if "/usr/bin/ssh" in line and "herdrm-tunnels" in line:
        match = re.match(r"\s*(\d+)", line)
        if match:
            tunnel_pids.add(match.group(1))

print(f"local_samples={samples}")
print(f"local_samples_without_HerdrM={herdrm_missing}")
print(f"distinct_ssh_tunnel_pids={len(tunnel_pids)} pids={','.join(sorted(tunnel_pids, key=int)) or 'none'}")

for spec in specs:
    target, display = spec.split("|", 1)
    safe = re.sub(r"[^A-Za-z0-9._-]", "_", target)
    path = root / f"remote-{safe}.log"
    text = path.read_text(encoding="utf-8", errors="replace") if path.exists() else ""
    sample_count = text.count("@@ REMOTE_SAMPLE")
    status_ok = len(re.findall(r"^herdr_status_rc=0$", text, re.M))
    status_bad = len(re.findall(r"^herdr_status_rc=(?!0$)\d+", text, re.M))
    socket_missing = len(re.findall(r"^socket=(?:missing|stale-or-not-socket)$", text, re.M))
    active = len(re.findall(r"^herdr-server\.service ActiveState=active$", text, re.M))
    inactive = len(re.findall(r"^herdr-server\.service ActiveState=(?!active$).+", text, re.M))
    main_pids = {
        value for value in re.findall(r"^herdr-server\.service MainPID=(\d+)$", text, re.M)
        if value != "0"
    }
    restart_values = [
        int(value) for value in re.findall(r"^herdr-server\.service NRestarts=(\d+)$", text, re.M)
    ]
    ssh_exit = re.findall(r"^ssh_sampler_exit=(\d+)", text, re.M)
    print(
        f"remote={display!r} target={target!r} samples={sample_count} "
        f"status_ok={status_ok} status_bad={status_bad} "
        f"socket_missing_or_stale={socket_missing} "
        f"systemd_active_samples={active} systemd_nonactive_samples={inactive} "
        f"distinct_main_pids={len(main_pids)} "
        f"restart_counter_min={min(restart_values) if restart_values else 'n/a'} "
        f"restart_counter_max={max(restart_values) if restart_values else 'n/a'} "
        f"ssh_sampler_exit={ssh_exit[-1] if ssh_exit else 'missing'}"
    )
PY

emit ""
emit "Finished: $(now)"
emit "Report: $OUT"
emit ""
emit "Do not run remediation again before this report is reviewed."

open -R "$OUT" >/dev/null 2>&1 || true
printf '\nCapture complete: %s\n' "$OUT"
