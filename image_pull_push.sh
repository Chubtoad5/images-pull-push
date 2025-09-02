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
AIR_GAPPED_MODE=0
REGISTRY_URL=""
REGISTRY_USER=""
REGISTRY_PASS=""
CLEANUP_REQUIRED=0
ADD_REG_CERT=0
TEMP_DIR=""
user_name=$SUDO_USER
DOCKER_BRIDGE_CIDR=172.30.0.1/16
DOCKER_PACKAGES=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)
os_id=""

# --- Helper Functions ---

# Function to display a usage message
usage() {
    cat << EOF
Usage: $SCRIPT_NAME -f <path_to_images_or_manifest_file> [keep] [save] [push <registry:port> [<username> <password>]]

This script must be run with root privileges.

Parameters:
  -f <path_to_images_file>   : Path to the file containing a list of container images and tags (one per line).
                               Alternatively, this can be a .tar.gz file created by this script for air-gapped mode.
  <keep>                     : Optional. If specified, the script will NOT delete the images from the local Docker daemon at the end.
  <save>                     : Optional. If specified, saves the images and manifest to a .tar.gz file.
  <push>                     : Optional. Pushes the images to a specified registry after saving.
  <registry:port>            : Required when <push> is specified. The target registry URL and port.
  <username>                 : Optional. The username for the registry.
  <password>                 : Optional. Required when <username> is specified. The password for the registry.

Example:
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
    if [[ $CLEANUP_REQUIRED -eq 1 ]]; then
        echo "Performing cleanup..."
        if [[ -d "$TEMP_DIR" ]]; then
            rm -rf "$TEMP_DIR"
            echo "Removed temporary directory: $TEMP_DIR"
        fi
    fi
    # Exit with the last command's status
    exit $?
}
trap cleanup EXIT

# Function to perform validation checks
validate_prerequisites() {
    echo "--- Performing prerequisite checks ---"
    if [[ "$IMAGES_FILE" =~ \.tar\.gz$ ]]; then
      AIR_GAPPED_MODE=1
      echo "--- Air-gapped mode detected ---"
      echo "Extracting '$IMAGES_FILE'..."
      if ! tar -xzf "$IMAGES_FILE" -C "$TEMP_DIR"; then
        echo "Error: Failed to extract the .tar.gz archive. Please ensure it is a valid tar.gz file."
        exit 1
      fi
    fi
    # Check for Docker
    if ! command -v docker &> /dev/null; then
        echo "Warning: Docker CLI is not installed. Script will attempt to install it."
        install_docker
    else
        echo "Docker CLI found."
    fi
    # IF push is enabled, get registry certificate
    if [[ PUSH_MODE -eq 1 ]]; then
        # Check for OpenSSL
        if ! command -v openssl &> /dev/null; then
            echo "Error: openssl is not installed. Please install it with your system's package manager."
            exit 1
        fi
        echo "OpenSSL found."
        install_registry_cert
    fi
    echo "--- Prerequisite checks complete ---"
}

# Function to validate the images file
validate_images_file() {
    if [[ ! -f "$IMAGES_FILE" ]]; then
        echo "Error: Images file '$IMAGES_FILE' not found."
        exit 1
    fi
    if [[ ! -s "$IMAGES_FILE" ]]; then
        echo "Error: Images file '$IMAGES_FILE' is empty."
        exit 1
    fi
    echo "Images file '$IMAGES_FILE' is valid."
}

os_type() {
    # Get OS information from /etc/os-release
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        source /etc/os-release
        echo "OS type is: $ID"
        os_id="$ID"
    else
        echo "Unknown or unsupported OS $os_id."
        exit 1
    fi
}

create_bridge_json () {
  echo "pre-creating docker bridge json..."
  mkdir -p /etc/docker
  cat <<EOF | tee /etc/docker/daemon.json > /dev/null
{
  "bip": "$DOCKER_BRIDGE_CIDR"
}
EOF
  echo "Created /etc/docker/daemon.json with bip: $DOCKER_BRIDGE_CIDR"
}

install_docker() {
    create_bridge_json
    # check for airgapped and different OS version installs
    if [[ $AIR_GAPPED_MODE -eq 1 ]]; then
        # use helper script offline mode
        $TEMP_DIR/install_packages.sh offline "${DOCKER_PACKAGES[@]}"
    else
        # import docker repos before running helper script
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
            rhel|rocky|almalinux)
                dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo
                ;;
            centos)
                dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
                ;;
            fedora)
                dnf-3 config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo
                ;;
            *)
                echo "Error: Unsupported OS '$os_id'. Manual install of Docker required."
                rm -rf /etc/docker
                exit 1
                ;;
        esac
        # use helper script online mode
        curl -fsSL https://github.com/Chubtoad5/install-packages/raw/refs/heads/main/install_packages.sh -o $TEMP_DIR/install_packages.sh
        chmod +x $TEMP_DIR/install_packages.sh
        $TEMP_DIR/install_packages.sh online "${DOCKER_PACKAGES[@]}"
    fi
    # install using helper script
    if ! command -v docker &> /dev/null; then
        echo "Error: Docker installation failed."
        rm -rf /etc/docker
        exit 1
    fi
    usermod -aG docker $user_name
}

save_docker_packages() {
    echo "Creating offline Docker package..."
    if [[ ! -f $TEMP_DIR/install_packages.sh ]]; then
        curl -fsSL https://github.com/Chubtoad5/install-packages/raw/refs/heads/main/install_packages.sh -o $TEMP_DIR/install_packages.sh
        chmod +x $TEMP_DIR/install_packages.sh
    fi
    $TEMP_DIR/install_packages.sh save "${DOCKER_PACKAGES[@]}"
    mv offline-packages.tar.gz $TEMP_DIR/offline-packages.tar.gz
}

# Function to get and install the registry certificate based on OS
install_registry_cert() {
    echo "Registry URL is $REGISTRY_URL"
    local registry_hostname=$(echo "$REGISTRY_URL" | cut -d':' -f1)
    local registry_port=$(echo "$REGISTRY_URL" | cut -d':' -f2)
    local cert_path=""
    local update_cmd=""

    # Determine the correct certificate path and update command based on OS family
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
            cert_path="/etc/pki/ca-trust/source/anchors/$registry_hostname.crt"
            update_cmd="update-ca-trust extract"
            ;;
        *)
            echo "Error: Unsupported OS '$os_id'. Manual certificate installation may be required."
            exit 1
            ;;
    esac

    echo "Attempting to retrieve certificate for $registry_hostname:$registry_port..."
    
    # Use OpenSSL to connect and get the certificate
    if openssl s_client -showcerts -connect "$registry_hostname:$registry_port" < /dev/null 2>/dev/null | openssl x509 -outform PEM > "$cert_path"; then
        echo "Certificate saved to $cert_path."
        echo "Updating system certificate store with command: $update_cmd..."
        if ! $update_cmd &> /dev/null; then
            echo "Error: Failed to update CA trust store. Please check the command output."
            exit 1
        fi
        echo "Certificate store updated successfully."
    else
        echo "Error: Failed to retrieve certificate from '$REGISTRY_URL'. Please ensure the registry is accessible and the port is correct."
        exit 1
    fi
}

# Function to login to the registry
login_to_registry() {
    echo "Logging in to registry $REGISTRY_URL..."
    if [[ -n "$REGISTRY_USER" ]]; then
        if ! docker login "$REGISTRY_URL" --username "$REGISTRY_USER" --password-stdin <<< "$REGISTRY_PASS" &> /dev/null; then
            echo "Error: Failed to log in to registry '$REGISTRY_URL' with the provided credentials."
            exit 1
        fi
    fi
    echo "Logged in to registry."
}

# --- Main Script Logic ---

# Check if the script is running with root privileges
if [[ $EUID -ne 0 ]]; then
    echo "Error: This script must be run with sudo or as root."
    usage
fi

# Grab OS type
os_type

# Create a temporary directory for intermediate files
TEMP_DIR=$(mktemp -d -t docker-pull-push-XXXXXXXX)
CLEANUP_REQUIRED=1
echo "Created temporary directory: $TEMP_DIR"

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
            if [[ $PUSH_MODE -eq 1 ]]; then
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

# Check if the images file path was provided
if [[ -z "$IMAGES_FILE" ]]; then
    echo "Error: The -f parameter is required."
    usage
fi

# Validate push parameters
if [[ $PUSH_MODE -eq 1 ]]; then
    if [[ -z "$REGISTRY_URL" ]]; then
        echo "Error: <registry:port> is required when <push> is specified."
        usage
    fi
    if [[ -n "$REGISTRY_USER" ]] && [[ -z "$REGISTRY_PASS" ]]; then
        echo "Error: A password is required when a username is specified."
        usage
    fi
fi

# Run preflight checks
validate_prerequisites

# Validate the images file
validate_images_file

# Store the list of image names to be managed
declare -a images_to_manage

# --- Check if air-gapped mode is active ---
if [[ $AIR_GAPPED_MODE -eq 1 ]]; then
    
    echo "--- Handling container images in Air-gapped mode ---"
        
    # Find the images.tar and the original manifest file
    TAR_IMAGE_FILE_IN_ARCHIVE="$TEMP_DIR/images.tar.gz"
    MANIFEST_FILE_IN_ARCHIVE=$(find "$TEMP_DIR" -type f -name "*.txt")
    
    if [[ ! -f "$TAR_IMAGE_FILE_IN_ARCHIVE" || ! -f "$MANIFEST_FILE_IN_ARCHIVE" ]]; then
        echo "Error: The .tar.gz archive does not contain the expected 'images.tar' or a manifest .txt file."
        exit 1
    fi

    echo "Loading images from '$TAR_IMAGE_FILE_IN_ARCHIVE'..."
    if ! docker load -i "$TAR_IMAGE_FILE_IN_ARCHIVE" &> /dev/null; then
        echo "Error: Failed to load images from the tar archive."
        exit 1
    fi
    echo "Images loaded successfully."

    # Read the list of images from the manifest file
    echo "Reading image list from manifest file '$MANIFEST_FILE_IN_ARCHIVE'..."
    readarray -t images_to_manage < <(grep -vE '^\s*#|^\s*$' "$MANIFEST_FILE_IN_ARCHIVE")
    
    if [[ ${#images_to_manage[@]} -eq 0 ]]; then
        echo "Error: The manifest file is empty or does not contain valid image names."
        exit 1
    fi
    
# --- If not air-gapped, proceed with normal pull/save/push flow ---
elif [[ $SAVE_MODE -eq 1 || $PUSH_MODE -eq 1 || $KEEP_MODE -eq 1 ]]; then

    # Get images from the provided images list file
    readarray -t images_to_manage < <(grep -vE '^\s*#|^\s*$' "$IMAGES_FILE")

    echo "--- Starting image pull process ---"
    failed_pulls=()
    for image in "${images_to_manage[@]}"; do
        pull_successful=false
        echo "Pulling image: $image"
        
        # Attempt to pull from the original source
        if docker pull -q "$image" &> /dev/null; then
            echo "Successfully pulled from original source."
            pull_successful=true
        else
            echo "Initial pull failed. Retrying with mirror.gcr.io..."
            
            # Construct the mirror image URL
            mirror_image="mirror.gcr.io/$image"
            
            # Attempt to pull from the mirror
            if docker pull -q "$mirror_image"; then
                echo "Successfully pulled from mirror.gcr.io. Retagging image..."
                # Retag the image with its original name
                if docker tag "$mirror_image" "$image" &> /dev/null; then
                    echo "Successfully retagged to '$image'."
                    pull_successful=true
                else
                    echo "Error: Failed to retag '$mirror_image' to '$image'."
                    # Remove the mirror image to prevent a partial success
                    docker rmi "$mirror_image" &> /dev/null || true
                fi
            fi
        fi
        
        if [[ "$pull_successful" = false ]]; then
            echo "Warning: Failed to pull image '$image' from both sources."
            failed_pulls+=("$image")
        fi
    done

    if [[ ${#failed_pulls[@]} -gt 0 ]]; then
        echo "--- Summary of failed pulls ---"
        for img in "${failed_pulls[@]}"; do
            echo "Failed: $img"
        done
        # Exit if any image pull failed, as this is for automation
        echo "Critical: One or more images failed to pull. Exiting."
        exit 1
    fi
    echo "--- All images pulled successfully ---"

    # Save images if specified
    if [[ $SAVE_MODE -eq 1 ]]; then
        echo "--- Starting image save process ---"
        SAVE_FILE_NAME="container_images_$(date +%Y%m%d_%H%M%S).tar.gz"
        
        # Create docker offline packages
        save_docker_packages
        # Create a compressed tarball of the images directly from docker save stream
        echo "Saving and compressing images..."
        docker save "${images_to_manage[@]}" | gzip > "$TEMP_DIR/images.tar.gz"
        
        if [[ $? -ne 0 ]]; then
            echo "Error: Failed to save or compress images to a tar.gz file."
            exit 1
        fi

        # Copy the original images list file to the temporary directory
        cp "$IMAGES_FILE" "$TEMP_DIR/manifest.txt"
        
        # Combine the compressed images tarball and the manifest into the final deliverable
        echo "Combining compressed images and manifest into final archive '$SAVE_FILE_NAME'..."
        tar -czf "$SAVE_FILE_NAME" -C "$TEMP_DIR" "images.tar.gz" "manifest.txt" "offline-packages.tar.gz" "install_packages.sh"
        if [[ $? -ne 0 ]]; then
            echo "Error: Failed to create the final tar.gz archive."
            exit 1
        fi

        echo "Images and manifest saved to '$SAVE_FILE_NAME'."
    fi
else
    # Catch all for invalid parameters
    echo "Error: No mode specified. Use 'keep', 'save' or 'push'."
    usage
fi

# Push images if specified
if [[ $PUSH_MODE -eq 1 ]]; then
    echo "--- Starting image push process ---"
    
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
        # A registry name contains a '.' or is 'localhost'
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
        
        echo "Tagging '$image' as '$new_tag'..."
        if ! docker tag "$image" "$new_tag" &> /dev/null; then
            echo "Error: Failed to tag image '$image'. Skipping push for this image."
            failed_pushes+=("$image")
            continue
        fi
        
        # Push the tagged image
        echo "Pushing '$new_tag' to registry..."
        if ! docker push -q "$new_tag" &> /dev/null; then
            echo "Error: Failed to push image '$new_tag'. Skipping."
            failed_pushes+=("$image")
            continue
        fi
        
        # Clean up the new tag
        echo "Push successful. Removing temporary tag '$new_tag'..."
        if ! docker rmi "$new_tag" &> /dev/null; then
            # The removal of the tag failed, but it's not a critical error for the overall script.
            # We can print a warning but allow the script to continue.
            echo "Warning: Failed to remove temporary tag '$new_tag'."
        fi
    done
    
    if [[ ${#failed_pushes[@]} -gt 0 ]]; then
        echo "--- Summary of failed pushes ---"
        for img in "${failed_pushes[@]}"; do
            echo "Failed to push: $img"
        done
        echo "Warning: One or more images failed to push."
        exit 1
    fi
    echo "--- All images pushed successfully ---"
fi

# Delete local images only if push was successful AND keep was NOT specified
if [[ $PUSH_MODE -eq 1 ]] && [[ ${#images_to_manage[@]} -gt 0 ]] && [[ ${#failed_pushes[@]} -eq 0 ]] && [[ $KEEP_MODE -eq 0 ]]; then
    echo "--- Deleting local images that were pulled and pushed ---"
    if ! docker rmi "${images_to_manage[@]}" &> /dev/null; then
        echo "Warning: Could not delete all local images. Some may still exist."
    else
        echo "Successfully deleted local images."
    fi
fi

# If we are in air-gapped mode AND keep was NOT specified, delete the loaded images
if [[ $AIR_GAPPED_MODE -eq 1 ]] && [[ $KEEP_MODE -eq 0 ]]; then
    # We only want to delete the images if we didn't also push them
    # as the push block handles cleanup of its temporary tags
    if [[ $PUSH_MODE -eq 0 ]]; then
        echo "--- Deleting local images that were loaded from the archive ---"
        if ! docker rmi "${images_to_manage[@]}" &> /dev/null; then
            echo "Warning: Could not delete all local images. Some may still exist."
        else
            echo "Successfully deleted local images."
        fi
    fi
fi
echo ""
echo "--- Script completed successfully ---"
echo "Copy the archive '$SAVE_FILE_NAME' and $SCRIPT_NAME to the air-gapped host. Then run $SCRIPT_NAME with -f $SAVE_FILE_NAME"
exit 0