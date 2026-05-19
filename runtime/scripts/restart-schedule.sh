#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../.."
ROOT_DIR="$(pwd)"

STATE_FILE="runtime/generated/restart-schedule.env"
SERVICE_FILE="/etc/systemd/system/dune-awakening-scheduled-restart.service"
TIMER_FILE="/etc/systemd/system/dune-awakening-scheduled-restart.timer"

usage() {
  cat <<'EOF'
Usage:
  dune restart-schedule enable <hours>
  dune restart-schedule disable
  dune restart-schedule status
  dune restart-schedule run-now
EOF
}

write_state() {
  local enabled="$1"
  local hours="$2"

  mkdir -p runtime/generated
  cat > "$STATE_FILE" <<EOF
DUNE_SCHEDULED_RESTART_ENABLED=$enabled
DUNE_SCHEDULED_RESTART_HOURS=$hours
EOF
}

read_state() {
  DUNE_SCHEDULED_RESTART_ENABLED=0
  DUNE_SCHEDULED_RESTART_HOURS=""
  if [ -f "$STATE_FILE" ]; then
    # shellcheck disable=SC1090
    . "$STATE_FILE"
  fi
}

require_positive_hours() {
  local value="$1"
  if ! printf '%s' "$value" | grep -Eq '^[1-9][0-9]*$'; then
    echo "Hours must be a positive integer."
    exit 2
  fi
}

install_units() {
  local hours="$1"

  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Dune Awakening scheduled battlegroup restart
Wants=docker.service
After=network-online.target docker.service

[Service]
Type=oneshot
WorkingDirectory=$ROOT_DIR
ExecStart=$ROOT_DIR/runtime/scripts/restart-schedule.sh run-now
EOF

  cat > "$TIMER_FILE" <<EOF
[Unit]
Description=Run Dune Awakening scheduled battlegroup restart

[Timer]
OnBootSec=${hours}h
OnUnitActiveSec=${hours}h
Persistent=true
Unit=dune-awakening-scheduled-restart.service

[Install]
WantedBy=timers.target
EOF
}

enable_schedule() {
  local hours="$1"

  require_positive_hours "$hours"
  write_state 1 "$hours"

  if ! command -v systemctl >/dev/null 2>&1; then
    echo "Scheduled restart preference saved, but systemctl was not found."
    echo "Saved: $STATE_FILE"
    return 0
  fi

  install_units "$hours"
  systemctl daemon-reload
  systemctl enable --now dune-awakening-scheduled-restart.timer

  echo "Scheduled restart enabled."
  echo "Restart interval: every $hours hour(s)"
  echo "Timer: dune-awakening-scheduled-restart.timer"
}

disable_schedule() {
  read_state
  write_state 0 "${DUNE_SCHEDULED_RESTART_HOURS:-}"

  if command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now dune-awakening-scheduled-restart.timer >/dev/null 2>&1 || true
    rm -f "$SERVICE_FILE" "$TIMER_FILE"
    systemctl daemon-reload
  fi

  echo "Scheduled restart disabled."
}

show_status() {
  read_state

  echo "Scheduled restart enabled: ${DUNE_SCHEDULED_RESTART_ENABLED:-0}"
  echo "Restart interval hours:   ${DUNE_SCHEDULED_RESTART_HOURS:-unset}"

  if command -v systemctl >/dev/null 2>&1; then
    echo
    if systemctl list-unit-files dune-awakening-scheduled-restart.timer --no-legend --no-pager 2>/dev/null | grep -q '^dune-awakening-scheduled-restart.timer'; then
      timer_enabled="$(systemctl is-enabled dune-awakening-scheduled-restart.timer 2>/dev/null || true)"
      [ -n "$timer_enabled" ] && echo "Systemd timer:           $timer_enabled"
      systemctl list-timers --all dune-awakening-scheduled-restart.timer --no-pager || true
    else
      echo "Systemd timer:           not installed"
    fi
  fi
}

run_now() {
  echo "=== Scheduled battlegroup restart ==="
  echo "Stopping battlegroup..."
  runtime/scripts/stop-all.sh
  echo
  echo "Starting battlegroup..."
  runtime/scripts/start-all.sh
}

cmd="${1:-status}"

case "$cmd" in
  enable|on)
    enable_schedule "${2:-}"
    ;;
  disable|off)
    disable_schedule
    ;;
  status)
    show_status
    ;;
  run-now)
    run_now
    ;;
  *)
    usage
    exit 2
    ;;
esac
