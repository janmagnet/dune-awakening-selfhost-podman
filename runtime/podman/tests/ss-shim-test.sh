#!/usr/bin/env bash
# Unit tests for the Podman ss shim (runtime/podman/shim/ss). A fake ss and a
# fake podman stand in for the host tools, so no container engine is needed.
set -euo pipefail

cd "$(dirname "$0")/../../.."
ROOT_DIR="$(pwd -P)"
SHIM="$ROOT_DIR/runtime/podman/shim/ss"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FAKE_BIN="$WORK/bin"
mkdir -p "$FAKE_BIN"

# Real sockets: sshd on 22 and a game server's UDP port, as `ss -lntp`/`-lnup` print them.
cat >"$FAKE_BIN/ss" <<'EOF'
#!/usr/bin/env bash
[ -z "${FAKE_SS_EXIT:-}" ] || exit "$FAKE_SS_EXIT"
echo "State  Recv-Q Send-Q Local Address:Port Peer Address:Port Process"
case "$1" in
  -*u*) echo 'UNCONN 0      0      65.108.3.177:7777  0.0.0.0:*    users:(("DuneSandboxServ",pid=10,fd=58))' ;;
  *) echo 'LISTEN 0      128         0.0.0.0:22    0.0.0.0:*    users:(("sshd",pid=1,fd=3))' ;;
esac
EOF

# Published ports in Podman's {{.Ports}} form, including a UDP mapping, a range,
# an IPv6 duplicate and a port that a real socket already covers.
cat >"$FAKE_BIN/podman" <<'EOF'
#!/usr/bin/env bash
[ "${FAKE_PODMAN_DOWN:-0}" = 0 ] || exit 125
[ "$*" = "ps --format {{.Names}}|{{.Ports}}" ] || exit 0
echo 'dune-postgres|127.0.0.1:15432->5432/tcp'
echo 'dune-rmq-game|0.0.0.0:31982->5672/tcp, 127.0.0.1:31984->15672/tcp, 0.0.0.0:31983->15672/tcp, [::]:31982->5672/tcp'
echo 'dune-probe|0.0.0.0:7000-7001->7000-7001/tcp, 0.0.0.0:7777->7777/udp'
echo 'dune-sshlike|0.0.0.0:22->22/tcp'
echo 'dune-autoscaler|'
EOF
chmod 755 "$FAKE_BIN/ss" "$FAKE_BIN/podman"

export DUNE_PODMAN_ROOTLESS=1
export PATH="$FAKE_BIN:$PATH"

failures=0
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  failures=$((failures + 1))
}
# Upstream's checks: status.sh/ready.sh/doctor.sh grep ":$port ",
# ping-diagnostics.sh greps "[:.]$port[[:space:]]".
assert_listening() {
  grep -q ":$2 " <<<"$1" && grep -Eq "[:.]$2[[:space:]]" <<<"$1" || fail "$3: port $2 is not listed; got: $1"
}
count_port() { grep -Ec "[:.]$2[[:space:]]" <<<"$1" || true; }

output="$("$SHIM" -lntp)"
for port in 15432 31982 31983 31984 7000 7001; do
  assert_listening "$output" "$port" "published TCP ports are listed as listening"
done
grep -q 'container=dune-rmq-game' <<<"$output" || fail "added rows name the container; got: $output"
grep -q '127.0.0.1:15432 ' <<<"$output" || fail "added rows keep the published address; got: $output"
[ "$(count_port "$output" 31982)" = 1 ] || fail "a port published on IPv4 and IPv6 is listed once; got: $output"
[ "$(count_port "$output" 22)" = 1 ] || fail "a port with a real socket is not listed twice; got: $output"
[ "$(count_port "$output" 7777)" = 0 ] || fail "UDP mappings are not listed as TCP listeners; got: $output"
[ "$(head -n 2 <<<"$output")" = "$(ss -lntp)" ] || fail "the real ss rows come first, unchanged"

output="$("$SHIM" --tcp --listening --numeric)"
assert_listening "$output" 31982 "long options select TCP listeners too"

[ "$("$SHIM" -lnup)" = "$(ss -lnup)" ] || fail "UDP listings pass through unchanged"
[ "$("$SHIM" -tn)" = "$(ss -tn)" ] || fail "non-listening TCP listings pass through unchanged"
[ "$("$SHIM" -lnt sport = :22)" = "$(ss -lnt sport = :22)" ] || fail "filtered listings pass through unchanged"
[ "$(FAKE_PODMAN_DOWN=1 "$SHIM" -lntp)" = "$(ss -lntp)" ] || fail "without Podman only the real rows are printed"

status=0
FAKE_SS_EXIT=3 "$SHIM" -lntp >/dev/null 2>&1 || status=$?
[ "$status" = 3 ] || fail "the real ss exit status is kept; got $status"

if [ "$failures" -gt 0 ]; then
  echo "$failures ss shim test(s) failed." >&2
  exit 1
fi
echo "Podman ss shim tests passed."
