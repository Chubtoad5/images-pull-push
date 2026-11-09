#!/usr/bin/env bats
# Spec 15, Q9: the save bundle's LICENSES/ lists its OS packages and carries a written offer for the GPL and LGPL ones.
load ../helpers
setup() {
  load_script image_pull_push.sh
  D=$(mktemp -d)
  LICENSE_OFFER_CONTACT=me@example.invalid
}
pkgs() { # pkgs <file names...>: an offline-packages.tar.gz in $D holding them
  local s; s=$(mktemp -d); mkdir -p "$s/offline-packages"
  for n in "$@"; do touch "$s/offline-packages/$n"; done
  tar -czf "$D/offline-packages.tar.gz" -C "$s" offline-packages
}
@test "the manifest lists the bundle's OS packages, and the offer names the contact" {
  pkgs docker-ce-29.1.0-1.el10.x86_64.rpm kernel-modules-extra-6.12.0-211.16.1.el10_2.0.1.x86_64.rpm iptables-1.8.11-1.el10.x86_64.rpm
  generate_bundle_licenses "$D"
  grep -q "^  docker-ce-29.1.0-1.el10.x86_64.rpm$" "$D/LICENSES/THIRD_PARTY_NOTICES.txt"
  grep -q "^  kernel-modules-extra-6.12.0-211.16.1.el10_2.0.1.x86_64.rpm$" "$D/LICENSES/THIRD_PARTY_NOTICES.txt"
  grep -q "contact: me@example.invalid" "$D/LICENSES/WRITTEN_OFFER.txt"
}
@test "debs are listed too, and nothing else from the archive" {
  pkgs iptables_1.8.10-3ubuntu2_amd64.deb Packages.gz
  generate_bundle_licenses "$D"
  grep -q "^  iptables_1.8.10-3ubuntu2_amd64.deb$" "$D/LICENSES/THIRD_PARTY_NOTICES.txt"
  ! grep -q "Packages.gz" "$D/LICENSES/THIRD_PARTY_NOTICES.txt"
}
@test "with no package archive, it still writes both files" {
  generate_bundle_licenses "$D"
  grep -q "^  (none)$" "$D/LICENSES/THIRD_PARTY_NOTICES.txt"
  [ -s "$D/LICENSES/WRITTEN_OFFER.txt" ]
}
@test "save puts LICENSES in the archive" {
  grep -q '"install_packages.sh" "LICENSES"; then' "$BATS_TEST_DIRNAME/../../image_pull_push.sh"
  grep -B2 'Creating image_pull_push archive' "$BATS_TEST_DIRNAME/../../image_pull_push.sh" | grep -q 'generate_bundle_licenses "$TEMP_DIR"'
}
