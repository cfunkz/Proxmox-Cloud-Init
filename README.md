# Proxmox-Cloud-Init

`create-vm.sh` builds a cloud-init VM from the Proxmox VE shell in about a minute.
It asks a short series of questions, each with a sensible default, shows a summary
and only then touches the host.

Choices are shown as numbered lists built from what the host actually has: distros,
CPU types the host CPU supports (plus custom models), core and memory presets up to the
host's size, storages with free space, disk sizes, bridges with their IPs and GUI
comments, VLAN tags already used on a bridge, gateway candidates, DNS providers and the
SSH key files found on the host. Pick by number, by name, or type your own value where
the list says so.

```bash
wget -O create-vm.sh https://raw.githubusercontent.com/cfunkz/Proxmox-Cloud-Init/main/create-vm.sh
chmod +x create-vm.sh
./create-vm.sh --dry-run   # walk through everything, print the qm commands, change nothing
./create-vm.sh
```

## Images

| Key | Image | Verified with |
|-----|-------|---------------|
| ubuntu-26.04 / 24.04 / 22.04 | Ubuntu server cloud image | SHA256SUMS |
| debian-13 / debian-12 | Debian genericcloud | SHA512SUMS |
| rocky-10 / rocky-9 | Rocky GenericCloud Base | per-image .CHECKSUM |
| alma-10 / alma-9 | AlmaLinux GenericCloud | CHECKSUM |
| fedora | newest Fedora Cloud Base Generic release (looked up at run time) | CHECKSUM |
| custom | any qcow2/img/raw URL | checksum file URL or a pasted sha256/sha512 hash |

Images are cached in `/var/lib/vz/template/cloudimg/<key>/` and re-checked against
the upstream checksum on every run, so "latest" images are refreshed automatically.
A mismatching download is deleted. Rocky/Alma 10 need CPU type `host` or `x86-64-v3`.

## Networking

Every bridge on the host is listed (Linux bridges, SDN vnets and OVS), with its host
address, the comment set in the Proxmox GUI, and whether it is VLAN-aware. You can add
up to 8 NICs, each with its own bridge, VLAN tag, firewall flag and IPv4 mode
(dhcp/static/none) plus optional IPv6 (auto/dhcp).

For a static NIC the script predicts the network before asking:

1. **Other guests on the same bridge + VLAN**: the subnet and gateway of any VM or
   container in the cluster that already has a static address there.
2. **The host's own address** on that bridge (or its `vmbrX.TAG` / `vlanTAG`
   interface): the gateway is the host's default route if it goes out that bridge,
   otherwise the host itself (typical NAT/routed bridge).
3. **Nothing known**: you type `IP/CIDR` and the gateway defaults to the first usable
   host of that subnet (or the last one if the VM itself is the first).

It then suggests the first free address from `.100` up, skipping every IP already
configured on a guest or the host, and warns if the address answers ping. You can
type `10.5.0.20/24`, `10.5.0.20` (known prefix, else /24) or just `20` when the subnet
is known. Only one NIC gets the default gateway; later NICs default to none.
DNS defaults to that gateway (or `host` to inherit the node's resolvers).

## Security and reliability

* `set -Eeuo pipefail`, `umask 077`, every answer validated and re-asked when wrong.
* Downloads over HTTPS only (custom http needs explicit confirmation), checksums
  verified, concurrent runs locked per image.
* SSH keys are checked with `ssh-keygen` before use; passwords are typed twice,
  never echoed, or generated (shown once at the end). `none` gives key-only login.
* If anything fails after `qm create`, the half-built VM and its disks are removed
  (set `KEEP_ON_FAIL=1` to keep it). Temp files are always cleaned up.
* A vendor snippet installs and enables `qemu-guest-agent` on first boot (needs a
  storage with `snippets` content, e.g. `pvesm set local --content iso,vztmpl,backup,snippets`).

## Defaults

Copy `create-vm.conf.example` to `/etc/create-vm.conf` to change the defaults
(storage, bridge, sizes, CPU type, SSH key file, DNS...). The file is only read when
it is owned by root and not writable by group/others.

## Tests

`bash tests/test-helpers.sh` runs the unit tests for the subnet math, gateway/IP
prediction and checksum parsing (no Proxmox needed).
