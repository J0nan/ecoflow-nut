# ecoflow-nut

A small Docker image that turns an **EcoFlow Delta 3 Plus** (or River 3 Plus) into a
network UPS that TrueNAS CE, or any other NUT client, can monitor and act on.

It runs **Network UPS Tools 2.8.5** - the USB HID driver (`usbhid-ups`) plus the network
server (`upsd`) - and nothing else. The image never decides to shut anything down: it
publishes UPS state on TCP `3493`, and TrueNAS remains the shutdown decision-maker.

## Why this image exists

TrueNAS CE bundles a NUT release older than 2.8.3, which cannot drive EcoFlow USB HID
devices. This container carries a new-enough NUT for the job.

| | |
| --- | --- |
| Supported UPS units | EcoFlow **Delta 3 Plus**, EcoFlow **River 3 Plus** (same USB ID `3746:ffff`) |
| NUT version | **2.8.5**, built from the pinned upstream release; `>= 2.8.4` enforced at build time |
| Services | `usbhid-ups` (driver) and `upsd` (network server). No `upsmon`, no `upssched` |
| Image | `<dockerhub-user>/ecoflow-nut` - replace with the account that publishes your build |
| Platforms | `linux/amd64`, `linux/arm64` |
| Network | plain NUT protocol on port `3493`, **LAN only** (no TLS by design) |

## Quick start

```bash
docker run -d --name ecoflow-nut \
  --restart unless-stopped \
  -e MON_PASSWORD="$(openssl rand -base64 24)" \
  -p 3493:3493 \
  -v /dev/bus/usb:/dev/bus/usb \
  --device-cgroup-rule 'c 189:* rmw' \
  <dockerhub-user>/ecoflow-nut:latest
```

Keep the generated password: it is the monitor password you enter on TrueNAS.

Check that the driver found the UPS and that the server answers:

```bash
docker exec ecoflow-nut upsc ecoflow@127.0.0.1 battery.charge
docker exec ecoflow-nut upsc ecoflow@127.0.0.1 ups.status
```

A working unit reports `ups.status: OL` on mains power and a `battery.charge` between 0
and 100. `docker logs ecoflow-nut` shows both services' output.

Prefer Compose? Copy [`docker-compose.example.yml`](docker-compose.example.yml) to
`docker-compose.yml`, put `MON_PASSWORD` in a `.env` file next to it, and run
`docker compose up -d`.

## Configuration

Environment variables are rendered into the four NUT configuration files at container
start (env mode, the default). Every value is validated before it reaches a config file.

| Variable | Default | Purpose |
| --- | --- | --- |
| `UPS_NAME` | `ecoflow` | NUT UPS identifier - must match what the slave monitors |
| `UPS_DESC` | `EcoFlow Delta 3 Plus` | description shown to clients |
| `VENDOR_ID` | `3746` | USB vendor id |
| `PRODUCT_ID` | `ffff` | USB product id |
| `DRIVER` | `usbhid-ups` | NUT driver (this image ships `usbhid-ups` and `dummy-ups`) |
| `PORT` | `auto` | driver port (`auto` finds the only matching HID device) |
| `MON_USER` | `monuser` | `upsd` monitor username |
| `MON_PASSWORD` | *required in env mode* | `upsd` monitor password - long and random, no spaces, quotes or `#` |
| `LISTEN_ADDR` | `0.0.0.0` | `upsd` bind address |
| `LISTEN_PORT` | `3493` | `upsd` port |
| `OVERRIDE_BATTERY_CHARGE_LOW` | `30` | `override.battery.charge.low` percentage (EcoFlow firmware reports 0% = never) |
| `OVERRIDE_BATTERY_RUNTIME_LOW` | `900` | `override.battery.runtime.low` in seconds |
| `POLLONLY` | `true` | adds the `pollonly` driver flag (EcoFlow firmware sends no interrupt events); applied only to `usbhid-ups` |
| `IGNORELB` | `true` | adds the `ignorelb` driver flag so the overrides above take effect |
| `DRIVER_USER` | `root` | driver user; root avoids USB node permission problems inside the container |
| `EXTRA_DRIVER_ARGS` | *empty* | appended verbatim inside the `[ups]` section - trusted input, it can add any directive |

Two NUT files deserve a note:

- `upsd.users` contains `upsmon master`. That privilege also permits slave logins, which
  is exactly what TrueNAS uses. Nothing in this container logs in.
- `vendorid`, `productid` and `pollonly` are `usbhid-ups` options. When `DRIVER` is set to
  another driver they are omitted, because other drivers reject them.

### Mount mode: bring your own configuration

If `/etc/nut/ups.conf` already exists when the container starts - bind-mounted as a single
file or as a directory - the container uses that configuration as-is and does not render
the templates. `MON_PASSWORD` is not required in that mode, and no `envsubst` variable
applies.

```yaml
    volumes:
      - ./nut:/etc/nut:ro     # your nut.conf, ups.conf, upsd.conf, upsd.users
```

Ownership and permissions are still fixed (`0640 root:nut` for the files, `0750 root:nut`
for the directory) unless the mount is read-only, in which case the container logs a
warning and continues. The container starts the driver for the first section in
`ups.conf` (or for `UPS_NAME` when that section exists) and serves its listen address
from `upsd.conf`.

## USB passthrough

The Delta 3 Plus exposes its HID interface on **one port only: the leftmost USB-C port**
(the data/HID port). The other ports and the AC/DC outputs do not enumerate.

1. Use a **USB data cable**. A C-to-A data cable is often more reliable than C-to-C.
2. Connect the leftmost USB-C port to the Docker host.
3. Confirm the device is visible on the host:

   ```bash
   lsusb | grep -i 3746     # expect: ID 3746:ffff EcoFlow ...
   ```

4. Map the whole USB bus in the container (as in the examples above):

   ```yaml
   volumes:
     - /dev/bus/usb:/dev/bus/usb
   device_cgroup_rules:
     - 'c 189:* rmw'
   ```

   For tighter security, map only the node the device enumerates on
   (`/dev/bus/usb/BBB/DDD`). It changes whenever the device re-enumerates.

5. If hotplug or re-enumeration keeps breaking access, fall back to `privileged: true`.
   That is the escape hatch, not the default.

## TrueNAS CE as a NUT slave

TrueNAS does not talk to the UPS directly - it monitors this container over the LAN and
performs the graceful shutdown.

1. **System > Services > UPS**:
   - UPS Mode: **Slave**
   - Identifier: `ecoflow` (must match `UPS_NAME`)
   - Remote host: the LAN IP of the Docker host
   - Remote port: `3493`
   - Monitor user / Monitor password: `monuser` / your `MON_PASSWORD`
   - Shutdown mode: **UPS reaches low battery**
   - Power off UPS: **unchecked**
   - Enable the service and start it on boot
2. Or do the same from the CLI:

   ```bash
   midclt call ups.update '{"mode":"SLAVE","identifier":"ecoflow","remotehost":"<HOST_IP>","remoteport":3493,"monuser":"monuser","monpwd":"<PASSWORD>","shutdown":"LOWBATT"}'
   midclt call service.update ups '{"enable": true}'
   midclt call service.start ups
   ```

3. Verify from any machine with NUT client tools:

   ```bash
   upsc ecoflow@<HOST_IP>:3493
   ```

   Expect `battery.charge`, `ups.status: OL` and `battery.charge.low: 30`.

## Security notes

The NUT protocol is unencrypted, and reads are unauthenticated. That is fine for a
trusted LAN and unacceptable anywhere else.

- **Never port-forward 3493.** Do not publish the container with a public IP or through
  a reverse proxy, and keep it off guest/VLAN networks you do not control.
- Use a long random `MON_PASSWORD`; the `upsmon master` privilege in `upsd.users` can
  put the monitored system into forced shutdown, and the password is sent in clear text.
- The image contains no configuration and no secrets. The password is written with a
  `0077` umask, stored `0640 root:nut`, and removed from the environment of the services
  so it cannot be read from `/proc/<pid>/environ`.
- The driver runs as root inside the container because it must open the USB device node.
  The published image installs neither `upsmon` nor `upssched`, so no shutdown can be
  triggered from inside it.
- Optional hardening, verified with the hardware-free test setup: `cap_drop: [ALL]` with
  only `CHOWN, DAC_OVERRIDE, FOWNER, SETGID, SETUID` added back,
  `security_opt: [no-new-privileges:true]`, and `read_only: true` together with
  `tmpfs: [/run]` plus a writable `/etc/nut` volume (or mount mode).
- Supply chain: NUT is downloaded from its signed upstream release and verified against
  the published SHA-256; GitHub Actions are pinned to commit SHAs; Dependabot tracks
  actions and base images; published images carry a build provenance attestation
  (`docker buildx imagetools inspect <image>`).

Report a vulnerability privately - see [SECURITY.md](SECURITY.md).

## Testing the shutdown path

1. Pull the AC input from the UPS. `upsc ecoflow@127.0.0.1 ups.status` (or the TrueNAS
   UPS widget) must switch to `OB`.
2. Force the low-battery condition instead of draining the battery: restart the container
   with `OVERRIDE_BATTERY_CHARGE_LOW=100`, so `ups.status` reports `OB LB` immediately.
3. Confirm TrueNAS starts its shutdown and completes it.
4. Restore `OVERRIDE_BATTERY_CHARGE_LOW=30` and restart the container.

## Try it without hardware

`dummy-ups` simulates a UPS, so the whole path (driver, `upsd`, clients, TrueNAS UI) can
be exercised without an EcoFlow unit:

```bash
docker run -d --name nut-dummy -p 3493:3493 \
  -e MON_PASSWORD=test123 \
  -e DRIVER=dummy-ups \
  -e PORT=/fixtures/dummy.dev \
  -v "$PWD/tests/fixtures/dummy.dev:/fixtures/dummy.dev:ro" \
  <dockerhub-user>/ecoflow-nut:latest
```

The same setup drives the CI smoke tests.

## Known quirks

- **Low battery is reported as 0%.** EcoFlow firmware treats "never" as the low-battery
  threshold, so NUT's defaults make `LB` unreachable. This image overrides
  `battery.charge.low` (30%) and `battery.runtime.low` (900 s) and ignores the firmware's
  own threshold.
- **Runtime estimates are unreliable.** Prefer the charge threshold for the shutdown
  decision.
- **Some firmware needs `pollonly`.** EcoFlow units do not send HID interrupt events, so
  interrupt-driven polling stalls. `POLLONLY=true` (the default) polls instead.
- **The first `ups.status` can be `WAIT`.** The dummy and HID drivers publish a settled
  status within a few seconds; the healthcheck waits for the server, not for `OL`.
- **The USB HID link can drop.** Some units need a power cycle of the UPS (unplug power
  and USB, reconnect) before the device re-enumerates.
- **Keep the EcoFlow firmware updated** through the phone app; several HID reporting bugs
  were fixed there, not in NUT.
- **The container exits when the driver dies.** That is deliberate: with
  `restart: unless-stopped` the whole set recovers instead of serving stale data. The log
  line explains what happened.

## Development

```bash
# Build
docker build -t ecoflow-nut:dev .

# Lint (same versions CI uses)
docker run --rm -v "$PWD:/mnt" koalaman/shellcheck:stable -x /mnt/entrypoint.sh /mnt/tests/smoke.sh
docker run --rm -v "$PWD:/mnt" -w /mnt hadolint/hadolint hadolint Dockerfile

# Hardware-free smoke tests (bash; on Windows run them from Git Bash)
IMAGE=ecoflow-nut:dev ./tests/smoke.sh

# Run a single client command against the image
docker run --rm ecoflow-nut:dev upsc -V
```

How the image is built:

- NUT is compiled from the release pinned in the `Dockerfile` (`NUT_VERSION`,
  `NUT_SHA256`) on `debian:trixie-slim`, because no current Debian suite ships a NUT new
  enough (`trixie` has 2.8.1, `forky` dropped the package, `sid` has no security
  support). The build fails if the compiled version is below 2.8.4 or does not match the
  requested one.
- Only `usbhid-ups` and `dummy-ups` are compiled in, and only the server, the driver and
  the client tools are copied into the runtime stage.
- `entrypoint.sh` renders the configuration (or honours a mounted one), fixes
  permissions, starts the driver and `upsd`, waits up to 30 s for the server to answer,
  then supervises both processes and shuts everything down cleanly on `SIGTERM`.

Repository layout:

```
Dockerfile                    multi-stage NUT build + runtime
entrypoint.sh                 configuration, supervision, signal handling
templates/                    NUT configuration templates (env mode)
tests/smoke.sh                hardware-free smoke tests
tests/fixtures/               dummy-ups device file and mount-mode configs
docker-compose.example.yml    reference deployment
odd/tasks/                    implementation notes and decision log
```

### Publishing

`.github/workflows/build.yml`:

| Trigger | What happens |
| --- | --- |
| `pull_request` to `main` | lint, build `linux/amd64`, run the smoke tests, never push |
| `push` to `main` | lint, build + smoke test, then push `linux/amd64,linux/arm64` as `latest`, `main` and `sha-<short>` |
| tag `v*.*.*` | same, plus semver tags `{{version}}` and `{{major}}.{{minor}}`, and `latest` |
| weekly schedule (Mon 04:00 UTC) | rebuild and push `latest` (Debian security updates) |
| `workflow_dispatch` | run the whole pipeline manually |

Configure the repository once:

| Name | Kind | Value |
| --- | --- | --- |
| `DOCKERHUB_USERNAME` | secret | Docker Hub account name |
| `DOCKERHUB_TOKEN` | secret | Docker Hub **access token** with Read/Write (not the account password) |
| `DOCKERHUB_IMAGE` | variable | `<user>/ecoflow-nut` |

Release process: tag `vX.Y.Z`, push the tag, and the workflow publishes the semver tags
and `latest`. `.github/workflows/dockerhub-desc.yml` keeps the Docker Hub description in
sync with this README.

## License and disclaimer

MIT - see [LICENSE](LICENSE). The image bundles Network UPS Tools, which is licensed under
the GNU GPL v2 or later; its source is available upstream at
<https://github.com/networkupstools/nut>.

Not affiliated with, endorsed by, or supported by EcoFlow or iXsystems. "EcoFlow",
"Delta", "River" and "TrueNAS" are trademarks of their respective owners. Use at your own
risk, especially where the graceful shutdown of a storage server is concerned.
