#!/usr/bin/env bats
# Spec 26: after this script's own "reboot, then re-run", Docker is started (P1), and the first run keeps the
# daemon.json and docker group it set up once Docker's packages are installed (P2).
load ../helpers
setup() {
  load_script image_pull_push.sh
  setup_stubs
  TEMP_DIR=$(mktemp -d)
  os_id=rocky user_name=tester AIR_GAPPED_MODE=1 BRIDGE_JSON_COMMITTED=0
  printf '#!/bin/bash\necho "install_packages.sh $*" >> "$STUB_LOG"\n' > "$TEMP_DIR/install_packages.sh"
  chmod +x "$TEMP_DIR/install_packages.sh"
  stub docker
  stub usermod
  # systemctl is-active answers $STUB_ACTIVE (0 = running) until an enable --now works; enable answers $STUB_ENABLE
  stub systemctl 'up=$(dirname "$STUB_LOG")/up
[[ "$1" == is-active ]] && { [[ -f "$up" ]] && exit 0; exit "${STUB_ACTIVE:-0}"; }
[[ "$1" == enable ]] && { [[ "${STUB_ENABLE:-0}" == 0 ]] && touch "$up"; exit "${STUB_ENABLE:-0}"; }
exit 0'
  # The kernel-module check and the daemon.json step log their call, and what was already done when they ran
  ensure_el_kernel_modules() { echo "ensure_el_kernel_modules committed=$BRIDGE_JSON_COMMITTED" >> "$STUB_LOG"; }
  create_bridge_json() { echo "create_bridge_json" >> "$STUB_LOG"; BRIDGE_JSON_CHANGED=1; }
  # A Docker that has run before has its network store: the tests that need a never-started one remove it
  DOCKER_NETWORK_DB=$TEMP_DIR/local-kv.db; touch "$DOCKER_NETWORK_DB"
}
order() { grep -nE "$1" "$STUB_LOG" | head -1 | cut -d: -f1; }

@test "P1: a stopped Docker gets the module check, then enable --now, in that order" {
  export STUB_ACTIVE=3
  run start_stopped_docker
  [ "$status" -eq 0 ]
  [[ "$output" == *"Docker is installed but not running, starting it"* ]]
  called "ensure_el_kernel_modules"
  called "systemctl enable --now docker"
  [ "$(order ensure_el_kernel_modules)" -lt "$(order 'systemctl enable --now docker')" ]
}
@test "P1: a running Docker is left alone: no module check, no start, no restart" {
  export STUB_ACTIVE=0
  run start_stopped_docker
  [ "$status" -eq 0 ]
  ! called "ensure_el_kernel_modules" || false
  ! called "systemctl enable" || false
  ! called "systemctl restart" || false
  ! called "systemctl start" || false
}
@test "P1: a Docker that won't start stops the run, and says where to look" {
  export STUB_ACTIVE=3 STUB_ENABLE=1
  run start_stopped_docker
  [ "$status" -eq 1 ]
  [[ "$output" == *"journalctl -u docker"* ]]
}
@test "P1: the module check's own stop (a reboot needed) stops the run before any start" {
  export STUB_ACTIVE=3
  ensure_el_kernel_modules() { echo "Reboot into the new kernel, then re-run this script."; exit 1; }
  run start_stopped_docker
  [ "$status" -eq 1 ]
  ! called "systemctl enable" || false
}
@test "P1: the Docker CLI found path calls it" {
  grep -A3 'echo "  Docker CLI found."' "$BATS_TEST_DIRNAME/../../image_pull_push.sh" | grep -q '^ *start_stopped_docker$'
}
@test "P2: once the packages are in, the docker group and daemon.json are kept before the module check runs" {
  export STUB_ACTIVE=0
  run install_docker
  [ "$status" -eq 0 ]
  called "usermod -aG docker tester"
  called "ensure_el_kernel_modules committed=1"
  [ "$(order 'usermod')" -lt "$(order ensure_el_kernel_modules)" ]
  [ "$(order ensure_el_kernel_modules)" -lt "$(order 'systemctl enable --now docker')" ]
}
@test "P2: a stop for a reboot no longer rolls back this run's daemon.json" {
  d=$(mktemp -d); BRIDGE_JSON_CHANGED=1 BRIDGE_JSON_COMMITTED=1 BRIDGE_JSON_BACKUP=""
  printf '{"bip": "172.30.0.1/16"}\n' > "$d/daemon.json"
  # restore_bridge_json acts on /etc/docker/daemon.json: point it at a copy
  sed "s#/etc/docker/daemon.json#$d/daemon.json#g; s#/etc/docker\\b#$d#g" <(declare -f restore_bridge_json) > "$d/fn"
  source "$d/fn"
  restore_bridge_json
  [ -f "$d/daemon.json" ]
}
@test "P2: a package install that leaves no Docker CLI still rolls daemon.json back (not committed, no group)" {
  rm -f "$STUB_DIR/docker"
  PATH="$STUB_DIR:/usr/bin:/bin"; hash -r
  if command -v docker >/dev/null; then skip "this host has a real docker on PATH"; fi
  run install_docker
  [ "$status" -eq 1 ]
  [[ "$output" == *"Docker installation failed"* ]]
  ! called "usermod" || false
  ! called "ensure_el_kernel_modules" || false
}
@test "P1: a Docker that has run before keeps its network: no daemon.json step, no group change" {
  export STUB_ACTIVE=3
  run start_stopped_docker
  [ "$status" -eq 0 ]
  ! called "create_bridge_json" || false
  ! called "usermod" || false
}
@test "P1: a Docker that has never started gets the bridge and the group first, kept before the module check" {
  export STUB_ACTIVE=3
  rm -f "$DOCKER_NETWORK_DB"
  run start_stopped_docker
  [ "$status" -eq 0 ]
  called "usermod -aG docker tester"
  called "ensure_el_kernel_modules committed=1"
  [ "$(order create_bridge_json)" -lt "$(order ensure_el_kernel_modules)" ]
  [ "$(order ensure_el_kernel_modules)" -lt "$(order 'systemctl enable --now docker')" ]
}
@test "P1: a running Docker that has never made a network is still left alone" {
  export STUB_ACTIVE=0
  rm -f "$DOCKER_NETWORK_DB"
  run start_stopped_docker
  [ "$status" -eq 0 ]
  ! called "create_bridge_json" || false
}
@test "P1: with no docker.service here (a remote DOCKER_HOST, podman-docker), nothing is started or written" {
  export STUB_ACTIVE=3
  rm -f "$DOCKER_NETWORK_DB"
  stub systemctl '[[ "$1" == is-active ]] && exit 3; [[ "$1" == cat ]] && exit 1; exit 0'
  run start_stopped_docker
  [ "$status" -eq 0 ]
  ! called "create_bridge_json" || false
  ! called "systemctl enable" || false
  [[ "$output" != *"starting it"* ]]
}
@test "P1: the certificate step starts a stopped Docker the same way (enable, module check), before the Docker check" {
  grep -B2 -A3 'if command -v docker &> /dev/null; then' "$BATS_TEST_DIRNAME/../../image_pull_push.sh" | grep -q '^ *start_stopped_docker$'
  ! grep -q "systemctl start docker" "$BATS_TEST_DIRNAME/../../image_pull_push.sh" || false
}
