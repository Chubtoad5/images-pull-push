#!/bin/bash
# Spec 21, I6, on a throwaway host, as root, from the repo root: push to a registry that needs a login, with spec 21's
# test passwords (the full set of symbols, spaces at either end, and a password of --help), and refuse a wrong one.
# Spec 23, I7: the registry is reached by this host's own address, not localhost, which Docker never verifies. Trusting
# its certificate, and a renewed one, must not restart Docker. I8: the Docker 29.3 check works with the daemon stopped.
set -uo pipefail
REPO=$PWD
W=$(mktemp -d); cd "$W" || exit 1
cp "$REPO/image_pull_push.sh" . && chmod +x image_pull_push.sh
# shellcheck source=../vectors.bash
source "$REPO/tests/vectors.bash"
load_vectors "$REPO/tests/password-vectors.txt"
fail=0
ok()  { echo "PASS  $1"; }
bad() { echo "FAIL  $1"; fail=1; }
command -v docker >/dev/null || ./image_pull_push.sh docker >/dev/null 2>&1 || { bad "Docker install"; echo "=== exit 1"; exit 1; }
IP=${CI_CLONE_IP:-$(hostname -I | awk '{print $1}')}
R=$IP:5444
# cert: a new self-signed certificate (and key) for this host's address
cert() { openssl req -x509 -newkey rsa:2048 -nodes -days 2 -keyout r.key -out r.crt -subj "/CN=$IP" -addext "subjectAltName=IP:$IP" 2>/dev/null; }
cert
up() { for _ in $(seq 1 15); do curl -sk -o /dev/null "https://$R/v2/" && return 0; sleep 2; done; return 1; }
# registry <password>: a registry on 5444 whose one account, robot, has this password (bcrypt from htpasswd's stdin)
registry() {
  printf '%s\n' "$1" | docker run --rm -i --entrypoint htpasswd httpd:2.4-alpine -iBn robot > htpasswd
  grep -q '^robot:\$2' htpasswd || return 1
  docker rm -f reg21 >/dev/null 2>&1
  docker run -d --name reg21 --restart always -p 5444:5000 -v "$W:/c" -e REGISTRY_HTTP_TLS_CERTIFICATE=/c/r.crt \
    -e REGISTRY_HTTP_TLS_KEY=/c/r.key -e REGISTRY_AUTH=htpasswd -e REGISTRY_AUTH_HTPASSWD_REALM=r21 \
    -e REGISTRY_AUTH_HTPASSWD_PATH=/c/htpasswd registry:2 >/dev/null && up
}
dockerd_pid() { systemctl show -p MainPID --value docker; }
reg_started() { docker inspect -f '{{.State.StartedAt}}' reg21 2>/dev/null; }
fp() { openssl x509 -noout -fingerprint -sha256 -in "$1" 2>/dev/null; }
# The trust store's copy, whichever distro this is
store_copy() { local p; for p in /usr/local/share/ca-certificates /etc/pki/ca-trust/source/anchors /etc/pki/trust/anchors; do [ -s "$p/$IP.crt" ] && echo "$p/$IP.crt"; done; }
echo alpine:3.20 > list.txt

echo "=== I7: trust the registry with no Docker restart"
P=${VEC[full]}
registry "$P" || bad "I7: the test registry didn't start"
docker image inspect alpine:3.20 >/dev/null 2>&1 || docker pull -q alpine:3.20 >/dev/null 2>&1
docker tag alpine:3.20 "$R/library/alpine:pre" 2>/dev/null
# Before the script runs, Docker must refuse the registry, or this test doesn't exercise trust at all
out=$(timeout 60 docker push "$R/library/alpine:pre" 2>&1)
grep -qi 'x509\|certificate' <<< "$out" && ok "I7: before the run, Docker refuses the registry's certificate" \
  || { bad "I7: Docker didn't refuse the untrusted registry: $(tail -n 1 <<< "$out" | cut -c1-120)"; }
docker rmi "$R/library/alpine:pre" >/dev/null 2>&1
pid0=$(dockerd_pid) s0=$(reg_started)
if ./image_pull_push.sh -f list.txt push "$R" robot "$P" > o 2>&1; then ok "I7: the first push passes"
else bad "I7: the first push"; tail -n 4 o | cut -c1-170; fi
[ "$(dockerd_pid)" = "$pid0" ] && ok "I7: Docker wasn't restarted (dockerd pid $pid0)" || bad "I7: dockerd's pid changed: $pid0 -> $(dockerd_pid)"
[ "$(reg_started)" = "$s0" ] && ok "I7: the registry's container kept running" || bad "I7: the registry's container restarted"
D=/etc/docker/certs.d/$R/ca.crt S=$(store_copy)
[ "$(fp "$D")" = "$(fp r.crt)" ] && ok "I7: $D holds the registry's certificate" || bad "I7: $D doesn't hold the registry's certificate"
[ -n "$S" ] && [ "$(fp "$S")" = "$(fp r.crt)" ] && ok "I7: the trust store's copy too ($S)" || bad "I7: no matching trust-store copy"
if grep -i 'restart' o | grep -viq 'without a restart'; then bad "I7: the log mentions a restart: $(grep -i restart o | head -n 1)"; fi

echo "=== I7: a renewed certificate"
cert; registry "$P" || bad "I7: the renewed registry didn't start"
pid0=$(dockerd_pid) s0=$(reg_started)
if ./image_pull_push.sh -f list.txt push "$R" robot "$P" > o 2>&1; then ok "I7: the push after a renewal passes"
else bad "I7: the push after a renewal"; tail -n 4 o | cut -c1-170; fi
[ "$(dockerd_pid)" = "$pid0" ] && [ "$(reg_started)" = "$s0" ] && ok "I7: and still no Docker restart" || bad "I7: Docker or the registry restarted after the renewal"
[ "$(fp "$D")" = "$(fp r.crt)" ] && [ "$(fp "$(store_copy)")" = "$(fp r.crt)" ] && ok "I7: both copies hold the renewed certificate" \
  || bad "I7: a copy still holds the old certificate"
docker logout "$R" >/dev/null 2>&1

# Docker's CLI before 29.3 trims spaces at either end of a login's password (10-pinning.sh leaves Docker 28.5 here), so
# there the password with spaces at either end must be refused up front, saying why
dv=$(docker version --format '{{.Client.Version}}' 2>/dev/null)
old_docker=0; [[ "$(printf '%s\n%s\n' "$dv" 29.3.0 | sort -V | head -n 1)" != 29.3.0 ]] && old_docker=1
if [[ $old_docker == 1 ]]; then
  echo "=== I8: the check with Docker's daemon stopped"
  systemctl stop docker.socket docker >/dev/null 2>&1
  if ./image_pull_push.sh -f list.txt push "$R" robot "${VEC[ends]}" > o 2>&1; then bad "I8: with the daemon stopped, Docker $dv's push was attempted and passed"
  elif grep -q 'older than 29.3' o; then ok "I8: refused up front with the daemon stopped, and says why"
  else bad "I8: with the daemon stopped, the push failed without saying why"; tail -n 3 o | cut -c1-170; fi
  systemctl start docker >/dev/null 2>&1; up || true
fi
for name in full ends word-help; do
  P=${VEC[$name]}
  registry "$P" || { bad "$name: the test registry didn't start"; continue; }
  if [[ $name == ends && $old_docker == 1 ]]; then
    if ./image_pull_push.sh -f list.txt push "$R" robot "$P" > o 2>&1; then bad "ends: Docker $dv trims the password, but the push was attempted and passed"
    elif grep -q 'older than 29.3' o; then ok "ends: refused up front on Docker $dv, which trims a password's spaces, and says so"
    else bad "ends: on Docker $dv the push failed without saying why"; tail -n 3 o | cut -c1-170; fi
    continue
  fi
  if ./image_pull_push.sh -f list.txt push "$R" robot "$P" > o 2>&1; then ok "$name: push with that password"
  else bad "$name: push with that password"; tail -n 4 o | cut -c1-170; fi
  grep -q 'Usage:' o && bad "$name: printed the usage" || true
  up
  tags=$(curl -sk -K - "https://$R/v2/library/alpine/tags/list" <<< "user = \"robot:$(sed 's/[\\"]/\\&/g' <<< "$P")\"")
  [[ "$tags" == *'"3.20"'* ]] && ok "$name: the image is in the registry" || bad "$name: the registry has: $tags"
  ./image_pull_push.sh -f list.txt push "$R" robot "x$P" > o 2>&1 && bad "$name: a wrong password was accepted" || ok "$name: a wrong password is refused"
  # With spaces at either end, the trimmed password must fail, or nothing here proves the spaces arrived
  t=$(sed 's/^ *//; s/ *$//' <<< "$P")
  if [[ "$t" != "$P" ]]; then
    ./image_pull_push.sh -f list.txt push "$R" robot "$t" > o 2>&1 && bad "$name: the trimmed password was accepted" || ok "$name: the trimmed password is refused"
  fi
  docker logout "$R" >/dev/null 2>&1
done
docker rm -f reg21 >/dev/null 2>&1
echo "=== exit $fail"; exit $fail
