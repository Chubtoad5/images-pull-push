#!/bin/bash
# A1, on the host that builds the bundle: save two images (and Docker's packages), hand the archive on.
set -uo pipefail
REPO=$PWD
fail=0
ok()  { echo "PASS  $1"; }
bad() { echo "FAIL  $1"; fail=1; }
# within <seconds> <command...>: true once the command is, checking every 3 seconds
within() { local t=$1 i; shift; for ((i = 0; i < t; i += 3)); do "$@" && return 0; sleep 3; done; "$@"; }
W=$(mktemp -d -p /var/tmp); cd "$W" || exit 1
cp "$REPO/image_pull_push.sh" .; chmod +x image_pull_push.sh
printf 'alpine:3.20\nbusybox:1.36\n' > images.txt
if ./image_pull_push.sh -f images.txt save > "$W/o" 2>&1 && b=$(ls container_images_*.tar.gz 2>/dev/null | head -1) && [ -s "$b" ]; then
  ok "save builds $b ($(du -h "$b" | cut -f1))"
  cp "$b" "$CI_HANDOFF/" && ok "hand the bundle on" || bad "hand the bundle on"
else
  bad "save"; tail -8 "$W/o" | cut -c1-170
fi
echo "=== exit $fail"; exit $fail
