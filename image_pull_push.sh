#!/bin/bash

# --- Script Configuration ---
# Set strict mode to catch errors early
set -o errexit
set -o nounset
set -o pipefail

# --- Global Variables ---
SCRIPT_NAME=$(basename "$0")
IMAGES_FILE=""
SAVE_MODE=0
PUSH_MODE=0
KEEP_MODE=0
REG_CERT_MODE=0
DOCKER_MODE=0
AIR_GAPPED_MODE=0
REGISTRY_URL=""
REGISTRY_USER=""
REGISTRY_PASS=""
CLEANUP_REQUIRED=0
ADD_REG_CERT=0
TEMP_DIR=""
user_name=${SUDO_USER:-$(whoami)}
DOCKER_BRIDGE_CIDR=${DOCKER_BRIDGE_CIDR:-"172.30.0.1/16"}
DOCKER_PACKAGES=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)
os_id=""
images_to_manage=()
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

Parameters:
  -f <file_path>     : File path containing names tags of container images (one per line)
                         Alternate: A .tar.gz file created by this script (air-gapped mode)
  Commands:
    [keep]           : Pulls images locally
    [save]           : Saves images and manifest to a single tar.gz
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
EOF
    exit 1
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
            install_docker
        else
            echo "  Docker CLI found."
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

install_docker() {
    echo "  Installing Docker for $os_id"
    create_bridge_json
    if [[ $AIR_GAPPED_MODE -eq 1 ]]; then
        pushd "$TEMP_DIR" >/dev/null
        ./install_packages.sh offline "${DOCKER_PACKAGES[@]}"
        popd >/dev/null
    else
        ensure_docker_repo
        if ! curl -fsSL https://github.com/Chubtoad5/install-packages/raw/refs/heads/main/install_packages.sh -o "$TEMP_DIR/install_packages.sh"; then
            echo "Error: Failed to download install_packages.sh."
            exit 1
        fi
        chmod +x "$TEMP_DIR/install_packages.sh"
        "$TEMP_DIR/install_packages.sh" online "${DOCKER_PACKAGES[@]}"
    fi
    if ! command -v docker &> /dev/null; then
        echo "Error: Docker installation failed."
        exit 1
    fi
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
        if ! curl -fsSL https://github.com/Chubtoad5/install-packages/raw/refs/heads/main/install_packages.sh -o "$TEMP_DIR/install_packages.sh"; then
            echo "Error: Failed to download install_packages.sh."
            exit 1
        fi
        chmod +x "$TEMP_DIR/install_packages.sh"
    fi
    if ! "$TEMP_DIR/install_packages.sh" save "${DOCKER_PACKAGES[@]}"; then
        echo "Error: install_packages.sh failed to save the docker packages (${DOCKER_PACKAGES[*]})."
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

install_registry_cert() {
    local registry_hostname=$(echo "$REGISTRY_URL" | cut -d':' -f1)
    local registry_port=$(echo "$REGISTRY_URL" | cut -d':' -f2)
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

# Check if the script is running with root privileges
if [[ $EUID -ne 0 ]]; then
    echo "Error: This script must be run with sudo or as root."
    exit 1
fi

# Verify Operating System
os_type

# Select the per-distro docker package list (applies to every mode)
select_docker_packages

# Parse command-line parameters
while [[ $# -gt 0 ]]; do
    case "$1" in
        -f)
            if [[ -z "$2" ]]; then
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
        push)
            PUSH_MODE=1
            shift
            ;;
        *)
            # Handle registry URL, username, and password
            if [[ $PUSH_MODE -eq 1 || $REG_CERT_MODE -eq 1 ]]; then
                if [[ -z "$REGISTRY_URL" ]]; then
                    REGISTRY_URL="$1"
                elif [[ -z "$REGISTRY_USER" ]]; then
                    REGISTRY_USER="$1"
                elif [[ -z "$REGISTRY_PASS" ]]; then
                    REGISTRY_PASS="$1"
                else
                    echo "Error: Unknown parameter '$1'."
                    usage
                fi
            else
                echo "Error: Unknown parameter '$1'."
                usage
            fi
            shift
            ;;
    esac
done

# Check that a command was passed
if [[ $PUSH_MODE -eq 0 && $KEEP_MODE -eq 0 && $SAVE_MODE -eq 0 && $DOCKER_MODE -eq 0 && $REG_CERT_MODE -eq 0 ]]; then
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
    fi
fi

# Display runtime arguments
echo "### Image Pull Push started at $(date) ###"
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

# Check and run air-gapped logic
if [[ $AIR_GAPPED_MODE -eq 1 ]]; then
    echo "--- Running air-gapped logic"
    if [[ ! -d "$TEMP_DIR/images" ]]; then
        echo "Error: The extracted archive does not contain an 'images' directory."
        exit 1
    fi
    TAR_IMAGE_FILE_IN_ARCHIVE=$(find "$TEMP_DIR/images" -type f -name "*.tar.gz")
    MANIFEST_FILE_IN_ARCHIVE=$(find "$TEMP_DIR/images" -type f -name "*.txt")
    if [[ ! -f "$TAR_IMAGE_FILE_IN_ARCHIVE" || ! -f "$MANIFEST_FILE_IN_ARCHIVE" ]]; then
        echo "Error: The extracted archive did not contain the expected images 'tar.gz' or a manifest '.txt' file."
        exit 1
    fi
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
# Run remaining logic
elif [[ $SAVE_MODE -eq 1 || $PUSH_MODE -eq 1 || $KEEP_MODE -eq 1 ]]; then
    echo "--- Starting image pull process"
    failed_pulls=()
    for image in "${images_to_manage[@]}"; do
        pull_successful=false
        echo "  pulling image: $image"
        if docker pull -q "$image" &> /dev/null; then
            echo "  successfully pulled from original source."
            pull_successful=true
        else
            # Construct the mirror image URL; empty when the image can never
            # exist on mirror.gcr.io (it only mirrors Docker Hub)
            mirror_image=$(mirror_fallback_for "$image")
            if [[ -z "$mirror_image" ]]; then
                echo "  initial pull failed; not a Docker Hub image, no mirror.gcr.io fallback possible"
            else
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
    # Save images if specified
    if [[ $SAVE_MODE -eq 1 ]]; then
        SAVE_FILE_NAME="container_images_$(date +%Y%m%d_%H%M%S).tar.gz"
        echo "--- Saving docker packages"
        save_docker_packages
        echo "--- Saving and compressing images"
        mkdir -p "$TEMP_DIR/images"
        if ! docker save "${images_to_manage[@]}" | gzip > "$TEMP_DIR/images/images.tar.gz"; then
            echo "Error: Failed to save or compress images to a tar.gz file."
            exit 1
        fi
        # Copy the original images list (CR-stripped) into the archive manifest
        tr -d '\r' < "$IMAGES_FILE" > "$TEMP_DIR/images/manifest.txt"
        echo "--- Creating image_pull_push archive '$SAVE_FILE_NAME'"
        # Write to a temporary name, then rename atomically, so an interrupted
        # save never leaves a truncated archive matching container_images_*.tar.gz
        if ! tar -czf "$SAVE_FILE_NAME.partial" -C "$TEMP_DIR" "images" "offline-packages.tar.gz" "install_packages.sh"; then
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
        # Check if the first part of the name looks like a registry
        first_part=$(echo "$image" | cut -d'/' -f1)
        if [[ "$first_part" =~ \. ]] || [[ "$first_part" == "localhost" ]]; then
            # If it's a registry, strip it and use the rest of the path
            image_path_and_tag=$(echo "$image" | cut -d'/' -f2-)
        elif [[ "$image" =~ / ]]; then
            # If it has a path but not a registry (e.g., longhornio/...), use the whole path
            image_path_and_tag="$image"
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
fi
exit 0