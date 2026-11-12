#!/usr/bin/env bats
# I6 (spec 21): when two or more arguments follow push <registry>, the first two are the user and the password,
# whatever they say.
# Each of spec 21's test passwords, and each command word or option, is run as the password and as the user, and what
# docker login receives is compared byte for byte.
load ../helpers
load ../vectors
SCRIPT="$BATS_TEST_DIRNAME/../../image_pull_push.sh"
setup() {
  setup_stubs
  cd "$STUB_DIR"
  # docker login records its user and the exact bytes on stdin; everything else succeeds quietly
  stub docker 'case "$1" in
    info) echo "classic" ;;
    version) echo "${STUB_DOCKER_VERSION:-29.9.2}" ;;
    image) echo "sha256:id1" ;;
    login) shift; while [[ $# -gt 0 ]]; do [[ "$1" == --username ]] && printf "%s" "$2" > "${STUB_LOG%/*}/login.user"; shift; done
           cat > "${STUB_LOG%/*}/login.stdin" ;;
  esac'
  # The registry's certificate: what openssl fetches matches what's installed, so nothing is changed or restarted
  stub openssl 'if [[ "$1" == s_client ]]; then printf "%s\n" "-----BEGIN CERTIFICATE-----" FAKE "-----END CERTIFICATE-----"; fi'
  mkdir -p /usr/local/share/ca-certificates
  printf '%s\n' "-----BEGIN CERTIFICATE-----" FAKE "-----END CERTIFICATE-----" > /usr/local/share/ca-certificates/reg.test.crt
  cat > helper.sh <<'H'
#!/bin/bash
echo "helper $*" >> "$STUB_LOG"
H
  export INSTALL_PACKAGES_URL="file://$STUB_DIR/helper.sh"
  mkdir -p /etc/apt/sources.list.d && touch /etc/apt/sources.list.d/docker.list
  echo alpine:3.20 > images.txt
  load_vectors
}
# pushed_with <user> <password>: the script pushes, and docker login got exactly this user and password
pushed_with() {
  run "$SCRIPT" -f images.txt push reg.test:443 "$1" "$2"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"--- Starting image push process"* ]]
  [ "$(cat "$STUB_DIR/login.user")" = "$1" ]
  # <<< adds one newline, which docker login --password-stdin removes
  [ "$(cat "$STUB_DIR/login.stdin")" = "$2" ]
  [ "$(wc -c < "$STUB_DIR/login.stdin")" -eq $(( $(printf '%s' "$2" | wc -c) + 1 )) ]
}
@test "I6: every test password reaches docker login exactly" {
  local n
  for n in "${VEC_NAMES[@]}"; do
    echo "vector: $n"
    pushed_with robot "${VEC[$n]}"
  done
}
@test "I6: a password that is a command word or an option is a password" {
  local w
  for w in push save keep lock docker reg-cert -f -h --help --version -n -e; do
    echo "word: $w"
    pushed_with robot "$w"
  done
}
@test "I6: a user that is a command word or an option is a user" {
  local w
  for w in push save keep lock docker reg-cert -f -h --help --version; do
    echo "word: $w"
    pushed_with "$w" 'Aa1 pass'
  done
}
@test "I6: no user and no password, as rke2 sends them for an open registry" {
  run "$SCRIPT" -f images.txt push reg.test:443 "" ""
  [ "$status" -eq 0 ]
  ! called 'docker login' || false
}
@test "push with only a registry still works, and a user with no password is still refused" {
  run "$SCRIPT" -f images.txt push reg.test:443
  [ "$status" -eq 0 ]
  run "$SCRIPT" -f images.txt push reg.test:443 robot
  [ "$status" -ne 0 ]
  [[ "$output" == *"A password is required"* ]]
}
@test "--help and --version still work before push, and an extra argument after the password is refused" {
  run "$SCRIPT" --help -f images.txt push reg.test:443 robot pw
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
  run "$SCRIPT" -f images.txt --version push reg.test:443 robot pw
  [ "$output" = "$(sed -n 's/^SCRIPT_VERSION="\(.*\)"/\1/p' "$SCRIPT")" ]
  run "$SCRIPT" -f images.txt push reg.test:443 robot pw extra
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown parameter 'extra'"* ]]
}
@test "-f with nothing after it is an error, not an unbound variable" {
  run "$SCRIPT" keep -f
  [ "$status" -ne 0 ]
  [[ "$output" == *"-f requires a file path"* ]]
  [[ "$output" != *"unbound variable"* ]]
}
@test "a user name a registry login can't carry, or a control character, is refused before anything changes" {
  local u
  for u in 'ro:bot' ' robot' 'robot ' $'ro\tbot'; do
    run "$SCRIPT" -f images.txt push reg.test:443 "$u" pw
    [ "$status" -ne 0 ]
    [[ "$output" == *"The registry username can't contain"* ]]
  done
  run "$SCRIPT" -f images.txt push reg.test:443 robot $'Aa1\npass'
  [ "$status" -ne 0 ]
  [[ "$output" == *"The registry password can't contain a control character"* ]]
  ! called 'docker pull' || false
  ! called 'docker login' || false
}
@test "a single command after the registry is still a command" {
  run "$SCRIPT" -f images.txt push reg.test:443 keep
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"KEEP IMAGES: 1"* ]]
  ! called 'docker login' || false
  [[ "$output" != *"--- Deleting local images"* ]]
}
@test "commands and -f after the password are read as before" {
  cd "$STUB_DIR"
  run "$SCRIPT" push reg.test:443 robot pw -f images.txt keep
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"KEEP IMAGES: 1"* ]]
  [ "$(cat "$STUB_DIR/login.stdin")" = pw ]
}
@test "a password with a space at either end is refused up front on a Docker older than 29.3, whose login trims it" {
  export STUB_DOCKER_VERSION=28.5.2
  run "$SCRIPT" -f images.txt push reg.test:443 robot ' Aa1pass '
  [ "$status" -ne 0 ]
  [[ "$output" == *"older than 29.3"* && "$output" == *"Nothing has been changed"* ]]
  [[ "$output" != *"Aa1pass"* ]]
  ! called 'docker pull' || false
  ! called 'docker login' || false
  # Spaces only inside are fine there, and 29.3 takes spaces at either end
  pushed_with robot 'Aa1 pass'
  export STUB_DOCKER_VERSION=29.3.0
  pushed_with robot ' Aa1pass '
}
@test "--help or --version as the password is a password in every argument order the parser takes" {
  local w
  for w in --help -h --version; do
    pushed_with robot "$w"
    run "$SCRIPT" push -f images.txt reg.test:443 robot "$w"
    [ "$status" -eq 0 ]; [ "$(cat "$STUB_DIR/login.stdin")" = "$w" ]
    run "$SCRIPT" push keep -f images.txt reg.test:443 robot "$w"
    [ "$status" -eq 0 ]; [ "$(cat "$STUB_DIR/login.stdin")" = "$w" ]
  done
}
