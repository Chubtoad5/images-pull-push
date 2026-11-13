# images-pull-push
Script to pull, push, and save container images dynamically using Docker
- Recommened when needing to leverage a local OCI container registry instead of a public registry when no proxy/pull passthrough is enabled
- Optionally saves tar.gz that contains an image manifest txt and a tarball of all pulled images
- Automatically preserves original tagging and dynamicaly updates the tags when pushing to the registry
- Specify to keep the images loaded in the docker daemon or remove them (useful for Kubernetes environments)
- Great for airgapped environment preparation
- Easily integrate with existing automation

---

## Table of Contents

- [Quick Start](#quick-start)
- [Getting started](#getting-started)
- [Usage](#usage)
- [Examples](#examples)
- [Behavior notes](#behavior-notes)

---

## Quick Start

New here? `image_pull_push.sh` mirrors a list of container images into **your own** registry (or saves
them to a tarball for air-gapped transfer), preserving each image's tags automatically.

**Prerequisites**
- A supported OS (Ubuntu/Debian, RHEL family, SLES/openSUSE Leap) and `root` / `sudo`
- Docker — the script installs it for you if it's missing
- When pushing: access to your registry, with the target **project paths already created**
  (e.g. `/library`, `/rancher`, `/longhornio`)

**1. Get the script and write a plain-text image list**
```bash
git clone https://github.com/Chubtoad5/images-pull-push.git
cd images-pull-push
chmod +x image_pull_push.sh

cat > my_images.txt <<'EOF'
nginx:latest
rancher/local-path-provisioner:v0.0.31
EOF
```

**2. Pull the images and push them to your registry**
```bash
sudo ./image_pull_push.sh -f my_images.txt push my-registry.example.com:443 <username> <password>
```

Or pull and **save to a tarball** to carry into an air-gapped environment:
```bash
sudo ./image_pull_push.sh -f my_images.txt save
```
Then, on the air-gapped host, load from that tarball and push — no image list needed, the manifest is
bundled inside the archive:
```bash
sudo ./image_pull_push.sh -f container_images_*.tar.gz push my-registry.example.com:443 <username> <password>
```

See [Usage](#usage) for every parameter. (`docker` and `reg-cert` are internal helper modes used by
the other Chubtoad5 tools — you won't normally call them directly.)

## Getting started

### Requirements
- Supported Operating Systems:  ```ubuntu|debian|rhel|centos|rocky|almalinux|fedora|sles|opensuse-leap```
- Docker engine and CLI
- Openssl
- `curl`, `tar`, and `gzip` — checked up front; the script reports anything missing along with the distro's install command
- Sudo or root access
- Access to an existing container registry when using push
- Container registry must have the coresponding project path(s) pre-created (i.e /rancher, /library, /longhornio, etc.)
- The image_pull_push.sh script downloaded, i.e:
```
git clone https://github.com/Chubtoad5/images-pull-push.git
```
- A .txt file on the localhost which contains a list of the container images and tags, i.e: `image-manifest.txt`
```
nginx:latest
rancher/local-path-provisioner:v0.0.31
registry.k8s.io/e2e-test-images/agnhost:2.39
```
- If loading or pushing from a pre-created tar.gz, the ``` container_images_####.tar.gz ``` file downloaded locally (no txt file needed as the manifest is auto-generated in the pre-created tar.gz)

##  Usage
```
Usage: ./image_pull_push.sh -f <path_to_images_or_manifest_file> [keep] [save] [push <registry:port> [<username> <password>]]

This script must be run with root privileges.

Parameters:
  -f <path_to_images_file>   : Path to the file containing a list of container images and tags (one per line).
                               Alternatively, this can be a .tar.gz file created by this script for air-gapped mode.
  <keep>                     : Optional. If specified, the script will NOT delete the images from the local Docker daemon at the end.
  <save>                     : Optional. If specified, saves the images to a .tar.gz file.
  <push>                     : Optional. Pushes the images to a specified registry after saving.
  <registry:port>            : Required when <push> is specified. The target registry URL and port.
  <username>                 : Optional. The username for the registry.
  <password>                 : Optional. Required when <username> is specified. The password for the registry.
  ```

## Examples
### Pull and save images:
```
./image_pull_push.sh -f my_images.txt save
```

### Pull, save, and push to a registry:
```
./image_pull_push.sh -f my_images.txt save push my-registry.com:5000 <username> <password>
```

### Load images from a local file and push (air-gapped):
```
./image_pull_push.sh -f container_images_...tar.gz push my-registry.com:5000 <username> <password>
```

### Load image freom a local file and keep them without pushing
```
./image_pull_push.sh -f container_images_...tar.gz keep
```
---

## Behavior notes

- **Exit codes are truthful.** Any failure exits non-zero; success exits `0`. Safe to call from automation under `set -e`.
- **Passwords are never printed.** The registry password is masked (`********`) in the runtime-argument display.
- **Any password works, as typed** (spec 21): when two or more arguments follow `<registry:port>`, the first two are the
  username and the password, taken by position, so a password such as `--help`, `push` or `-f` is a password, not an
  option. It reaches `docker login` on stdin, never on the command line. Quote it in your shell, for example
  `push my-registry.com:5000 robot 'Pa$$ w0rd!'`. Put `-f` and other commands before `push`, or after the password. A
  username can't contain `:` or start or end with a space, because registry logins can't carry them. A password that
  starts or ends with a space needs Docker 29.3 or later: older `docker login` trims those spaces, so on an older
  Docker such a password is refused before anything is pulled, with a message that says so.
- **Registry certificate handling:** `push`/`reg-cert` fetch the registry's full certificate chain and write it to `/etc/docker/certs.d/<registry:port>/ca.crt`, which Docker reads on each registry connection, and to the system trust store, for other clients. **Docker is never restarted** for it (since v1.2.1), so the containers already running on the host keep running; a Docker that is installed but stopped is started. Each copy is written only when it differs from the fetched chain, and a failed retrieval leaves nothing behind in either place.
- **`save` always bundles the Docker packages** for the detected distro (Docker CE on Ubuntu/Debian/RHEL family, the distro `docker` package on SLES/openSUSE Leap), even when Docker is already installed on the build host. If the package archive cannot be produced, `save` fails loudly instead of producing an incomplete archive. When Docker is not yet installed on the build host, the packages are saved **before** Docker is installed, so the archive captures Docker's full dependency closure — this matters on SUSE, where zypper only resolves dependencies missing from the build host.
- **EL10 kernel modules:** on RHEL/Rocky/Alma 10, stock cloud images omit `kernel-modules-extra`, which provides the `xt_addrtype` module the Docker daemon needs for its NAT rules. The installer detects this and installs `kernel-modules-extra` matched to the *running* kernel; if that version has aged out of the repos it installs the latest kernel + modules and exits with an explicit "reboot, then re-run" error instead of leaving a docker that cannot start. Air-gapped, `save` on such a host also bundles the build host's running kernel's `kernel-modules-extra`, and the install uses it when the target runs that same kernel, as a target built from the same image does. On any other kernel, it says which package to bring from local media.
- **`INSTALL_PACKAGES_URL`** overrides where `install_packages.sh` is fetched from (defaults to the upstream `main` branch) — useful for feature-branch testing or internal mirrors.
- **Atomic save archives:** the `container_images_*.tar.gz` archive is written under a temporary name and renamed only on success, so an interrupted save never leaves a truncated, valid-looking archive behind.
- **`save` requires a text manifest** — passing a `.tar.gz` archive together with `save` is an error (the archive is already a saved bundle; use `keep` or `push` with it).
- **Windows (CRLF) manifests work** — carriage returns are stripped from manifest lines.
- **mirror.gcr.io fallback:** bare official images fall back as `mirror.gcr.io/library/<name>`; images pinned to a non-Docker-Hub registry (e.g. `registry.k8s.io/...`, `quay.io/...`) skip the fallback, since the mirror only carries Docker Hub content. Temporary mirror tags created by the script are removed after a successful retag.
- **`/etc/docker/daemon.json` is merged, not overwritten.** When the file already exists, the `bip` (bridge CIDR) setting is merged in via `jq` or `python3`; if neither is available the existing file is left untouched with a warning. An existing `bip` value is always respected. On failure, only the changes made by the current run are reverted — the script never deletes `/etc/docker`.
- **Rocky/Alma/CentOS** use Docker's designated `centos` repository path, and `dnf-plugins-core` is installed automatically when `dnf config-manager` is missing (minimal images).

## Version pinning

All of this is optional. A plain list of `repo:tag` lines works as it always has.

**Pin images by digest.** `lock` pulls a list and writes the same list with each digest added. The result works with every other command:

```bash
sudo ./image_pull_push.sh -f images.txt lock            # writes images.pinned.txt
sudo ./image_pull_push.sh -f images.pinned.txt save
sudo PIN_STRICT=true ./image_pull_push.sh -f images.pinned.txt keep   # refuse any line with no digest
sudo PIN_STRICT=true ./image_pull_push.sh -f container_images_*.tar.gz keep   # a bundle: refuse an image with no digest in its lock file
```

- A line looks like `repo:tag@sha256:<64 hex>`. A digest with no tag is refused.
- A bundle's `images/images.lock` records each image, and loading the bundle checks it. Image IDs can't be compared across Docker's two image stores, so a bundle from the other store gets a note.
- Pushing a multi-arch image sends only the local platform, so the registry's digest won't match the source. Nothing compares them.

**Pin the Docker engine.** This applies when Docker isn't installed yet, and to `save`. A Docker that's already installed is never moved: it only gets a warning.

```bash
sudo DOCKER_VERSION=28.5.2 COMPOSE_VERSION=2.30 ./image_pull_push.sh docker
```

**Pin this script's helper.** `install_packages.sh` is fetched at the tag this version was tested with. Set `INSTALL_PACKAGES_REF` to a tag, branch or commit, `INSTALL_PACKAGES_URL` for a full URL, and `INSTALL_PACKAGES_SHA256` to check it.

**Licences in a save bundle.** A `save` archive holds `LICENSES/`: a manifest of the OS packages it carries for installing Docker with no route out, and a written offer for the GPL and LGPL ones, such as `iptables`, and on EL the kernel's `kernel-modules-extra`. Set `LICENSE_OFFER_CONTACT` to who the offer tells people to ask (default: the Chubtoad5 project). The saved container images carry their own licences inside.

## Upstream / Credits

This project automates the following open-source software; all credit to their authors. See [NOTICE](NOTICE) for
details.

- Docker / Moby — Apache-2.0

This is a generic image mover: it pulls/saves/pushes whatever images **you** specify; the licenses of those images
are your responsibility.

## License

Licensed under the **Apache License 2.0** — see [LICENSE](LICENSE) and [NOTICE](NOTICE).
