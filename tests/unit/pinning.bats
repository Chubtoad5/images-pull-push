#!/usr/bin/env bats
# Digests in manifests, the lock file, Docker version pins (spec 06).
load ../helpers
D=sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc
setup() {
  load_script image_pull_push.sh
  setup_stubs
  TEMP_DIR=$(mktemp -d)
  # A second load would keep the array from an earlier test in the same process
  IMAGE_DIGEST=()
}
@test "plain lines pass through" {
  images_to_manage=(alpine:3.20 rancher/foo:v1 my.reg:5000/a/b:c)
  normalize_images
  [ "${images_to_manage[*]}" = "alpine:3.20 rancher/foo:v1 my.reg:5000/a/b:c" ]
  [ ${#IMAGE_DIGEST[@]} -eq 0 ]
}
@test "a pinned line is split into the tag and the digest" {
  images_to_manage=("rancher/foo:v1@$D" alpine:3.20)
  normalize_images
  [ "${images_to_manage[*]}" = "rancher/foo:v1 alpine:3.20" ]
  [ "${IMAGE_DIGEST[rancher/foo:v1]}" = "$D" ]
}
@test "a registry with a port still counts as having a tag" {
  images_to_manage=("my.reg:5000/a/b:c@$D")
  normalize_images
  [ "${images_to_manage[0]}" = "my.reg:5000/a/b:c" ]
}
@test "a digest with no tag is refused" {
  images_to_manage=("alpine@$D")
  run normalize_images
  [ "$status" -eq 1 ]
  [[ "$output" == *"has a digest but no tag"* ]]
  images_to_manage=("my.reg:5000/a/b@$D")
  run normalize_images
  [ "$status" -eq 1 ]
}
@test "a bad digest is refused" {
  images_to_manage=("alpine:3.20@sha256:abc")
  run normalize_images
  [ "$status" -eq 1 ]
  [[ "$output" == *"bad digest"* ]]
}
@test "PIN_STRICT refuses a line with no digest, and accepts one with" {
  PIN_STRICT=true
  images_to_manage=(alpine:3.20)
  run normalize_images
  [ "$status" -eq 1 ]
  [[ "$output" == *"PIN_STRICT"* ]]
  images_to_manage=("alpine:3.20@$D")
  normalize_images
  [ "${images_to_manage[0]}" = "alpine:3.20" ]
}
@test "PIN_STRICT accepts a bundle whose lock file has every digest" {
  PIN_STRICT=true
  printf '# image-store: classic\nalpine:3.20\t%s\tsha256:aa\nbusybox:1.36\t%s\tsha256:bb\n' "$D" "$D" > "$TEMP_DIR/lock"
  run check_bundle_pinned "$TEMP_DIR/lock"
  [ "$status" -eq 0 ]
}
@test "PIN_STRICT refuses a bundle with an image that has no digest, and names it" {
  PIN_STRICT=true
  printf '# image-store: classic\nalpine:3.20\t%s\tsha256:aa\nbusybox:1.36\t-\tsha256:bb\n' "$D" > "$TEMP_DIR/lock"
  run check_bundle_pinned "$TEMP_DIR/lock"
  [ "$status" -eq 1 ]
  [[ "$output" == *"busybox:1.36 has no digest"* ]]
  [[ "$output" != *"alpine:3.20 has no digest"* ]]
}
@test "PIN_STRICT refuses a bundle with no lock file" {
  PIN_STRICT=true
  run check_bundle_pinned "$TEMP_DIR/no-such-lock"
  [ "$status" -eq 1 ]
  [[ "$output" == *"has no lock file"* ]]
}
@test "with PIN_STRICT off, a bundle needs neither a lock file nor digests" {
  run check_bundle_pinned "$TEMP_DIR/no-such-lock"
  [ "$status" -eq 0 ]
  printf 'busybox:1.36\t-\tsha256:bb\n' > "$TEMP_DIR/lock"
  run check_bundle_pinned "$TEMP_DIR/lock"
  [ "$status" -eq 0 ]
}
@test "the bundle path doesn't apply PIN_STRICT to its plain manifest, and checks before loading anything" {
  grep -n 'PIN_STRICT=false normalize_images' image_pull_push.sh
  check=$(grep -n 'check_bundle_pinned "\$TEMP_DIR' image_pull_push.sh | cut -d: -f1)
  load=$(grep -n 'docker load -i "\$TAR_IMAGE_FILE_IN_ARCHIVE"' image_pull_push.sh | cut -d: -f1)
  [ "$check" -lt "$load" ]
}
@test "PIN_STRICT is off by default" {
  [ "$PIN_STRICT" = "false" ]
}
@test "pull_ref uses the digest for a pinned image, and the tag otherwise" {
  IMAGE_DIGEST[rancher/foo:v1]=$D
  [ "$(pull_ref rancher/foo:v1)" = "rancher/foo@$D" ]
  [ "$(pull_ref alpine:3.20)" = "alpine:3.20" ]
  IMAGE_DIGEST[my.reg:5000/a:b]=$D
  [ "$(pull_ref my.reg:5000/a:b)" = "my.reg:5000/a@$D" ]
}
@test "mirror_fallback_for keeps its existing answers" {
  [ "$(mirror_fallback_for nginx:latest)" = "mirror.gcr.io/library/nginx:latest" ]
  [ "$(mirror_fallback_for rancher/foo:v1)" = "mirror.gcr.io/rancher/foo:v1" ]
  [ "$(mirror_fallback_for docker.io/library/nginx:1)" = "mirror.gcr.io/library/nginx:1" ]
  [ -z "$(mirror_fallback_for quay.io/a/b:c)" ]
}
@test "no Docker version asked for: package names are unchanged" {
  os_id=ubuntu
  DOCKER_PACKAGES=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)
  select_docker_packages
  [ "${DOCKER_PACKAGES[*]}" = "docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin" ]
}
@test "Docker version pins use install_packages.sh's name=version form" {
  os_id=rocky; DOCKER_VERSION=28.5.2; CONTAINERD_VERSION=1.7; COMPOSE_VERSION=2.30
  DOCKER_PACKAGES=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)
  select_docker_packages
  [ "${DOCKER_PACKAGES[*]}" = "docker-ce=28.5.2 docker-ce-cli=28.5.2 containerd.io=1.7 docker-buildx-plugin docker-compose-plugin=2.30" ]
}
@test "SUSE uses its own package names, pinned the same way" {
  os_id=opensuse-leap; DOCKER_VERSION=28; COMPOSE_VERSION=2
  DOCKER_PACKAGES=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)
  select_docker_packages
  [ "${DOCKER_PACKAGES[*]}" = "docker=28 docker-compose=2" ]
}
@test "a Docker that's already installed gets a warning, not a change" {
  DOCKER_VERSION=28.5
  stub docker 'echo 29.9.2'
  run warn_docker_version
  [[ "$output" == *"Warning"* ]]
  ! called 'install'
  DOCKER_VERSION=29.9
  run warn_docker_version
  [ -z "$output" ]
}
@test "the lock file records tag, digest and ID, and verifies against itself" {
  stub docker 'case "$1 $2" in
    "info "*) echo "[[\"driver-type\",\"io.containerd.snapshotter.v1\"]]" ;;
    "image inspect") [[ "$4" == *RepoDigests* ]] && echo "alpine@sha256:aaa" || echo "sha256:id1" ;;
  esac'
  images_to_manage=(alpine:3.20)
  write_lock_file "$TEMP_DIR/l"
  grep -qx '# image-store: containerd' "$TEMP_DIR/l"
  grep -q $'^alpine:3.20\tsha256:aaa\tsha256:id1$' "$TEMP_DIR/l"
  run verify_lock_file "$TEMP_DIR/l"
  [ "$status" -eq 0 ]
  [[ "$output" == *Verified* ]]
}
@test "an image that doesn't match the lock file fails" {
  stub docker 'case "$1 $2" in
    "info "*) echo classic ;;
    "image inspect") echo "sha256:other" ;;
  esac'
  printf '# image-store: classic\nalpine:3.20\tsha256:aaa\tsha256:id1\n' > "$TEMP_DIR/l"
  run verify_lock_file "$TEMP_DIR/l"
  [ "$status" -eq 1 ]
  [[ "$output" == *"doesn't match"* ]]
}
@test "a bundle from the other image store gets a note, not a false failure" {
  stub docker 'case "$1 $2" in
    "info "*) echo "[[\"driver-type\",\"io.containerd.snapshotter.v1\"]]" ;;
    "image inspect") echo "sha256:other" ;;
  esac'
  printf '# image-store: classic\nalpine:3.20\tsha256:aaa\tsha256:id1\n' > "$TEMP_DIR/l"
  run verify_lock_file "$TEMP_DIR/l"
  [ "$status" -eq 0 ]
  [[ "$output" == *"can't be compared"* ]]
}
@test "fetching install_packages.sh: the URL wins, and a bad checksum fails" {
  echo 'echo helper' > "$TEMP_DIR/src.sh"
  INSTALL_PACKAGES_URL="file://$TEMP_DIR/src.sh"
  fetch_install_packages
  [ -x "$TEMP_DIR/install_packages.sh" ]
  INSTALL_PACKAGES_SHA256=0000000000000000000000000000000000000000000000000000000000000000
  run fetch_install_packages
  [ "$status" -eq 1 ]
  [[ "$output" == *"doesn't match"* ]]
  INSTALL_PACKAGES_SHA256=$(sha256sum "$TEMP_DIR/src.sh" | cut -d' ' -f1)
  fetch_install_packages
}
@test "the default helper is a tag, not main" {
  [[ "$INSTALL_PACKAGES_URL" == *"/install-packages/v"* ]]
}
