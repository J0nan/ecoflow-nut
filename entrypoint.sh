#!/bin/bash
#
# ecoflow-nut entrypoint.
#
# Two configuration modes, chosen at container start:
#
#   env mode    (default)  render /etc/nut/*.conf from the templates in
#                          /templates using the documented environment
#                          variables.
#   mount mode             a bind-mounted /etc/nut/ups.conf (single file or a
#                          whole directory) is used as-is. Nothing is rendered,
#                          but ownership and permissions are still fixed.
#
# In both modes the UPS driver runs in the background and upsd stays attached
# to this process, which supervises both: a dead driver can never hide behind a
# healthy upsd, because the container exits non-zero and the restart policy
# recovers it. No UPS monitor runs here - TrueNAS (or any other NUT slave)
# owns the shutdown decision.

set -Eeuo pipefail

readonly CONF_DIR=/etc/nut
readonly TPL_DIR=/templates
readonly STATE_DIR=/run/nut
readonly RENDER_STAMP="${CONF_DIR}/.entrypoint-rendered"
readonly HEALTHCHECK_TARGET="${STATE_DIR}/healthcheck.args"
readonly READY_TIMEOUT=30

# ---------------------------------------------------------------------------
# Environment (defaults match the documented table in README.md)
# ---------------------------------------------------------------------------
UPS_NAME="${UPS_NAME:-ecoflow}"
UPS_DESC="${UPS_DESC:-EcoFlow Delta 3 Plus}"
VENDOR_ID="${VENDOR_ID:-3746}"
PRODUCT_ID="${PRODUCT_ID:-ffff}"
DRIVER="${DRIVER:-usbhid-ups}"
PORT="${PORT:-auto}"
MON_USER="${MON_USER:-monuser}"
MON_PASSWORD="${MON_PASSWORD:-}"
LISTEN_ADDR="${LISTEN_ADDR:-0.0.0.0}"
LISTEN_PORT="${LISTEN_PORT:-3493}"
OVERRIDE_BATTERY_CHARGE_LOW="${OVERRIDE_BATTERY_CHARGE_LOW:-30}"
OVERRIDE_BATTERY_RUNTIME_LOW="${OVERRIDE_BATTERY_RUNTIME_LOW:-900}"
POLLONLY="${POLLONLY:-true}"
IGNORELB="${IGNORELB:-true}"
DRIVER_USER="${DRIVER_USER:-root}"
EXTRA_DRIVER_ARGS="${EXTRA_DRIVER_ARGS:-}"

# Docker places -e values in the environment of PID 1, so the monitor password
# would otherwise be inherited by the driver and upsd and be readable in
# /proc/<pid>/environ. It is only needed to render upsd.users.
export -n MON_PASSWORD 2>/dev/null || true

# ---------------------------------------------------------------------------
# Runtime state
# ---------------------------------------------------------------------------
MODE='env'
EFFECTIVE_UPS=''
EFFECTIVE_DRIVER=''
EFFECTIVE_ADDR=''
EFFECTIVE_PORT=''
DRIVER_BIN=''
DRIVER_PID=''
UPSD_PID=''
PROBE_TARGET=''

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log() { printf '%s [entrypoint] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }
warn() { log "WARN: $*"; }
die() { printf '%s [entrypoint] ERROR: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Validation
#
# Every value that ends up inside a NUT configuration file is validated first:
# a newline (or a quote, for the quoted description) would otherwise let an
# environment variable inject arbitrary configuration directives.
# ---------------------------------------------------------------------------
validate_env() {
  local pattern

  [[ $UPS_NAME =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$ ]] \
    || die "UPS_NAME must be 1-32 characters of A-Z a-z 0-9 . _ - and start alphanumeric (got '${UPS_NAME}')"
  [[ $MON_USER =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$ ]] \
    || die "MON_USER must be 1-32 characters of A-Z a-z 0-9 . _ - and start alphanumeric (got '${MON_USER}')"
  [[ $DRIVER =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
    || die "DRIVER must be a driver name such as usbhid-ups (got '${DRIVER}')"
  [[ $DRIVER_USER =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] \
    || die "DRIVER_USER must be a user name (got '${DRIVER_USER}')"

  case "$UPS_DESC" in
    *'"'*|*\\*|*$'\n'*|*$'\r'*)
      die "UPS_DESC must not contain double quotes, backslashes or newlines" ;;
  esac
  [ "${#UPS_DESC}" -le 128 ] || die "UPS_DESC must be at most 128 characters"

  case "$LISTEN_ADDR" in
    *[!A-Za-z0-9.:_%*-]*)
      die "LISTEN_ADDR must be an IP address (got '${LISTEN_ADDR}')" ;;
  esac

  [[ $LISTEN_PORT =~ ^[0-9]{1,5}$ ]] || die "LISTEN_PORT must be a TCP port number (got '${LISTEN_PORT}')"
  [ "$LISTEN_PORT" -ge 1 ] && [ "$LISTEN_PORT" -le 65535 ] \
    || die "LISTEN_PORT must be between 1 and 65535 (got '${LISTEN_PORT}')"

  case "$PORT" in
    *[!A-Za-z0-9._/:@+%-]*)
      die "PORT must be 'auto', a device node or a file name (got '${PORT}')" ;;
  esac

  # Accept the USB ids with or without a 0x prefix.
  VENDOR_ID="${VENDOR_ID#0x}"
  VENDOR_ID="${VENDOR_ID#0X}"
  PRODUCT_ID="${PRODUCT_ID#0x}"
  PRODUCT_ID="${PRODUCT_ID#0X}"
  [[ $VENDOR_ID =~ ^[0-9A-Fa-f]{1,4}$ ]] || die "VENDOR_ID must be a USB vendor id in hex (got '${VENDOR_ID}')"
  [[ $PRODUCT_ID =~ ^[0-9A-Fa-f]{1,4}$ ]] || die "PRODUCT_ID must be a USB product id in hex (got '${PRODUCT_ID}')"

  pattern='^[0-9]{1,3}$'
  [[ $OVERRIDE_BATTERY_CHARGE_LOW =~ $pattern ]] \
    || die "OVERRIDE_BATTERY_CHARGE_LOW must be an integer percentage (got '${OVERRIDE_BATTERY_CHARGE_LOW}')"
  [ "$OVERRIDE_BATTERY_CHARGE_LOW" -le 100 ] \
    || die "OVERRIDE_BATTERY_CHARGE_LOW must be between 0 and 100 (got '${OVERRIDE_BATTERY_CHARGE_LOW}')"

  [[ $OVERRIDE_BATTERY_RUNTIME_LOW =~ ^[0-9]{1,7}$ ]] \
    || die "OVERRIDE_BATTERY_RUNTIME_LOW must be a number of seconds (got '${OVERRIDE_BATTERY_RUNTIME_LOW}')"
}

# Values that only matter when this container renders its own configuration.
validate_env_config() {
  normalize_bools

  [ -n "$MON_PASSWORD" ] \
    || die "MON_PASSWORD is required in env mode. Set it to a long random value and use the same value as the monitor password on the NUT slave (for example in TrueNAS). Alternatively bind-mount your own /etc/nut to skip templating."

  case "$MON_PASSWORD" in
    *[!A-Za-z0-9._~+=:,/@%^*!?-]*)
      die "MON_PASSWORD contains characters that NUT configuration parsing cannot represent safely; use A-Z a-z 0-9 and . _ ~ + = : , / @ % ^ * ! ? -" ;;
  esac
  [ "${#MON_PASSWORD}" -le 128 ] || die "MON_PASSWORD must be at most 128 characters"
  if [ "${#MON_PASSWORD}" -lt 12 ]; then
    warn "MON_PASSWORD is shorter than 12 characters; use a long random value"
  fi

  if [ "$DRIVER_USER" != root ]; then
    id -u "$DRIVER_USER" >/dev/null 2>&1 \
      || die "DRIVER_USER '${DRIVER_USER}' does not exist in this image"
    if ! id -nG "$DRIVER_USER" | tr ' ' '\n' | grep -qx nut; then
      warn "DRIVER_USER '${DRIVER_USER}' is not in group 'nut'; ${STATE_DIR} may not be writable by the driver"
    fi
  fi
}

# Sets POLLONLY / IGNORELB to true or false in this shell.
normalize_bools() {
  local name value normalized
  for name in POLLONLY IGNORELB; do
    value="${!name}"
    case "${value,,}" in
      true|yes|on|1) normalized=true ;;
      false|no|off|0) normalized=false ;;
      *) die "${name} must be true or false (got '${value}')" ;;
    esac
    printf -v "$name" '%s' "$normalized"
  done
}

# ---------------------------------------------------------------------------
# Configuration mode
# ---------------------------------------------------------------------------
is_mount_point() {
  [ -r /proc/mounts ] || return 1
  awk -v target="$1" '$2 == target { found = 1 } END { exit !found }' /proc/mounts
}

detect_mode() {
  # A file that this entrypoint rendered is recognised by its stamp, so a
  # `docker restart` (or a named volume for /etc/nut) keeps rendering from the
  # environment. A bind-mounted ups.conf always wins over a stale stamp.
  if [ -f "${CONF_DIR}/ups.conf" ]; then
    if is_mount_point "${CONF_DIR}/ups.conf" || [ ! -f "$RENDER_STAMP" ]; then
      MODE=mount
    fi
  fi

  if [ "$MODE" = mount ]; then
    log "configuration mode: mount (using ${CONF_DIR} as provided)"
  else
    log "configuration mode: env (rendering ${CONF_DIR} from the environment)"
  fi
}

# ---------------------------------------------------------------------------
# Rendering and permissions
# ---------------------------------------------------------------------------
render_configs() {
  local vars
  # Only substitute the documented variables, so a literal $ in another value
  # can never be re-expanded.
  # shellcheck disable=SC2016
  vars='$UPS_NAME $UPS_DESC $VENDOR_ID $PRODUCT_ID $DRIVER $PORT $MON_USER $MON_PASSWORD $LISTEN_ADDR $LISTEN_PORT $OVERRIDE_BATTERY_CHARGE_LOW $OVERRIDE_BATTERY_RUNTIME_LOW $DRIVER_USER'

  # envsubst reads the process environment. Only the non-secret values are
  # exported here; MON_PASSWORD is passed per invocation so the driver and upsd
  # never inherit it (it would otherwise be readable in /proc/<pid>/environ).
  export UPS_NAME UPS_DESC VENDOR_ID PRODUCT_ID DRIVER PORT MON_USER \
    LISTEN_ADDR LISTEN_PORT OVERRIDE_BATTERY_CHARGE_LOW \
    OVERRIDE_BATTERY_RUNTIME_LOW DRIVER_USER

  (
    # The password must never exist in a world-readable file, not even for the
    # moment between creation and chmod.
    umask 0077
    envsubst "$vars" <"${TPL_DIR}/nut.conf.tmpl" >"${CONF_DIR}/nut.conf"
    envsubst "$vars" <"${TPL_DIR}/ups.conf.tmpl" >"${CONF_DIR}/ups.conf"
    envsubst "$vars" <"${TPL_DIR}/upsd.conf.tmpl" >"${CONF_DIR}/upsd.conf"
    MON_PASSWORD="$MON_PASSWORD" envsubst "$vars" \
      <"${TPL_DIR}/upsd.users.tmpl" >"${CONF_DIR}/upsd.users"
    # vendorid/productid are usbhid-ups options; every other driver rejects
    # them, so they are dropped when DRIVER is not usbhid-ups (for example the
    # hardware-free dummy-ups setup documented in the README).
    if [ "$DRIVER" != usbhid-ups ]; then
      sed -i -E '/^[[:space:]]*(vendorid|productid)[[:space:]]*=/d' "${CONF_DIR}/ups.conf"
    fi
    # A template whose last line has no trailing newline must not glue the
    # driver flags below onto that line.
    if [ "$(tail -c 1 "${CONF_DIR}/ups.conf" | wc -l)" -eq 0 ]; then
      printf '\n' >>"${CONF_DIR}/ups.conf"
    fi
    # Driver flags live inside the [ups] section, which the template leaves
    # open at the end of the file. `pollonly` is registered by usbhid-ups only,
    # so other drivers reject it; `ignorelb` is common to every driver.
    if [ "$POLLONLY" = true ] && [ "$DRIVER" = usbhid-ups ]; then
      printf '    pollonly\n' >>"${CONF_DIR}/ups.conf"
    fi
    if [ "$IGNORELB" = true ]; then
      printf '    ignorelb\n' >>"${CONF_DIR}/ups.conf"
    fi
    if [ -n "$EXTRA_DRIVER_ARGS" ]; then
      printf '%s\n' "$EXTRA_DRIVER_ARGS" >>"${CONF_DIR}/ups.conf"
    fi
    : >"$RENDER_STAMP"
  )
}

fix_permissions() {
  local file state_mode=0750

  install -d -m 0750 -o root -g nut "$CONF_DIR" \
    || warn "could not enforce ownership/mode on ${CONF_DIR} (read-only mount?)"

  for file in nut.conf ups.conf upsd.conf upsd.users; do
    if [ ! -e "${CONF_DIR}/${file}" ]; then
      warn "${CONF_DIR}/${file} is missing"
      continue
    fi
    # upsd reads upsd.users as the nut group; root-only files cause silent
    # authentication failures.
    chown root:nut "${CONF_DIR}/${file}" 2>/dev/null \
      || warn "could not chown ${CONF_DIR}/${file}"
    chmod 0640 "${CONF_DIR}/${file}" 2>/dev/null \
      || warn "could not chmod ${CONF_DIR}/${file}"
  done

  if [ "$DRIVER_USER" != root ]; then
    state_mode=0770
  fi
  install -d -m "$state_mode" -o root -g nut "$STATE_DIR" \
    || die "cannot prepare the NUT state directory ${STATE_DIR}"
}

# ---------------------------------------------------------------------------
# Which UPS / driver / listen address is actually in effect
# ---------------------------------------------------------------------------
has_section() {
  awk -v want="$1" '
    /^[[:space:]]*\[/ {
      name = $0
      sub(/^[[:space:]]*\[/, "", name)
      sub(/\].*$/, "", name)
      gsub(/[[:space:]]/, "", name)
      if (name == want) { found = 1; exit }
    }
    END { exit !found }' "${CONF_DIR}/ups.conf"
}

first_section() {
  awk '
    /^[[:space:]]*\[/ {
      name = $0
      sub(/^[[:space:]]*\[/, "", name)
      sub(/\].*$/, "", name)
      gsub(/[[:space:]]/, "", name)
      print name
      exit
    }' "${CONF_DIR}/ups.conf"
}

driver_of_section() {
  awk -v want="$1" '
    /^[[:space:]]*\[/ {
      name = $0
      sub(/^[[:space:]]*\[/, "", name)
      sub(/\].*$/, "", name)
      gsub(/[[:space:]]/, "", name)
      current = name
      next
    }
    current == want && /^[[:space:]]*driver[[:space:]]*=/ {
      value = $0
      sub(/^[^=]*=[[:space:]]*/, "", value)
      sub(/[[:space:]]*#.*$/, "", value)
      gsub(/[[:space:]]/, "", value)
      print value
      exit
    }' "${CONF_DIR}/ups.conf"
}

listen_of_conf() {
  awk '
    /^[[:space:]]*LISTEN[[:space:]]/ {
      port = ($3 == "" || $3 ~ /^#/ ? "3493" : $3)
      print $2, port
      exit
    }' "${CONF_DIR}/upsd.conf"
}

# Address upsc should use to reach the port upsd actually listens on.
probe_addr() {
  case "$1" in
    0.0.0.0|'*') printf '127.0.0.1' ;;
    ::|'[::]') printf '::1' ;;
    *) printf '%s' "$1" ;;
  esac
}

format_probe_target() {
  case "$EFFECTIVE_ADDR" in
    *:*) printf '%s@[%s]:%s' "$EFFECTIVE_UPS" "$EFFECTIVE_ADDR" "$EFFECTIVE_PORT" ;;
    *) printf '%s@%s:%s' "$EFFECTIVE_UPS" "$EFFECTIVE_ADDR" "$EFFECTIVE_PORT" ;;
  esac
}

resolve_targets() {
  local addr port

  if has_section "$UPS_NAME"; then
    EFFECTIVE_UPS="$UPS_NAME"
  else
    EFFECTIVE_UPS="$(first_section)"
    [ -n "$EFFECTIVE_UPS" ] || die "no UPS section found in ${CONF_DIR}/ups.conf"
    warn "UPS_NAME '${UPS_NAME}' is not a section of ${CONF_DIR}/ups.conf; using '${EFFECTIVE_UPS}'"
  fi

  if [ "$MODE" = env ]; then
    EFFECTIVE_DRIVER="$DRIVER"
    EFFECTIVE_ADDR="$(probe_addr "$LISTEN_ADDR")"
    EFFECTIVE_PORT="$LISTEN_PORT"
  else
    EFFECTIVE_DRIVER="$(driver_of_section "$EFFECTIVE_UPS")"
    [ -n "$EFFECTIVE_DRIVER" ] || die "no driver= line for [${EFFECTIVE_UPS}] in ${CONF_DIR}/ups.conf"
    addr=''
    port=''
    read -r addr port < <(listen_of_conf) || true
    EFFECTIVE_ADDR="$(probe_addr "${addr:-0.0.0.0}")"
    EFFECTIVE_PORT="${port:-3493}"
  fi

  PROBE_TARGET="$(format_probe_target)"
  # The healthcheck cannot know about mount mode or a custom LISTEN_ADDR, so
  # the resolved target is published for it.
  printf '%s\n' "$PROBE_TARGET" >"$HEALTHCHECK_TARGET" \
    || warn "could not write ${HEALTHCHECK_TARGET}; the healthcheck will use its defaults"
}

resolve_driver_bin() {
  local dir
  for dir in /usr/lib/nut /usr/libexec/nut /lib/nut; do
    if [ -x "${dir}/${EFFECTIVE_DRIVER}" ]; then
      DRIVER_BIN="${dir}/${EFFECTIVE_DRIVER}"
      return 0
    fi
  done
  die "driver '${EFFECTIVE_DRIVER}' not found (this image ships usbhid-ups and dummy-ups only)"
}

# ---------------------------------------------------------------------------
# Processes
# ---------------------------------------------------------------------------
start_driver() {
  log "starting driver ${DRIVER_BIN} for UPS '${EFFECTIVE_UPS}' as user '${DRIVER_USER}'"
  # -F keeps the driver in the foreground so this process can supervise it.
  "${DRIVER_BIN}" -F -a "$EFFECTIVE_UPS" -u "$DRIVER_USER" \
    > >(sed -u 's/^/[driver] /') 2>&1 &
  DRIVER_PID=$!
}

start_upsd() {
  log "starting upsd"
  upsd -F > >(sed -u 's/^/[upsd] /') 2>&1 &
  UPSD_PID=$!
}

wait_for_ready() {
  local deadline=$((SECONDS + READY_TIMEOUT)) status

  while [ "$SECONDS" -lt "$deadline" ]; do
    if ! kill -0 "$DRIVER_PID" 2>/dev/null; then
      warn "the UPS driver exited during startup"
      return 1
    fi
    if ! kill -0 "$UPSD_PID" 2>/dev/null; then
      warn "upsd exited during startup"
      return 1
    fi
    if status="$(upsc "$PROBE_TARGET" ups.status 2>/dev/null)" && [ -n "$status" ]; then
      log "UPS '${EFFECTIVE_UPS}' is available at ${PROBE_TARGET} (ups.status: ${status})"
      return 0
    fi
    sleep 1
  done

  warn "upsd did not answer on ${PROBE_TARGET} within ${READY_TIMEOUT}s"
  return 1
}

shutdown() {
  trap - TERM INT
  local pid alive i

  log "stopping services"
  for pid in "${UPSD_PID}" "${DRIVER_PID}"; do
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      kill -TERM "$pid" 2>/dev/null || true
    fi
  done

  for ((i = 0; i < 20; i++)); do
    alive=0
    for pid in "${UPSD_PID}" "${DRIVER_PID}"; do
      if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        alive=1
      fi
    done
    if [ "$alive" -eq 0 ]; then
      break
    fi
    sleep 0.5
  done

  for pid in "${UPSD_PID}" "${DRIVER_PID}"; do
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      warn "process ${pid} ignored SIGTERM; sending SIGKILL"
      kill -KILL "$pid" 2>/dev/null || true
    fi
  done

  wait 2>/dev/null || true
  log "stopped"
}

supervise() {
  local who='' rc=0

  while :; do
    set +e
    wait -n -p who "$DRIVER_PID" "$UPSD_PID"
    rc=$?
    set -e

    # A trapped signal interrupted the wait; the trap owns the exit.
    if [ "$rc" -gt 128 ]; then
      continue
    fi

    case "$who" in
      "$DRIVER_PID")
        warn "the UPS driver exited (status ${rc}); stopping the container so the restart policy recovers it" ;;
      "$UPSD_PID")
        warn "upsd exited (status ${rc}); stopping the container" ;;
      *)
        warn "a supervised process exited (status ${rc}); stopping the container" ;;
    esac

    shutdown
    exit 1
  done
}

# ---------------------------------------------------------------------------
main() {
  # Any command after the image name replaces service startup. This keeps
  # `docker run --rm <image> upsc -l` style debugging possible.
  if [ "$#" -gt 0 ]; then
    exec "$@"
  fi

  validate_env
  detect_mode

  if [ "$MODE" = env ]; then
    validate_env_config
    render_configs
  elif [ -n "$MON_PASSWORD" ]; then
    warn "MON_PASSWORD is set but ignored in mount mode"
  fi

  fix_permissions
  resolve_targets
  resolve_driver_bin

  start_driver
  start_upsd

  if ! wait_for_ready; then
    shutdown
    exit 1
  fi

  trap 'shutdown; exit 0' TERM INT
  log "ready: serving UPS '${EFFECTIVE_UPS}' for NUT clients (no TLS: keep port ${EFFECTIVE_PORT} on a trusted network)"
  supervise
}

main "$@"
