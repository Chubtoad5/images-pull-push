#!/bin/bash
# A1, on a clean host with no route out: keep the bundle the build role made, which installs Docker from its
# packages and loads the images, then run one of them.
set -uo pipefail
REPO=$PWD
fail=0
ok()  { echo "PASS  $1"; }
bad() { echo "FAIL  $1"; fail=1; }
# within <seconds> <command...>: true once the command is, checking every 3 seconds
within() { local t=$1 i; shift; for ((i = 0; i < t; i += 3)); do "$@" && return 0; sleep 3; done; "$@"; }
W=$(mktemp -d -p /var/tmp); cd "$W" || exit 1
cp "$REPO/image_pull_push.sh" .; chmod +x image_pull_push.sh
b=$(ls "$CI_HANDOFF"/container_images_*.tar.gz 2>/dev/null | head -1)
[ -n "$b" ] && cp "$b" . && ok "put the bundle here" || { bad "no bundle handed on"; echo "=== exit 1"; exit 1; }
command -v docker >/dev/null && echo "  note: Docker is already on this image"
./image_pull_push.sh -f "$(basename "$b")" keep > "$W/o" 2>&1 && ok "keep, with no route out" || { bad "keep"; tail -8 "$W/o" | cut -c1-170; }
systemctl is-active -q docker && ok "Docker, from the bundle, runs" || bad "Docker isn't running"
for i in alpine:3.20 busybox:1.36; do docker image inspect "$i" >/dev/null 2>&1 && ok "$i is loaded" || bad "$i isn't loaded"; done
[ "$(docker run --rm --network none alpine:3.20 echo offline-ok 2>/dev/null)" = offline-ok ] && ok "a loaded image runs" || bad "alpine:3.20 doesn't run"
echo "=== exit $fail"; exit $fail
