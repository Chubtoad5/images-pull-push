#!/usr/bin/env bats
# What consumers rely on: commands, the archive's name and layout, and that plain manifests behave as before.
# rke2-installer reads images/images.tar.gz out of the archive directly, so that path is part of the contract.
load ../helpers
SCRIPT="$BATS_TEST_DIRNAME/../../image_pull_push.sh"
setup() {
  setup_stubs
  cd "$STUB_DIR"
  stub docker 'case "$1" in
    save) shift; echo "fake-image-data" ;;
    info) echo "classic" ;;
    version) echo 29.0.0 ;;
    image) [[ "$*" == *RepoDigests* ]] && echo "alpine@sha256:abc" || echo "sha256:id1" ;;
    login) cat >/dev/null ;;
  esac'
  cat > helper.sh <<'H'
#!/bin/bash
echo "helper $*" >> "$STUB_LOG"
if [[ "$1" == save ]]; then
  mkdir -p offline-packages && touch offline-packages/docker-ce_1.0_amd64.deb
  tar -czf offline-packages.tar.gz offline-packages
fi
H
  export INSTALL_PACKAGES_URL="file://$STUB_DIR/helper.sh"
  mkdir -p /etc/apt/sources.list.d && touch /etc/apt/sources.list.d/docker.list
  echo alpine:3.20 > images.txt
}
@test "--version needs no root, and prints a version" {
  run su -s /bin/bash nobody -c "bash '$SCRIPT' --version"
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}
@test "--help needs no root" {
  run su -s /bin/bash nobody -c "bash '$SCRIPT' --help"
  [ "$status" -eq 0 ]
  [[ "$output" == *"keep"* && "$output" == *"push"* && "$output" == *"reg-cert"* && "$output" == *"docker"* ]]
}
@test "no command is an error" {
  run "$SCRIPT" -f images.txt
  [ "$status" -ne 0 ]
}
@test "an unknown parameter is an error" {
  run "$SCRIPT" -f images.txt nope
  [ "$status" -ne 0 ]
}
@test "keep pulls a plain image by its tag, and doesn't retag it" {
  run "$SCRIPT" -f images.txt keep
  [ "$status" -eq 0 ]
  called 'docker pull -q alpine:3.20'
  ! called 'docker tag'
}
@test "keep pulls a pinned image by digest, then gives it its tag" {
  d=sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc
  echo "alpine:3.20@$d" > pinned.txt
  run "$SCRIPT" -f pinned.txt keep
  [ "$status" -eq 0 ]
  called "docker pull -q alpine@$d"
  called "docker tag alpine@$d alpine:3.20"
}
@test "lock writes images.pinned.txt" {
  run "$SCRIPT" -f images.txt lock
  [ "$status" -eq 0 ]
  grep -qx 'alpine:3.20@sha256:abc' images.pinned.txt
}
@test "lock refuses an archive, and refuses other commands alongside it" {
  echo x > a.tar.gz
  run "$SCRIPT" -f a.tar.gz lock
  [ "$status" -ne 0 ]
  run "$SCRIPT" -f images.txt lock save
  [ "$status" -ne 0 ]
}
@test "save makes the archive consumers expect, with a plain manifest" {
  d=sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc
  echo "alpine:3.20@$d" > pinned.txt
  run "$SCRIPT" -f pinned.txt save
  [ "$status" -eq 0 ]
  called 'docker save alpine:3.20'
  archive=$(ls container_images_*.tar.gz)
  list=$(tar -tzf "$archive")
  for f in images/images.tar.gz images/manifest.txt images/images.lock images/HELPER_VERSION offline-packages.tar.gz install_packages.sh; do
    grep -qx "$f" <<< "$list"
  done
  [ "$(tar -xzf "$archive" images/manifest.txt -O)" = "alpine:3.20" ]
  [ "$(tar -tzf "$archive" | grep -c 'images/.*\.txt$')" -eq 1 ]
}
@test "the archive round-trips through keep" {
  run "$SCRIPT" -f images.txt save
  [ "$status" -eq 0 ]
  run "$SCRIPT" -f "$(ls container_images_*.tar.gz)" keep
  [ "$status" -eq 0 ]
  called 'docker load -i'
  [[ "$output" == *"Verified the loaded images"* ]]
}
@test "reg-cert and docker exist as commands" {
  grep -q 'reg-cert)' "$SCRIPT"
  grep -q 'docker)' "$SCRIPT"
}
@test "still runs when piped to bash" {
  run bash -c "cat '$BATS_TEST_DIRNAME/../../image_pull_push.sh' | bash -s -- --version"
  [ "$status" -eq 0 ]
  [[ "$output" =~ [0-9]+\.[0-9]+\.[0-9]+ ]]
}
