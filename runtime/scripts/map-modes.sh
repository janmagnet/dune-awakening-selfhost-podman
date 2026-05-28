#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../.."

STATE_FILE="${DUNE_MAP_MODES_FILE:-runtime/generated/map-runtime-modes.json}"
GRACE_SECONDS="${DUNE_AUTOSCALER_DESPAWN_GRACE_SECONDS:-${DUNE_AUTOSCALER_IDLE_SECONDS:-300}}"

usage() {
  cat <<'EOF'
Usage:
  dune maps list
  dune maps mode
  dune maps mode <map>
  dune maps set <map> dynamic
  dune maps set <map> always-on
  dune maps reconcile

Survival_1 and Overmap are protected always-on maps and are not configurable here.
EOF
}

require_postgres() {
  if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx dune-postgres; then
    echo "dune-postgres is not running."
    exit 1
  fi
}

protected_map() {
  case "$1" in
    Survival_1|Overmap|survival|survival-1|survival_1|overmap) return 0 ;;
    *) return 1 ;;
  esac
}

canonical_map() {
  local input="$1"
  if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx dune-postgres; then
    printf '%s' "$input"
    return 0
  fi
  docker exec dune-postgres psql -U postgres -d dune -At -v ON_ERROR_STOP=1 -c "
    select map
    from dune.world_partition
    where lower(map) = lower('${input//\'/\'\'}')
    order by partition_id
    limit 1;
  " 2>/dev/null | tr -d '\r' || printf '%s' "$input"
}

ensure_state_file() {
  mkdir -p "$(dirname "$STATE_FILE")"
  if [ ! -s "$STATE_FILE" ]; then
    python3 - "$STATE_FILE" <<'PY'
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

path = Path(sys.argv[1])
payload = {
    "version": 1,
    "updated_at": datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
    "maps": {},
}
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
  fi
}

mode_for_map() {
  local map="$1"
  ensure_state_file
  python3 - "$STATE_FILE" "$map" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
target = sys.argv[2]
try:
    data = json.loads(path.read_text(encoding="utf-8"))
except Exception:
    data = {}
mode = data.get("maps", {}).get(target, {}).get("mode", "dynamic")
print("always-on" if mode == "always-on" else "dynamic")
PY
}

last_change_epoch() {
  local map="$1"
  ensure_state_file
  python3 - "$STATE_FILE" "$map" <<'PY'
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

try:
    data = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
    raw = data.get("maps", {}).get(sys.argv[2], {}).get("last_mode_change_at", "")
    if not raw:
        raise ValueError
    dt = datetime.fromisoformat(raw.replace("Z", "+00:00"))
    print(int(dt.timestamp()))
except Exception:
    print("")
PY
}

set_mode() {
  local map="$1"
  local mode="$2"
  local canonical

  require_postgres
  canonical="$(canonical_map "$map")"
  if [ -z "$canonical" ] || protected_map "$canonical"; then
    echo "Map is protected or unknown and cannot be configured here: $map"
    exit 1
  fi

  case "$mode" in
    dynamic|always-on) ;;
    *) echo "Mode must be dynamic or always-on."; exit 2 ;;
  esac

  ensure_state_file
  python3 - "$STATE_FILE" "$canonical" "$mode" <<'PY'
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

path = Path(sys.argv[1])
target = sys.argv[2]
mode = sys.argv[3]
try:
    data = json.loads(path.read_text(encoding="utf-8"))
except Exception:
    data = {}
data["version"] = 1
data.setdefault("maps", {})
now = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
data["updated_at"] = now
data["maps"][target] = {"mode": mode, "last_mode_change_at": now}
tmp = path.with_name(f".{path.name}.tmp.{os.getpid()}")
tmp.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")
tmp.replace(path)
PY

  echo "Map mode saved: $canonical -> $mode"
  if [ "$mode" = "always-on" ]; then
    reconcile_map "$canonical"
  else
    echo "Map remains running if already active. It is eligible for normal despawn after ${GRACE_SECONDS}s."
  fi
}

list_maps() {
  require_postgres
  ensure_state_file
  docker exec dune-postgres psql -U postgres -d dune -At -F '|' -c "
    select
      wp.map,
      count(*) as partitions,
      count(nullif(wp.server_id, '')) as assigned
    from dune.world_partition wp
    where wp.map not in ('Survival_1', 'Overmap')
    group by wp.map
    order by min(wp.partition_id);
  " | while IFS='|' read -r map partitions assigned; do
    [ -n "${map:-}" ] || continue
    printf '%-28s Current: %-9s Partitions: %-3s Assigned: %s\n' "$map" "$(mode_for_map "$map")" "$partitions" "$assigned"
  done
}

show_mode() {
  local map="${1:-}"
  if [ -z "$map" ]; then
    list_maps
    return 0
  fi
  map="$(canonical_map "$map")"
  printf '%s\t%s\n' "$map" "$(mode_for_map "$map")"
}

reconcile_map() {
  local map="$1"
  local rows assigned running

  require_postgres
  rows="$(docker exec dune-postgres psql -U postgres -d dune -At -F '|' -c "
    select partition_id, coalesce(server_id, '')
    from dune.world_partition
    where map = '${map//\'/\'\'}'
      and coalesce(blocked, false) = false
    order by partition_id;
  ")"

  if [ -z "$rows" ]; then
    echo "No non-blocked partitions found for map: $map"
    return 1
  fi

  while IFS='|' read -r partition_id assigned; do
    [ -n "${partition_id:-}" ] || continue
    running="$(docker ps --format '{{.Names}}' | grep -Ec "^dune-server-$(printf '%s' "$map" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g')-${partition_id}$" || true)"
    if [ -n "$assigned" ] || [ "$running" != "0" ]; then
      echo "OK   always-on map=$map partition=$partition_id"
      continue
    fi
    echo "SPAWN always-on map=$map partition=$partition_id"
    runtime/scripts/spawn-server.sh "$partition_id"
  done <<< "$rows"
}

reconcile_all() {
  require_postgres
  ensure_state_file
  python3 - "$STATE_FILE" <<'PY' | while read -r map; do
import json
import sys
from pathlib import Path

try:
    data = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
except Exception:
    data = {}
for map_name, cfg in sorted(data.get("maps", {}).items()):
    if cfg.get("mode") == "always-on":
        print(map_name)
PY
    [ -n "$map" ] || continue
    protected_map "$map" && continue
    reconcile_map "$map"
  done
}

dynamic_grace_remaining() {
  local map="$1"
  local changed now elapsed
  changed="$(last_change_epoch "$map")"
  [ -n "$changed" ] || { echo 0; return 0; }
  now="$(date +%s)"
  elapsed=$((now - changed))
  if [ "$elapsed" -lt "$GRACE_SECONDS" ]; then
    echo $((GRACE_SECONDS - elapsed))
  else
    echo 0
  fi
}

cmd="${1:-help}"
case "$cmd" in
  list) list_maps ;;
  mode) shift || true; show_mode "${1:-}" ;;
  set)
    if [ $# -ne 3 ]; then usage; exit 2; fi
    set_mode "$2" "$3"
    ;;
  reconcile) reconcile_all ;;
  is-always-on)
    map="$(canonical_map "${2:-}")"
    [ "$(mode_for_map "$map")" = "always-on" ]
    ;;
  grace-remaining)
    map="$(canonical_map "${2:-}")"
    dynamic_grace_remaining "$map"
    ;;
  help|--help|-h) usage ;;
  *) echo "Unknown maps command: $cmd"; usage; exit 2 ;;
esac
