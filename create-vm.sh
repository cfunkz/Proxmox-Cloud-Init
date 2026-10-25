#!/usr/bin/env bash
# create-vm: Ubuntu cloud-init VM for the segmented homelab
set -euo pipefail

die()  { echo "ERROR: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null || die "Missing dependency: $1"; }
log()  { echo "[+] $*"; }

prompt_default() {
  local q="$1" d="$2" __v="$3" a
  read -rp "$q [$d]: " a
  printf -v "$__v" "%s" "${a:-$d}"
}

prompt_required() {
  local q="$1" __v="$2" a=""
  while [[ -z "$a" ]]; do read -rp "$q: " a; done
  printf -v "$__v" "%s" "$a"
}

is_ipv4() {
  local ip="$1" a b c d o
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS='.' read -r a b c d <<<"$ip"
  for o in "$a" "$b" "$c" "$d"; do (( 10#$o <= 255 )) || return 1; done
}

for dep in qm pvesm awk wget openssl sha256sum ip; do need "$dep"; done

# Bridge -> subnet prefix and gateway (the guide's IP plan)
declare -A PREFIX=( [vmbr0]=192.168.1 [vmbr10]=10.10.10 [vmbr20]=10.10.20 [vmbr31]=10.10.31 [vmbr32]=10.10.32 )
declare -A GWS=( [vmbr0]=192.168.1.1 [vmbr10]=10.10.10.1 [vmbr20]=10.10.20.1 [vmbr31]=10.10.31.1 [vmbr32]=10.10.32.1 )

SNIP_STORE="local"
SNIP_DIR="/var/lib/vz/snippets"
SNIP_NAME="ubuntu-base.yaml"
IMG_DIR="/var/lib/vz/template/cloudimg"

VMID=""
CREATED=0
on_exit() {
  local rc=$?
  if (( rc != 0 && CREATED == 1 )); then
    echo "Build failed after VM $VMID was created. Remove it with: qm destroy $VMID --purge" >&2
  fi
}
trap on_exit EXIT

# Fail early if snippets are not enabled
pvesm status --content snippets 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "$SNIP_STORE" || die "Storage '$SNIP_STORE' does not allow snippets (see the one-time setup)"

echo "=== Proxmox: Ubuntu cloud-init VM ==="
echo

prompt_required "VMID (numeric)" VMID
[[ "$VMID" =~ ^[0-9]+$ ]]     || die "VMID must be numeric"
qm status "$VMID" &>/dev/null && die "VMID $VMID already exists"

prompt_default "VM name" "ubuntu-vm" VMNAME
[[ "$VMNAME" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || die "VM name: letters, digits, dots and dashes only"

prompt_default "Storage" "local-lvm" STORAGE
pvesm status | awk 'NR>1{print $1}' | grep -qx "$STORAGE" || die "Storage '$STORAGE' not found"

prompt_default "Disk size (e.g. 100G)" "100G" DISK_SIZE
[[ "$DISK_SIZE" =~ ^[0-9]+G$ ]] || die "Disk size must look like 100G"
prompt_default "Memory (MB)" "8192" MEM
prompt_default "CPU cores" "4" CORES
[[ "$MEM" =~ ^[0-9]+$ && "$CORES" =~ ^[0-9]+$ ]] || die "Memory and cores must be numbers"

echo
echo "Bridges: vmbr0 home LAN | vmbr10 MGMT | vmbr20 SERVICES | vmbr31 DMZ-STATX | vmbr32 DMZ-APPWRITE"
prompt_default "Network bridge" "vmbr20" BRIDGE
ip link show "$BRIDGE" &>/dev/null || die "Bridge '$BRIDGE' does not exist"
prompt_default "Proxmox firewall on this NIC (0 = off, OPNsense filters)" "0" FW
[[ "$FW" == 0 || "$FW" == 1 ]] || die "Enter 0 or 1"

DEF_PREFIX="${PREFIX[$BRIDGE]:-192.168.1}"
DEF_GW="${GWS[$BRIDGE]:-192.168.1.1}"

echo
echo "=== Network ==="
IP_ADDR="" CIDR="" GATEWAY="" DNS="" IPCONFIG0=""
read -rp "Use DHCP? (y/N): " USE_DHCP
USE_DHCP="${USE_DHCP,,}"
if [[ "$USE_DHCP" == "y" ]]; then
  IPCONFIG0="ip=dhcp"; IP_ADDR="(DHCP)"; CIDR="-"; GATEWAY="-"; DNS="(DHCP)"
else
  prompt_default "IP address" "${DEF_PREFIX}.50" IP_ADDR
  is_ipv4 "$IP_ADDR" || die "Invalid IP address"
  prompt_default "CIDR" "24" CIDR
  [[ "$CIDR" =~ ^[0-9]+$ ]] && (( 10#$CIDR >= 8 && 10#$CIDR <= 30 )) || die "CIDR must be between 8 and 30"
  prompt_default "Gateway" "$DEF_GW" GATEWAY
  is_ipv4 "$GATEWAY" || die "Invalid gateway"
  [[ "$IP_ADDR" != "$GATEWAY" ]] || die "IP address cannot be the gateway"
  prompt_default "DNS" "$GATEWAY" DNS
  is_ipv4 "$DNS" || die "Invalid DNS"
  IPCONFIG0="ip=${IP_ADDR}/${CIDR},gw=${GATEWAY}"
fi

echo
echo "=== Cloud-init user ==="
prompt_default "Username" "ubuntu" CIUSER
read -rsp "Password (blank = generate): " CIPASS
echo
if [[ -z "$CIPASS" ]]; then
  CIPASS="$(openssl rand -base64 15)"
  echo "  Generated password: $CIPASS"
fi
read -rp "SSH public key file or key line (Enter to skip): " SSHKEY_IN

echo
prompt_default "Ubuntu image URL" "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img" IMG_URL
IMG_NAME="${IMG_URL##*/}"
IMG_PATH="${IMG_DIR}/${IMG_NAME}"

echo
echo "=== Summary ==="
echo "  VM      : $VMID ($VMNAME)"
echo "  Storage : $STORAGE | Disk $DISK_SIZE | RAM ${MEM} MB | $CORES cores"
echo "  Network : $BRIDGE (firewall=$FW) | IP $IP_ADDR/$CIDR | GW $GATEWAY | DNS $DNS"
echo "  User    : $CIUSER"
echo "  Check the IP is not used by another VM: the host cannot ping inside the new bridges."
read -rp "Proceed? (y/N): " OK
[[ "${OK,,}" == "y" ]] || die "Aborted"

# Cloud-init vendor snippet: installs the guest agent
mkdir -p "$SNIP_DIR"
if [[ ! -f "$SNIP_DIR/$SNIP_NAME" ]]; then
  log "Creating cloud-init snippet $SNIP_NAME..."
  cat > "$SNIP_DIR/$SNIP_NAME" <<'EOF'
#cloud-config
package_update: true
packages:
  - qemu-guest-agent
runcmd:
  - [ systemctl, enable, --now, qemu-guest-agent ]
EOF
fi

# Image: cached and checksum-verified
mkdir -p "$IMG_DIR"
log "Fetching checksums..."
wget -q -O "$IMG_DIR/SHA256SUMS" "${IMG_URL%/*}/SHA256SUMS" || die "Could not download SHA256SUMS"
SUM_LINE="$(awk -v f="$IMG_NAME" '$2==f || $2=="*"f' "$IMG_DIR/SHA256SUMS")"
[[ -n "$SUM_LINE" ]] || die "No checksum listed for $IMG_NAME"
verify_img() { ( cd "$IMG_DIR" && printf '%s\n' "$SUM_LINE" | sha256sum -c --status ); }
if [[ -s "$IMG_PATH" ]] && verify_img; then
  log "Using cached image (checksum OK)"
else
  log "Downloading cloud image..."
  wget -q --show-progress -O "$IMG_PATH.part" "$IMG_URL" || die "Download failed"
  mv "$IMG_PATH.part" "$IMG_PATH"
  verify_img || { rm -f "$IMG_PATH"; die "Checksum mismatch, image deleted"; }
fi

log "Creating VM..."
qm create "$VMID" --name "$VMNAME" --ostype l26 --memory "$MEM" --balloon 0 --cores "$CORES" --cpu host --machine q35 --bios ovmf --scsihw virtio-scsi-single --net0 "virtio,bridge=${BRIDGE},firewall=${FW}" --agent enabled=1 --serial0 socket --vga std --tablet 0 --onboot 1 --startup order=2
CREATED=1

log "Adding EFI disk..."
qm set "$VMID" --efidisk0 "${STORAGE}:0,efitype=4m,pre-enrolled-keys=0"

log "Importing OS disk..."
qm disk import "$VMID" "$IMG_PATH" "$STORAGE"
OS_VOL="$(qm config "$VMID" | awk -F': ' '/^unused0:/{print $2; exit}')"
[[ -n "$OS_VOL" ]] || die "Import failed: no unused disk in VM config"
qm set "$VMID" --scsi0 "${OS_VOL},discard=on,iothread=1,cache=none"

log "Configuring cloud-init..."
qm set "$VMID" --ide2 "${STORAGE}:cloudinit"
qm set "$VMID" --ciuser "$CIUSER" --cipassword "$CIPASS" --ipconfig0 "$IPCONFIG0" --cicustom "vendor=${SNIP_STORE}:snippets/${SNIP_NAME}"
if [[ "$USE_DHCP" != "y" ]]; then
  qm set "$VMID" --nameserver "$DNS"
fi

if [[ -n "${SSHKEY_IN:-}" ]]; then
  if [[ -f "$SSHKEY_IN" ]]; then
    qm set "$VMID" --sshkeys "$SSHKEY_IN"
  else
    KEYFILE="$(mktemp)"
    printf "%s\n" "$SSHKEY_IN" > "$KEYFILE"
    qm set "$VMID" --sshkeys "$KEYFILE"
    rm -f "$KEYFILE"
  fi
fi

log "Resizing disk to ${DISK_SIZE}..."
qm resize "$VMID" scsi0 "$DISK_SIZE"
qm set "$VMID" --boot order=scsi0

log "Starting VM..."
qm start "$VMID"
CREATED=0

echo
echo "VM $VMID ($VMNAME) created and started"
echo "  IP       : $IP_ADDR"
echo "  User     : $CIUSER"
echo "  Password : $CIPASS"
echo "  Console  : qm terminal $VMID  (serial, Ctrl+O to exit)"
echo "  The guest agent installs on first boot; give it 2 minutes."
