#!/bin/bash
# The real thing on a throwaway host, as root, from the repo root: Docker pins, digests, lock files and old copies of
# this script, on both of Docker's image stores, against a local TLS registry.
set -uo pipefail
REPO=$PWD
W=$(mktemp -d); cd "$W" || exit 1
cp "$REPO/image_pull_push.sh" . && chmod +x image_pull_push.sh
curl -fsSL https://raw.githubusercontent.com/Chubtoad5/images-pull-push/c84ad7a/image_pull_push.sh -o old.sh && chmod +x old.sh
fail=0
ok()  { echo "PASS  $1"; }
bad() { echo "FAIL  $1"; fail=1; }
expect() { local name=$1; shift; if "$@" >"$W/o" 2>&1; then ok "$name"; else bad "$name"; tail -6 "$W/o" | cut -c1-170; fi; }
refuse() { local name=$1; shift; if "$@" >"$W/o" 2>&1; then bad "$name"; else ok "$name"; fi; }
apt-get update -qq >/dev/null 2>&1; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends curl >/dev/null 2>&1

# A real pin on a clean host: the helper resolves 28.5 to the newest 28.5.x build
expect "DOCKER_VERSION installs that version on a clean host" env DOCKER_VERSION=28.5 COMPOSE_VERSION= ./image_pull_push.sh docker
docker version --format '{{.Client.Version}}' | grep -q '^28\.5' && ok "Docker is 28.5.x: $(docker version --format '{{.Client.Version}}')" || bad "Docker is $(docker version --format '{{.Client.Version}}')"
before=$(dpkg-query -W -f='${Version}' docker-ce)
expect "a different DOCKER_VERSION on a running host" env DOCKER_VERSION=29 ./image_pull_push.sh docker
grep -q Warning "$W/o" && ok "it warns" || bad "no warning"
[ "$(dpkg-query -W -f='${Version}' docker-ce)" = "$before" ] && ok "Docker wasn't moved" || bad "Docker moved"

openssl req -x509 -newkey rsa:2048 -nodes -days 2 -keyout r.key -out r.crt -subj "/CN=localhost" -addext "subjectAltName=DNS:localhost" 2>/dev/null
registry() {
  docker rm -f reg >/dev/null 2>&1
  docker run -d --name reg --restart always -p 5443:5000 -v "$W:/c" -e REGISTRY_HTTP_TLS_CERTIFICATE=/c/r.crt -e REGISTRY_HTTP_TLS_KEY=/c/r.key registry:2 >/dev/null
  for _ in 1 2 3 4 5 6 7 8 9 10; do curl -sk https://localhost:5443/v2/ >/dev/null && return 0; sleep 2; done
  return 1
}
store_round() { # store_round <label>
  local label=$1
  echo "=== image store: $label ($(docker info --format '{{json .DriverStatus}}' | grep -c snapshotter) snapshotter lines)"
  registry || bad "$label: registry didn't start"
  docker rmi -f alpine:3.20 busybox:1.36 >/dev/null 2>&1
  printf 'alpine:3.20\nbusybox:1.36\n' > plain.txt
  expect "$label: lock" ./image_pull_push.sh -f plain.txt lock
  [ "$(grep -cE '^[a-z]+:[0-9.]+@sha256:[0-9a-f]{64}$' images.pinned.txt)" = 2 ] && ok "$label: both lines pinned" || bad "$label: images.pinned.txt: $(cat images.pinned.txt)"
  docker rmi -f alpine:3.20 busybox:1.36 >/dev/null 2>&1
  expect "$label: keep from a pinned list" ./image_pull_push.sh -f images.pinned.txt keep
  docker image inspect alpine:3.20 >/dev/null 2>&1 && ok "$label: keep restored the tag" || bad "$label: keep lost the tag"
  expect "$label: push from a pinned list" ./image_pull_push.sh -f images.pinned.txt push localhost:5443 keep
  # push restarts Docker. The registry comes back by itself, so wait for it rather than recreating it.
  for _ in 1 2 3 4 5 6 7 8 9 10; do curl -sk https://localhost:5443/v2/ >/dev/null && break; sleep 2; done
  curl -sk https://localhost:5443/v2/library/alpine/tags/list | grep -q '3.20' && ok "$label: the tag is in the registry" || bad "$label: registry has: $(curl -sk https://localhost:5443/v2/_catalog)"
  rm -f container_images_*.tar.gz
  expect "$label: save from a pinned list" env DOCKER_VERSION= ./image_pull_push.sh -f images.pinned.txt save
  b=$(ls container_images_*.tar.gz)
  [ "$(tar -xzf "$b" images/manifest.txt -O | grep -c @)" = 0 ] && ok "$label: manifest.txt stayed plain" || bad "$label: digests in manifest.txt"
  tar -xzf "$b" images/images.lock -O | grep -q 'alpine:3.20' && ok "$label: lock file written" || bad "$label: no lock file"
  docker rmi -f alpine:3.20 busybox:1.36 >/dev/null 2>&1
  expect "$label: keep from the bundle" ./image_pull_push.sh -f "$b" keep
  grep -q 'Verified the loaded images' "$W/o" && ok "$label: lock file verified" || bad "$label: not verified"
  docker image inspect alpine:3.20 >/dev/null 2>&1 && ok "$label: bundle restored the tag" || bad "$label: bundle lost the tag"
  docker rmi -f alpine:3.20 busybox:1.36 >/dev/null 2>&1
  expect "$label: PIN_STRICT accepts a bundle from a pinned list" env PIN_STRICT=true ./image_pull_push.sh -f "$b" keep
  docker image inspect alpine:3.20 >/dev/null 2>&1 && ok "$label: and restores the tag" || bad "$label: PIN_STRICT lost the tag"
  docker rmi -f alpine:3.20 busybox:1.36 >/dev/null 2>&1
  expect "$label: the old script can use a new bundle" ./old.sh -f "$b" keep
  docker image inspect alpine:3.20 >/dev/null 2>&1 && ok "$label: and restores the tag" || bad "$label: the old script lost the tag"
  # A tampered record must fail
  mkdir -p t && tar -xzf "$b" -C t && sed -i 's/\tsha256:[0-9a-f]*$/\tsha256:0000/' t/images/images.lock && tar -czf tampered.tar.gz -C t images offline-packages.tar.gz install_packages.sh
  refuse "$label: a bundle that doesn't match its lock file fails" ./image_pull_push.sh -f tampered.tar.gz keep
  chmod -R u+w t; find t -delete; rm -f tampered.tar.gz
  cp "$b" "$W/bundle-$label.tar.gz"
  rm -f "$b"
  docker rmi -f alpine:3.20 busybox:1.36 >/dev/null 2>&1
  expect "$label: an old bundle works, with a note" sh -c "./old.sh -f plain.txt save && ./image_pull_push.sh -f \$(ls container_images_*.tar.gz) keep"
  grep -q 'has no lock file' "$W/o" && ok "$label: it says it can't verify" || bad "$label: no note about the missing lock file"
  refuse "$label: PIN_STRICT refuses a bundle with no lock file" env PIN_STRICT=true ./image_pull_push.sh -f "$(ls container_images_*.tar.gz)" keep
  rm -f container_images_*.tar.gz
  env PIN_STRICT=true ./image_pull_push.sh -f plain.txt keep >"$W/o" 2>&1 && bad "$label: PIN_STRICT accepted a plain line" || ok "$label: PIN_STRICT refuses a plain line"
  expect "$label: PIN_STRICT accepts a pinned list" env PIN_STRICT=true ./image_pull_push.sh -f images.pinned.txt keep
}
store_round classic
docker info --format '{{json .DriverStatus}}' | grep -q snapshotter && echo "note: this Docker already uses the containerd store"
# Switch to the containerd image store, and repeat
python3 - <<'P'
import json
p='/etc/docker/daemon.json'
d=json.load(open(p))
d.setdefault('features',{})['containerd-snapshotter']=True
json.dump(d,open(p,'w'),indent=2)
P
systemctl restart docker
docker info --format '{{json .DriverStatus}}' | grep -q snapshotter && ok "switched to the containerd store" || bad "still on the classic store"
store_round containerd
# A bundle from the other store must not fail falsely
docker rmi -f alpine:3.20 busybox:1.36 >/dev/null 2>&1
expect "a bundle from the other image store loads" ./image_pull_push.sh -f "$W/bundle-classic.tar.gz" keep
grep -q "can't be compared" "$W/o" && ok "and says the IDs can't be compared" || bad "no note about the image stores"
# A pinned Docker through save
rm -f container_images_*.tar.gz
expect "save with DOCKER_VERSION bundles that Docker" env DOCKER_VERSION=28.5 ./image_pull_push.sh -f plain.txt save
held=$(tar -xzf "$(ls container_images_*.tar.gz)" offline-packages.tar.gz -O | tar -tzf - | grep 'docker-ce_')
[[ "$held" == *docker-ce_5%3a28.5* ]] && ok "the bundle holds Docker 28.5" || bad "the bundle holds: $held"
echo "=== exit $fail"
exit $fail
