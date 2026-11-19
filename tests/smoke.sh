#!/bin/bash
#
# Hardware-free smoke tests for the ecoflow-nut image.
#
# The EcoFlow unit cannot be attached in CI, so everything except real USB I/O
# is exercised here: version gate, env-mode rendering and permissions,
# missing/blocked configuration errors, the full driver -> upsd -> client path
# with the dummy-ups driver, mount mode, the healthcheck and signal handling.
#
# Usage:  IMAGE=myuser/ecoflow-nut:dev ./tests/smoke.sh
#
# Requires bash, docker and GNU coreutils. On Windows run it from Git Bash.

set -Eeuo pipefail

# Git Bash rewrites /absolute/arguments passed to native binaries; the container
# paths below must reach docker verbatim.
export MSYS_NO_PATHCONV=1

IMAGE="${IMAGE:-ecoflow-nut:dev}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURES="${SCRIPT_DIR}/fixtures"
PASSWORD='smoke_test_password_123'
PREFIX="ecoflow-nut-smoke-$$"

CURRENT_CONTAINER=''
CREATED_CONTAINERS=()
CREATED_VOLUMES=()

host_path() {
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -m "$1"
  else
    printf '%s' "$1"
  fi
}

cleanup() {
  local name
  for name in "${CREATED_CONTAINERS[@]:-}"; do
    [ -n "$name" ] || continue
    docker rm -f "$name" >/dev/null 2>&1 || true
  done
  for name in "${CREATED_VOLUMES[@]:-}"; do
    [ -n "$name" ] || continue
    docker volume rm -f "$name" >/dev/null 2>&1 || true
  done
}
trap cleanup EXIT

fail() {
  printf '\nFAIL: %s\n' "$*" >&2
  if [ -n "$CURRENT_CONTAINER" ]; then
    printf '\n--- docker logs %s ---\n' "$CURRENT_CONTAINER" >&2
    docker logs "$CURRENT_CONTAINER" >&2 2>&1 || true
    printf -- '--- end of logs ---\n' >&2
  fi
  exit 1
}

assert_eq() { # <expected> <actual> <message>
  [ "$1" = "$2" ] || fail "$3 (expected '$1', got '$2')"
}

assert_contains() { # <haystack> <needle> <message>
  case "$1" in
    *"$2"*) ;;
    *) fail "$3 (missing '$2' in: $1)" ;;
  esac
}

assert_not_contains() { # <haystack> <needle> <message>
  case "$1" in
    *"$2"*) fail "$3 (unexpected '$2' in: $1)" ;;
  esac
}

# $1 >= $2 for dotted versions
version_ge() {
  printf '%s\n%s\n' "$2" "$1" | sort -VC
}

rsh() { # run inside the current container
  docker exec "$CURRENT_CONTAINER" "$@"
}

# Reads a path from a volume with a throwaway container.
volume_read() { # <volume> <command...>
  local volume="$1"
  shift
  docker run --rm -v "${volume}:/mnt" "$IMAGE" "$@"
}

start_container() { # <name> [docker run options...]
  local name="$1"
  shift
  CREATED_CONTAINERS+=("$name")
  CURRENT_CONTAINER="$name"
  docker run -d --name "$name" "$@" "$IMAGE" >/dev/null
}

create_volume() { # <name>
  docker volume create "$1" >/dev/null
  CREATED_VOLUMES+=("$1")
}

wait_for_health() {
  local name="$1" deadline=$((SECONDS + 90)) status=unknown
  while [ "$SECONDS" -lt "$deadline" ]; do
    status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$name" 2>/dev/null || echo missing)"
    case "$status" in
      healthy) return 0 ;;
      unhealthy) fail "container ${name} turned unhealthy" ;;
      missing) fail "container ${name} disappeared during startup" ;;
    esac
    sleep 2
  done
  fail "container ${name} did not become healthy within 90s (last status: ${status})"
}

wait_for_exit() { # <name> <timeout seconds>
  local name="$1" timeout="$2" deadline=$((SECONDS + $2)) status=unknown
  while [ "$SECONDS" -lt "$deadline" ]; do
    status="$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || echo missing)"
    case "$status" in
      exited) return 0 ;;
      missing) fail "container ${name} disappeared" ;;
    esac
    sleep 1
  done
  fail "container ${name} did not exit within ${timeout}s (last status: ${status})"
}

test_image_contents() {
  local out version
  printf '== image contents and version gate\n'

  out="$(docker run --rm "$IMAGE" upsd -V 2>&1)"
  assert_contains "$out" 'upsd' 'upsd -V should report the server version'
  version="$(printf '%s\n' "$out" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)"
  [ -n "$version" ] || fail "could not parse the NUT version from: ${out}"
  version_ge "$version" 2.8.4 || fail "NUT must be >= 2.8.4 for EcoFlow support (got ${version})"

  # A shutdown decision must be impossible from inside this container.
  docker run --rm "$IMAGE" test ! -e /usr/sbin/upsmon \
    || fail 'the image must not ship upsmon'
  docker run --rm "$IMAGE" test ! -e /usr/sbin/upssched \
    || fail 'the image must not ship upssched'

  printf '   NUT %s, no upsmon/upssched present\n' "$version"
}

test_missing_password() {
  local rc=0 out=''
  printf '== missing MON_PASSWORD\n'

  out="$(docker run --rm "$IMAGE" 2>&1)" || rc=$?
  assert_eq '1' "$rc" 'a missing MON_PASSWORD must exit with status 1'
  assert_contains "$out" 'MON_PASSWORD is required' 'the error must name MON_PASSWORD'
  printf '   exit 1 with an actionable message\n'
}

test_input_validation() {
  local rc=0 out=''
  printf '== configuration injection is rejected\n'

  out="$(docker run --rm -e MON_PASSWORD="$PASSWORD" -e 'UPS_NAME=bad name' "$IMAGE" 2>&1)" || rc=$?
  assert_eq '1' "$rc" 'an invalid UPS_NAME must exit with status 1'
  assert_contains "$out" 'UPS_NAME must be' 'the error must name the offending variable'
  printf '   invalid UPS_NAME rejected\n'
}

test_env_mode_rendering() {
  local name="${PREFIX}-render" volume="${PREFIX}-render-etc-nut" conf rc
  printf '== env mode: rendered configuration and permissions\n'

  create_volume "$volume"
  # The default usbhid-ups cannot start without the device, so this run proves
  # both rendering and fail-fast; the rendered files are read back afterwards.
  start_container "$name" -v "${volume}:/etc/nut" -e MON_PASSWORD="$PASSWORD"
  wait_for_exit "$name" 90

  rc="$(docker inspect -f '{{.State.ExitCode}}' "$name")"
  assert_eq '1' "$rc" 'a driver without a device must exit with status 1'
  assert_contains "$(docker logs "$name" 2>&1)" 'driver' 'the logs should name the driver failure'

  conf="$(volume_read "$volume" cat /mnt/ups.conf)"
  assert_contains "$conf" 'driver = usbhid-ups' 'ups.conf should render the default driver'
  assert_contains "$conf" 'port = auto' 'ups.conf should render PORT'
  assert_contains "$conf" 'vendorid = 3746' 'ups.conf should render VENDOR_ID'
  assert_contains "$conf" 'productid = ffff' 'ups.conf should render PRODUCT_ID'
  assert_contains "$conf" 'desc = "EcoFlow Delta 3 Plus"' 'ups.conf should render UPS_DESC'
  assert_contains "$conf" 'override.battery.charge.low = 30' 'ups.conf should render OVERRIDE_BATTERY_CHARGE_LOW'
  assert_contains "$conf" 'override.battery.runtime.low = 900' 'ups.conf should render OVERRIDE_BATTERY_RUNTIME_LOW'
  assert_contains "$conf" 'pollonly' 'POLLONLY=true should add pollonly'
  assert_contains "$conf" 'ignorelb' 'IGNORELB=true should add ignorelb'
  assert_contains "$conf" 'user = root' 'ups.conf should render DRIVER_USER'
  assert_contains "$(volume_read "$volume" cat /mnt/upsd.users)" 'upsmon master' \
    'upsd.users must grant upsmon master'
  assert_contains "$(volume_read "$volume" cat /mnt/upsd.conf)" 'LISTEN 0.0.0.0 3493' \
    'upsd.conf should render the listen address'
  assert_contains "$(volume_read "$volume" cat /mnt/nut.conf)" 'MODE=netserver' \
    'nut.conf must select netserver mode'

  assert_eq '640 root nut' "$(volume_read "$volume" stat -c '%a %U %G' /mnt/ups.conf)" \
    'ups.conf must be 640 root:nut'
  assert_eq '640 root nut' "$(volume_read "$volume" stat -c '%a %U %G' /mnt/upsd.users)" \
    'upsd.users must be 640 root:nut'
  assert_eq '750 root nut' "$(volume_read "$volume" stat -c '%a %U %G' /mnt)" \
    '/etc/nut must be 750 root:nut'

  CURRENT_CONTAINER=''
  printf '   configs rendered, 640 root:nut, driver failure exits 1\n'
}

test_env_mode_live() {
  local name="${PREFIX}-env"
  printf '== env mode: dummy-ups end to end (client, healthcheck, clean stop)\n'

  start_container "$name" \
    -e MON_PASSWORD="$PASSWORD" \
    -e DRIVER=dummy-ups \
    -e PORT=/fixtures/dummy.dev \
    -v "$(host_path "${FIXTURES}/dummy.dev"):/fixtures/dummy.dev:ro"

  wait_for_health "$CURRENT_CONTAINER"

  local conf
  conf="$(rsh cat /etc/nut/ups.conf)"
  assert_contains "$conf" 'driver = dummy-ups' 'DRIVER should be rendered'
  assert_contains "$conf" 'override.battery.charge.low = 30' 'the override should be rendered'
  assert_not_contains "$conf" 'vendorid' 'vendorid must be dropped for non-USB drivers'
  assert_not_contains "$conf" 'productid' 'productid must be dropped for non-USB drivers'
  assert_not_contains "$conf" 'pollonly' 'pollonly is a usbhid-ups flag and must be dropped for other drivers'
  assert_contains "$conf" 'ignorelb' 'IGNORELB=true should still be applied for any driver'

  assert_eq '100' "$(rsh upsc ecoflow@127.0.0.1:3493 battery.charge)" 'upsc must return the battery charge over TCP'
  assert_eq '30' "$(rsh upsc ecoflow@127.0.0.1:3493 battery.charge.low)" 'the low battery override must reach the client'
  assert_contains "$(rsh upsc ecoflow@127.0.0.1:3493 ups.status)" 'OL' 'ups.status must be OL'
  rsh bash -c '</dev/tcp/127.0.0.1/3493' || fail 'port 3493 must accept TCP connections'
  assert_contains "$(rsh cat /run/nut/healthcheck.args)" 'ecoflow@127.0.0.1:3493' \
    'the healthcheck target should be published'
  # shellcheck disable=SC2016  # the inner shell expands these on purpose
  assert_eq 'healthy' "$(rsh sh -c 'upsc "$(cat /run/nut/healthcheck.args)" ups.status >/dev/null && echo healthy')" \
    'the healthcheck command must succeed'

  # A restart must come back in env mode instead of mistaking its own rendered
  # files for a mounted configuration.
  docker restart "$CURRENT_CONTAINER" >/dev/null
  wait_for_health "$CURRENT_CONTAINER"
  assert_eq '100' "$(rsh upsc ecoflow@127.0.0.1:3493 battery.charge)" 'a restart must serve data again'
  assert_contains "$(docker logs "$CURRENT_CONTAINER" 2>&1)" 'configuration mode: env' \
    'a restart must keep rendering from the environment'

  docker stop -t 20 "$CURRENT_CONTAINER" >/dev/null
  assert_eq '0' "$(docker inspect -f '{{.State.ExitCode}}' "$CURRENT_CONTAINER")" \
    'SIGTERM must stop the container with exit status 0'
  CURRENT_CONTAINER=''
  printf '   upsc over TCP, healthcheck green, exit 0\n'
}

test_mount_mode() {
  local name="${PREFIX}-mount" volume="${PREFIX}-etc-nut"
  printf '== mount mode: provided /etc/nut, no MON_PASSWORD\n'

  create_volume "$volume"
  docker run --rm --entrypoint cp \
    -v "$(host_path "${FIXTURES}/nut-mount"):/seed:ro" \
    -v "${volume}:/config" \
    "$IMAGE" -R /seed/. /config/

  start_container "$name" \
    -v "${volume}:/etc/nut" \
    -v "$(host_path "${FIXTURES}/dummy.dev"):/fixtures/dummy.dev:ro"

  wait_for_health "$CURRENT_CONTAINER"

  assert_contains "$(rsh cat /etc/nut/ups.conf)" 'Mounted dummy UPS' \
    'mount mode must use the provided ups.conf verbatim'
  assert_eq '640 root nut' "$(rsh stat -c '%a %U %G' /etc/nut/ups.conf)" \
    'mounted configs must still be 640 root:nut'
  assert_eq '100' "$(rsh upsc dummy@127.0.0.1:3493 battery.charge)" \
    'the mounted UPS section must serve data over TCP'

  docker stop -t 20 "$CURRENT_CONTAINER" >/dev/null
  assert_eq '0' "$(docker inspect -f '{{.State.ExitCode}}' "$CURRENT_CONTAINER")" \
    'SIGTERM in mount mode must exit 0'
  CURRENT_CONTAINER=''
  printf '   mounted config honoured, no password required, exit 0\n'
}

test_hardened_deployment() {
  local name="${PREFIX}-hardened"
  printf '== hardened deployment: read-only rootfs, tmpfs, dropped capabilities\n'

  # Mirrors the deployment documented in the README: read-only root filesystem,
  # tmpfs for /run and /etc/nut, every capability dropped but the six the
  # container needs (KILL included, because upsd runs as the nut user).
  start_container "$name" \
    --read-only \
    --tmpfs /run \
    --tmpfs /etc/nut \
    --cap-drop ALL \
    --cap-add CHOWN \
    --cap-add DAC_OVERRIDE \
    --cap-add FOWNER \
    --cap-add SETGID \
    --cap-add SETUID \
    --cap-add KILL \
    --security-opt no-new-privileges:true \
    -e MON_PASSWORD="$PASSWORD" \
    -e DRIVER=dummy-ups \
    -e PORT=/fixtures/dummy.dev \
    -v "$(host_path "${FIXTURES}/dummy.dev"):/fixtures/dummy.dev:ro"

  wait_for_health "$CURRENT_CONTAINER"
  assert_eq '100' "$(rsh upsc ecoflow@127.0.0.1:3493 battery.charge)" \
    'the hardened container must serve data'
  assert_eq '640 root nut' "$(rsh stat -c '%a %U %G' /etc/nut/ups.conf)" \
    'configs rendered into the tmpfs must still be 640 root:nut'

  docker stop -t 20 "$CURRENT_CONTAINER" >/dev/null
  assert_eq '0' "$(docker inspect -f '{{.State.ExitCode}}' "$CURRENT_CONTAINER")" \
    'SIGTERM must stop the hardened container with exit status 0'
  CURRENT_CONTAINER=''
  printf '   read-only rootfs, dropped capabilities, exit 0\n'
}

test_fail_fast() {
  local name="${PREFIX}-failfast" rc
  printf '== fail-fast: dead driver stops the container\n'

  start_container "$name" -e MON_PASSWORD="$PASSWORD"
  wait_for_exit "$name" 90

  rc="$(docker inspect -f '{{.State.ExitCode}}' "$name")"
  [ "$rc" != '0' ] || fail 'the container must exit non-zero when the UPS driver dies'
  assert_contains "$(docker logs "$name" 2>&1)" 'driver' 'the logs should explain that the driver failed'

  CURRENT_CONTAINER=''
  printf '   exited with status %s\n' "$rc"
}

main() {
  command -v docker >/dev/null 2>&1 || {
    printf 'docker is not available\n' >&2
    exit 1
  }
  docker image inspect "$IMAGE" >/dev/null 2>&1 || {
    printf 'image %s not found; build it first: docker build -t %s .\n' "$IMAGE" "$IMAGE" >&2
    exit 1
  }

  printf 'Smoke tests for %s\n\n' "$IMAGE"
  test_image_contents
  test_missing_password
  test_input_validation
  test_env_mode_rendering
  test_env_mode_live
  test_mount_mode
  test_hardened_deployment
  test_fail_fast
  printf '\nAll smoke tests passed.\n'
}

main "$@"
