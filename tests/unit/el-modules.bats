#!/usr/bin/env bats
# On EL, a Docker bundle carries the running kernel's kernel-modules-extra, and an air-gapped install uses it (spec 15, F1).
load ../helpers
KVER=6.12.0-211.16.1.el10_2.0.1.x86_64
setup() {
  load_script image_pull_push.sh
  setup_stubs
  stub uname "echo $KVER"
  os_id=rocky
  TEMP_DIR=$(mktemp -d)
  printf '#!/bin/bash\necho "install_packages.sh $*" >> "$STUB_LOG"\n' > "$TEMP_DIR/install_packages.sh"
  chmod +x "$TEMP_DIR/install_packages.sh"
}
bundle_with() { # bundle_with <rpm file name>...: an offline-packages.tar.gz in TEMP_DIR holding those files
  local d; d=$(mktemp -d); mkdir -p "$d/offline-packages"
  for f in "$@"; do touch "$d/offline-packages/$f"; done
  tar -czf "$TEMP_DIR/offline-packages.tar.gz" -C "$d" offline-packages
}
@test "save: on EL, the running kernel's kernel-modules-extra, when the repos have it" {
  stub dnf "echo kernel-modules-extra-0:$KVER"
  run el_modules_extra_pkg
  [ "$status" -eq 0 ]
  [ "$output" = "kernel-modules-extra-$KVER" ]
}
@test "save: when the repos no longer have it, nothing, and a note" {
  stub dnf 'exit 0'
  run el_modules_extra_pkg
  [ "$status" -eq 0 ]
  [[ "$output" == *"isn't in this host's repos"* ]]
  [[ "$output" != kernel-modules-extra-* ]]
}
@test "save: off EL, nothing" {
  os_id=ubuntu
  stub dnf "echo kernel-modules-extra-0:$KVER"
  run el_modules_extra_pkg
  [ -z "$output" ]
  ! called "dnf"
}
@test "the bundle's kernel-modules-extra is read from the archive" {
  bundle_with docker-ce-29.1.0-1.el10.x86_64.rpm "kernel-modules-extra-$KVER.rpm" "kernel-core-$KVER.rpm"
  run bundled_modules_extra
  [ "$output" = "kernel-modules-extra-$KVER" ]
}
@test "no archive, or none in it: nothing" {
  run bundled_modules_extra
  [ -z "$output" ]
  bundle_with docker-ce-29.1.0-1.el10.x86_64.rpm
  run bundled_modules_extra
  [ -z "$output" ]
}
@test "air-gapped: a matching package in the bundle is installed from it" {
  AIR_GAPPED_MODE=1
  stub modprobe 'case "$*" in "-n xt_addrtype") exit 1 ;; *) exit 0 ;; esac'
  bundle_with "kernel-modules-extra-$KVER.rpm"
  run ensure_el_kernel_modules
  [ "$status" -eq 0 ]
  called "install_packages.sh offline kernel-modules-extra-$KVER"
  [[ "$output" == *"xt_addrtype kernel module loaded"* ]]
}
@test "air-gapped: a package for another kernel isn't used, and the message says so" {
  AIR_GAPPED_MODE=1
  stub modprobe 'case "$*" in "-n xt_addrtype") exit 1 ;; *) exit 0 ;; esac'
  bundle_with kernel-modules-extra-6.12.0-211.74.1.el10_2.x86_64.rpm
  run ensure_el_kernel_modules
  [ "$status" -eq 1 ]
  ! called "install_packages.sh offline"
  [[ "$output" == *"built on a host running 6.12.0-211.74.1.el10_2.x86_64"* ]]
  [[ "$output" == *"dnf install kernel-modules-extra-$KVER"* ]]
}
