# syntax=docker/dockerfile:1

# ---------------------------------------------------------------------------
# ecoflow-nut
#
# Network UPS Tools (NUT) server for EcoFlow USB HID UPS units (Delta 3 Plus,
# River 3 Plus). The image ships the driver (`usbhid-ups`) and `upsd` only: it
# never runs `upsmon` and never decides to shut anything down.
#
# Why NUT is compiled here instead of installed from Debian:
#   - Debian stable (trixie) ships NUT 2.8.1, older than the 2.8.4 floor
#     required for EcoFlow support.
#   - Debian testing (forky) no longer ships the `nut` source package at all.
#   - Debian unstable (sid) does ship 2.8.5, but unstable gets no security
#     support, so it is a poor base for a long-running appliance container.
# Building the pinned upstream release onto stable Debian gives an exact,
# checksum-verified NUT version on a base image that still receives security
# updates. The NUT version floor is re-checked at build time (see below).
# ---------------------------------------------------------------------------

ARG NUT_VERSION=2.8.5
# SHA-256 of nut-${NUT_VERSION}.tar.gz as published upstream:
# https://github.com/networkupstools/nut/releases/download/v${NUT_VERSION}/nut-${NUT_VERSION}.tar.gz.sha256
ARG NUT_SHA256=18bf32e59eb764b13da3c4fa70384926d7fa584cb31d2fe7f137a570633eeec1

# ---------------------------------------------------------------------------
# Stage 1: build NUT from the pinned upstream release
# ---------------------------------------------------------------------------
FROM debian:trixie-slim AS nut-build

ARG NUT_VERSION
ARG NUT_SHA256

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# hadolint ignore=DL3008
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      build-essential \
      ca-certificates \
      curl \
      libusb-1.0-0-dev \
      pkg-config \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /usr/src/nut

RUN curl -fsSL -o nut.tar.gz \
      "https://github.com/networkupstools/nut/releases/download/v${NUT_VERSION}/nut-${NUT_VERSION}.tar.gz" \
 && printf '%s  %s\n' "${NUT_SHA256}" nut.tar.gz | sha256sum -c - \
 && tar -xzf nut.tar.gz --strip-components=1 \
 && rm -f nut.tar.gz

# Only the two drivers this image supports are built: usbhid-ups (EcoFlow) and
# dummy-ups (hardware-free smoke tests). Everything optional is disabled so the
# binaries stay small and the runtime image needs no extra libraries.
RUN ./configure \
      --prefix=/usr \
      --sysconfdir=/etc/nut \
      --localstatedir=/var \
      --with-user=nut \
      --with-group=nut \
      --with-confdir=/etc/nut \
      --with-statepath=/run/nut \
      --with-altpidpath=/run/nut \
      --with-pidpath=/run/nut \
      --with-drvpath=/usr/lib/nut \
      --with-drivers=usbhid-ups,dummy-ups \
      --with-dev=no \
      --with-docs=no \
      --with-ssl=no \
      --with-serial=no \
      --with-usb=yes \
      --with-snmp=no \
      --with-neon=no \
      --with-powerman=no \
      --with-modbus=no \
      --with-gpio=no \
      --with-avahi=no \
      --with-ipmi=no \
      --with-linux_i2c=no \
      --with-macosx_ups=no \
      --with-nutconf=no \
      --with-nut_monitor=no \
      --with-pynut=no \
      --with-cgi=no \
      --with-wrap=no \
      --with-libltdl=no \
      --with-systemdsystemunitdir=no \
      --with-systemdsystempresetdir=no \
      --with-udev-dir=no \
      --with-devd-dir=no \
      --disable-static \
      --enable-strip \
 && make -j"$(nproc)" \
 && make install DESTDIR=/out

# Mandatory version gate: the EcoFlow support this image exists for needs NUT
# >= 2.8.4. Fail the build instead of shipping a silently broken driver.
RUN set -eu; \
    ver="$(/out/usr/sbin/upsd -V 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)"; \
    echo "Built NUT version: ${ver:-unknown}"; \
    if [ -z "${ver}" ]; then \
      echo "ERROR: could not determine the built NUT version from 'upsd -V'" >&2; \
      exit 1; \
    fi; \
    if ! printf '%s\n%s\n' "2.8.4" "${ver}" | sort -VC; then \
      echo "ERROR: NUT ${ver} is too old for EcoFlow support (need >= 2.8.4)" >&2; \
      exit 1; \
    fi; \
    if [ "${ver}" != "${NUT_VERSION}" ]; then \
      echo "ERROR: built NUT ${ver} but NUT_VERSION=${NUT_VERSION} was requested" >&2; \
      exit 1; \
    fi

# ---------------------------------------------------------------------------
# Stage 2: runtime
# ---------------------------------------------------------------------------
FROM debian:trixie-slim

ARG NUT_VERSION

LABEL org.opencontainers.image.title="ecoflow-nut" \
      org.opencontainers.image.description="Network UPS Tools server for EcoFlow USB HID UPS units (Delta 3 Plus, River 3 Plus)" \
      org.opencontainers.image.source="https://github.com/J0nan/ecoflow-nut" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="nut-${NUT_VERSION}"

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Runtime dependencies only: tini as PID 1, envsubst for templating, and the
# libraries the driver and the CLI tools link against. No TLS stack is
# installed because upsd speaks plain NUT over a trusted, LAN-only network
# (documented in the README).
# The `nut` user/group matches Debian's convention for NUT state and config
# files; the UPS driver itself runs as root inside this container so it can
# reach the USB device node.
# hadolint ignore=DL3008
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      gettext-base \
      libcap2 \
      libudev1 \
      libusb-1.0-0 \
      tini \
 && rm -rf /var/lib/apt/lists/* \
 && groupadd --system --gid 84 nut \
 && useradd --system --uid 84 --gid nut --no-create-home \
      --home-dir /nonexistent --shell /usr/sbin/nologin nut \
 && install -d -m 0750 -o root -g nut /etc/nut /run/nut

# Only the server, the two drivers and the client tools are installed.
# `upsmon` is deliberately not copied: this image must never make a shutdown
# decision, and the packages that could are left out of the filesystem.
COPY --from=nut-build /out/usr/sbin/upsd /out/usr/sbin/upsdrvctl /usr/sbin/
COPY --from=nut-build /out/usr/bin/upsc /out/usr/bin/upscmd /out/usr/bin/upslog /out/usr/bin/upsrw /usr/bin/
COPY --from=nut-build /out/usr/lib/libupsclient.so.7.1.0 /usr/lib/
COPY --from=nut-build /out/usr/lib/nut/ /usr/lib/nut/
# Command/variable descriptions served to NUT clients (upscmd, upsrw).
COPY --from=nut-build /out/usr/share/cmdvartab /usr/share/cmdvartab

COPY templates/ /templates/
COPY entrypoint.sh /entrypoint.sh
RUN ln -s libupsclient.so.7.1.0 /usr/lib/libupsclient.so.7 \
 && ldconfig \
 && chmod 0755 /entrypoint.sh

EXPOSE 3493/tcp
STOPSIGNAL SIGTERM

# Probes the UPS the entrypoint actually started (see entrypoint.sh), so a
# custom LISTEN_ADDR or a mounted upsd.conf still reports a correct status.
# hadolint ignore=DL3025
HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
  CMD if [ -r /run/nut/healthcheck.args ]; then read -r target < /run/nut/healthcheck.args; else target="${UPS_NAME:-ecoflow}@127.0.0.1:${LISTEN_PORT:-3493}"; fi; upsc "$target" ups.status || exit 1

ENTRYPOINT ["/usr/bin/tini", "--", "/entrypoint.sh"]
