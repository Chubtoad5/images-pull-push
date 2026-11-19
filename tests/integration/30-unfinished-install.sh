#!/bin/bash
# Spec 26, P1: a host where Docker's packages are installed but the service is stopped and disabled, as this script's own
# "reboot, then re-run" used to leave it. A re-run has to start and enable Docker, and the next pull has to work. A running
# Docker is never restarted. As root, from the repo root, on a host the earlier tests left with Docker installed.
set -uo pipefail
REPO=$PWD
W=$(mktemp -d); cd "$W" || exit 1
cp "$REPO/image_pull_push.sh" . && chmod +x image_pull_push.sh
fail=0
ok()  { echo "PASS  $1"; }
bad() { echo "FAIL  $1"; fail=1; }
command -v docker >/dev/null || ./image_pull_push.sh docker > o 2>&1 || { bad "a first Docker install for this test"; tail -6 o; }

# The state P1 leaves: packages in, the service (and its socket, so nothing starts it on demand) stopped and disabled
systemctl disable --now docker.socket docker.service >/dev/null 2>&1
if systemctl is-active --quiet docker || systemctl is-enabled --quiet docker; then
  bad "the test couldn't stop and disable Docker"
else
  ok "Docker is installed, stopped and disabled"
fi

if ./image_pull_push.sh docker > o 2>&1; then ok "a re-run of 'docker' exits 0"; else bad "a re-run of 'docker' exits non-zero"; tail -6 o | cut -c1-170; fi
grep -q "Docker is installed but not running, starting it" o && ok "the re-run says it's starting Docker" || bad "the re-run doesn't say it's starting Docker"
systemctl is-active --quiet docker && ok "Docker is running after the re-run" || bad "Docker isn't running after the re-run: $(systemctl is-active docker)"
systemctl is-enabled --quiet docker && ok "Docker is enabled after the re-run" || bad "Docker isn't enabled after the re-run: $(systemctl is-enabled docker 2>&1)"

echo docker.io/library/alpine:3.20 > list.txt
if ./image_pull_push.sh -f list.txt keep > o 2>&1; then ok "keep pulls an image after the re-run"; else bad "keep fails after the re-run"; tail -6 o | cut -c1-170; fi

# A running Docker is left alone, with its containers
before=$(systemctl show -p ActiveEnterTimestampMonotonic --value docker)
./image_pull_push.sh docker > o 2>&1 || { bad "a run with Docker running exits non-zero"; tail -6 o | cut -c1-170; }
after=$(systemctl show -p ActiveEnterTimestampMonotonic --value docker)
[[ -n "$before" && "$before" == "$after" ]] && ok "a run with Docker running doesn't restart it" || bad "Docker restarted: $before -> $after"
grep -q "Docker is installed but not running" o && bad "a run with Docker running says it's starting it" || ok "a run with Docker running says nothing about starting it"

echo "=== exit $fail"; exit $fail
