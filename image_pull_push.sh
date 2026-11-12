#!/bin/bash

# --- Script Configuration ---
# Set strict mode to catch errors early
set -o errexit
set -o nounset
set -o pipefail

# --- Global Variables ---
SCRIPT_VERSION="1.2.0"
SCRIPT_NAME=$(basename "$0")
IMAGES_FILE=""
SAVE_MODE=0
PUSH_MODE=0
KEEP_MODE=0
LOCK_MODE=0
REG_CERT_MODE=0
DOCKER_MODE=0
AIR_GAPPED_MODE=0
REGISTRY_URL=""
REGISTRY_USER=""
REGISTRY_PASS=""
CLEANUP_REQUIRED=0
TEMP_DIR=""
user_name=${SUDO_USER:-$(whoami)}
DOCKER_BRIDGE_CIDR=${DOCKER_BRIDGE_CIDR:-"172.30.0.1/16"}
DOCKER_PACKAGES=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)
# Optional Docker versions, used only when Docker isn't installed yet. Empty = newest. The start of a version is enough.
DOCKER_VERSION=${DOCKER_VERSION:-""}
CONTAINERD_VERSION=${CONTAINERD_VERSION:-""}
COMPOSE_VERSION=${COMPOSE_VERSION:-""}
# Which install_packages.sh to fetch: a tag, branch or commit. INSTALL_PACKAGES_URL wins over the ref
# (e.g. an internal mirror), and INSTALL_PACKAGES_SHA256 is checked when set.
INSTALL_PACKAGES_REF=${INSTALL_PACKAGES_REF:-"v1.1.3"}
INSTALL_PACKAGES_URL=${INSTALL_PACKAGES_URL:-"https://raw.githubusercontent.com/Chubtoad5/install-packages/${INSTALL_PACKAGES_REF}/install_packages.sh"}
INSTALL_PACKAGES_SHA256=${INSTALL_PACKAGES_SHA256:-""}
# Who the save bundle's written offer for its GPL/LGPL OS packages tells people to ask for source code
LICENSE_OFFER_CONTACT=${LICENSE_OFFER_CONTACT:-"the Chubtoad5 project via https://github.com/Chubtoad5"}
# true = refuse any manifest line that has no digest
PIN_STRICT=${PIN_STRICT:-"false"}
os_id=""
DOCKER_PACKAGES_SAVED=0
images_to_manage=()
# repo:tag -> sha256:... for manifest lines pinned by digest
declare -gA IMAGE_DIGEST=()
SAVE_FILE_NAME=""
BRIDGE_JSON_CHANGED=0
BRIDGE_JSON_COMMITTED=0
BRIDGE_JSON_BACKUP=""
ETC_DOCKER_CREATED=0

# --- Helper Functions ---

# Function to display a usage message
usage() {
    cat << EOF
Usage: $SCRIPT_NAME -f <file_path> [command] <option>
       $SCRIPT_NAME --version

Parameters:
  -f <file_path>     : File path containing names tags of container images (one per line).
                         A line may pin a digest: repo:tag@sha256:<64 hex>
                         Alternate: A .tar.gz file created by this script (air-gapped mode)
  Commands:
    [keep]           : Pulls images locally
    [save]           : Saves images and manifest to a single tar.gz
    [lock]           : Pulls images and writes images.pinned.txt, the same list with each digest added
    [push]           : Pushes images to a specified registry
    [docker]         : Install docker then exits
    [reg-cert]       : Installs registry certificate then exits
  Options:           
    <registry:port>  : Target registry FQDN/IP and port. Required with [push] or [reg-cert]
    <username>       : Target registry username. Required with [push]
    <password>       : Target registry password. Required with [push]

Examples:
  Pull and save images:
    sudo ./$SCRIPT_NAME -f my_images.txt save

  Pull, save, and push to a registry:
    sudo ./$SCRIPT_NAME -f my_images.txt save push my-registry.com:5000

  Load images from a local file and push (air-gapped):
    sudo ./$SCRIPT_NAME -f container_images_...tar.gz push my-registry.com:5000

  Load images from a local file and keep them without pushing:
    sudo ./$SCRIPT_NAME -f container_images_...tar.gz keep

  Pin a list of images by digest, then use the pinned list:
    sudo ./$SCRIPT_NAME -f my_images.txt lock
    sudo ./$SCRIPT_NAME -f images.pinned.txt save

Environment (all optional):
  DOCKER_VERSION, CONTAINERD_VERSION, COMPOSE_VERSION : Versions to install when Docker isn't installed yet
  PIN_STRICT=true        : Refuse any manifest line with no digest
  INSTALL_PACKAGES_REF   : Tag, branch or commit of install_packages.sh to fetch
  INSTALL_PACKAGES_URL, INSTALL_PACKAGES_SHA256 : Full URL, and a checksum to verify
EOF
    exit "${1:-1}"
}

# Fetch install_packages.sh into TEMP_DIR, checking the checksum when one was given
fetch_install_packages() {
    if ! curl -fsSL "$INSTALL_PACKAGES_URL" -o "$TEMP_DIR/install_packages.sh"; then
        echo "Error: Failed to download install_packages.sh from $INSTALL_PACKAGES_URL"
        exit 1
    fi
    if [[ -n "$INSTALL_PACKAGES_SHA256" ]] && ! echo "$INSTALL_PACKAGES_SHA256  $TEMP_DIR/install_packages.sh" | sha256sum -c --status; then
        echo "Error: install_packages.sh doesn't match INSTALL_PACKAGES_SHA256."
        exit 1
    fi
    chmod +x "$TEMP_DIR/install_packages.sh"
}

# Split "repo:tag@sha256:..." manifest lines: images_to_manage keeps repo:tag, because the rest of the flow
# and every consumer work with tags, and the digest goes into IMAGE_DIGEST.
normalize_images() {
    local line ref digest out=()
    for line in "${images_to_manage[@]}"; do
        if [[ "$line" == *@* ]]; then
            ref=${line%%@*}
            digest=${line#*@}
            if [[ ! "$digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
                echo "Error: bad digest in manifest line '$line'. Expected sha256: and 64 hex characters."
                exit 1
            fi
            if [[ "${ref##*/}" != *:* ]]; then
                echo "Error: manifest line '$line' has a digest but no tag. Use repo:tag@sha256:..."
                exit 1
            fi
            IMAGE_DIGEST["$ref"]=$digest
            out+=("$ref")
        else
            if [[ "${PIN_STRICT,,}" == "true" ]]; then
                echo "Error: PIN_STRICT=true, and manifest line '$line' has no digest. Add one with the 'lock' command."
                exit 1
            fi
            out+=("$line")
        fi
    done
    images_to_manage=("${out[@]}")
}

# pull_ref <repo:tag>: what to pull. A pinned image is pulled by digest, so Docker verifies it.
pull_ref() {
    local image=$1 digest=${IMAGE_DIGEST[$1]:-}
    if [[ -n "$digest" ]]; then
        echo "${image%:*}@$digest"
    else
        echo "$image"
    fi
}

# image_digest <repo:tag>: the registry digest Docker recorded when it pulled this image
image_digest() {
    local digests
    digests=$(docker image inspect --format '{{join .RepoDigests " "}}' "$1" 2>/dev/null) || return 1
    digests=${digests%% *}
    [[ "$digests" == *@sha256:* ]] || return 1
    echo "${digests##*@}"
}

# image_store: which image store this Docker uses, because it changes what an image ID means
image_store() {
    if docker info --format '{{json .DriverStatus}}' 2>/dev/null | grep -q 'io.containerd.snapshotter'; then
        echo containerd
    else
        echo classic
    fi
}

# check_bundle_pinned <lock file> <manifest>: PIN_STRICT for a bundle. Its manifest is always plain repo:tag, so that an
# older copy of this script can use it. What pins a bundle is its lock file, so every image in the manifest needs a digest there.
check_bundle_pinned() {
    local lock=$1 manifest=$2 line image digest rc=0
    [[ "${PIN_STRICT,,}" == "true" ]] || return 0
    if [[ ! -f "$lock" ]]; then
        echo "Error: PIN_STRICT=true, and this bundle has no lock file, so nothing records what its images are."
        exit 1
    fi
    while read -r line; do
        image=${line%%@*}
        # awk, not read: read collapses an empty tab-separated field, and would take the image ID for the digest.
        digest=$(awk -F'\t' -v image="$image" '$1 == image { print $2; exit }' "$lock")
        if [[ ! "$digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
            echo "Error: PIN_STRICT=true, and $image has no digest in this bundle's lock file."
            rc=1
        fi
    done < <(tr -d '\r' < "$manifest" | grep -vE '^\s*#|^\s*$')
    if [[ $rc -ne 0 ]]; then
        exit 1
    fi
}

# write_lock_file <path>: repo:tag, digest (when known), image ID, tab-separated
write_lock_file() {
    local image digest id
    {
        echo "# image-store: $(image_store)"
        for image in "${images_to_manage[@]}"; do
            digest=${IMAGE_DIGEST[$image]:-}
            [[ -n "$digest" ]] || digest=$(image_digest "$image" || true)
            id=$(docker image inspect --format '{{.Id}}' "$image")
            printf '%s\t%s\t%s\n' "$image" "${digest:--}" "$id"
        done
    } > "$1"
}

# verify_lock_file <path>: after 'docker load', check each image is the one the bundle recorded.
# Image IDs only compare within one image store, so a bundle from the other store gets a note instead.
verify_lock_file() {
    local lock=$1 saved_store here_store image digest id actual rc=0
    saved_store=$(sed -n 's/^# image-store: //p' "$lock")
    here_store=$(image_store)
    if [[ "$saved_store" != "$here_store" ]]; then
        echo "  Note: this bundle came from Docker's $saved_store image store, and this host uses $here_store. Image IDs can't be compared."
        return 0
    fi
    while IFS=$'\t' read -r image digest id; do
        [[ -z "$image" || "$image" == \#* ]] && continue
        actual=$(docker image inspect --format '{{.Id}}' "$image" 2>/dev/null || echo "missing")
        if [[ "$actual" != "$id" ]]; then
            echo "Error: $image doesn't match the bundle's record. Expected $id, found $actual."
            rc=1
        fi
    done < "$lock"
    if [[ $rc -ne 0 ]]; then
        exit 1
    fi
    echo "  Verified the loaded images against the bundle's lock file."
}

# A Docker that's already there is never moved. Say so when it doesn't match what was asked for.
warn_docker_version() {
    [[ -n "$DOCKER_VERSION" ]] || return 0
    local have
    have=$(docker version --format '{{.Client.Version}}' 2>/dev/null || true)
    if [[ "$have" != "$DOCKER_VERSION"* ]]; then
        echo "  Warning: DOCKER_VERSION=$DOCKER_VERSION, but Docker ${have:-unknown} is already installed. Leaving it as it is."
    fi
}

# Function to handle script exit gracefully
cleanup() {
    # Capture the script's real exit status FIRST so the trap's own commands
    # can never mask a failure with exit 0
    local rc=$?
    # On failure, revert any /etc/docker/daemon.json change made by this run
    if [[ $rc -ne 0 ]]; then
        restore_bridge_json
    fi
    # Never leave a partially written save archive behind
    if [[ -n "$SAVE_FILE_NAME" && -f "$SAVE_FILE_NAME.partial" ]]; then
        rm -f "$SAVE_FILE_NAME.partial" || true
        echo "  Removed partial save archive: $SAVE_FILE_NAME.partial"
    fi
    if [[ $CLEANUP_REQUIRED -eq 1 ]]; then
        echo "--- Performing image_pull_push cleanup"
        if [[ -d "$TEMP_DIR" ]]; then
            rm -rf "$TEMP_DIR"
            echo "  Removed temporary directory: $TEMP_DIR"
            echo "### Image Pull Push ended at $(date) ###"
        fi
    fi
    # Exit with the status the script was exiting with when the trap fired
    exit "$rc"
}
trap cleanup EXIT

# Function to check required commands up front, with a distro install hint
# (minimal cloud images frequently lack curl)
require_cmds() {
    local missing=()
    local cmd
    for cmd in "$@"; do
        if ! command -v "$cmd" &> /dev/null; then
            missing+=("$cmd")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "Error: Required command(s) not found: ${missing[*]}"
        case "$os_id" in
            ubuntu|debian)
                echo "  Hint: apt-get update && apt-get install -y ${missing[*]}"
                ;;
            rhel|centos|rocky|almalinux|fedora)
                echo "  Hint: dnf install -y ${missing[*]}"
                ;;
            sles|opensuse-leap)
                echo "  Hint: zypper install -y ${missing[*]}"
                ;;
        esac
        exit 1
    fi
}

# Function to perform validation checks
validate_prerequisites() {
    echo "--- Validating prerequisites"
    # Preflight: verify the commands this run will need before doing any work
    local required_cmds=(tar gzip)
    if [[ $PUSH_MODE -eq 1 || $REG_CERT_MODE -eq 1 ]]; then
        required_cmds+=(openssl)
    fi
    if [[ $AIR_GAPPED_MODE -eq 0 ]]; then
        # Online mode may need to fetch install_packages.sh / repo keys
        if [[ $SAVE_MODE -eq 1 ]] || ! command -v docker &> /dev/null; then
            required_cmds+=(curl)
        fi
    fi
    require_cmds "${required_cmds[@]}"
    # Create a temporary directory for intermediate files
    TEMP_DIR=$(mktemp -d -t image-pull-push-XXXXXXXX)
    CLEANUP_REQUIRED=1
    echo "  Created temporary directory: $TEMP_DIR"
    if [[ $AIR_GAPPED_MODE -eq 1 ]]; then
        if ! tar -xzf "$IMAGES_FILE" -C "$TEMP_DIR"; then
          echo "Error: Failed to extract the .tar.gz archive. Please ensure it is a valid tar.gz file."
          exit 1
        fi
    fi
    # If push or reg cert mode is enabled, get registry certificate
    if [[ $PUSH_MODE -eq 1 || $REG_CERT_MODE -eq 1 ]]; then
        install_registry_cert
    fi
    if [[ $REG_CERT_MODE -eq 1 ]]; then
        echo "  Registry certificate installed"
        echo "### Image Pull Push ended at $(date) ###"
        exit 0
    fi
    # Check for Docker
    if [[ $REG_CERT_MODE -eq 0 ]]; then
        if ! command -v docker &> /dev/null; then
            if [[ $SAVE_MODE -eq 1 ]]; then
                # Save the docker packages BEFORE installing docker: zypper only
                # resolves dependencies missing on this host, so saving after the
                # install produces bundles that cannot install docker on a fresh
                # SUSE host (P4-02)
                echo "--- Saving docker packages (before docker is installed)"
                save_docker_packages
                DOCKER_PACKAGES_SAVED=1
            fi
            install_docker
        else
            echo "  Docker CLI found."
            warn_docker_version
        fi
        if [[ $DOCKER_MODE -eq 1 ]]; then
            echo "  Docker installed"
            echo "### Image Pull Push ended at $(date) ###"
            exit 0
        fi
    fi
    # Store the list of image names to be managed (strip CR so CRLF manifests work)
    if [[ $AIR_GAPPED_MODE -eq 0 ]]; then
        readarray -t images_to_manage < <(tr -d '\r' < "$IMAGES_FILE" | grep -vE '^\s*#|^\s*$')
        if [[ ${#images_to_manage[@]} -eq 0 ]]; then
            echo "Error: The manifest file $IMAGES_FILE is empty or does not contain valid image names."
            exit 1
        fi
        normalize_images
    fi
}

os_type() {
    # Get OS information from /etc/os-release
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        source /etc/os-release
        os_id="$ID"
    else
        echo "Error: Unknown or unsupported OS $os_id."
        exit 1
    fi
}

create_bridge_json () {
  # Merge bip into an existing daemon.json instead of clobbering it, and track
  # exactly what this run changed so failure paths can revert only that
  if [[ ! -d /etc/docker ]]; then
      mkdir -p /etc/docker
      ETC_DOCKER_CREATED=1
  fi
  if [[ -f /etc/docker/daemon.json ]]; then
      if grep -q '"bip"' /etc/docker/daemon.json; then
          echo "  Existing /etc/docker/daemon.json already defines \"bip\", leaving it unchanged"
          return 0
      fi
      BRIDGE_JSON_BACKUP="$TEMP_DIR/daemon.json.bak"
      cp /etc/docker/daemon.json "$BRIDGE_JSON_BACKUP"
      if command -v jq &> /dev/null; then
          if ! jq --arg bip "$DOCKER_BRIDGE_CIDR" '. + {bip: $bip}' "$BRIDGE_JSON_BACKUP" > /etc/docker/daemon.json; then
              cp "$BRIDGE_JSON_BACKUP" /etc/docker/daemon.json
              echo "Error: Failed to merge bip into existing /etc/docker/daemon.json."
              exit 1
          fi
      elif command -v python3 &> /dev/null; then
          if ! python3 -c 'import json,sys; p="/etc/docker/daemon.json"; d=json.load(open(p)); d["bip"]=sys.argv[1]; f=open(p,"w"); json.dump(d,f,indent=2); f.write("\n")' "$DOCKER_BRIDGE_CIDR"; then
              cp "$BRIDGE_JSON_BACKUP" /etc/docker/daemon.json
              echo "Error: Failed to merge bip into existing /etc/docker/daemon.json."
              exit 1
          fi
      else
          echo "Warning: /etc/docker/daemon.json exists but neither jq nor python3 is available to merge \"bip\": \"$DOCKER_BRIDGE_CIDR\"."
          echo "         Leaving the existing file unchanged; set bip manually if a custom docker bridge CIDR is required."
          BRIDGE_JSON_BACKUP=""
          return 0
      fi
      BRIDGE_JSON_CHANGED=1
      echo "  Merged bip: $DOCKER_BRIDGE_CIDR into existing /etc/docker/daemon.json"
  else
      cat <<EOF | tee /etc/docker/daemon.json > /dev/null
{
  "bip": "$DOCKER_BRIDGE_CIDR"
}
EOF
      BRIDGE_JSON_CHANGED=1
      echo "  Created /etc/docker/daemon.json with bip: $DOCKER_BRIDGE_CIDR"
  fi
}

restore_bridge_json () {
    # Failure path: revert only what this run changed under /etc/docker.
    # Never remove /etc/docker wholesale — it can hold other registries'
    # certs.d and daemon settings this script does not own.
    if [[ $BRIDGE_JSON_CHANGED -eq 1 && $BRIDGE_JSON_COMMITTED -eq 0 ]]; then
        if [[ -n "$BRIDGE_JSON_BACKUP" && -f "$BRIDGE_JSON_BACKUP" ]]; then
            cp "$BRIDGE_JSON_BACKUP" /etc/docker/daemon.json 2>/dev/null || true
            echo "  Restored previous /etc/docker/daemon.json"
        else
            rm -f /etc/docker/daemon.json 2>/dev/null || true
            echo "  Removed /etc/docker/daemon.json created by this run"
        fi
        if [[ $ETC_DOCKER_CREATED -eq 1 ]]; then
            rmdir /etc/docker 2>/dev/null || true
        fi
        BRIDGE_JSON_CHANGED=0
    fi
}

select_docker_packages () {
    # Pick the per-distro docker package list up front so every path (online
    # install, air-gapped install, and save) uses the correct names. Docker CE
    # is not published for the SUSE family; the distro 'docker' package is used,
    # plus 'docker-compose' explicitly - callers (seaweedfs, harbor) need the
    # compose plugin and the base package is not guaranteed to recommend it.
    case "$os_id" in
        sles|opensuse-leap)
            DOCKER_PACKAGES=(docker docker-compose)
            ;;
    esac
    # Optional pins, in install_packages.sh's name=version form
    local i pkg version
    for i in "${!DOCKER_PACKAGES[@]}"; do
        pkg=${DOCKER_PACKAGES[$i]}
        case "$pkg" in
            docker-ce|docker-ce-cli|docker) version=$DOCKER_VERSION ;;
            containerd.io) version=$CONTAINERD_VERSION ;;
            docker-compose-plugin|docker-compose) version=$COMPOSE_VERSION ;;
            *) version="" ;;
        esac
        [[ -n "$version" ]] && DOCKER_PACKAGES[i]="$pkg=$version"
    done
    return 0
}

ensure_dnf_config_manager () {
    # 'dnf config-manager' is provided by dnf-plugins-core, which is absent on
    # minimal images
    if ! dnf config-manager --help &> /dev/null; then
        echo "  Installing dnf-plugins-core (provides 'dnf config-manager')"
        if ! dnf install -y dnf-plugins-core; then
            echo "Error: Failed to install dnf-plugins-core (required for 'dnf config-manager')."
            exit 1
        fi
    fi
}

ensure_docker_repo () {
    # Only (re)add the docker repository when it is not already configured
    case "$os_id" in
        ubuntu|debian)
            [[ -f /etc/apt/sources.list.d/docker.list ]] || add_docker_repo
            ;;
        rhel|centos|rocky|almalinux|fedora)
            [[ -f /etc/yum.repos.d/docker-ce.repo ]] || add_docker_repo
            ;;
        sles|opensuse-leap)
            : # distro repositories already provide the 'docker' package
            ;;
        *)
            add_docker_repo
            ;;
    esac
}

add_docker_repo () {
    echo "  Adding docker repository"
    case "$os_id" in
        ubuntu)
            install -m 0755 -d /etc/apt/keyrings
            curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
            chmod a+r /etc/apt/keyrings/docker.asc
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
            ;;
        debian)
            install -m 0755 -d /etc/apt/keyrings
            curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
            chmod a+r /etc/apt/keyrings/docker.asc
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
            ;;
        rhel)
            ensure_dnf_config_manager
            dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo
            ;;
        rocky|almalinux|centos)
            # Docker designates the 'centos' repo path for CentOS/Rocky/Alma
            ensure_dnf_config_manager
            dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
            ;;
        fedora)
            dnf-3 config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo
            ;;
        sles|opensuse-leap)
            : # no Docker CE repo for SUSE; the distro 'docker' package is used
            ;;
        *)
            echo "Error: Unsupported OS '$os_id'. Manual install of Docker required."
            exit 1
            ;;
    esac
}

ensure_el_kernel_modules () {
    # EL10 ships the legacy xtables match modules (xt_addrtype et al.) in
    # kernel-modules-extra, which stock Rocky/Alma/RHEL 10 cloud images omit.
    # dockerd cannot create its NAT chains without xt_addrtype and never starts (P4-01)
    case "$os_id" in
        rhel|centos|rocky|almalinux|fedora) ;;
        *) return 0 ;;
    esac
    if modprobe -n xt_addrtype &>/dev/null; then
        return 0
    fi
    local kver bundled
    kver=$(uname -r)
    echo "  Kernel module xt_addrtype is unavailable (the docker daemon requires it)."
    if [[ $AIR_GAPPED_MODE -eq 1 ]]; then
        # A bundle built on a host running this same kernel carries its kernel-modules-extra (spec 15, F1)
        bundled=$(bundled_modules_extra)
        if [[ "$bundled" == "kernel-modules-extra-$kver" ]]; then
            echo "  Installing kernel-modules-extra-$kver from the bundle..."
            pushd "$TEMP_DIR" >/dev/null
            if ! ./install_packages.sh offline "kernel-modules-extra-$kver"; then
                popd >/dev/null
                echo "Error: kernel-modules-extra-$kver from the bundle failed to install."
                exit 1
            fi
            popd >/dev/null
        else
            [[ -n "$bundled" ]] && echo "  The bundle carries $bundled, which is for another kernel: it was built on a host running ${bundled#kernel-modules-extra-}."
            echo "Error: install kernel-modules-extra for the running kernel from local media"
            echo "  (dnf install kernel-modules-extra-$kver), then re-run this script."
            exit 1
        fi
    else
        echo "  Installing kernel-modules-extra-$kver to match the running kernel..."
        if ! dnf install -y "kernel-modules-extra-$kver"; then
            # The running kernel's package has aged out of the repos: install the
            # latest kernel + modules instead, which only take effect after a reboot
            echo "  kernel-modules-extra for the running kernel is no longer available;"
            echo "  installing the latest kernel and kernel-modules-extra..."
            if ! dnf install -y kernel kernel-modules-extra; then
                echo "Error: Failed to install kernel-modules-extra. Docker cannot start without the xt_addrtype module."
                exit 1
            fi
            echo "Error: A newer kernel and kernel-modules-extra were installed, but the running kernel"
            echo "  ($kver) still has no xt_addrtype module. Reboot into the new kernel, then re-run this script."
            exit 1
        fi
    fi
    if ! modprobe xt_addrtype; then
        echo "Error: xt_addrtype still fails to load after installing kernel-modules-extra-$kver."
        exit 1
    fi
    echo "  xt_addrtype kernel module loaded."
}

# el_modules_extra_pkg: on an EL host, the running kernel's kernel-modules-extra when this host's repos still have it, so
# that a bundle carries it. A target built from the same image then gets xt_addrtype with no local media (spec 15, F1).
# Prints nothing elsewhere, and a note on stderr when the repos no longer have it.
el_modules_extra_pkg() {
    case "$os_id" in
        rhel|centos|rocky|almalinux|fedora) ;;
        *) return 0 ;;
    esac
    local pkg
    pkg="kernel-modules-extra-$(uname -r)"
    if [[ -n "$(dnf -q repoquery --available "$pkg" 2>/dev/null)" ]]; then
        echo "$pkg"
    else
        echo "  Note: $pkg isn't in this host's repos, so the bundle won't carry it. A target that lacks xt_addrtype will need it from local media." >&2
    fi
}

# bundled_modules_extra: the kernel-modules-extra package that the bundle's offline-packages.tar.gz carries, as
# kernel-modules-extra-<kernel>, or nothing
bundled_modules_extra() {
    local listing
    [[ -f "$TEMP_DIR/offline-packages.tar.gz" ]] || return 0
    listing=$(tar -tzf "$TEMP_DIR/offline-packages.tar.gz" 2>/dev/null) || return 0
    # tail, not head: head stops reading, and the writer then dies of SIGPIPE under pipefail
    sed -n 's#^.*/\(kernel-modules-extra-[0-9][^/]*\)\.rpm$#\1#p' <<< "$listing" | tail -n 1
}

install_docker() {
    echo "  Installing Docker for $os_id"
    create_bridge_json
    if [[ $AIR_GAPPED_MODE -eq 1 ]]; then
        pushd "$TEMP_DIR" >/dev/null
        ./install_packages.sh offline "${DOCKER_PACKAGES[@]}"
        popd >/dev/null
    else
        ensure_docker_repo
        fetch_install_packages
        "$TEMP_DIR/install_packages.sh" online "${DOCKER_PACKAGES[@]}"
    fi
    if ! command -v docker &> /dev/null; then
        echo "Error: Docker installation failed."
        exit 1
    fi
    ensure_el_kernel_modules
    if ! systemctl enable --now docker; then
        echo "Error: Failed to enable and start the docker service."
        exit 1
    fi
    if ! systemctl is-active --quiet docker; then
        echo "Error: The docker service is not active after 'systemctl enable --now docker'."
        exit 1
    fi
    usermod -aG docker "$user_name"
    # Docker is installed and running: the daemon.json change is now permanent
    BRIDGE_JSON_COMMITTED=1
}

save_docker_packages() {
    # Saving the docker packages must work regardless of whether docker is
    # already installed on this host: ensure the docker repo is configured and
    # verify a usable package archive was actually produced. Never skip
    # silently — the save archive contract includes offline-packages.tar.gz.
    ensure_docker_repo
    if [[ ! -f "$TEMP_DIR/install_packages.sh" ]]; then
        fetch_install_packages
    fi
    local extra
    extra=$(el_modules_extra_pkg)
    if ! "$TEMP_DIR/install_packages.sh" save "${DOCKER_PACKAGES[@]}" ${extra:+"$extra"}; then
        echo "Error: install_packages.sh failed to save the docker packages (${DOCKER_PACKAGES[*]}${extra:+ $extra})."
        exit 1
    fi
    if [[ ! -s offline-packages.tar.gz ]]; then
        echo "Error: install_packages.sh did not produce offline-packages.tar.gz. The save archive would be unable to install docker offline."
        exit 1
    fi
    # grep without -q: -q exits at first match and a large listing then dies of
    # SIGPIPE under pipefail, turning a good archive into a spurious failure.
    if ! tar -tzf offline-packages.tar.gz 2>/dev/null | grep -E '\.(deb|rpm)$' >/dev/null; then
        echo "Error: offline-packages.tar.gz contains no .deb/.rpm packages. Refusing to bundle an unusable docker package archive."
        exit 1
    fi
    mv offline-packages.tar.gz "$TEMP_DIR/offline-packages.tar.gz"
}

# generate_bundle_licenses <dir>: LICENSES/ for a save bundle (spec 15, Q9). A manifest of the OS packages in
# offline-packages.tar.gz, and a written offer for the GPL and LGPL ones: Docker's dependencies, iptables, and on EL the
# kernel's modules, on SUSE the SELinux policy. The container images are the user's choice, and each carries its own
# licences inside.
generate_bundle_licenses() {
    local dir="$1/LICENSES" pkgs="$1/offline-packages.tar.gz" listing=""
    mkdir -p "$dir"
    if [[ -f "$pkgs" ]]; then
        listing=$(tar -tzf "$pkgs" 2>/dev/null | sed -n 's#^.*/\([^/]*\.\(deb\|rpm\)\)$#  \1#p' | sort) || listing=""
    fi
    cat > "$dir/THIRD_PARTY_NOTICES.txt" <<EOF
Third-party components redistributed in this images-pull-push save bundle
Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)

Container images (images/images.tar.gz, listed in images/manifest.txt): the images this
bundle was asked to save. Each carries its own licence and notices inside the image.

OS packages in offline-packages.tar.gz, for installing Docker with no route out: Docker and
containerd (Apache-2.0), and what they need on this OS. Each package carries its own licence
(rpm -q --licensefiles <package>, or /usr/share/doc/<package>/copyright once installed). Some
are copyleft, for example iptables (GPL-2.0), on RHEL-family hosts the running kernel's
kernel-modules-extra (GPL-2.0), and on SUSE the SELinux policy packages (GPL-2.0). They are
covered by WRITTEN_OFFER.txt. The packages:
${listing:-  (none)}

install_packages.sh and image_pull_push.sh are Apache-2.0 (Chubtoad5).
EOF
    cat > "$dir/WRITTEN_OFFER.txt" <<EOF
WRITTEN OFFER FOR CORRESPONDING SOURCE CODE (GPL, LGPL)

This save bundle redistributes operating system packages in binary form, in
offline-packages.tar.gz. THIRD_PARTY_NOTICES.txt lists them. Some are licensed under the GNU
General Public License or the GNU Lesser General Public License.

The distributor of this bundle hereby makes a written offer, valid for three (3) years from the
date this bundle was created ($(date -u +%Y-%m-%d)), to give any third party who possesses this
bundle a complete machine-readable copy of the corresponding source code for those packages,
for a charge no more than the cost of physically performing the source distribution.

The source is also publicly available from the operating system distribution that each package
came from (for example, apt-get source <package> on Debian and Ubuntu).

To request the source on a physical medium, contact: ${LICENSE_OFFER_CONTACT}

This offer is independent of the Apache-2.0 license covering the scripts themselves.
EOF
}

install_registry_cert() {
    local registry_hostname registry_port
    registry_hostname=$(echo "$REGISTRY_URL" | cut -d':' -f1)
    registry_port=$(echo "$REGISTRY_URL" | cut -d':' -f2)
    local cert_path=""
    local update_cmd=""
    case "$os_id" in
        ubuntu|debian)
            cert_path="/usr/local/share/ca-certificates/$registry_hostname.crt"
            update_cmd="update-ca-certificates"
            ;;
        rhel|centos|rocky|almalinux|fedora)
            cert_path="/etc/pki/ca-trust/source/anchors/$registry_hostname.crt"
            update_cmd="update-ca-trust extract"
            ;;
        sles|opensuse-leap)
            cert_path="/etc/pki/trust/anchors/$registry_hostname.crt"
            update_cmd="update-ca-certificates"
            ;;
        *)
            echo "Error: Unsupported OS '$os_id'. Manual certificate installation may be required."
            exit 1
            ;;
    esac
    # Fetch to a temp file first so a failed retrieval never leaves an empty
    # or partial .crt in the trust anchors directory
    local tmp_cert="$TEMP_DIR/registry-cert.pem"
    echo "  Attempting to retrieve certificate chain for $registry_hostname:$registry_port"
    if ! openssl s_client -showcerts -connect "$registry_hostname:$registry_port" < /dev/null 2>/dev/null \
        | awk '/-----BEGIN CERTIFICATE-----/{incert=1} incert{print} /-----END CERTIFICATE-----/{incert=0}' > "$tmp_cert"; then
        echo "Error: Failed to retrieve certificate from '$REGISTRY_URL'. Please ensure the registry is accessible and the port is correct."
        exit 1
    fi
    if ! grep -q -- '-----BEGIN CERTIFICATE-----' "$tmp_cert" || ! openssl x509 -in "$tmp_cert" -noout &> /dev/null; then
        echo "Error: Did not receive a valid certificate from '$REGISTRY_URL'. Please ensure the registry is accessible and the port is correct."
        exit 1
    fi
    # Only (re)install the certificate and restart docker when the fetched
    # certificate differs from the one already installed
    if [[ -s "$cert_path" ]] && cmp -s "$tmp_cert" "$cert_path"; then
        echo "  Certificate for $registry_hostname already installed and unchanged, skipping trust store update and docker restart"
        return 0
    fi
    cp "$tmp_cert" "$cert_path"
    echo "  Certificate saved to $cert_path"
    echo "  Updating system certificate store with command: $update_cmd"
    if ! $update_cmd &> /dev/null; then
        echo "Error: Failed to update CA trust store. Please check the command output."
        exit 1
    fi
    if command -v docker &> /dev/null; then
        systemctl restart docker
    fi
}

mirror_fallback_for() {
    # Prints the mirror.gcr.io fallback reference for a Docker Hub image, or
    # nothing when the image cannot exist there (mirror.gcr.io only mirrors
    # Docker Hub). Bare official images need the 'library/' namespace.
    local image="$1"
    local first_part="${image%%/*}"
    local rest=""
    if [[ "$first_part" == "$image" ]]; then
        # Bare official image (e.g. 'nginx:latest') -> Docker Hub 'library/'
        echo "mirror.gcr.io/library/$image"
        return 0
    fi
    if [[ "$first_part" =~ [.:] ]] || [[ "$first_part" == "localhost" ]]; then
        # Image pinned to an explicit registry
        if [[ "$first_part" == "docker.io" || "$first_part" == "index.docker.io" || "$first_part" == "registry-1.docker.io" ]]; then
            rest="${image#*/}"
            if [[ "$rest" == */* ]]; then
                echo "mirror.gcr.io/$rest"
            else
                echo "mirror.gcr.io/library/$rest"
            fi
        fi
        # Any other registry: no fallback possible, print nothing
        return 0
    fi
    # user/repo form (e.g. 'rancher/local-path-provisioner') -> Docker Hub as-is
    echo "mirror.gcr.io/$image"
}

# docker_trims_password: true when this host's Docker CLI is older than 29.3. Those versions trim spaces at either end
# of the password docker login is given, on stdin too, so such a password can't log in (spec 21, measured in CI).
docker_trims_password() {
    local v
    v=$(docker version --format '{{.Client.Version}}' 2>/dev/null) || return 1
    [[ -n "$v" ]] || return 1
    [[ "$(printf '%s\n%s\n' "$v" 29.3.0 | sort -V | head -n 1)" != 29.3.0 ]]
}

# check_password_ends: a registry password with a space at either end needs Docker 29.3 or later. Checked before any
# image is pulled, so the run stops with the reason, not with "Failed to log in" after the pulls.
check_password_ends() {
    [[ -n "$REGISTRY_USER" ]] || return 0
    [[ "$REGISTRY_PASS" == [[:space:]]* || "$REGISTRY_PASS" == *[[:space:]] ]] || return 0
    if docker_trims_password; then
        echo "Error: The registry password starts or ends with a space, and this host's Docker CLI"
        echo "  ($(docker version --format '{{.Client.Version}}' 2>/dev/null)) is older than 29.3, whose docker login trims those spaces,"
        echo "  so the registry would refuse it. Use Docker 29.3 or later, or a password without them. Nothing has been changed."
        exit 1
    fi
}

login_to_registry() {
    echo "  Logging in to registry $REGISTRY_URL"
    if [[ -n "$REGISTRY_USER" ]]; then
        if ! docker login "$REGISTRY_URL" --username "$REGISTRY_USER" --password-stdin <<< "$REGISTRY_PASS" &> /dev/null; then
            echo "Error: Failed to log in to registry '$REGISTRY_URL' with the provided credentials."
            exit 1
        fi
    fi
    echo "  Login OK"
}

# --- Main Script Logic --- #

# When sourced by a test harness, stop here: only the functions above are wanted.
if [[ "${BASH_SOURCE[0]:-$0}" != "$0" ]]; then
    return 0
fi

# creds_follow <args after the registry...>: true when the next two arguments are the registry's user and password (I6,
# spec 21). They are whenever two or more follow the registry, whatever they say, so a password of push, keep, -f or
# --help is a password. A single word after the registry is a command, as in 'push <registry> keep', or else a user
# with no password, which is refused below.
creds_follow() { [[ $# -ge 2 ]]; }

# These two work for anyone, so they come before the root check. The scan walks the arguments exactly as the parser
# below does: -f's value, the commands, then the first other word after push or reg-cert is the registry, and the user
# and password follow it. Only a --help or --version the parser would see as a word of its own counts.
pre_args=("$@")
pre_cmd=0 pre_registry=0 pre_slots=0
for ((i = 0; i < ${#pre_args[@]}; i++)); do
    if [[ $pre_slots -gt 0 ]]; then pre_slots=$((pre_slots - 1)); continue; fi
    case "${pre_args[i]}" in
        -f) i=$((i + 1)) ;;
        docker|keep|save|lock) ;;
        push|reg-cert) pre_cmd=1 ;;
        --version) echo "$SCRIPT_VERSION"; exit 0 ;;
        -h|--help) usage 0 ;;
        *)
            if [[ $pre_cmd -eq 1 && $pre_registry -eq 0 ]]; then
                pre_registry=1
                if creds_follow "${pre_args[@]:i+1}"; then pre_slots=2; fi
            fi
            ;;
    esac
done

# Check if the script is running with root privileges
if [[ $EUID -ne 0 ]]; then
    echo "Error: This script must be run with sudo or as root."
    exit 1
fi

# Verify Operating System
os_type

# Select the per-distro docker package list (applies to every mode)
select_docker_packages

# Parse command-line parameters. The user and the password after the registry are taken by position (creds_follow).
cred_slots=0
registry_seen=0
while [[ $# -gt 0 ]]; do
    if [[ $cred_slots -gt 0 ]]; then
        if [[ $cred_slots -eq 2 ]]; then
            REGISTRY_USER="$1"
        else
            REGISTRY_PASS="$1"
        fi
        cred_slots=$((cred_slots - 1))
        shift
        continue
    fi
    case "$1" in
        -f)
            if [[ -z "${2:-}" ]]; then
                echo "Error: -f requires a file path."
                usage
            fi
            IMAGES_FILE="$2"
            shift # Skip the -f flag
            shift # Skip the file path
            ;;
        docker)
            DOCKER_MODE=1
            shift
            ;;
        reg-cert)
            REG_CERT_MODE=1
            shift
            ;;    
        keep)
            KEEP_MODE=1
            shift
            ;;
        save)
            SAVE_MODE=1
            shift
            ;;
        lock)
            LOCK_MODE=1
            shift
            ;;
        push)
            PUSH_MODE=1
            shift
            ;;
        *)
            # The registry, after push or reg-cert. The user and the password follow it, by position.
            if [[ ($PUSH_MODE -eq 1 || $REG_CERT_MODE -eq 1) && $registry_seen -eq 0 ]]; then
                REGISTRY_URL="$1"
                registry_seen=1
                if creds_follow "${@:2}"; then cred_slots=2; fi
            elif [[ ($PUSH_MODE -eq 1 || $REG_CERT_MODE -eq 1) && -z "$REGISTRY_USER" && $# -eq 1 ]]; then
                # One word after the registry that isn't a command: a user with no password, refused below
                REGISTRY_USER="$1"
            else
                echo "Error: Unknown parameter '$1'."
                usage
            fi
            shift
            ;;
    esac
done

# Check that a command was passed
if [[ $PUSH_MODE -eq 0 && $KEEP_MODE -eq 0 && $SAVE_MODE -eq 0 && $LOCK_MODE -eq 0 && $DOCKER_MODE -eq 0 && $REG_CERT_MODE -eq 0 ]]; then
    echo "Error: No command specified."
    usage
fi

# Check if the images file path was provided
if [[ $DOCKER_MODE -eq 0 && $REG_CERT_MODE -eq 0 ]]; then
    if [[ -z "$IMAGES_FILE" ]]; then
        echo "Error: The -f parameter is required."
        usage
    fi
    if [[ "$IMAGES_FILE" =~ \.tar\.gz$ ]]; then
      if [[ ! -s "$IMAGES_FILE" ]]; then
          echo "Error: Images file '$IMAGES_FILE' is empty."
          exit 1
      fi
      AIR_GAPPED_MODE=1
    fi
fi

# Check for air-gapped while in docker mode
if [[ $DOCKER_MODE -eq 1 ]]; then
    if [[ "$IMAGES_FILE" =~ \.tar\.gz$ ]]; then
        if [[ ! -s "$IMAGES_FILE" ]]; then
            echo "Error: Images file '$IMAGES_FILE' is empty."
            exit 1
        fi
        AIR_GAPPED_MODE=1
    fi
fi


# 'save' requires a text manifest; a .tar.gz input is already a saved archive
if [[ $SAVE_MODE -eq 1 && $AIR_GAPPED_MODE -eq 1 ]]; then
    echo "Error: 'save' cannot be used with a .tar.gz archive input. '$IMAGES_FILE' is already a saved archive; use 'keep' or 'push' with it."
    exit 1
fi

# 'lock' needs a text manifest too, and it does nothing else
if [[ $LOCK_MODE -eq 1 ]]; then
    if [[ $AIR_GAPPED_MODE -eq 1 ]]; then
        echo "Error: 'lock' cannot be used with a .tar.gz archive input. It needs a text manifest."
        exit 1
    fi
    if [[ $SAVE_MODE -eq 1 || $PUSH_MODE -eq 1 || $KEEP_MODE -eq 1 ]]; then
        echo "Error: 'lock' cannot be combined with other commands."
        exit 1
    fi
fi

# Validate push parameters
if [[ $PUSH_MODE -eq 1 || $REG_CERT_MODE -eq 1 ]]; then
    if [[ -z "$REGISTRY_URL" ]]; then
        echo "Error: <registry:port> is required when <push> or <reg-cert> is specified."
        usage
    fi
    if [[ $PUSH_MODE -eq 1 ]]; then
        if [[ -n "$REGISTRY_USER" ]] && [[ -z "$REGISTRY_PASS" ]]; then
            echo "Error: A password is required when a username is specified."
            usage
        fi
        # Spec 21: any printable password works. A registry login can't carry a : in the user name, where basic auth
        # splits, or a space at either end, which docker login trims, and neither can carry a control character.
        if [[ "$REGISTRY_USER" == *:* || "$REGISTRY_USER" == [[:space:]]* || "$REGISTRY_USER" == *[[:space:]] || "$REGISTRY_USER" == *[[:cntrl:]]* ]]; then
            echo "Error: The registry username can't contain ':' or a control character, or start or end with a space,"
            echo "  because a registry login can't carry them. Nothing has been changed."
            exit 1
        fi
        if [[ "$REGISTRY_PASS" == *[[:cntrl:]]* ]]; then
            echo "Error: The registry password can't contain a control character, such as a tab or a newline. Nothing has been changed."
            exit 1
        fi
    fi
fi

# Display runtime arguments
echo "### Image Pull Push started at $(date) ###"
echo "  VERSION: $SCRIPT_VERSION"
echo "  AIR-GAPPED MODE: $AIR_GAPPED_MODE"
echo "  PUSH IMAGES: $PUSH_MODE"
echo "  KEEP IMAGES: $KEEP_MODE"
echo "  SAVE IMAGES: $SAVE_MODE"
echo "  REGISTRY URL: $REGISTRY_URL"
echo "  REGISTRY USER: $REGISTRY_USER"
echo "  REGISTRY PASS: ${REGISTRY_PASS:+********}"
echo "  ONLY ADD CERT: $REG_CERT_MODE"
echo "  ONLY INSTALL DOCKER: $DOCKER_MODE"
echo "  OS: $os_id"

# Run preflight checks
validate_prerequisites
if [[ $PUSH_MODE -eq 1 ]]; then
    check_password_ends
fi

# Check and run air-gapped logic
if [[ $AIR_GAPPED_MODE -eq 1 ]]; then
    echo "--- Running air-gapped logic"
    if [[ ! -d "$TEMP_DIR/images" ]]; then
        echo "Error: The extracted archive does not contain an 'images' directory."
        exit 1
    fi
    TAR_IMAGE_FILE_IN_ARCHIVE=$(find "$TEMP_DIR/images" -type f -name "*.tar.gz")
    # Exactly one *.txt may exist in images/, or this breaks in this and older copies of the script.
    # That's why images.lock and HELPER_VERSION aren't named .txt.
    MANIFEST_FILE_IN_ARCHIVE=$(find "$TEMP_DIR/images" -type f -name "*.txt")
    if [[ ! -f "$TAR_IMAGE_FILE_IN_ARCHIVE" || ! -f "$MANIFEST_FILE_IN_ARCHIVE" ]]; then
        echo "Error: The extracted archive did not contain the expected images 'tar.gz' or a manifest '.txt' file."
        exit 1
    fi
    check_bundle_pinned "$TEMP_DIR/images/images.lock" "$MANIFEST_FILE_IN_ARCHIVE"
    echo "  Loading images from '$TAR_IMAGE_FILE_IN_ARCHIVE'"
    if ! docker load -i "$TAR_IMAGE_FILE_IN_ARCHIVE" &> /dev/null; then
        echo "Error: Failed to load images from the tar archive."
        exit 1
    fi
    readarray -t images_to_manage < <(tr -d '\r' < "$MANIFEST_FILE_IN_ARCHIVE" | grep -vE '^\s*#|^\s*$')
    if [[ ${#images_to_manage[@]} -eq 0 ]]; then
        echo "Error: The manifest file $MANIFEST_FILE_IN_ARCHIVE is empty or does not contain valid image names."
        exit 1
    fi
    # check_bundle_pinned has already applied PIN_STRICT, and to the lock file. This manifest is plain on purpose.
    PIN_STRICT=false normalize_images
    if [[ -f "$TEMP_DIR/images/images.lock" ]]; then
        verify_lock_file "$TEMP_DIR/images/images.lock"
    else
        echo "  Note: this bundle has no lock file, so its images can't be verified."
    fi
# Run remaining logic
elif [[ $SAVE_MODE -eq 1 || $PUSH_MODE -eq 1 || $KEEP_MODE -eq 1 || $LOCK_MODE -eq 1 ]]; then
    echo "--- Starting image pull process"
    failed_pulls=()
    for image in "${images_to_manage[@]}"; do
        pull_successful=false
        ref=$(pull_ref "$image")
        echo "  pulling image: $ref"
        if docker pull -q "$ref" &> /dev/null; then
            echo "  successfully pulled from original source."
            if [[ "$ref" == "$image" ]] || docker tag "$ref" "$image" &> /dev/null; then
                pull_successful=true
            else
                echo "Error: Failed to tag '$ref' as '$image'."
            fi
        else
            # Construct the mirror image URL; empty when the image can never
            # exist on mirror.gcr.io (it only mirrors Docker Hub)
            mirror_image=$(mirror_fallback_for "$image")
            if [[ -z "$mirror_image" ]]; then
                echo "  initial pull failed; not a Docker Hub image, no mirror.gcr.io fallback possible"
            else
                # A pinned image stays pinned on the mirror, so the mirror can't substitute a different image
                if [[ "$ref" != "$image" ]]; then
                    mirror_image="${mirror_image%:*}@${IMAGE_DIGEST[$image]}"
                fi
                echo "  initial pull failed, retrying with $mirror_image"
                if docker pull -q "$mirror_image" &> /dev/null; then
                    echo "  successfully pulled from mirror.gcr.io, retagging to '$image'"
                    if docker tag "$mirror_image" "$image" &> /dev/null; then
                        pull_successful=true
                        # Remove the temporary mirror tag created by this run;
                        # the image remains under its canonical tag
                        docker rmi "$mirror_image" &> /dev/null || true
                    else
                        echo "Error: Failed to retag '$mirror_image' to '$image'."
                        docker rmi "$mirror_image" &> /dev/null || true
                    fi
                fi
            fi
        fi
        if [[ "$pull_successful" = false ]]; then
            echo "Warning: Failed to pull image '$image' from both sources."
            failed_pulls+=("$image")
        fi
    done
    if [[ ${#failed_pulls[@]} -gt 0 ]]; then
        echo "--- Summary of failed pulls"
        for img in "${failed_pulls[@]}"; do
            echo "  failed: $img"
        done
        # Exit if any image pull failed, as this is for automation
        echo "Critical: One or more images failed to pull. Exiting."
        exit 1
    fi
    echo "--- All images pulled successfully"
    if [[ $LOCK_MODE -eq 1 ]]; then
        : > images.pinned.txt
        for image in "${images_to_manage[@]}"; do
            digest=${IMAGE_DIGEST[$image]:-}
            [[ -n "$digest" ]] || digest=$(image_digest "$image") || {
                echo "Error: Docker has no registry digest for '$image'."
                exit 1
            }
            echo "$image@$digest" >> images.pinned.txt
        done
        echo "  Wrote images.pinned.txt"
        echo "### Image Pull Push ended at $(date) ###"
        exit 0
    fi
    # Save images if specified
    if [[ $SAVE_MODE -eq 1 ]]; then
        SAVE_FILE_NAME="container_images_$(date +%Y%m%d_%H%M%S).tar.gz"
        if [[ $DOCKER_PACKAGES_SAVED -eq 0 ]]; then
            echo "--- Saving docker packages"
            save_docker_packages
        fi
        echo "--- Saving and compressing images"
        mkdir -p "$TEMP_DIR/images"
        if ! docker save "${images_to_manage[@]}" | gzip > "$TEMP_DIR/images/images.tar.gz"; then
            echo "Error: Failed to save or compress images to a tar.gz file."
            exit 1
        fi
        # The manifest stays plain repo:tag lines, so an older copy of this script can still use this bundle.
        # What each image really is goes in images.lock.
        printf '%s\n' "${images_to_manage[@]}" > "$TEMP_DIR/images/manifest.txt"
        write_lock_file "$TEMP_DIR/images/images.lock"
        echo "$SCRIPT_VERSION" > "$TEMP_DIR/images/HELPER_VERSION"
        generate_bundle_licenses "$TEMP_DIR"
        echo "--- Creating image_pull_push archive '$SAVE_FILE_NAME'"
        # Write to a temporary name, then rename atomically, so an interrupted
        # save never leaves a truncated archive matching container_images_*.tar.gz
        if ! tar -czf "$SAVE_FILE_NAME.partial" -C "$TEMP_DIR" "images" "offline-packages.tar.gz" "install_packages.sh" "LICENSES"; then
            echo "Error: Failed to create the final tar.gz archive."
            exit 1
        fi
        mv "$SAVE_FILE_NAME.partial" "$SAVE_FILE_NAME"
        echo "  Save archive created: $SAVE_FILE_NAME"
    fi
else
    echo "Error: No mode specified. Use 'keep', 'save' or 'push'."
    usage
fi

# Push images if specified
if [[ $PUSH_MODE -eq 1 ]]; then
    echo "--- Starting image push process"
    # Check if a manifest exists to push images from
    if [[ ${#images_to_manage[@]} -eq 0 ]]; then
        echo "Error: No images found to push. Check your input file or manifest."
        exit 1
    fi
    login_to_registry
    failed_pushes=()
    for image in "${images_to_manage[@]}"; do
        image_path_and_tag=""
        if [[ "$image" =~ / ]]; then
            # Check if the first path segment looks like a registry. Only
            # meaningful when the name has a '/' - on a bare name the "first
            # segment" is the whole ref, and a dotted TAG (alpine:3.20) would
            # be mistaken for a hostname, silently skipping the library/ rule.
            first_part=$(echo "$image" | cut -d'/' -f1)
            if [[ "$first_part" =~ \. ]] || [[ "$first_part" =~ : ]] || [[ "$first_part" == "localhost" ]]; then
                # If it's a registry (dot, port, or localhost), strip it
                image_path_and_tag=$(echo "$image" | cut -d'/' -f2-)
            else
                # A path but not a registry (e.g., longhornio/...), use the whole path
                image_path_and_tag="$image"
            fi
        else
            # For official Docker Hub images (e.g., 'ubuntu'), prepend 'library/'
            image_path_and_tag="library/$image"
        fi
        # Construct the new tag using the target registry and the extracted path
        new_tag="$REGISTRY_URL/$image_path_and_tag"
        echo "  tagging '$image' as '$new_tag'"
        if ! docker tag "$image" "$new_tag" &> /dev/null; then
            echo "Error: Failed to tag image '$image'. Skipping push for this image."
            failed_pushes+=("$image")
            continue
        fi
        # Push the tagged image
        echo "  pushing '$new_tag' to registry"
        if ! docker push -q "$new_tag" &> /dev/null; then
            echo "Error: Failed to push image '$new_tag'. Skipping."
            failed_pushes+=("$image")
            continue
        fi
        if ! docker rmi "$new_tag" &> /dev/null; then
            # The removal of the tag failed, but it's not a critical error for the overall script.
            echo "Warning: Failed to remove temporary tag '$new_tag'."
        fi
    done
    if [[ ${#failed_pushes[@]} -gt 0 ]]; then
        echo "--- Summary of failed pushes"
        for img in "${failed_pushes[@]}"; do
            echo "  failed to push: $img"
        done
        echo "Warning: One or more images failed to push."
        exit 1
    fi
    echo "--- All images pushed successfully"
fi

# Delete local images only if push was successful AND keep was NOT specified
if [[ $PUSH_MODE -eq 1 ]] && [[ ${#images_to_manage[@]} -gt 0 ]] && [[ ${#failed_pushes[@]} -eq 0 ]] && [[ $KEEP_MODE -eq 0 ]]; then
    echo "--- Deleting local images"
    if ! docker rmi "${images_to_manage[@]}" &> /dev/null; then
        echo "Warning: Could not delete all local images. Some may still exist."
    fi
    # A pinned image also has a repo@digest reference, which would otherwise keep it alive
    for image in "${!IMAGE_DIGEST[@]}"; do
        docker rmi "$(pull_ref "$image")" &> /dev/null || true
    done
fi
exit 0