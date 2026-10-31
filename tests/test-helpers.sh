#!/usr/bin/env bash
# Unit tests for the pure helpers in create-vm.sh: bash tests/test-helpers.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
# shellcheck source=../create-vm.sh
source ./create-vm.sh
set +e; trap - EXIT ERR INT TERM

pass=0 fail=0
eq() { if [[ "$2" == "$3" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1: got '$2' want '$3'"; fi; }
ok() { if "${@:2}"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1"; fi; }
no() { if "${@:2}"; then fail=$((fail + 1)); echo "FAIL: $1"; else pass=$((pass + 1)); fi; }

ok "valid ip" is_ipv4 10.5.0.20
no "octet > 255" is_ipv4 10.5.0.256
no "3 octets" is_ipv4 10.5.0
ok "leading zero" is_ipv4 010.005.000.020

eq "int roundtrip" "$(int2ip "$(ip2int 192.168.1.77)")" 192.168.1.77
eq "net /24" "$(int2ip "$(net_int 10.5.0.20 24)")" 10.5.0.0
eq "net /22" "$(int2ip "$(net_int 10.5.3.20 22)")" 10.5.0.0
eq "bcast /22" "$(int2ip "$(bcast_int 10.5.1.20 22)")" 10.5.3.255
eq "bcast /0" "$(int2ip "$(bcast_int 1.2.3.4 0)")" 255.255.255.255

eq "gw /24" "$(predict_gateway 10.5.0.20 24)" 10.5.0.1
eq "gw /22" "$(predict_gateway 172.16.2.9 22)" 172.16.0.1
eq "gw /28 mid" "$(predict_gateway 10.0.0.37 28)" 10.0.0.33
eq "gw when vm is .1" "$(predict_gateway 10.5.0.1 24)" 10.5.0.254
eq "gw /30" "$(predict_gateway 10.9.9.6 30)" 10.9.9.5
eq "gw /31 none" "$(predict_gateway 10.9.9.6 31)" ""

ok "in subnet" in_subnet 10.5.0.200 10.5.0.1 24
no "outside subnet" in_subnet 10.5.1.2 10.5.0.1 24
ok "host addr" is_host_addr 10.5.0.20 24
no "network addr" is_host_addr 10.5.0.0 24
no "broadcast addr" is_host_addr 10.5.0.255 24
ok "/32 host" is_host_addr 10.5.0.255 32

eq "free ip from .100" "$(suggest_free_ip 10.5.0.1 24 10.5.0.1)" 10.5.0.100
eq "skips used" "$(suggest_free_ip 10.5.0.1 24 10.5.0.100 10.5.0.101)" 10.5.0.102
eq "small net from .2" "$(suggest_free_ip 10.0.0.33 28 10.0.0.33)" 10.0.0.34

t="$(mktemp -d)"
printf '%s *noble-server-cloudimg-amd64.img\n%s *other.img\n' "$(printf 'a%.0s' {1..64})" "$(printf 'b%.0s' {1..64})" >"$t/gnu"
eq "gnu sha256" "$(checksum_lookup "$t/gnu" noble-server-cloudimg-amd64.img)" "sha256 $(printf 'a%.0s' {1..64})"
printf '%s  debian-13-genericcloud-amd64.qcow2\r\n' "$(printf 'C%.0s' {1..128})" >"$t/deb"
eq "sha512 + CRLF + lowercase" "$(checksum_lookup "$t/deb" debian-13-genericcloud-amd64.qcow2)" "sha512 $(printf 'c%.0s' {1..128})"
printf -- '-----BEGIN PGP SIGNED MESSAGE-----\n# Fedora-Cloud-Base-Generic-43-1.6.x86_64.qcow2: 1 bytes\nSHA256 (Fedora-Cloud-Base-Generic-43-1.6.x86_64.qcow2) = %s\n' "$(printf 'd%.0s' {1..64})" >"$t/bsd"
eq "bsd format" "$(checksum_lookup "$t/bsd" Fedora-Cloud-Base-Generic-43-1.6.x86_64.qcow2)" "sha256 $(printf 'd%.0s' {1..64})"
printf 'SHA256 (Rocky-9-GenericCloud-Base-9.6-20250531.0.x86_64.qcow2) = %s\n' "$(printf 'e%.0s' {1..64})" >"$t/rocky"
no "name mismatch" checksum_lookup "$t/rocky" Rocky-9-GenericCloud-Base.latest.x86_64.qcow2
eq "single-entry file" "$(checksum_lookup "$t/rocky" Rocky-9-GenericCloud-Base.latest.x86_64.qcow2 1)" "sha256 $(printf 'e%.0s' {1..64})"
rm -rf "$t"

ok "vlan blank" v_vlan ""
no "vlan 4095" v_vlan 4095 2>/dev/null
ok "dns list" v_dns "1.1.1.1, 9.9.9.9"
no "dns bad" v_dns "1.1.1" 2>/dev/null
no "name underscore" v_name "bad_name" 2>/dev/null
ok "name fqdn" v_name "web-01.lab.lan"

echo "$pass passed, $fail failed"
(( fail == 0 ))
