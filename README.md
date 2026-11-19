# ecoflow-nut

A small Docker image that runs Network UPS Tools (NUT) 2.8.5 and exposes an EcoFlow Delta 3 Plus (or River 3 Plus) as a network UPS, so TrueNAS CE can monitor it and shut down gracefully when the battery runs low. It runs the USB HID driver (`usbhid-ups`) and the network server (`upsd`) only; the shutdown decision stays on TrueNAS.

| | |
| --- | --- |
| Supported UPS units | EcoFlow **Delta 3 Plus**, EcoFlow **River 3 Plus** (same USB ID `3746:ffff`) |
| NUT version | **2.8.5**, built from the pinned upstream release; `>= 2.8.4` enforced at build time |
| Services | `usbhid-ups` (driver) and `upsd` (network server). No `upsmon`, no `upssched` |
| Image | `j0n4n/ecoflow-nut` |
| Platforms | `linux/amd64`, `linux/arm64` |
| Network | plain NUT protocol on port `3493`, LAN only (no TLS by design) |

## Why this image exists

TrueNAS CE bundles a NUT release older than 2.8.3, which cannot drive EcoFlow USB HID units, so it cannot talk to a Delta 3 Plus directly. This container carries a new-enough NUT, publishes the UPS on TCP 3493, and leaves every shutdown decision to TrueNAS.

## Deploy on TrueNAS

Deployment is one custom app installed from YAML, followed by the built-in UPS service pointed at that app as a slave. The app runs on the TrueNAS machine itself, so the UPS cable goes into that machine.

### Connect the UPS

Plug the USB cable into the **leftmost USB-C port** of the Delta 3 Plus, which is the only port that exposes the HID interface, and connect the other end to a USB port on the TrueNAS host. Use a USB data cable; a C-to-A data cable is often more reliable than C-to-C. Then confirm the host sees the device:

```bash
lsusb | grep -i 3746     # expect: ID 3746:ffff EcoFlow ...
```

### Install the custom app

In TrueNAS, open **Apps**, choose **Discover Apps** (or the three-dot menu) and select **Custom App**, then **Install via YAML**. Paste the following, replacing the password, and save.

```yaml
services:
  ecoflow-nut:
    image: j0n4n/ecoflow-nut:latest
    restart: unless-stopped
    stop_grace_period: 30s
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    cap_add:
      - CHOWN        # chown root:nut on the rendered configs
      - DAC_OVERRIDE # read the 0640 configs and the USB device node
      - FOWNER       # chmod files this process does not own
      - SETGID
      - SETUID
    environment:
      UPS_NAME: ecoflow
      UPS_DESC: EcoFlow Delta 3 Plus
      MON_USER: monuser
      MON_PASSWORD: change_me_long_random
      OVERRIDE_BATTERY_CHARGE_LOW: "30"
    ports:
      - "127.0.0.1:3493:3493"
    volumes:
      - /dev/bus/usb:/dev/bus/usb
    device_cgroup_rules:
      - 'c 189:* rmw'
```

Notes for the app YAML:

- The published port is bound to `127.0.0.1`, which is all TrueNAS needs because it runs on the same machine. Change it to `"3493:3493"` only if another machine must query the UPS directly, and keep that port off any untrusted network.
- `MON_PASSWORD` is the monitor password; it is visible in the app configuration and must match what you enter in the UPS service below. Use a long random value, for example `openssl rand -base64 24`.
- If your TrueNAS version rejects `device_cgroup_rules`, remove that key and keep the `/dev/bus/usb` bind mount.
- If hotplug or re-enumeration keeps breaking access, replace the capability block with `privileged: true`. That is the escape hatch, not the default.
- Optional extra hardening: `read_only: true` together with `tmpfs: [/run]`; the driver only needs to write inside `/run` and `/etc/nut`.

Check the app logs in the TrueNAS UI for `UPS 'ecoflow' is available at ecoflow@127.0.0.1:3493`, then from a TrueNAS shell:

```bash
upsc ecoflow@127.0.0.1:3493 battery.charge
upsc ecoflow@127.0.0.1:3493 ups.status
```

A working unit reports `ups.status: OL` on mains power and a `battery.charge` between 0 and 100.

### Configure the UPS service as a slave

In TrueNAS open **System > Services > UPS** and fill in the form as follows:

- UPS Mode: **Slave**
- Identifier: `ecoflow` (must match `UPS_NAME`)
- Remote host: `127.0.0.1` (or the address of the machine running the container, if it is not this one)
- Remote port: `3493`
- Monitor user / Monitor password: `monuser` / your `MON_PASSWORD`
- Shutdown mode: **UPS reaches low battery**
- Power off UPS: **unchecked**
- Enable the service and start it on boot

The same configuration from the CLI:

```bash
midclt call ups.update '{"mode":"SLAVE","identifier":"ecoflow","remotehost":"127.0.0.1","remoteport":3493,"monuser":"monuser","monpwd":"<PASSWORD>","shutdown":"LOWBATT"}'
midclt call service.update ups '{"enable": true}'
midclt call service.start ups
```

Verify from the TrueNAS shell or any machine with NUT client tools:

```bash
upsc ecoflow@127.0.0.1:3493
```

Expect `battery.charge`, `ups.status: OL` and `battery.charge.low: 30`.

### Verify the shutdown path

1. Pull the AC input from the UPS and confirm `ups.status` switches to `OB`.
2. Instead of draining the battery, restart the app with `OVERRIDE_BATTERY_CHARGE_LOW: "100"` in the YAML: the UPS immediately reports `OB LB`.
3. Confirm TrueNAS starts and completes its shutdown.
4. Restore `OVERRIDE_BATTERY_CHARGE_LOW: "30"` and restart the app.

## Test it locally

Everything except the real USB device can be exercised on a workstation with Docker. The repository ships a hardware-free test suite that uses the `dummy-ups` driver.

### Build and lint

```bash
docker build -t ecoflow-nut:dev .
docker run --rm -v "$PWD:/mnt" koalaman/shellcheck:stable -x /mnt/entrypoint.sh /mnt/tests/smoke.sh
docker run --rm -v "$PWD:/mnt" -w /mnt hadolint/hadolint hadolint Dockerfile
```

### Run the smoke tests

```bash
IMAGE=ecoflow-nut:dev ./tests/smoke.sh
```

The suite checks the NUT version floor, the rendered configuration and its `0640 root:nut` permissions, a missing and an invalid `MON_PASSWORD`/`UPS_NAME`, the full driver → `upsd` → `upsc` path over TCP, mount mode, restarts, the healthcheck and `SIGTERM` handling. On Windows run it from Git Bash.

### Simulate a UPS without hardware

```bash
docker run -d --name nut-dummy -p 3493:3493 \
  -e MON_PASSWORD=test123 \
  -e DRIVER=dummy-ups \
  -e PORT=/fixtures/dummy.dev \
  -v "$PWD/tests/fixtures/dummy.dev:/fixtures/dummy.dev:ro" \
  ecoflow-nut:dev

docker exec nut-dummy upsc ecoflow@127.0.0.1 ups.status    # OL
docker exec nut-dummy upsc ecoflow@127.0.0.1 battery.charge
```

This is the same setup the CI smoke tests use, and it is enough to configure and rehearse the TrueNAS side before the real UPS is connected.

### Check a real UPS locally

```bash
docker run -d --name ecoflow-nut --restart unless-stopped \
  -e MON_PASSWORD="$(openssl rand -base64 24)" \
  -p 3493:3493 \
  -v /dev/bus/usb:/dev/bus/usb \
  --device-cgroup-rule 'c 189:* rmw' \
  ecoflow-nut:dev
```

Stop it again before installing the TrueNAS app, so port 3493 is free.

## Configuration

Environment variables are rendered into the four NUT configuration files at container start (env mode, the default). Every value is validated before it reaches a config file.

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
| `LISTEN_ADDR` | `0.0.0.0` | `upsd` bind address inside the container |
| `LISTEN_PORT` | `3493` | `upsd` port inside the container |
| `OVERRIDE_BATTERY_CHARGE_LOW` | `30` | `override.battery.charge.low` percentage (EcoFlow firmware reports 0% = never) |
| `OVERRIDE_BATTERY_RUNTIME_LOW` | `900` | `override.battery.runtime.low` in seconds |
| `POLLONLY` | `true` | adds the `pollonly` driver flag (EcoFlow firmware sends no interrupt events); applied only to `usbhid-ups` |
| `IGNORELB` | `true` | adds the `ignorelb` driver flag so the overrides above take effect |
| `DRIVER_USER` | `root` | driver user; root avoids USB node permission problems inside the container |
| `EXTRA_DRIVER_ARGS` | *empty* | appended verbatim inside the `[ups]` section - trusted input, it can add any directive |

Two NUT files deserve a note. `upsd.users` contains `upsmon master`, a privilege that also permits slave logins, which is what TrueNAS uses; nothing in this container logs in. And `vendorid`, `productid` and `pollonly` are `usbhid-ups` options: when `DRIVER` is set to another driver they are omitted, because other drivers reject them.

### Mount your own /etc/nut

If `/etc/nut/ups.conf` already exists when the container starts, mounted as a single file or as a directory, the container uses that configuration as-is and does not render the templates. `MON_PASSWORD` is not required in that mode and no environment variable is applied. Ownership and permissions are still fixed unless the mount is read-only, in which case the container logs a warning and continues. The container starts the driver for the first section in `ups.conf`, or for `UPS_NAME` when that section exists.

## Security

- The NUT protocol is unencrypted and reads are unauthenticated, and there is no TLS by design. That is fine on a trusted LAN and unacceptable anywhere else, so **never port-forward 3493** and keep the published port bound to loopback unless another machine really needs it.
- Use a long random `MON_PASSWORD`. The `upsmon master` privilege in `upsd.users` can put the monitored system into forced shutdown, and the password travels in clear text.
- The image contains no configuration and no secrets. The password is written with a `0077` umask, stored `0640 root:nut`, and removed from the environment of the services so it cannot be read from `/proc/<pid>/environ`.
- The driver runs as root inside the container because it must open the USB device node. `upsmon` and `upssched` are not installed in the image, so no shutdown can be triggered from inside it.
- The app YAML drops all capabilities and adds back only the five the entrypoint needs, and sets `no-new-privileges`. `read_only: true` with `tmpfs: [/run]` works as well and is worth enabling once the UPS is reporting correctly.
- Supply chain: NUT is downloaded from the upstream release and verified against the published SHA-256, GitHub Actions are pinned to commit SHAs, Dependabot tracks actions and base images, the weekly rebuild picks up Debian security updates, and published images carry a build provenance attestation (`docker buildx imagetools inspect j0n4n/ecoflow-nut`).
- Report a vulnerability through the repository's private security advisory page instead of a public issue.

## Known quirks

- **Low battery is reported as 0%.** EcoFlow firmware treats "never" as the low-battery threshold, so NUT's defaults make `LB` unreachable. This image overrides `battery.charge.low` (30%) and `battery.runtime.low` (900 s) and ignores the firmware's own threshold.
- **Runtime estimates are unreliable.** Prefer the charge threshold for the shutdown decision.
- **Some firmware needs `pollonly`.** EcoFlow units do not send HID interrupt events, so interrupt-driven polling stalls; `POLLONLY=true` is the default for that reason.
- **The first `ups.status` can be `WAIT`.** Both drivers publish a settled status within a few seconds; the healthcheck waits for the server, not for `OL`.
- **The USB HID link can drop.** Some units need the UPS power-cycled (unplug power and USB, reconnect) before the device re-enumerates.
- **Keep the EcoFlow firmware updated** through the phone app; several HID reporting bugs were fixed there, not in NUT.
- **The container exits when the driver dies.** That is deliberate: with `restart: unless-stopped` the whole set recovers instead of serving stale data, and the log line explains what happened.

## Publishing

`.github/workflows/build.yml` builds and publishes the image.

| Trigger | What happens |
| --- | --- |
| `pull_request` to `main` | lint, build `linux/amd64`, run the smoke tests, never push |
| `push` to `main` | lint, build + smoke test, then push `linux/amd64,linux/arm64` as `latest`, `main` and `sha-<short>` |
| tag `v*.*.*` | same, plus semver tags `{{version}}` and `{{major}}.{{minor}}`, and `latest` |
| weekly schedule (Mon 04:00 UTC) | rebuild and push `latest` for Debian security updates |
| `workflow_dispatch` | run the whole pipeline manually |

Configure the repository once under **Settings > Secrets and variables > Actions**:

| Name | Kind | Value |
| --- | --- | --- |
| `DOCKERHUB_USERNAME` | secret | `j0n4n` |
| `DOCKERHUB_TOKEN` | secret | Docker Hub **access token** with Read/Write, not the account password |
| `DOCKERHUB_IMAGE` | variable | `j0n4n/ecoflow-nut` |

To release, tag `vX.Y.Z` and push the tag; the workflow publishes the semver tags and `latest`. `.github/workflows/dockerhub-desc.yml` keeps the Docker Hub description in sync with this README.

## License

AGPL-3.0 - see [LICENSE](LICENSE). The image bundles Network UPS Tools, which is licensed under the GNU GPL v2 or later; its source is available upstream at <https://github.com/networkupstools/nut>. Not affiliated with, endorsed by, or supported by EcoFlow or iXsystems; "EcoFlow", "Delta", "River" and "TrueNAS" are trademarks of their respective owners.