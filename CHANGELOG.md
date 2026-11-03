# Changelog — images-pull-push

## v1.1.0 — 2026-11-03 — Optional version pinning

All of this is optional. A manifest of plain `repo:tag` lines, with no new settings, behaves as before.

### Added
- **Digests in manifests.** A line can be `repo:tag@sha256:<64 hex>`. The image is pulled by digest, so Docker verifies
  it, and it then gets its tag, so the rest of the flow works as usual. A digest with no tag is refused. The
  `mirror.gcr.io` fallback keeps the digest, so a mirror can't substitute a different image.
- **`lock` command.** It pulls a plain list and writes `images.pinned.txt`, the same list with each digest added.
- **`PIN_STRICT=true`** refuses any manifest line with no digest. It's off by default.
- **Bundles record what they hold.** `save` adds `images/images.lock` (tag, digest, image ID), and loading a bundle
  checks it. A mismatch fails. A bundle with no lock file gets a note. Image IDs mean different things in Docker's two
  image stores, so a bundle from the other store gets a note instead of a false failure.
- **`DOCKER_VERSION`, `CONTAINERD_VERSION` and `COMPOSE_VERSION`**, used when Docker isn't installed yet, and by
  `save`. These need install-packages v1.1.0. A Docker that's already installed is never moved. It only gets a warning.
- **`INSTALL_PACKAGES_REF`** picks which `install_packages.sh` to fetch, and **`INSTALL_PACKAGES_SHA256`** checks it.
  `INSTALL_PACKAGES_URL` still works, and wins.
- **`--version`, and `SCRIPT_VERSION`.** `--version` and `--help` work without root. Each bundle records the version
  in `images/HELPER_VERSION`.
- **Tests:** `tests/unit`, `tests/contract` and `tests/integration`.

### Changed
- `install_packages.sh` now defaults to tag `v1.1.0` rather than `main`. Set `INSTALL_PACKAGES_REF=main` for the old
  behaviour. **Release install-packages v1.1.0 first,** or the default won't resolve.
- `images/manifest.txt` in a bundle is now always plain `repo:tag` lines, with comments removed, rather than a copy of
  the input file. An older copy of this script can still use a new bundle.

### Fixed
- A pinned line used to fail at `push`, and lost its tag at `keep` and `save`.

## 2026-09-09 — Idempotence release (feature/idempotence-phase2)

Suite-wide idempotence and correctness pass. `image_pull_push.sh` now reports truthful exit
codes, keeps credentials out of its output, changes host Docker configuration only when it
actually needs to, and produces air-gap archives that are complete or absent — never partial.

### Fixed
- **Truthful exit codes.** Any failure exits non-zero; success exits `0`. An `EXIT` trap
  preserves the real status, and the root check exits instead of continuing. Safe to call
  from automation under `set -e`.
- **Passwords are never printed.** The registry password is masked (`********`) in the
  runtime-argument display.
- **Certificate handling is change-detecting and atomic.** `push`/`reg-cert` fetch the
  registry's full chain and update the trust store and restart Docker **only when the
  certificate actually changed**; a failed retrieval leaves nothing behind in the trust
  anchors.
- **`/etc/docker/daemon.json` is merged, not overwritten.** The `bip` setting is merged into
  an existing file via `jq`/`python3` (with the existing `bip` always respected); if neither
  tool is available the file is left untouched with a warning. On failure only the current
  run's changes are reverted — the script never deletes `/etc/docker`.
- **`save` bundles the Docker packages state-independently**, even when Docker is already
  installed on the build host, and fails loudly rather than producing an incomplete archive.
  When Docker is not yet installed, packages are saved **before** Docker is installed so the
  archive captures Docker's full dependency closure — this is what makes SUSE bundles usable,
  since zypper only resolves dependencies missing from the build host.
- **EL10 kernel modules.** On RHEL/Rocky/Alma 10, stock cloud images omit
  `kernel-modules-extra`, which provides the `xt_addrtype` module the Docker daemon needs for
  its NAT rules. The installer now detects this and installs `kernel-modules-extra` matched to
  the **running** kernel; if that version has aged out of the repos it installs the latest
  kernel + modules and exits with an explicit "reboot, then re-run" error instead of leaving
  a Docker that cannot start.
- **`mirror.gcr.io` fallback corrected.** Bare official images fall back as
  `mirror.gcr.io/library/<name>`; images pinned to a non-Docker-Hub registry
  (`registry.k8s.io/…`, `quay.io/…`) skip the fallback, since the mirror only carries Docker
  Hub content. Temporary mirror tags created by the script are cleaned up after a successful
  retag.
- **`library/` prepend now works for bare names with dotted tags** (e.g. `redis:7.2`), which
  previously took an unreachable branch.
- **Atomic save archives.** `container_images_*.tar.gz` is written under a temporary name and
  renamed only on success.
- **Save-input validation.** Passing a `.tar.gz` together with `save` is now an error (the
  archive is already a bundle — use `keep` or `push`).
- **Windows (CRLF) manifests work** — carriage returns are stripped from manifest lines.
- **Distro correctness.** Rocky/Alma/CentOS use Docker's designated `centos` repo path, and
  `dnf-plugins-core` is installed automatically when `dnf config-manager` is missing (minimal
  images). The SUSE package list gains `docker-compose`.

### Added
- **Command preflight** — `curl`, `tar`, and `gzip` are checked up front, and anything missing
  is reported with the distro's install command.
- **`INSTALL_PACKAGES_URL`** overrides where `install_packages.sh` is fetched from (defaults to
  upstream `main`) — useful for feature-branch testing or internal mirrors. This retires the
  previous sed-patch workaround.
- **Behavior notes** section in the README.
- `image_pull_push.sh` is now tracked executable (mode 755).

### Unchanged
- CLI surface (`-f <file>` plus the `keep`, `save`, `push`, `docker` and `reg-cert` commands
  and their `<registry:port> <username> <password>` options), the manifest format, and the
  `container_images_*.tar.gz` archive naming are unchanged. Callers
  (`rke2-installer`, `seaweedfs-installer`, `markdown-server`,
  `automation-platform-tools`) need no changes.
