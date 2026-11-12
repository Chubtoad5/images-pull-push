#!/bin/bash
# Spec 21, I6, on a throwaway host, as root, from the repo root: push to a registry that needs a login, with spec 21's
# test passwords (the full set of symbols, spaces at either end, and a password of --help), and refuse a wrong one.
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
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -keyout r.key -out r.crt -subj "/CN=localhost" -addext "subjectAltName=DNS:localhost" 2>/dev/null
up() { for _ in $(seq 1 15); do curl -sk -o /dev/null https://localhost:5444/v2/ && return 0; sleep 2; done; return 1; }
# registry <password>: a registry on 5444 whose one account, robot, has this password (bcrypt from htpasswd's stdin)
registry() {
  printf '%s\n' "$1" | docker run --rm -i --entrypoint htpasswd httpd:2.4-alpine -iBn robot > htpasswd
  grep -q '^robot:\$2' htpasswd || return 1
  docker rm -f reg21 >/dev/null 2>&1
  docker run -d --name reg21 --restart always -p 5444:5000 -v "$W:/c" -e REGISTRY_HTTP_TLS_CERTIFICATE=/c/r.crt \
    -e REGISTRY_HTTP_TLS_KEY=/c/r.key -e REGISTRY_AUTH=htpasswd -e REGISTRY_AUTH_HTPASSWD_REALM=r21 \
    -e REGISTRY_AUTH_HTPASSWD_PATH=/c/htpasswd registry:2 >/dev/null && up
}
echo alpine:3.20 > list.txt
for name in full ends word-help; do
  P=${VEC[$name]}
  registry "$P" || { bad "$name: the test registry didn't start"; continue; }
  if ./image_pull_push.sh -f list.txt push localhost:5444 robot "$P" > o 2>&1; then ok "$name: push with that password"
  else bad "$name: push with that password"; tail -n 4 o | cut -c1-170; fi
  grep -q 'Usage:' o && bad "$name: printed the usage" || true
  up
  tags=$(curl -sk -K - https://localhost:5444/v2/library/alpine/tags/list <<< "user = \"robot:$(sed 's/[\\"]/\\&/g' <<< "$P")\"")
  [[ "$tags" == *'"3.20"'* ]] && ok "$name: the image is in the registry" || bad "$name: the registry has: $tags"
  ./image_pull_push.sh -f list.txt push localhost:5444 robot "x$P" > o 2>&1 && bad "$name: a wrong password was accepted" || ok "$name: a wrong password is refused"
  # With spaces at either end, the trimmed password must fail, or nothing here proves the spaces arrived
  t=$(sed 's/^ *//; s/ *$//' <<< "$P")
  if [[ "$t" != "$P" ]]; then
    ./image_pull_push.sh -f list.txt push localhost:5444 robot "$t" > o 2>&1 && bad "$name: the trimmed password was accepted" || ok "$name: the trimmed password is refused"
  fi
  docker logout localhost:5444 >/dev/null 2>&1
done
docker rm -f reg21 >/dev/null 2>&1
echo "=== exit $fail"; exit $fail
