# Security policy

## Reporting a vulnerability

Open a private security advisory at
<https://github.com/J0nan/ecoflow-nut/security/advisories/new>, or email the
maintainer listed in the repository profile. Please do not open a public issue
for a security problem.

Include the image tag (or digest), how the container is run, and the smallest
reproduction you can build. Expect an acknowledgement within a week.

## Scope

In scope:

- the image contents (NUT version, libraries, missing services, permissions);
- `entrypoint.sh` (configuration rendering, validation, supervision);
- the GitHub Actions workflows and the publishing chain;
- the documented security properties below.

Out of scope:

- the NUT protocol itself being unauthenticated for reads and unencrypted for
  everything. This image is documented as LAN-only by design; there is no TLS
  in `upsd`. Exposing port 3493 to an untrusted network is a misconfiguration,
  not a vulnerability.
- bugs inside NUT or its drivers. Report those upstream at
  <https://github.com/networkupstools/nut/issues>; this project only pins and
  repackages the release.
- physical or firmware issues in the UPS itself.

## Security properties this project maintains

| Property | How it is enforced |
| --- | --- |
| No shutdown decision inside the container | `upsmon` and `upssched` are not installed; the driver and `upsd` are the only services |
| No secrets in image layers | the image contains no configuration and no password; `MON_PASSWORD` is required at runtime |
| Secrets are not readable by the services | the password is rendered with a `0077` umask, stored `0640 root:nut`, and removed from the exported environment of the driver and `upsd` |
| No configuration injection | every templated value is validated; newlines, quotes and backslashes are rejected |
| Exact NUT version | built from a checksum-pinned upstream release, gated to `>= 2.8.4` and checked against the requested version |
| Reproducible dependencies | actions pinned to commit SHAs, Dependabot for actions and base images, weekly rebuild for Debian security updates |
| Untrusted pull requests cannot publish | no secrets on `pull_request`, workflow-level `permissions: contents: read`, `persist-credentials: false` |

## Supported versions

Only the `latest` tag and the most recent `vX.Y.Z` release are supported.
Older tags are rebuilt only through the weekly schedule.
