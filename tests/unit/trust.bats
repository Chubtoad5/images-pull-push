#!/usr/bin/env bats
# I7 (spec 23): the registry's certificate goes to /etc/docker/certs.d/<registry>/ca.crt and to the system trust store,
# and Docker is never restarted for it. I8: the Docker 29.3 check reads the client's version with the daemon down, and
# its message names the certificate when one was trusted.
load ../helpers
REG=reg.test:5443
STORE=/usr/local/share/ca-certificates/reg.test.crt
DCERT=/etc/docker/certs.d/$REG/ca.crt
pem() { printf '%s\n' "-----BEGIN CERTIFICATE-----" "$1" "-----END CERTIFICATE-----"; }
setup() {
  load_script image_pull_push.sh
  setup_stubs
  TEMP_DIR=$(mktemp -d)
  os_id=ubuntu REGISTRY_URL=$REG CERT_WRITTEN=0
  export STUB_CHAIN=NEW
  # openssl fetches $STUB_CHAIN as the registry's chain; x509 accepts it
  stub openssl 'if [[ "$1" == s_client ]]; then printf "%s\n" "-----BEGIN CERTIFICATE-----" "$STUB_CHAIN" "-----END CERTIFICATE-----"; fi'
  stub update-ca-certificates
  stub docker
  # systemctl is-active answers $STUB_ACTIVE (0 = running)
  stub systemctl '[[ "$1" == is-active ]] && exit "${STUB_ACTIVE:-0}"; exit 0'
  rm -f "$STORE" "$DCERT"; rmdir "/etc/docker/certs.d/$REG" 2>/dev/null || true
  mkdir -p /usr/local/share/ca-certificates
}
teardown() {
  rm -f "$STORE" "$DCERT"; rmdir "/etc/docker/certs.d/$REG" 2>/dev/null || true
}

@test "I7: a new certificate goes to certs.d and the trust store, and Docker isn't restarted" {
  run install_registry_cert
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(cat "$DCERT")" = "$(pem NEW)" ]
  [ "$(cat "$STORE")" = "$(pem NEW)" ]
  [ "$(stat -c %a "$DCERT")" = 644 ]
  [ "$(stat -c %a "/etc/docker/certs.d/$REG")" = 755 ]
  called update-ca-certificates
  ! called "systemctl restart" || false
  [[ "$output" == *"$DCERT, which Docker reads without a restart"* ]]
}
@test "I7: an unchanged certificate writes nothing and starts nothing" {
  mkdir -p "/etc/docker/certs.d/$REG"; pem NEW > "$DCERT"; pem NEW > "$STORE"
  run install_registry_cert
  [ "$status" -eq 0 ]
  [[ "$output" == *"already installed and unchanged"* ]]
  ! called update-ca-certificates || false
  ! called "systemctl" || false
}
@test "I7: a host an earlier release trusted (trust store only) gets the certs.d copy, with no restart" {
  pem NEW > "$STORE"
  run install_registry_cert
  [ "$status" -eq 0 ]
  [ "$(cat "$DCERT")" = "$(pem NEW)" ]
  ! called update-ca-certificates || false
  ! called "systemctl restart" || false
}
@test "I7: a renewed certificate replaces both copies" {
  mkdir -p "/etc/docker/certs.d/$REG"; pem OLD > "$DCERT"; pem OLD > "$STORE"
  run install_registry_cert
  [ "$status" -eq 0 ]
  [ "$(cat "$DCERT")" = "$(pem NEW)" ]
  [ "$(cat "$STORE")" = "$(pem NEW)" ]
  ! called "systemctl restart" || false
}
@test "I7: a stopped Docker is started, not restarted" {
  export STUB_ACTIVE=3
  run install_registry_cert
  [ "$status" -eq 0 ]
  called "systemctl start docker"
  ! called "systemctl restart" || false
}
@test "I7: a running Docker is left alone" {
  export STUB_ACTIVE=0
  run install_registry_cert
  [ "$status" -eq 0 ]
  ! called "systemctl start" || false
  ! called "systemctl restart" || false
}
@test "I7: a Docker that won't start stops the run" {
  export STUB_ACTIVE=3
  stub systemctl '[[ "$1" == is-active ]] && exit 3; [[ "$1" == start ]] && exit 1; exit 0'
  run install_registry_cert
  [ "$status" -eq 1 ]
  [[ "$output" == *"'systemctl start docker' failed"* ]]
}
@test "I7: a registry that isn't <host>:<port> is refused before anything is written" {
  for r in "reg.test:5443/x" "../etc:443" "" "reg.test:https" "reg.test" ".hidden:443"; do
    REGISTRY_URL=$r
    run install_registry_cert
    [ "$status" -eq 1 ]
    [[ "$output" == *"must be given as <host>:<port>"* ]]
  done
  [ ! -e "$STORE" ]
  [ ! -e /etc/docker/certs.d/reg.test:5443/x ]
}
@test "I7: an IPv4 address and an FQDN with a port are accepted" {
  for r in 192.168.10.215:5000 harbor.lab.example:8443; do
    REGISTRY_URL=$r
    run install_registry_cert
    [ "$status" -eq 0 ]
    [ -s "/etc/docker/certs.d/$r/ca.crt" ]
    rm -f "/etc/docker/certs.d/$r/ca.crt" "/usr/local/share/ca-certificates/${r%%:*}.crt"; rmdir "/etc/docker/certs.d/$r"
  done
}
@test "I7: certs.d is named after the registry as given, port included" {
  REGISTRY_URL=reg.test:443
  run install_registry_cert
  [ "$status" -eq 0 ]
  [ -s /etc/docker/certs.d/reg.test:443/ca.crt ]
  rm -f /etc/docker/certs.d/reg.test:443/ca.crt; rmdir /etc/docker/certs.d/reg.test:443
}
@test "I8: an old Docker whose daemon is down is still seen as trimming the password" {
  stub docker '[[ "$1" == version ]] && { echo 28.5.2; exit 1; }; exit 0'
  docker_trims_password
}
@test "I8: a new Docker whose daemon is down isn't" {
  stub docker '[[ "$1" == version ]] && { echo 29.9.3; exit 1; }; exit 0'
  ! docker_trims_password || false
}
@test "I8: after a Docker install, the refusal names the certificate it trusted" {
  stub docker '[[ "$1" == version ]] && echo 28.5.2; exit 0'
  REGISTRY_USER=robot REGISTRY_PASS=" Aa1 pass " CERT_WRITTEN=1
  run check_password_ends installed
  [ "$status" -eq 1 ]
  [[ "$output" == *"Docker was installed and"* ]]
  [[ "$output" == *"certificate trusted (the system trust store and /etc/docker/certs.d/$REG)"* ]]
  [[ "$output" != *"Only Docker was installed"* ]]
}
@test "I8: with no certificate written, the refusal still says only Docker was installed" {
  stub docker '[[ "$1" == version ]] && echo 28.5.2; exit 0'
  REGISTRY_USER=robot REGISTRY_PASS=" Aa1 pass " CERT_WRITTEN=0
  run check_password_ends installed
  [ "$status" -eq 1 ]
  [[ "$output" == *"Only Docker was installed"* ]]
}
