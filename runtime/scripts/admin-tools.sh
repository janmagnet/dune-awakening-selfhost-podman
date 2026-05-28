#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../.."

ITEMS_FILE="runtime/data/admin-items.json"
TOKEN_FILE="runtime/secrets/funcom-token.txt"
COMMAND_TOKEN_FILE="runtime/secrets/command-auth-token.txt"
BUILTIN_COMMAND_AUTH_TOKEN="Nu6VmPWUMvdPMeB7qErr"
RMQ_CONTAINER="dune-rmq-game"
POSTGRES_CONTAINER="dune-postgres"
TEXT_ROUTER_LOG="runtime/text-router/director-current.log"

usage() {
  cat <<'EOF'
Usage:
  runtime/scripts/dune admin players [--online] [--show-full-ids]
  runtime/scripts/dune admin kick <player-fls-id> [--dry-run] [--yes] [--force]
  runtime/scripts/dune admin kick --all-online [--dry-run] [--yes]
  runtime/scripts/dune admin item-search <query>
  runtime/scripts/dune admin item-list [category]
  runtime/scripts/dune admin grant-item <player-id|*> <item-name-or-id> [quantity] [durability]
  runtime/scripts/dune admin grant-item-id <player-id|*> <item-id> [quantity] [durability]
  runtime/scripts/dune admin grant-template <player-id|*> scout-ornithopter-mk6
EOF
}

redact_fls() {
  local value="$1"
  local len="${#value}"
  if [ "$len" -le 10 ]; then
    printf '<redacted:%s>' "$len"
  else
    printf '%s...%s' "${value:0:4}" "${value: -4}"
  fi
}

audit_admin_command() {
  local command="$1" target="$2" dry_run="$3" result="$4"
  mkdir -p runtime/generated
  printf '%s\t%s\t%s\t%s\t%s\n' "$(date -Iseconds)" "$command" "$target" "$dry_run" "$result" >> runtime/generated/admin-command-history.tsv
}

require_items_file() {
  if [ ! -r "$ITEMS_FILE" ]; then
    echo "Missing readable item dataset: $ITEMS_FILE" >&2
    echo "Admin grants require the vendored item dataset." >&2
    exit 1
  fi
}

require_token_file() {
  if [ ! -s "$TOKEN_FILE" ]; then
    echo "Missing non-empty Funcom auth token: $TOKEN_FILE" >&2
    exit 1
  fi
}

display_category() {
  local value="${1:-}"
  printf '%s' "${value^}"
}

command_auth_token() {
  local raw

  if [ -n "${DUNE_COMMAND_AUTH_TOKEN:-}" ]; then
    printf '%s' "$DUNE_COMMAND_AUTH_TOKEN"
    return 0
  fi

  if [ -s "$COMMAND_TOKEN_FILE" ]; then
    raw="$(tr -d '\r\n' < "$COMMAND_TOKEN_FILE")"
    if [ -n "$raw" ]; then
      printf '%s' "$raw"
      return 0
    fi
  fi

  # Matches the working upstream manager's command-auth fallback.
  printf '%s' "$BUILTIN_COMMAND_AUTH_TOKEN"
}

require_rmq_game_running() {
  if ! docker exec "$RMQ_CONTAINER" rabbitmqctl status >/dev/null 2>&1; then
    echo "RabbitMQ game container is not running: $RMQ_CONTAINER" >&2
    echo "Start the battlegroup first; item grants are published live to the running container." >&2
    exit 1
  fi
}

require_postgres_running() {
  if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$POSTGRES_CONTAINER"; then
    echo "Postgres container is not running: $POSTGRES_CONTAINER" >&2
    exit 1
  fi
}

resolve_player_id() {
  local player_id="$1"
  local resolved

  if [ "$player_id" = "*" ]; then
    printf '%s' "$player_id"
    return 0
  fi

  if ! printf '%s' "$player_id" | grep -Eq '^[0-9]+$'; then
    printf '%s' "$player_id"
    return 0
  fi

  resolved="$(
    docker exec "$POSTGRES_CONTAINER" psql -U dune -d dune -At -c "
      select coalesce(nullif(\"user\", ''), nullif(funcom_id, ''))
      from dune.accounts
      where id = ${player_id}
      limit 1;
    " 2>/dev/null | tr -d '[:space:]' || true
  )"

  if [ -z "$resolved" ]; then
    echo "Could not resolve local account id '$player_id' to an FLS id in dune.accounts." >&2
    echo "Use the player's FLS id instead, or make sure $POSTGRES_CONTAINER is running." >&2
    exit 1
  fi

  printf '%s' "$resolved"
}

account_id_for_player_id() {
  local player_id="$1"

  [ "$player_id" != "*" ] || return 0
  docker exec "$POSTGRES_CONTAINER" psql -U dune -d dune -At -c "
    select id
    from dune.accounts
    where \"user\" = '${player_id//\'/\'\'}'
       or funcom_id = '${player_id//\'/\'\'}'
    limit 1;
  " 2>/dev/null | tr -d '[:space:]' || true
}

player_item_stack_count() {
  local account_id="$1"
  local item_id="$2"

  [ -n "$account_id" ] || return 0
  docker exec "$POSTGRES_CONTAINER" psql -U dune -d dune -At -c "
    select coalesce(sum(it.stack_size), 0)
    from dune.items it
    join dune.inventories inv on inv.id = it.inventory_id
    join dune.actors a on a.id = inv.actor_id
    where a.owner_account_id = ${account_id}
      and it.template_id = '${item_id//\'/\'\'}';
  " 2>/dev/null | tr -d '[:space:]' || true
}

validate_quantity() {
  local quantity="$1"
  if ! printf '%s' "$quantity" | grep -Eq '^[1-9][0-9]*$'; then
    echo "Quantity must be a positive integer." >&2
    exit 1
  fi
}

validate_durability() {
  local durability="$1"
  python3 - "$durability" <<'PY'
import sys
try:
    value = float(sys.argv[1])
except ValueError:
    print("Durability must be a number between 0 and 1.", file=sys.stderr)
    raise SystemExit(1)
if not 0 <= value <= 1:
    print("Durability must be a number between 0 and 1.", file=sys.stderr)
    raise SystemExit(1)
PY
}

item_search() {
  local query="${1:-}"
  if [ -z "$query" ]; then
    echo "Usage: runtime/scripts/dune admin item-search <query>" >&2
    exit 1
  fi
  require_items_file
  python3 - "$ITEMS_FILE" "$query" <<'PY'
import json
import sys

items_path, query = sys.argv[1], sys.argv[2]
needle = query.casefold()
with open(items_path, encoding="utf-8") as f:
    items = json.load(f)

matches = []
for item in items:
    name = str(item.get("name") or "")
    category = str(item.get("category") or "")
    source = str(item.get("source") or "")
    item_id = str(item.get("id") or "")
    haystacks = (name, category, source, item_id)
    if any(needle in value.casefold() for value in haystacks):
        rank = 0 if needle in name.casefold() else 1
        matches.append((rank, name.casefold(), item))

if not matches:
    print(f"No items found for: {query}")
    raise SystemExit(1)

for index, (_, __, item) in enumerate(sorted(matches, key=lambda row: (row[0], row[1], row[2].get("source") or ""))[:100], 1):
    category = str(item.get("category") or "")
    category = category[:1].upper() + category[1:]
    print(f"{index}) {item.get('name', '')}")
    print(f"   category: {category}")
    print(f"   source: {item.get('source', '')}")
PY
}

item_list() {
  local category="${1:-}"
  require_items_file
  python3 - "$ITEMS_FILE" "$category" <<'PY'
import collections
import json
import sys

items_path, category_filter = sys.argv[1], sys.argv[2]
with open(items_path, encoding="utf-8") as f:
    items = json.load(f)

if category_filter:
    wanted = category_filter.casefold()
    filtered = [item for item in items if str(item.get("category") or "").casefold() == wanted]
    if not filtered:
        print(f"No items found in category: {category_filter}", file=sys.stderr)
        raise SystemExit(1)
    for item in sorted(filtered, key=lambda value: (str(value.get("name") or "").casefold(), str(value.get("source") or ""))):
        category = str(item.get("category") or "")
        category = category[:1].upper() + category[1:]
        print(f"{item.get('name', '')}")
        print(f"  category: {category}")
        print(f"  source: {item.get('source', '')}")
    raise SystemExit(0)

by_category = collections.defaultdict(list)
for item in items:
    by_category[str(item.get("category") or "uncategorized")].append(item)

for category in sorted(by_category, key=str.casefold):
    label = category[:1].upper() + category[1:]
    print(f"{label} ({len(by_category[category])})")
    for item in sorted(by_category[category], key=lambda value: str(value.get("name") or "").casefold()):
        print(f"  - {item.get('name', '')} [{item.get('source', '')}]")
PY
}

resolve_item() {
  local mode="$1"
  local value="$2"
  require_items_file
  python3 - "$ITEMS_FILE" "$mode" "$value" <<'PY'
import json
import sys

items_path, mode, value = sys.argv[1], sys.argv[2], sys.argv[3]
with open(items_path, encoding="utf-8") as f:
    items = json.load(f)

def emit(item):
    print(json.dumps({
        "id": item.get("id") or value,
        "name": item.get("name") or item.get("id") or value,
        "category": item.get("category") or "manual",
        "source": item.get("source") or "manual",
    }, ensure_ascii=False))

if mode == "id":
    for item in items:
        if str(item.get("id") or "") == value:
            emit(item)
            raise SystemExit(0)
    emit({"id": value, "name": value, "category": "manual", "source": "manual"})
    raise SystemExit(0)

folded = value.casefold()
name_matches = [item for item in items if str(item.get("name") or "").casefold() == folded]
if len(name_matches) > 1:
    non_schematics = [item for item in name_matches if str(item.get("category") or "").casefold() != "schematics"]
    if len(non_schematics) == 1:
        emit(non_schematics[0])
        raise SystemExit(0)
if len(name_matches) == 1:
    emit(name_matches[0])
    raise SystemExit(0)
if len(name_matches) > 1:
    print(f"Ambiguous item name: {value}", file=sys.stderr)
    for index, item in enumerate(name_matches[:25], 1):
        print(f"{index}) {item.get('name', '')}", file=sys.stderr)
        print(f"   category: {item.get('category', '')}", file=sys.stderr)
        print(f"   source: {item.get('source', '')}", file=sys.stderr)
    raise SystemExit(2)

id_matches = [item for item in items if str(item.get("id") or "") == value]
if len(id_matches) == 1:
    emit(id_matches[0])
    raise SystemExit(0)

partial = [
    item for item in items
    if folded in str(item.get("name") or "").casefold()
    or folded in str(item.get("category") or "").casefold()
    or folded in str(item.get("source") or "").casefold()
    or folded in str(item.get("id") or "").casefold()
]
if partial:
    print(f"No exact item name or id found for: {value}", file=sys.stderr)
    print("Close matches:", file=sys.stderr)
    for index, item in enumerate(sorted(partial, key=lambda x: str(x.get("name") or "").casefold())[:25], 1):
        print(f"{index}) {item.get('name', '')}", file=sys.stderr)
        print(f"   category: {item.get('category', '')}", file=sys.stderr)
        print(f"   source: {item.get('source', '')}", file=sys.stderr)
    raise SystemExit(1)

print(f"No item found for: {value}", file=sys.stderr)
print("Use item-search with a human-readable name, or grant-item-id for an advanced raw id grant.", file=sys.stderr)
raise SystemExit(1)
PY
}

build_inner_json() {
  local player_id="$1"
  local item_id="$2"
  local quantity="$3"
  local durability="$4"
  python3 - "$player_id" "$item_id" "$quantity" "$durability" <<'PY'
import json
import sys

player_id, item_id, quantity, durability = sys.argv[1], sys.argv[2], int(sys.argv[3]), float(sys.argv[4])
print(json.dumps({
    "ServerCommand": "AddItemToInventory",
    "PlayerId": player_id,
    "ItemName": item_id,
    "Quantity": quantity,
    "Durability": durability,
}, separators=(",", ":")))
PY
}

build_kick_json() {
  local player_id="$1"
  python3 - "$player_id" <<'PY'
import json
import sys
print(json.dumps({"ServerCommand": "KickPlayer", "PlayerId": sys.argv[1]}, separators=(",", ":")))
PY
}

build_outer_b64() {
  local inner_json="$1"
  local token
  token="$(command_auth_token)"
  python3 - "$token" "$inner_json" <<'PY'
import base64
import json
import sys

token, inner_json = sys.argv[1], sys.argv[2]
outer = {
    "Version": 2,
    "AuthToken": token,
    "MessageContent": inner_json,
}
encoded = base64.b64encode(json.dumps(outer, separators=(",", ":")).encode("utf-8")).decode("ascii")
print(encoded)
PY
}

build_outer_json() {
  local inner_json="$1"
  local token
  token="$(command_auth_token)"
  python3 - "$token" "$inner_json" <<'PY'
import json
import sys

token, inner_json = sys.argv[1], sys.argv[2]
outer = {
    "Version": 2,
    "AuthToken": token,
    "MessageContent": inner_json,
}
print(json.dumps(outer, separators=(",", ":")))
PY
}

redact_sensitive_output() {
  sed -E 's/("AuthToken"[[:space:]]*:[[:space:]]*")[^"]+/\1<redacted>/g; s/[A-Za-z0-9+\/]{80,}={0,2}/<redacted-base64>/g'
}

publish_inner_json() {
  local inner_json="$1"
  local label="${2:-admin-command}"
  local outer_b64 eval_code output

  require_token_file
  require_rmq_game_running
  outer_b64="$(build_outer_b64 "$inner_json")"
  eval_code='Outer = base64:decode(<<"'"$outer_b64"'">>), XName = rabbit_misc:r(<<"/">>, exchange, <<"heartbeats">>), X = rabbit_exchange:lookup_or_die(XName), MsgId = list_to_binary("smgmt-'"$label"'-" ++ integer_to_list(erlang:system_time(millisecond))), P = {list_to_atom("P_basic"), <<"Content">>, undefined, [], undefined, undefined, undefined, undefined, undefined, MsgId, undefined, undefined, <<"fls">>, <<"fls_backend">>, undefined}, Content = rabbit_basic:build_content(P, Outer), {ok, Msg} = rabbit_basic:message(XName, <<"notifications">>, Content), Result = rabbit_queue_type:publish_at_most_once(X, Msg), io:format("publish=~p exchange=heartbeats routing=notifications app_id=fls_backend user_id=fls label='"$label"'~n", [Result]).'

  set +e
  output="$(docker exec "$RMQ_CONTAINER" rabbitmqctl eval "$eval_code" 2>&1)"
  local rc=$?
  set -e

  if [ "$rc" -ne 0 ]; then
    printf '%s\n' "$output" | redact_sensitive_output >&2
    echo "RabbitMQ publish command failed." >&2
    exit "$rc"
  fi

  printf '%s\n' "$output" | redact_sensitive_output
  if ! printf '%s\n' "$output" | grep -q 'publish=ok'; then
    echo "RabbitMQ publish did not report publish=ok." >&2
    exit 1
  fi
}

ensure_text_router_log() {
  local container_log
  mkdir -p runtime/text-router
  if [ -s "$TEXT_ROUTER_LOG" ]; then
    return 0
  fi
  container_log="$(docker exec dune-text-router sh -lc 'find /Tools/Battlegroups/TextRouter/TextRouter/logs -maxdepth 1 -type f -name "director*.log" | sort | tail -n 1' 2>/dev/null | tr -d '\r')"
  [ -n "$container_log" ] || return 1
  docker cp "dune-text-router:${container_log}" "$TEXT_ROUTER_LOG" >/dev/null
}

load_rmq_admin_creds() {
  ensure_text_router_log

  python3 - <<'PY'
from pathlib import Path
import re
import sys

log_path = Path("runtime/text-router/director-current.log")
if not log_path.exists():
    sys.exit(1)

pattern = re.compile(r'(bgd\.[^/\s]+\.admin)/([A-Za-z0-9+/=]+) => allow administrator')
matches = pattern.findall(log_path.read_text(errors="ignore"))
if not matches:
    sys.exit(1)

username, password = matches[-1]
print(username)
print(password)
PY
}

rmq_admin() {
  local rmq_user rmq_password
  mapfile -t rmq_creds < <(load_rmq_admin_creds)
  [ "${#rmq_creds[@]}" -ge 2 ] || return 1
  rmq_user="${rmq_creds[0]}"
  rmq_password="${rmq_creds[1]}"
  docker exec dune-rmq-admin rabbitmqadmin -q -u "$rmq_user" -p "$rmq_password" "$@"
}

publish_admin_grant_json() {
  local queue_name="$1"
  local inner_json="$2"
  local label="${3:-admin-command}"
  local outer_json output routing_key queue_stem

  require_token_file
  if ! docker exec dune-rmq-admin rabbitmqctl status >/dev/null 2>&1; then
    echo "RabbitMQ admin container is not running: dune-rmq-admin" >&2
    exit 1
  fi

  outer_json="$(build_outer_json "$inner_json")"
  queue_stem="${queue_name%_queue}"
  routing_key="grant.${queue_stem}"

  set +e
  output="$(rmq_admin publish exchange=grant routing_key="$routing_key" properties='{"content_type":"Content","type":"server_admin"}' payload="$outer_json" 2>&1)"
  local rc=$?
  set -e

  if [ "$rc" -ne 0 ]; then
    printf '%s\n' "$output" | redact_sensitive_output >&2
    echo "RabbitMQ admin grant publish failed." >&2
    exit "$rc"
  fi

  if [ -n "$output" ]; then
    printf '%s\n' "$output" | redact_sensitive_output
  fi
  echo "publish=ok exchange=grant routing=$routing_key label=$label"
}

publish_admin_grant_rows() {
  local rows="$1"
  local inner_json="$2"
  local label="$3"
  local queue_name queue_map queue_partition queue_server publish_count=0

  while IFS='|' read -r queue_name queue_map queue_partition queue_server; do
    [ -n "${queue_name:-}" ] || continue
    publish_admin_grant_json "$queue_name" "$inner_json" "$label"
    publish_count=$((publish_count + 1))
  done <<< "$rows"

  if [ "$publish_count" -eq 0 ]; then
    echo "No admin grant publish was performed." >&2
    exit 1
  fi
  PUBLISH_COUNT="$publish_count"
}

player_rows() {
  local online_only="$1"
  require_postgres_running
  docker exec "$POSTGRES_CONTAINER" psql -U postgres -d dune -At -F '|' -c "
    select
      convert_from(e.encrypted_funcom_id, 'UTF8') as fls_id,
      coalesce(ps.character_name, '') as character_name,
      coalesce(ps.online_status::text, 'Unknown') as online_status,
      coalesce(fs.map, '') as map,
      coalesce(wp.partition_id::text, '') as partition_id
    from dune.encrypted_accounts e
    left join dune.player_state ps on ps.account_id = e.id
    left join dune.farm_state fs on fs.server_id = ps.server_id
    left join dune.world_partition wp on wp.server_id = ps.server_id
    where convert_from(e.encrypted_funcom_id, 'UTF8') <> ''
      $([ "$online_only" = "1" ] && printf "and coalesce(ps.online_status::text, 'Offline') <> 'Offline'")
    order by ps.online_status desc nulls last, ps.character_name nulls last, fls_id;
  " 2>/dev/null
}

players_command() {
  local online_only=0 show_full=0 rows row fls name status map partition id_label count=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --online) online_only=1 ;;
      --show-full-ids) show_full=1 ;;
      *) echo "Unknown players option: $1" >&2; exit 2 ;;
    esac
    shift
  done
  rows="$(player_rows "$online_only" || true)"
  if [ "$online_only" = "1" ] && [ -z "$(printf '%s\n' "$rows" | sed '/^$/d')" ]; then
    echo "No online players were found, or online state is unavailable from player_state/farm_state." >&2
    exit 1
  fi
  printf '%-24s %-22s %-12s %-20s %s\n' "FLS" "Character" "Status" "Map" "Partition"
  while IFS='|' read -r fls name status map partition; do
    [ -n "${fls:-}" ] || continue
    if [ "$show_full" = "1" ]; then id_label="$fls"; else id_label="$(redact_fls "$fls")"; fi
    printf '%-24s %-22s %-12s %-20s %s\n' "$id_label" "${name:-}" "${status:-Unknown}" "${map:-}" "${partition:-}"
    count=$((count + 1))
  done <<< "$rows"
  [ "$count" -gt 0 ] || echo "No known players found."
}

player_status_for_fls() {
  local fls="$1"
  if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$POSTGRES_CONTAINER"; then
    return 2
  fi
  docker exec "$POSTGRES_CONTAINER" psql -U postgres -d dune -At -F '|' -c "
    with matched_accounts as (
      select a.id
      from dune.accounts a
      where lower(coalesce(nullif(a.\"user\", ''), '')) = lower('${fls//\'/\'\'}')
         or lower(coalesce(nullif(a.funcom_id, ''), '')) = lower('${fls//\'/\'\'}')
      union
      select e.id
      from dune.encrypted_accounts e
      where lower(convert_from(e.encrypted_funcom_id, 'UTF8')) = lower('${fls//\'/\'\'}')
    )
    select coalesce(ps.online_status::text, 'Unknown') || '|' || coalesce(fs.map, wp.map, '')
    from matched_accounts m
    left join dune.player_state ps on ps.account_id = m.id
    left join dune.farm_state fs on fs.server_id = ps.server_id
    left join dune.world_partition wp on wp.partition_id = ps.previous_server_partition_id
    limit 1;
  " 2>/dev/null | tr -d '\r' || true
}

player_location_for_fls() {
  local fls="$1"
  if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$POSTGRES_CONTAINER"; then
    return 2
  fi
  docker exec "$POSTGRES_CONTAINER" psql -U postgres -d dune -At -F '|' -c "
    with matched_accounts as (
      select a.id
      from dune.accounts a
      where lower(coalesce(nullif(a.\"user\", ''), '')) = lower('${fls//\'/\'\'}')
         or lower(coalesce(nullif(a.funcom_id, ''), '')) = lower('${fls//\'/\'\'}')
      union
      select e.id
      from dune.encrypted_accounts e
      where lower(convert_from(e.encrypted_funcom_id, 'UTF8')) = lower('${fls//\'/\'\'}')
    )
    select
      coalesce(ps.online_status::text, 'Unknown'),
      coalesce(fs.map, wp.map, ''),
      coalesce(wp.partition_id::text, ps.previous_server_partition_id::text, ''),
      coalesce(ps.server_id, '')
    from matched_accounts m
    left join dune.player_state ps on ps.account_id = m.id
    left join dune.farm_state fs on fs.server_id = ps.server_id
    left join dune.world_partition wp on wp.server_id = ps.server_id
    limit 1;
  " 2>/dev/null | tr -d '\r' || true
}

queue_name_for_map_partition() {
  local map_name="$1"
  local partition_id="$2"
  python3 - "$map_name" "$partition_id" <<'PY'
import re
import sys
map_name = sys.argv[1]
partition_id = sys.argv[2]
stem = re.sub(r'[^A-Za-z0-9]', '', map_name)
print(f"{stem}{partition_id}_queue")
PY
}

kick_target_queues() {
  local target="$1"
  local row status map partition_id server_id queue_name

  if [ "$target" = "*" ]; then
    docker exec "$POSTGRES_CONTAINER" psql -U postgres -d dune -At -F '|' -c "
      select distinct
        coalesce(wp.map, ''),
        coalesce(wp.partition_id::text, ''),
        coalesce(wp.server_id, '')
      from dune.player_state ps
      join dune.world_partition wp on wp.server_id = ps.server_id
      where ps.online_status <> 'Offline'
         or (
           ps.reconnect_grace_period_end is not null
           and ps.reconnect_grace_period_end > (current_timestamp at time zone 'UTC')
         )
         or (
           ps.last_avatar_activity is not null
           and ps.last_avatar_activity > (current_timestamp - interval '5 minutes')
         )
      order by wp.map, wp.partition_id;
    " 2>/dev/null | while IFS='|' read -r map partition_id server_id connected_players; do
      [ -n "${map:-}" ] || continue
      [ -n "${partition_id:-}" ] || continue
      queue_name="$(queue_name_for_map_partition "$map" "$partition_id")"
      printf '%s|%s|%s|%s\n' "$queue_name" "$map" "$partition_id" "$server_id"
    done
    return 0
  fi

  row="$(player_location_for_fls "$target" || true)"
  [ -n "$row" ] || return 1
  IFS='|' read -r status map partition_id server_id <<< "$row"
  [ -n "${map:-}" ] || return 1
  [ -n "${partition_id:-}" ] || return 1
  queue_name="$(queue_name_for_map_partition "$map" "$partition_id")"
  printf '%s|%s|%s|%s\n' "$queue_name" "$map" "$partition_id" "$server_id"
}

kick_command() {
  local target="" dry_run=0 assume_yes=0 force=0 all_online=0 inner_json status map answer audit_target result
  local row status_rc queue_rows queue_row queue_name queue_map queue_partition queue_server publish_count=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dry-run) dry_run=1 ;;
      --yes|-y) assume_yes=1 ;;
      --force) force=1 ;;
      --all-online) all_online=1; target="*" ;;
      --*) echo "Unknown kick option: $1" >&2; exit 2 ;;
      *) target="$1" ;;
    esac
    shift
  done
  [ -n "$target" ] || { echo "Usage: dune admin kick <player-fls-id> [--dry-run] [--yes]" >&2; exit 2; }
  if [ "$target" = "*" ] && [ "$all_online" != "1" ]; then
    echo "Use --all-online to target PlayerId='*'." >&2
    exit 2
  fi

  if [ "$all_online" = "1" ]; then
    audit_target="*"
    echo "Target: all players the server considers online (PlayerId='*')."
    echo "WARNING: this publishes a kick command for all online players."
    if [ "$assume_yes" != "1" ] && [ "$dry_run" != "1" ]; then
      read -r -p "Type KICK ALL ONLINE PLAYERS to continue: " answer
      [ "$answer" = "KICK ALL ONLINE PLAYERS" ] || { echo "Cancelled."; exit 1; }
    fi
  else
    audit_target="$(redact_fls "$target")"
    set +e
    row="$(player_status_for_fls "$target")"
    status_rc=$?
    set -e
    if [ "$status_rc" -eq 2 ]; then
      echo "WARNING: Postgres is unavailable, so target player validation was skipped."
      [ "$force" = "1" ] || [ "$dry_run" = "1" ] || exit 1
    elif [ -z "$row" ]; then
      echo "WARNING: target was not found in local accounts: $(redact_fls "$target")"
      [ "$force" = "1" ] || echo "Use --force if you still want to publish to RabbitMQ."
      [ "$force" = "1" ] || [ "$dry_run" = "1" ] || exit 1
    else
      IFS='|' read -r status map <<< "$row"
      echo "Target: $(redact_fls "$target") status=${status:-Unknown} map=${map:-unknown}"
      if [ "${status:-Offline}" = "Offline" ] && [ "$force" != "1" ] && [ "$dry_run" != "1" ]; then
        echo "Refusing to kick an offline player without --force."
        exit 1
      fi
    fi
    if [ "$assume_yes" != "1" ] && [ "$dry_run" != "1" ]; then
      read -r -p "Publish KickPlayer for $(redact_fls "$target")? [y/N]: " answer
      case "$answer" in y|Y|yes|YES) ;; *) echo "Cancelled."; exit 1 ;; esac
    fi
  fi

  inner_json="$(build_kick_json "$target")"
  queue_rows="$(kick_target_queues "$target" || true)"
  if [ "$all_online" = "1" ]; then
    if [ -z "$(printf '%s\n' "$queue_rows" | sed '/^$/d')" ]; then
      echo "WARNING: no live world-server admin queues were resolved for --all-online." >&2
      [ "$force" = "1" ] || [ "$dry_run" = "1" ] || exit 1
    fi
  else
    if [ -z "$queue_rows" ]; then
      echo "WARNING: could not resolve the player's current admin queue from player_state/world_partition." >&2
      [ "$force" = "1" ] || [ "$dry_run" = "1" ] || exit 1
    fi
  fi

  if [ -n "$queue_rows" ]; then
    echo "Target admin queue(s):"
    while IFS='|' read -r queue_name queue_map queue_partition queue_server; do
      [ -n "${queue_name:-}" ] || continue
      printf '  %s (map=%s partition=%s server=%s)\n' "$queue_name" "$queue_map" "$queue_partition" "${queue_server:-unknown}"
    done <<< "$queue_rows"
  fi
  echo "Payload shape:"
  python3 - "$inner_json" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
if payload.get("PlayerId") != "*":
    payload["PlayerId"] = "<redacted>"
print(json.dumps(payload, separators=(",", ":")))
PY

  if [ "$dry_run" = "1" ]; then
    echo "Dry run: not publishing."
    audit_admin_command "KickPlayer" "$audit_target" "true" "dry-run"
    return 0
  fi

  PUBLISH_COUNT=0
  publish_admin_grant_rows "$queue_rows" "$inner_json" "kick-player"
  publish_count="$PUBLISH_COUNT"

  result="published"
  audit_admin_command "KickPlayer" "$audit_target" "false" "$result"
  echo "KickPlayer command published to $publish_count admin route(s). This means the command was queued, not that disconnection was verified."
}

grant_item() {
  local mode="$1"
  local player_id="${2:-}"
  local item_value="${3:-}"
  local quantity="${4:-1}"
  local durability="${5:-1.0}"
  local original_player_id item_json item_id item_name item_category item_source inner_json
  local verify_account_id before_count after_count

  if [ -z "$player_id" ] || [ -z "$item_value" ]; then
    usage >&2
    exit 1
  fi

  require_items_file
  require_token_file
  validate_quantity "$quantity"
  validate_durability "$durability"

  original_player_id="$player_id"
  player_id="$(resolve_player_id "$player_id")"
  item_json="$(resolve_item "$mode" "$item_value")"
  item_id="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["id"])' "$item_json")"
  item_name="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["name"])' "$item_json")"
  item_category="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["category"])' "$item_json")"
  item_source="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["source"])' "$item_json")"

  inner_json="$(build_inner_json "$player_id" "$item_id" "$quantity" "$durability")"

  echo "Grant item:"
  if [ "$original_player_id" != "$player_id" ]; then
    echo "  Player: $original_player_id"
    echo "  Resolved PlayerId: $player_id"
  else
    echo "  Player: $player_id"
  fi
  echo "  Item: $item_name"
  echo "  Category: $(display_category "$item_category")"
  echo "  Source: $item_source"
  echo "  Resolved id: $item_id"
  echo "  Quantity: $quantity"
  echo "  Durability: $durability"

  if [ "${DUNE_ADMIN_DRY_RUN:-0}" = "1" ]; then
    echo
    echo "Dry run: not publishing to RabbitMQ."
    echo "Inner JSON:"
    printf '%s\n' "$inner_json"
    return 0
  fi

  echo
  verify_account_id="$(account_id_for_player_id "$player_id")"
  before_count="$(player_item_stack_count "$verify_account_id" "$item_id")"
  publish_inner_json "$inner_json" "grant-item"
  after_count="$(player_item_stack_count "$verify_account_id" "$item_id")"
  if [ -n "${before_count:-}" ] && [ -n "${after_count:-}" ]; then
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      [ "$after_count" -gt "$before_count" ] && break
      sleep 1
      after_count="$(player_item_stack_count "$verify_account_id" "$item_id")"
      [ -n "${after_count:-}" ] || break
    done
  fi
  echo "Grant item command published."

  if [ -n "${before_count:-}" ] && [ -n "${after_count:-}" ]; then
    if [ "$after_count" -gt "$before_count" ]; then
      echo "Verified inventory stack increased: $item_name ($before_count -> $after_count)."
    else
      echo "WARNING: publish succeeded, but the player's inventory stack did not increase for $item_name." >&2
      echo "The game server may reject this template for AddItemToInventory, or the player may need to relog/refresh inventory." >&2
    fi
  fi
}

template_scout_ornithopter_mk6_components() {
  cat <<'EOF'
OrnithopterLightChassis_6	1
OrnithopterLightHullFront_6	1
OrnithopterLightEngine_6	1
OrnithopterLightGenerator_6	1
OrnithopterLightHullBack_6	1
OrnithopterLightLocomotion_6	4
OrnithopterLightBoost_6	1
OrnithopterLightInventory_4	1
FuelCanister_Large	5
RepairTool5	1
EOF
}

grant_template() {
  local player_id="${1:-}"
  local template_name="${2:-}"
  local original_player_id verify_account_id
  local item_id quantity item_json item_name item_category item_source inner_json
  local before_count after_count expected_count
  local failures=0
  local work_file

  if [ -z "$player_id" ] || [ -z "$template_name" ]; then
    usage >&2
    exit 1
  fi

  case "${template_name,,}" in
    scout-ornithopter-mk6|"scout ornithopter mk6")
      ;;
    *)
      echo "Unknown admin item template: $template_name" >&2
      echo "Available templates: scout-ornithopter-mk6" >&2
      exit 1
      ;;
  esac

  require_items_file
  require_token_file

  original_player_id="$player_id"
  player_id="$(resolve_player_id "$player_id")"

  echo "Grant template:"
  if [ "$original_player_id" != "$player_id" ]; then
    echo "  Player: $original_player_id"
    echo "  Resolved PlayerId: $player_id"
  else
    echo "  Player: $player_id"
  fi
  echo "  Template: Scout Ornithopter Mk6"
  echo "  Components:"

  while IFS=$'\t' read -r item_id quantity; do
    item_json="$(resolve_item "id" "$item_id")"
    item_name="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["name"])' "$item_json")"
    item_category="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["category"])' "$item_json")"
    item_source="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["source"])' "$item_json")"
    printf '  %sx %s (%s / %s, id: %s)\n' "$quantity" "$item_name" "$(display_category "$item_category")" "$item_source" "$item_id"
  done < <(template_scout_ornithopter_mk6_components)

  if [ "${DUNE_ADMIN_DRY_RUN:-0}" = "1" ]; then
    echo
    echo "Dry run: not publishing to RabbitMQ."
    echo "Inner JSON commands:"
    while IFS=$'\t' read -r item_id quantity; do
      inner_json="$(build_inner_json "$player_id" "$item_id" "$quantity" "1.0")"
      printf '%s\n' "$inner_json"
    done < <(template_scout_ornithopter_mk6_components)
    return 0
  fi

  echo
  verify_account_id="$(account_id_for_player_id "$player_id")"
  work_file="$(mktemp)"
  trap 'rm -f "$work_file"' RETURN

  while IFS=$'\t' read -r item_id quantity; do
    item_json="$(resolve_item "id" "$item_id")"
    item_name="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["name"])' "$item_json")"
    before_count="$(player_item_stack_count "$verify_account_id" "$item_id")"
    printf '%s\t%s\t%s\t%s\n' "$item_id" "$quantity" "${before_count:-}" "$item_name" >> "$work_file"
  done < <(template_scout_ornithopter_mk6_components)

  echo "Publishing template component grants..."
  while IFS=$'\t' read -r item_id quantity before_count item_name; do
    inner_json="$(build_inner_json "$player_id" "$item_id" "$quantity" "1.0")"
    publish_inner_json "$inner_json" "grant-item" >/dev/null
  done < "$work_file"
  echo "Published all Scout Ornithopter Mk6 component grants."

  echo "Verifying inventory changes..."
  sleep 1
  while IFS=$'\t' read -r item_id quantity before_count item_name; do
    [ -n "${before_count:-}" ] || continue
    after_count="$(player_item_stack_count "$verify_account_id" "$item_id")"
    [ -n "${after_count:-}" ] || continue
    expected_count=$((before_count + quantity))
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      [ "$after_count" -ge "$expected_count" ] && break
      sleep 1
      after_count="$(player_item_stack_count "$verify_account_id" "$item_id")"
      [ -n "${after_count:-}" ] || break
    done
    if [ "$after_count" -ge "$expected_count" ]; then
      echo "Verified: $item_name ($before_count -> $after_count)."
    else
      failures=$((failures + 1))
      echo "WARNING: published $item_name, but inventory count did not reach expected value ($before_count -> $after_count, expected at least $expected_count)." >&2
    fi
  done < "$work_file"

  if [ "$failures" -ne 0 ]; then
    echo "Template grant completed with $failures verification warning(s)." >&2
    exit 1
  fi
  echo "Template grant completed: Scout Ornithopter Mk6."
}

cmd="${1:-help}"
case "$cmd" in
  players)
    shift || true
    players_command "$@"
    ;;
  kick)
    shift || true
    kick_command "$@"
    ;;
  item-search)
    shift || true
    item_search "${1:-}"
    ;;
  item-list)
    shift || true
    item_list "${1:-}"
    ;;
  grant-item)
    shift || true
    grant_item "name" "$@"
    ;;
  grant-item-id)
    shift || true
    grant_item "id" "$@"
    ;;
  grant-template)
    shift || true
    grant_template "$@"
    ;;
  help|--help|-h)
    usage
    ;;
  *)
    echo "Unknown admin command: $cmd" >&2
    usage >&2
    exit 1
    ;;
esac
