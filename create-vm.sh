#!/usr/bin/env bash
# create-vm.sh: interactive cloud-init VM builder for Proxmox VE
#
# Pick a distro, a storage and any bridge(s); for static addressing the script
# predicts subnet, gateway, a free IP and DNS from the host, its routes and the
# other guests already on that bridge/VLAN. Every answer can be overridden.
#
# Usage: create-vm.sh [--dry-run] [--help]
set -Eeuo pipefail
umask 077

VERSION="2.0.0"

# ---------------------------------------------------------------------------
# Defaults (override in /etc/create-vm.conf, see create-vm.conf.example)
# ---------------------------------------------------------------------------
DEF_DISTRO="ubuntu-24.04"
DEF_STORAGE=""            # blank = local-lvm if present, else first image storage
DEF_BRIDGE=""             # blank = bridge holding the host's default route
DEF_DISK="32G"
DEF_MEM="2048"
DEF_CORES="2"
DEF_CPU="host"            # Rocky/Alma 10 need x86-64-v3 or host
DEF_BIOS="ovmf"
DEF_FW="1"                # Proxmox firewall flag on the NIC (no effect unless enabled in the datacenter)
DEF_SSHKEYS="/root/.ssh/authorized_keys"
DEF_DNS=""                # blank = gateway of the first static NIC
DEF_SEARCHDOMAIN=""       # blank = search domain from the host's resolv.conf
DEF_ONBOOT="1"
DEF_UPGRADE="1"           # upgrade packages on first boot
SNIPPET_STORAGE=""        # blank = first storage with "snippets" content
IMG_DIR="/var/lib/vz/template/cloudimg"
KEEP_ON_FAIL="0"          # 1 = keep a half-built VM instead of destroying it
SYS_NET="${SYS_NET:-/sys/class/net}"   # overridable for tests
PVE_DIR="${PVE_DIR:-/etc/pve}"

CONF_FILE="${CREATE_VM_CONF:-/etc/create-vm.conf}"
DRY_RUN=0

# Distro catalog: key|label|default user|image URL|checksum URL
#   checksum URL "@file" = per-image checksum file (<image URL>.CHECKSUM, single entry)
#   image URL "fedora"   = resolved to the newest Fedora Cloud release at runtime
CATALOG=(
  "ubuntu-26.04|Ubuntu 26.04 LTS (Resolute)|ubuntu|https://cloud-images.ubuntu.com/resolute/current/resolute-server-cloudimg-amd64.img|https://cloud-images.ubuntu.com/resolute/current/SHA256SUMS"
  "ubuntu-24.04|Ubuntu 24.04 LTS (Noble)|ubuntu|https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img|https://cloud-images.ubuntu.com/noble/current/SHA256SUMS"
  "ubuntu-22.04|Ubuntu 22.04 LTS (Jammy)|ubuntu|https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img|https://cloud-images.ubuntu.com/jammy/current/SHA256SUMS"
  "debian-13|Debian 13 (Trixie)|debian|https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2|https://cloud.debian.org/images/cloud/trixie/latest/SHA512SUMS"
  "debian-12|Debian 12 (Bookworm)|debian|https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2|https://cloud.debian.org/images/cloud/bookworm/latest/SHA512SUMS"
  "rocky-10|Rocky Linux 10|rocky|https://dl.rockylinux.org/pub/rocky/10/images/x86_64/Rocky-10-GenericCloud-Base.latest.x86_64.qcow2|@file"
  "rocky-9|Rocky Linux 9|rocky|https://dl.rockylinux.org/pub/rocky/9/images/x86_64/Rocky-9-GenericCloud-Base.latest.x86_64.qcow2|@file"
  "alma-10|AlmaLinux 10|almalinux|https://repo.almalinux.org/almalinux/10/cloud/x86_64/images/AlmaLinux-10-GenericCloud-latest.x86_64.qcow2|https://repo.almalinux.org/almalinux/10/cloud/x86_64/images/CHECKSUM"
  "alma-9|AlmaLinux 9|almalinux|https://repo.almalinux.org/almalinux/9/cloud/x86_64/images/AlmaLinux-9-GenericCloud-latest.x86_64.qcow2|https://repo.almalinux.org/almalinux/9/cloud/x86_64/images/CHECKSUM"
  "fedora|Fedora Cloud (latest release)|fedora|fedora|"
  "custom|Custom image URL|cloud|custom|"
)

# ---------------------------------------------------------------------------
# Output and prompts
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then C_B=$'\e[1m' C_D=$'\e[2m' C_G=$'\e[32m' C_Y=$'\e[33m' C_R=$'\e[31m' C_0=$'\e[0m'
else C_B="" C_D="" C_G="" C_Y="" C_R="" C_0=""; fi

die()  { echo "${C_R}ERROR:${C_0} $*" >&2; exit 1; }
warn() { echo "${C_Y}WARN:${C_0} $*" >&2; }
log()  { echo "${C_G}[+]${C_0} $*"; }
hint() { echo "  ${C_D}$*${C_0}"; }
hdr()  { echo; echo "${C_B}=== $* ===${C_0}"; }

# ask VAR "Question" "default" [validator]: re-asks until the validator accepts
ask() {
  local __var="$1" q="$2" def="${3:-}" check="${4:-}" a
  while true; do
    if [[ -n "$def" ]]; then read -erp "$q [$def]: " a || exit 130
    else read -erp "$q: " a || exit 130; fi
    a="${a:-$def}"
    a="${a#"${a%%[![:space:]]*}"}"; a="${a%"${a##*[![:space:]]}"}"
    if [[ -n "$check" ]]; then "$check" "$a" || continue
    elif [[ -z "$a" ]]; then continue; fi
    printf -v "$__var" '%s' "$a"
    return 0
  done
}

# ask_yn "Question" y|n: returns 0 for yes
ask_yn() {
  local q="$1" def="${2:-n}" a
  while true; do
    read -erp "$q [$([[ $def == y ]] && echo Y/n || echo y/N)]: " a || exit 130
    a="${a:-$def}"
    case "${a,,}" in y|yes) return 0 ;; n|no) return 1 ;; esac
  done
}

# menu VAR "Question" default "value|description"...: numbered list, pick by number or value.
# Set MENU_FREE=<validator> right before the call to also accept other typed values.
menu() {
  local __var="$1" q="$2" def="$3" free="${MENU_FREE:-}" a e v d i
  MENU_FREE=""
  shift 3
  local vals=() w=8
  for e in "$@"; do v="${e%%|*}"; (( ${#v} > w )) && w=${#v}; done
  for e in "$@"; do
    v="${e%%|*}"; d=""; [[ "$e" == *"|"* ]] && d="${e#*|}"
    vals+=("$v")
    printf '  %s%2d) %-*s  %s%s\n' "$([[ $v == "$def" ]] && echo "*" || echo " ")" "${#vals[@]}" "$w" "$v" "${C_D}" "$d${C_0}"
  done
  [[ -n "$free" ]] && hint "...or type another value"
  while true; do
    read -erp "$q [$def]: " a || exit 130
    a="${a:-$def}"
    if [[ "$a" =~ ^[0-9]+$ ]] && (( 10#$a >= 1 && 10#$a <= ${#vals[@]} )); then
      printf -v "$__var" '%s' "${vals[10#$a-1]}"; return 0
    fi
    for v in "${vals[@]}"; do
      [[ "$a" == "$v" ]] && { printf -v "$__var" '%s' "$a"; return 0; }
    done
    if [[ -n "$free" && -n "$a" ]] && "$free" "$a"; then printf -v "$__var" '%s' "$a"; return 0; fi
    [[ -n "$free" ]] || echo "  Pick 1-${#vals[@]}" >&2
  done
}

run() {
  if (( DRY_RUN )); then
    local a hide=0
    printf '%s+%s' "$C_D" "$C_0" >&2
    for a in "$@"; do (( hide )) && a="********"; [[ "$a" == --cipassword ]] && hide=1 || hide=0; printf ' %q' "$a" >&2; done
    echo >&2
  else "$@" || die "Command failed: $1 $2 ${3:-}"; fi
}

# ---------------------------------------------------------------------------
# IPv4 math (pure bash)
# ---------------------------------------------------------------------------
is_ipv4() {
  local ip="$1" o
  [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  for o in "${BASH_REMATCH[@]:1}"; do (( 10#$o <= 255 )) || return 1; done
}
ip2int() { local a b c d; IFS=. read -r a b c d <<<"$1"; echo $(( (10#$a << 24) | (10#$b << 16) | (10#$c << 8) | 10#$d )); }
int2ip() { local n="$1"; echo "$(( (n >> 24) & 255 )).$(( (n >> 16) & 255 )).$(( (n >> 8) & 255 )).$(( n & 255 ))"; }
mask_int() { local p="$1"; (( p == 0 )) && echo 0 || echo $(( (0xFFFFFFFF << (32 - p)) & 0xFFFFFFFF )); }
net_int()   { echo $(( $(ip2int "$1") & $(mask_int "$2") )); }
bcast_int() { echo $(( $(net_int "$1" "$2") | (~$(mask_int "$2") & 0xFFFFFFFF) )); }
first_host() { local p="$2"; (( p >= 31 )) && int2ip "$(net_int "$1" "$p")" || int2ip $(( $(net_int "$1" "$p") + 1 )); }
last_host()  { local p="$2"; (( p >= 31 )) && int2ip "$(bcast_int "$1" "$p")" || int2ip $(( $(bcast_int "$1" "$p") - 1 )); }
in_subnet() { [[ "$(net_int "$1" "$3")" == "$(net_int "$2" "$3")" ]]; }   # in_subnet IP NETIP PREFIX
is_prefix() { [[ "$1" =~ ^[0-9]{1,2}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 32 )); }

# Gateway guess for IP/PREFIX: first usable host, or the last one when the VM itself is the first
predict_gateway() {
  local ip="$1" p="$2" g
  (( p >= 31 )) && return 0
  g="$(first_host "$ip" "$p")"
  [[ "$g" == "$ip" ]] && g="$(last_host "$ip" "$p")"
  echo "$g"
}

# Address usable for a host? (not network/broadcast on /1-/30)
is_host_addr() {
  local ip="$1" p="$2" n
  (( p >= 31 )) && return 0
  n="$(ip2int "$ip")"
  (( n != $(net_int "$ip" "$p") && n != $(bcast_int "$ip" "$p") ))
}

# ---------------------------------------------------------------------------
# Host discovery
# ---------------------------------------------------------------------------
list_bridges() {
  local d b
  {
    for d in "$SYS_NET"/*/bridge; do
      [[ -d "$d" ]] || continue
      b="${d%/bridge}"; b="${b##*/}"
      [[ "$b" =~ ^(fwbr|fwpr|fwln|vmbr[0-9]+v[0-9]+$) ]] && continue
      echo "$b"
    done
    if command -v ovs-vsctl >/dev/null 2>&1; then ovs-vsctl list-br 2>/dev/null || true; fi
  } | sort -uV
}

iface_ipv4() { ip -4 -o addr show dev "$1" scope global 2>/dev/null | awk '{print $4; exit}'; }
default_route() { ip -4 route show default 2>/dev/null | awk '{for(i=1;i<NF;i++){if($i=="via")g=$(i+1);if($i=="dev")d=$(i+1)}; print d"|"g; exit}'; }
vlan_aware() { [[ "$(cat "$SYS_NET/$1/bridge/vlan_filtering" 2>/dev/null)" == 1 ]]; }

# Comment Proxmox stores in /etc/network/interfaces for an interface (shown in the GUI)
iface_comment() {
  awk -v want="$1" '
    $1=="iface" { cur=$2; next }
    $1=="auto" || $1=="allow-hotplug" || NF==0 { cur="" ; next }
    cur==want && /^#/ { sub(/^#+[ ]*/,""); print; exit }
  ' /etc/network/interfaces 2>/dev/null || true
}

# Every guest NIC in the cluster: kind|id|bridge|tag|ip/prefix|gw (ip may be dhcp/empty)
guest_addresses() {
  local files=()
  shopt -s nullglob
  files=("$PVE_DIR"/nodes/*/qemu-server/*.conf "$PVE_DIR"/nodes/*/lxc/*.conf)
  shopt -u nullglob
  (( ${#files[@]} )) || return 0
  awk '
    FNR==1 { stop=0; f=FILENAME; id=f; sub(/.*\//,"",id); sub(/\.conf$/,"",id)
             kind[f]=(f ~ /\/lxc\//) ? "ct" : "vm"; ids[f]=id }
    /^\[/ { stop=1 }
    stop { next }
    /^(net|ipconfig)[0-9]+: / {
      key=$1; sub(/:$/,"",key); idx=key; sub(/^[a-z]+/,"",idx)
      val=substr($0, length($1)+2); m=split(val, kv, ",")
      for (i=1; i<=m; i++) {
        eq=index(kv[i],"="); if (!eq) continue
        k=substr(kv[i],1,eq-1); v=substr(kv[i],eq+1)
        if (k=="bridge") BR[f,idx]=v; else if (k=="tag") TG[f,idx]=v
        else if (k=="ip") IP[f,idx]=v; else if (k=="gw") GW[f,idx]=v
      }
      SEEN[f,idx]=1
    }
    END { for (k in SEEN) { split(k,a,SUBSEP)
            print kind[a[1]] "|" ids[a[1]] "|" BR[k] "|" TG[k] "|" IP[k] "|" GW[k] } }
  ' "${files[@]}" 2>/dev/null || true
}

host_cores()  { nproc 2>/dev/null || echo 1; }
host_mem_mb() { awk -v k="${1:-MemTotal}:" '$1==k{print int($2/1024); exit}' /proc/meminfo 2>/dev/null || echo 0; }
host_has_flags() { local f fl; fl=" $(awk -F: '/^flags/{print $2; exit}' /proc/cpuinfo 2>/dev/null) "; for f in "$@"; do [[ "$fl" == *" $f "* ]] || return 1; done; }
host_resolvers() { awk '$1=="nameserver"{printf "%s ", $2}' /etc/resolv.conf 2>/dev/null | sed 's/ $//' || true; }
human_gib() { awk -v k="$1" 'BEGIN{ g=k/1048576; if (g>=1024) printf "%.1fT", g/1024; else printf "%.0fG", g }'; }

host_search_domain() { awk '$1=="search"||$1=="domain"{print $2; exit}' /etc/resolv.conf 2>/dev/null || true; }

# ---------------------------------------------------------------------------
# Images and checksums
# ---------------------------------------------------------------------------
fetch() { curl -fsSL --proto '=https' --tlsv1.2 --retry 3 --connect-timeout 15 "$@"; }

# checksum_lookup FILE NAME [single]: prints "sha256|sha512 HASH" for NAME.
# Understands GNU ("hash  name") and BSD ("SHA256 (name) = hash") formats.
checksum_lookup() {
  local file="$1" name="$2" single="${3:-}" line h n count=0 only=""
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    if [[ "$line" =~ ^SHA(256|512)\ \((.+)\)\ =\ ([0-9a-fA-F]+)$ ]]; then
      n="${BASH_REMATCH[2]}"; h="${BASH_REMATCH[3]}"
    elif [[ "$line" =~ ^([0-9a-fA-F]{64}|[0-9a-fA-F]{128})\ [\ *](.+)$ ]]; then
      h="${BASH_REMATCH[1]}"; n="${BASH_REMATCH[2]}"
    else continue; fi
    n="${n#./}"
    count=$(( count + 1 )); only="$h"
    if [[ "$n" == "$name" ]]; then echo "$(hash_algo "$h") ${h,,}"; return 0; fi
  done <"$file"
  if [[ -n "$single" ]] && (( count == 1 )); then echo "$(hash_algo "$only") ${only,,}"; return 0; fi
  return 1
}
hash_algo() { (( ${#1} == 128 )) && echo sha512 || echo sha256; }

file_hash() { "${1}sum" "$2" | awk '{print $1}'; }

resolve_fedora() {
  local base="https://download.fedoraproject.org/pub/fedora/linux/releases" v dir idx img sum
  for v in $(fetch "$base/" | grep -oE 'href="[0-9]+/"' | grep -oE '[0-9]+' | sort -rn | head -3); do
    dir="$base/$v/Cloud/x86_64/images"
    idx="$(fetch "$dir/" 2>/dev/null)" || continue
    img="$(grep -oE 'Fedora-Cloud-Base-Generic-[0-9][A-Za-z0-9._-]*\.x86_64\.qcow2' <<<"$idx" | sort -uV | tail -1)"
    sum="$(grep -oE 'Fedora-Cloud-[0-9][A-Za-z0-9._-]*-x86_64-CHECKSUM' <<<"$idx" | sort -uV | tail -1)"
    if [[ -n "$img" && -n "$sum" ]]; then IMG_URL="$dir/$img"; SUM_URL="$dir/$sum"; return 0; fi
  done
  die "Could not find a Fedora Cloud image under $base"
}

# Download (or reuse) IMG_URL into IMG_PATH and verify it against EXPECT ("algo hash" or empty)
get_image() {
  local algo="" want=""
  [[ -n "$EXPECT" ]] && read -r algo want <<<"$EXPECT"
  verify() { [[ -z "$want" ]] || [[ "$(file_hash "$algo" "$IMG_PATH")" == "$want" ]]; }

  if (( DRY_RUN )); then log "[dry-run] would download/verify $IMG_URL -> $IMG_PATH"; return 0; fi
  mkdir -p "${IMG_PATH%/*}"
  exec 9>"${IMG_PATH}.lock"
  flock -w 600 9 || die "Another run is downloading $IMG_PATH"

  if [[ -s "$IMG_PATH" && -n "$want" ]] && verify; then
    log "Using cached image (${algo} OK)"
    return 0
  fi
  log "Downloading ${IMG_URL##*/}..."
  TMP_FILES+=("${IMG_PATH}.part")
  curl -fL --retry 3 --connect-timeout 15 --progress-bar -o "${IMG_PATH}.part" "$IMG_URL" || die "Download failed: $IMG_URL"
  mv -f "${IMG_PATH}.part" "$IMG_PATH"
  if ! verify; then rm -f "$IMG_PATH"; die "Checksum mismatch for ${IMG_URL##*/}, image deleted"; fi
  [[ -n "$want" ]] && log "Checksum verified (${algo})"
  return 0
}

# ---------------------------------------------------------------------------
# Validators (print why, return 1 to re-ask)
# ---------------------------------------------------------------------------
v_vmid() {
  [[ "$1" =~ ^[1-9][0-9]{2,8}$ ]] || { echo "  VMID must be a number from 100 to 999999999" >&2; return 1; }
  if [[ -e "$PVE_DIR/nodes" ]] && compgen -G "$PVE_DIR/nodes/*/*/$1.conf" >/dev/null; then
    echo "  VMID $1 is already in use" >&2; return 1; fi
  if qm status "$1" &>/dev/null; then echo "  VMID $1 is already in use" >&2; return 1; fi
}
v_name() { [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$ ]] || { echo "  Use a DNS name: letters, digits, dashes, dots" >&2; return 1; }; }
v_disk() { [[ "$1" =~ ^[1-9][0-9]*[GT]?$ ]] || { echo "  Use a size like 32G or 1T" >&2; return 1; }; }
v_mem()  { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 512 )) || { echo "  Memory in MB, at least 512" >&2; return 1; }; }
v_cores() { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 512 )) || { echo "  1 or more cores" >&2; return 1; }; }
v_01()   { [[ "$1" == 0 || "$1" == 1 ]] || { echo "  Enter 0 or 1" >&2; return 1; }; }
v_vlan() { [[ -z "$1" || "$1" == none ]] && return 0; [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 4094 )) || { echo "  VLAN tag 1-4094, or blank for none" >&2; return 1; }; }
v_cpu()  { [[ "$1" =~ ^[A-Za-z0-9_.-]+$ ]] || { echo "  Invalid CPU type" >&2; return 1; }; }
v_user() { [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,31}$ && "$1" != root ]] || { echo "  Lowercase user name, not root" >&2; return 1; }; }
v_dns() {
  [[ "$1" == host ]] && return 0
  local s; for s in ${1//,/ }; do is_ipv4 "$s" || { echo "  '$s' is not an IPv4 address (or type 'host')" >&2; return 1; }; done
  [[ -n "${1//[ ,]/}" ]] || { echo "  Enter at least one DNS server, or 'host'" >&2; return 1; }
}
v_domain() { [[ -z "$1" || "$1" == none || "$1" =~ ^[A-Za-z0-9.-]+$ ]] || { echo "  Invalid search domain" >&2; return 1; }; }
v_url() { [[ "$1" =~ ^https?://[^[:space:]]+$ ]] || { echo "  Enter an http(s) URL" >&2; return 1; }; }
v_any() { return 0; }

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
VMID="" CREATED=0 TMP_FILES=()
on_exit() {
  local rc=$?
  set +e
  (( ${#TMP_FILES[@]} )) && rm -f "${TMP_FILES[@]}"
  if (( rc != 0 && CREATED == 1 )); then
    if (( KEEP_ON_FAIL )); then
      echo "Build failed; VM $VMID was kept. Remove it with: qm destroy $VMID --purge" >&2
    else
      echo "Build failed; removing half-built VM $VMID..." >&2
      qm stop "$VMID" --skiplock 1 &>/dev/null
      qm destroy "$VMID" --purge 1 --destroy-unreferenced-disks 1 &>/dev/null \
        || echo "Could not remove VM $VMID, run: qm destroy $VMID --purge" >&2
    fi
  fi
  exit "$rc"
}
trap on_exit EXIT
trap 'exit 130' INT TERM
trap '(( BASH_SUBSHELL )) || echo "${C_R}Failed at line $LINENO: $BASH_COMMAND${C_0}" >&2' ERR

# ---------------------------------------------------------------------------
# Steps
# ---------------------------------------------------------------------------
load_config() {
  [[ -f "$CONF_FILE" ]] || return 0
  local owner perms
  owner="$(stat -c %u "$CONF_FILE")"; perms="$(stat -c %a "$CONF_FILE")"
  [[ "$owner" == 0 ]] || die "$CONF_FILE must be owned by root"
  (( (8#$perms & 8#022) == 0 )) || die "$CONF_FILE must not be group/world writable"
  # shellcheck source=/dev/null
  source "$CONF_FILE"
  log "Loaded defaults from $CONF_FILE"
}

preflight() {
  local dep
  if (( ! DRY_RUN )); then
    (( EUID == 0 )) || die "Run as root on a Proxmox VE node"
  fi
  for dep in qm pvesm pvesh ip awk curl sha256sum sha512sum flock qemu-img openssl ssh-keygen; do
    command -v "$dep" >/dev/null || die "Missing dependency: $dep"
  done
}

step_distro() {
  hdr "Image"
  local i key label user url sum opts=()
  for i in "${!CATALOG[@]}"; do
    IFS='|' read -r key label user _ _ <<<"${CATALOG[i]}"
    opts+=("$key|$label (user $user)")
  done
  menu DISTRO "Distro" "$DEF_DISTRO" "${opts[@]}"
  for i in "${!CATALOG[@]}"; do
    IFS='|' read -r key label user url sum <<<"${CATALOG[i]}"
    [[ "$key" == "$DISTRO" ]] && break
  done
  DISTRO_LABEL="$label" DISTRO_USER="$user" IMG_URL="$url" SUM_URL="$sum" SUM_SINGLE=""

  case "$IMG_URL" in
    fedora) log "Looking up the newest Fedora Cloud release..."; resolve_fedora ;;
    custom)
      ask IMG_URL "Image URL (qcow2/img/raw)" "" v_url
      [[ "$IMG_URL" == https://* ]] || ask_yn "Plain http download. Continue?" n || die "Aborted"
      ask SUM_URL "Checksum file URL, or the sha256/sha512 hash itself (blank = none)" "" v_any
      DISTRO_LABEL="Custom (${IMG_URL##*/})"
      ;;
  esac
  [[ "$SUM_URL" == "@file" ]] && { SUM_URL="${IMG_URL}.CHECKSUM"; SUM_SINGLE=1; }

  EXPECT=""
  if [[ "$SUM_URL" =~ ^([0-9a-fA-F]{64}|[0-9a-fA-F]{128})$ ]]; then
    EXPECT="$(hash_algo "$SUM_URL") ${SUM_URL,,}"
  elif [[ -n "$SUM_URL" ]]; then
    local sums; sums="$(mktemp)"; TMP_FILES+=("$sums")
    log "Fetching checksums..."
    fetch -o "$sums" "$SUM_URL" || die "Could not download $SUM_URL"
    EXPECT="$(checksum_lookup "$sums" "${IMG_URL##*/}" "$SUM_SINGLE")" \
      || die "No checksum for ${IMG_URL##*/} in $SUM_URL"
  else
    warn "No checksum given: the image will not be verified"
    ask_yn "Continue without verification?" n || die "Aborted"
  fi
  IMG_PATH="${IMG_DIR}/${DISTRO}/${IMG_URL##*/}"
  [[ "${IMG_URL##*/}" =~ ^[A-Za-z0-9._+-]+$ ]] || die "Unexpected image file name: ${IMG_URL##*/}"
}

step_vm() {
  hdr "VM"
  local next; next="$(pvesh get /cluster/nextid 2>/dev/null || echo 100)"
  ask VMID "VMID (next free: $next)" "$next" v_vmid
  ask VMNAME "Name" "${DISTRO%%-*}-${VMID}" v_name

  echo; echo "${C_B}CPU${C_0} ${C_D}(host: $(host_cores) threads, $(awk -F': ' '/^model name/{print $2; exit}' /proc/cpuinfo 2>/dev/null))${C_0}"
  local opts=() c hc; hc="$(host_cores)"
  for c in 1 2 4 6 8 12 16 24 32; do (( c <= hc )) && opts+=("$c|"); done
  MENU_FREE=v_cores menu CORES "CPU cores" "$DEF_CORES" "${opts[@]}"
  (( CORES <= hc )) || warn "$CORES cores is more than the host's $hc threads"

  opts=("host|all host CPU features, fastest (no live migration to different CPUs)")
  opts+=("x86-64-v2-AES|portable, safe for mixed clusters (Proxmox default)")
  host_has_flags avx avx2 bmi1 bmi2 fma movbe && opts+=("x86-64-v3|portable + AVX2 (needed by Rocky/Alma 10 if not host)")
  host_has_flags avx512f avx512bw avx512cd avx512dq avx512vl && opts+=("x86-64-v4|portable + AVX-512")
  opts+=("kvm64|oldest baseline, maximum compatibility")
  local m
  while read -r m; do [[ -n "$m" ]] && opts+=("custom-$m|custom model from cpu-models.conf"); done \
    < <(awk '$1=="cpu-model:"{print $2}' "$PVE_DIR/virtual-guest/cpu-models.conf" 2>/dev/null)
  MENU_FREE=v_cpu menu CPU "CPU type" "$DEF_CPU" "${opts[@]}"
  if [[ "$DISTRO" =~ ^(rocky|alma)-10$ && "$CPU" =~ ^(x86-64-v2|x86-64-v2-AES|kvm64|qemu64)$ ]]; then
    warn "$DISTRO needs x86-64-v3 or newer and will not boot with $CPU"
    ask_yn "Keep $CPU anyway?" n || MENU_FREE=v_cpu menu CPU "CPU type" host "${opts[@]}"
  fi

  echo; echo "${C_B}Memory${C_0} ${C_D}(host: $(host_mem_mb) MB total, $(host_mem_mb MemAvailable) MB available)${C_0}"
  local hm; hm="$(host_mem_mb)"; opts=()
  for m in 1024 2048 4096 8192 16384 32768 65536; do (( hm == 0 || m <= hm )) && opts+=("$m|$(( m / 1024 )) GiB"); done
  MENU_FREE=v_mem menu MEM "Memory (MB)" "$DEF_MEM" "${opts[@]}"
  (( hm == 0 || MEM <= hm )) || warn "$MEM MB is more than the host has"

  echo; echo "${C_B}Firmware${C_0}"
  menu BIOS "Firmware" "$DEF_BIOS" "ovmf|UEFI (recommended for cloud images)" "seabios|legacy BIOS"

  echo; echo "${C_B}Storage${C_0}"
  local stores=() s def="" name type st total used avail
  opts=()
  while read -r name type st total used avail _; do
    [[ "$st" == active ]] || continue
    stores+=("$name")
    opts+=("$name|$type, $(human_gib "$avail") free of $(human_gib "$total")")
  done < <(pvesm status --content images 2>/dev/null | awk 'NR>1')
  (( ${#stores[@]} )) || die "No active storage allows VM disk images"
  for s in "${stores[@]}"; do [[ "$s" == "${DEF_STORAGE:-local-lvm}" ]] && def="$s"; done
  menu STORAGE "Storage for the disks" "${def:-${stores[0]}}" "${opts[@]}"

  opts=()
  for s in 16G 32G 64G 128G 256G 512G; do opts+=("$s|"); done
  MENU_FREE=v_disk menu DISK_SIZE "Disk size" "$DEF_DISK" "${opts[@]}"
  [[ "$DISK_SIZE" =~ [GT]$ ]] || DISK_SIZE="${DISK_SIZE}G"
}

# Network: fills NIC_NET[], NIC_IPCFG[], NIC_DESC[] and DNS settings
step_network() {
  hdr "Network"
  mapfile -t BRIDGES < <(list_bridges)
  (( ${#BRIDGES[@]} )) || die "No bridges found on this host"
  mapfile -t GUESTS < <(guest_addresses)
  local dr; dr="$(default_route)"; DR_DEV="${dr%%|*}" DR_GW="${dr#*|}"

  local b addr extra cm
  BRIDGE_OPTS=()
  for b in "${BRIDGES[@]}"; do
    addr="$(iface_ipv4 "$b")"; extra=""; cm="$(iface_comment "$b")"
    vlan_aware "$b" && extra+=", vlan-aware"
    [[ "$b" == "$DR_DEV" ]] && extra+=", default route"
    BRIDGE_OPTS+=("$b|${addr:-no host IP}${cm:+  \"$cm\"}$extra")
  done

  NIC_NET=() NIC_IPCFG=() NIC_DESC=() GW_SET="" FIRST_GW=""
  local n=0
  while true; do
    nic_prompt "$n"
    n=$(( n + 1 ))
    (( n < 8 )) && ask_yn "Add another network card?" n || break
  done

  echo
  echo "${C_B}DNS${C_0}"
  local opts=() hr; hr="$(host_resolvers)"
  [[ -n "$FIRST_GW" ]] && opts+=("$FIRST_GW|the VM's gateway (usual for a router/firewall)")
  opts+=("host|copy the Proxmox host's resolvers (${hr:-none found})")
  opts+=("1.1.1.1 1.0.0.1|Cloudflare" "9.9.9.9 149.112.112.112|Quad9" "8.8.8.8 8.8.4.4|Google")
  MENU_FREE=v_dns menu DNS "DNS servers (space separated)" "${DEF_DNS:-${FIRST_GW:-host}}" "${opts[@]}"
  local -a dns_list; read -ra dns_list <<<"${DNS//,/ }"; DNS="${dns_list[*]}"
  local sd; sd="${DEF_SEARCHDOMAIN:-$(host_search_domain)}"
  ask SEARCHDOMAIN "Search domain (none = skip)" "${sd:-none}" v_domain
}

nic_prompt() {
  local n="$1" br tag fw mode v6 ipcfg="" desc def_br="${DEF_BRIDGE:-${DR_DEV:-${BRIDGES[0]}}}"
  echo; echo "${C_B}-- net${n} --${C_0}"
  local in_list=0 b; for b in "${BRIDGES[@]}"; do [[ "$b" == "$def_br" ]] && in_list=1; done
  (( in_list )) || def_br="${BRIDGES[0]}"
  menu br "Bridge" "$def_br" "${BRIDGE_OPTS[@]}"

  # VLAN tags other guests already use on this bridge
  local opts=("none|untagged") g kind id gbr gtag gip ggw t
  local -A seen=()
  for g in "${GUESTS[@]}"; do
    IFS='|' read -r kind id gbr gtag gip ggw <<<"$g"
    [[ "$gbr" == "$br" && -n "$gtag" ]] || continue
    seen[$gtag]+="$kind $id${gip:+ ($gip)}, "
  done
  for t in $(printf '%s\n' "${!seen[@]}" | sort -n); do
    opts+=("$t|used by ${seen[$t]%, }")
  done
  vlan_aware "$br" || (( ${#seen[@]} )) || hint "$br is not VLAN-aware; a tag still works (Proxmox adds a VLAN bridge)"
  MENU_FREE=v_vlan menu tag "VLAN tag" none "${opts[@]}"
  [[ "$tag" == none ]] && tag=""

  menu fw "Proxmox firewall on this NIC" "$DEF_FW" "1|on (datacenter/VM firewall rules apply)" "0|off (e.g. a router VM filters this net)"

  local net="virtio,bridge=${br},firewall=${fw}"
  [[ -n "$tag" ]] && net+=",tag=${tag}"
  desc="${br}${tag:+ vlan $tag} fw=$fw"

  menu mode "IPv4" "$( (( n == 0 )) && echo static || echo dhcp)" \
    "static|fixed address (subnet and gateway predicted for you)" "dhcp|address from a DHCP server" "none|no IPv4"
  case "$mode" in
    dhcp) ipcfg="ip=dhcp"; desc+=" dhcp" ;;
    static) nic_static "$n" "$br" "$tag"; ipcfg="$STATIC_CFG"; desc+=" $STATIC_DESC" ;;
    none) ;;
  esac

  menu v6 "IPv6" none "none|no IPv6" "auto|SLAAC (router advertisements)" "dhcp|DHCPv6"
  if [[ "$v6" != none ]]; then ipcfg="${ipcfg:+$ipcfg,}ip6=${v6}"; desc+=" ip6=$v6"; fi

  NIC_NET[n]="$net" NIC_IPCFG[n]="$ipcfg" NIC_DESC[n]="$desc"
}

# Predicts subnet/gateway/free IP for bridge+tag, asks, validates. Sets STATIC_CFG, STATIC_DESC.
nic_static() {
  local n="$1" br="$2" tag="$3"
  local k_ip="" k_p="" k_gw="" why="" g b kind id gbr gtag gip ggw used=()
  local hostif="$br" hostaddr

  # 1) other guests with a static address on the same bridge + VLAN
  for g in "${GUESTS[@]}"; do
    IFS='|' read -r kind id gbr gtag gip ggw <<<"$g"
    [[ "$gip" == */* ]] || continue
    used+=("${gip%/*}")
    if [[ -z "$k_ip" && "$gbr" == "$br" && "$gtag" == "$tag" ]]; then
      k_ip="${gip%/*}" k_p="${gip#*/}" k_gw="$ggw" why="from $kind $id on this bridge"
    fi
  done
  # 2) the host's own address on the bridge (or its VLAN sub-interface)
  [[ -n "$tag" ]] && { hostif=""; for b in "${br}.${tag}" "vlan${tag}"; do [[ -e "$SYS_NET/$b" ]] && hostif="$b"; done; }
  hostaddr="${hostif:+$(iface_ipv4 "$hostif")}"
  [[ -n "$hostaddr" ]] && used+=("${hostaddr%/*}")
  if [[ -z "$k_ip" && -n "$hostaddr" ]]; then
    k_ip="${hostaddr%/*}" k_p="${hostaddr#*/}" why="from host address $hostaddr on $hostif"
    if [[ "$DR_DEV" == "$hostif" && -n "$DR_GW" ]]; then k_gw="$DR_GW"; why+=", via the default route"
    else k_gw="$k_ip"; why+=", host routes this net"; fi
  fi
  [[ -n "$k_gw" ]] && used+=("$k_gw")

  local def_ip=""
  if [[ -n "$k_ip" ]]; then
    hint "Known subnet $(int2ip "$(net_int "$k_ip" "$k_p")")/$k_p, gateway ${k_gw:-?} ($why)"
    def_ip="$(suggest_free_ip "$k_ip" "$k_p" "${used[@]}")"
    [[ -n "$def_ip" ]] && def_ip+="/$k_p"
  else
    hint "Nothing known about this network yet: enter IP/CIDR, e.g. 10.5.0.20/24"
  fi
  hint "Formats: 10.5.0.20/24, 10.5.0.20 (uses ${k_p:-24}), or just the host number when the subnet is known"

  local in ip p
  while true; do
    ask in "IP address/CIDR" "$def_ip" v_any
    if [[ "$in" =~ ^[0-9]+$ && -n "$k_ip" ]]; then
      ip="$(int2ip $(( $(net_int "$k_ip" "$k_p") + 10#$in )))"; p="$k_p"
      in_subnet "$ip" "$k_ip" "$k_p" || { echo "  Host number $in does not fit in /$k_p" >&2; continue; }
    elif [[ "$in" == */* ]]; then ip="${in%/*}" p="${in#*/}"
    else ip="$in" p="${k_p:-24}"; fi
    is_ipv4 "$ip" || { echo "  '$ip' is not an IPv4 address" >&2; continue; }
    is_prefix "$p" || { echo "  Prefix must be 1-32" >&2; continue; }
    p=$(( 10#$p ))
    is_host_addr "$ip" "$p" || { echo "  $ip is the network or broadcast address of /$p" >&2; continue; }
    if ip_in_use "$ip" "${used[@]}"; then
      warn "$ip is already configured on another guest or the host"
      ask_yn "Use it anyway?" n || continue
    fi
    if ping_responds "$ip" "$hostif"; then
      warn "$ip answers ping, something is already using it"
      ask_yn "Use it anyway?" n || continue
    fi
    break
  done

  # Gateway candidates: learned one if it fits this subnet, first and last usable host
  local cidr; cidr="$(int2ip "$(net_int "$ip" "$p")")/$p"
  local opts=() gw_def="" c fh lh
  if [[ -n "$k_gw" ]] && is_ipv4 "$k_gw" && in_subnet "$k_gw" "$ip" "$p" && [[ "$k_gw" != "$ip" ]]; then
    opts+=("$k_gw|$why"); gw_def="$k_gw"
  fi
  if (( p < 31 )); then
    fh="$(first_host "$ip" "$p")" lh="$(last_host "$ip" "$p")"
    for c in "$fh" "$lh"; do
      [[ "$c" == "$ip" || "$c" == "$gw_def" ]] && continue
      opts+=("$c|$([[ $c == "$fh" ]] && echo first || echo last) usable host of $cidr")
    done
    [[ -n "$gw_def" ]] || gw_def="$(predict_gateway "$ip" "$p")"
  fi
  opts+=("none|no gateway on this NIC")
  if [[ -n "$GW_SET" ]]; then
    hint "net${GW_SET} already has the default gateway, so 'none' is suggested here"
    gw_def="none"
  fi
  local gw
  while true; do
    MENU_FREE=v_any menu gw "Gateway" "${gw_def:-none}" "${opts[@]}"
    [[ "$gw" == none ]] && { gw=""; break; }
    is_ipv4 "$gw" || { echo "  Not an IPv4 address" >&2; continue; }
    [[ "$gw" != "$ip" ]] || { echo "  Gateway cannot be the VM's own address" >&2; continue; }
    if ! in_subnet "$gw" "$ip" "$p"; then
      warn "$gw is outside $cidr"
      ask_yn "Use it anyway (on-link gateway)?" n || continue
    fi
    break
  done

  STATIC_CFG="ip=${ip}/${p}${gw:+,gw=$gw}"
  STATIC_DESC="${ip}/${p} gw ${gw:-none}"
  if [[ -n "$gw" && -z "$GW_SET" ]]; then GW_SET="$n"; FIRST_GW="$gw"; fi
}

# suggest_free_ip REF PREFIX USED...: first free address from .100 (or host 2) upward
suggest_free_ip() {
  local ref="$1" p="$2"; shift 2
  local net bc start i ip
  (( p >= 31 )) && return 0
  net="$(net_int "$ref" "$p")"; bc="$(bcast_int "$ref" "$p")"
  start=$(( net + 100 )); (( start < bc - 1 )) || start=$(( net + 2 ))
  for (( i = start; i < bc && i < start + 1024; i++ )); do
    ip="$(int2ip "$i")"
    ip_in_use "$ip" "$@" || { echo "$ip"; return 0; }
  done
}
ip_in_use() { local ip="$1" u; shift; for u in "$@"; do [[ "$u" == "$ip" ]] && return 0; done; return 1; }

# Only meaningful when the host itself sits on that segment
ping_responds() {
  local ip="$1" dev="$2"
  (( DRY_RUN )) && return 1
  [[ -n "$dev" && -n "$(iface_ipv4 "$dev")" ]] || return 1
  command -v ping >/dev/null || return 1
  ping -c 1 -W 1 -I "$dev" "$ip" &>/dev/null
}

step_user() {
  hdr "Login"
  ask CIUSER "Username" "$DISTRO_USER" v_user

  SSHKEY_FILE=""
  echo; echo "${C_B}SSH keys${C_0}"
  local keys def_keys="none" opts=() f cnt home=""
  [[ -n "${SUDO_USER:-}" ]] && home="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
  for f in "$DEF_SSHKEYS" /root/.ssh/authorized_keys /root/.ssh/*.pub ${home:+"$home"/.ssh/*.pub}; do
    [[ -s "$f" ]] || continue
    ip_in_use "$f" "${opts[@]%%|*}" && continue
    cnt="$(grep -cE '^(ssh-|ecdsa-|sk-)' "$f" || true)"
    (( cnt )) || continue
    opts+=("$f|$cnt key(s): $(grep -E '^(ssh-|ecdsa-|sk-)' "$f" | awk '{print $NF}' | head -3 | paste -sd, -)")
    [[ "$def_keys" == none ]] && def_keys="$f"
  done
  opts+=("none|no SSH key (password login only)")
  while true; do
    MENU_FREE=v_any menu keys "SSH key file, or paste a public key" "$def_keys" "${opts[@]}"
    [[ "$keys" == none ]] && break
    SSHKEY_FILE="$(mktemp)"; TMP_FILES+=("$SSHKEY_FILE")
    if [[ -f "$keys" ]]; then grep -E '^(ssh-|ecdsa-|sk-)' "$keys" >"$SSHKEY_FILE" || true
    else printf '%s\n' "$keys" >"$SSHKEY_FILE"; fi
    if [[ -s "$SSHKEY_FILE" ]] && ssh-keygen -l -f "$SSHKEY_FILE" >/dev/null 2>&1; then
      log "$(wc -l <"$SSHKEY_FILE") SSH key(s) accepted"; break
    fi
    echo "  No valid SSH public key found there" >&2; SSHKEY_FILE=""
  done

  CIPASS="" PASS_GENERATED=0
  hint "Password is for console login; blank = generate one, 'none' = SSH key only"
  local p1 p2
  while true; do
    read -rsp "Password: " p1 || exit 130; echo
    if [[ "$p1" == none ]]; then
      [[ -n "$SSHKEY_FILE" ]] && break
      echo "  Without an SSH key a password is required" >&2; continue
    fi
    if [[ -z "$p1" ]]; then CIPASS="$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-20)"; PASS_GENERATED=1; break; fi
    (( ${#p1} >= 8 )) || { echo "  At least 8 characters" >&2; continue; }
    read -rsp "Repeat:   " p2 || exit 130; echo
    [[ "$p1" == "$p2" ]] && { CIPASS="$p1"; break; }
    echo "  Passwords do not match" >&2
  done
}

step_options() {
  hdr "Options"
  UPGRADE=0; ask_yn "Upgrade packages on first boot?" "$([[ $DEF_UPGRADE == 1 ]] && echo y || echo n)" && UPGRADE=1
  ONBOOT=0; ask_yn "Start with the host (onboot)?" "$([[ $DEF_ONBOOT == 1 ]] && echo y || echo n)" && ONBOOT=1
  menu FINISH "When done" start "start|boot the VM now" "stopped|leave it powered off" "template|convert to a template for cloning"

  SNIP_STORE="$SNIPPET_STORAGE"
  if [[ -z "$SNIP_STORE" ]]; then
    local snips=()
    mapfile -t snips < <(pvesm status --content snippets 2>/dev/null | awk 'NR>1 && $3=="active"{print $1}')
    if (( ${#snips[@]} > 1 )); then
      menu SNIP_STORE "Storage for the cloud-init snippet" "${snips[0]}" "${snips[@]}"
    elif (( ${#snips[@]} )); then SNIP_STORE="${snips[0]}"; fi
  fi
  if [[ -z "$SNIP_STORE" ]]; then
    warn "No storage has 'snippets' enabled: the guest agent will not be auto-installed."
    hint "Enable it with: pvesm set local --content iso,vztmpl,backup,snippets"
    ask_yn "Continue without the vendor snippet?" y || die "Aborted"
  fi
}

summary() {
  hdr "Summary"
  echo "  Image   : $DISTRO_LABEL"
  echo "            ${IMG_URL}"
  echo "            checksum: $([[ -n $EXPECT ]] && echo "${EXPECT%% *} verified" || echo "NOT verified")"
  echo "  VM      : $VMID ($VMNAME) | $CORES cores, ${MEM} MB, $DISK_SIZE on $STORAGE | cpu $CPU | $BIOS"
  local i
  for i in "${!NIC_DESC[@]}"; do echo "  net$i    : ${NIC_DESC[i]}"; done
  echo "  DNS     : $DNS | search ${SEARCHDOMAIN}"
  echo "  Login   : $CIUSER | ssh keys: $([[ -n $SSHKEY_FILE ]] && echo yes || echo no) | password: $([[ -n $CIPASS ]] && echo yes || echo no)"
  echo "  Options : upgrade=$UPGRADE onboot=$ONBOOT finish=$FINISH snippets=${SNIP_STORE:-none}"
  echo
  ask_yn "Create this VM?" y || die "Aborted"
}

write_snippet() {
  [[ -n "$SNIP_STORE" ]] || return 0
  SNIP_NAME="create-vm-vendor.yaml"
  (( UPGRADE )) && SNIP_NAME="create-vm-vendor-upgrade.yaml"
  local path; path="$(pvesm path "${SNIP_STORE}:snippets/${SNIP_NAME}" 2>/dev/null)" || die "Cannot resolve snippet path on $SNIP_STORE"
  local body
  body="#cloud-config
# managed by create-vm.sh
package_update: true
package_upgrade: $( (( UPGRADE )) && echo true || echo false)
packages:
  - qemu-guest-agent
runcmd:
  - [ systemctl, enable, --now, qemu-guest-agent ]"
  if [[ ! -f "$path" ]] || [[ "$(cat "$path")" != "$body" ]]; then
    log "Writing cloud-init vendor snippet $SNIP_NAME"
    if (( DRY_RUN )); then hint "[dry-run] would write $path"
    else mkdir -p "${path%/*}"; printf '%s\n' "$body" >"$path"; chmod 644 "$path"; fi
  fi
}

build() {
  get_image
  write_snippet

  local args=(--name "$VMNAME" --ostype l26 --machine q35 --bios "$BIOS" --cpu "$CPU"
              --cores "$CORES" --memory "$MEM" --balloon 0 --scsihw virtio-scsi-single
              --agent enabled=1 --serial0 socket --vga std --tablet 0 --onboot "$ONBOOT"
              --tags "create-vm;${DISTRO//./-}")
  local i
  for i in "${!NIC_NET[@]}"; do args+=("--net$i" "${NIC_NET[i]}"); done

  log "Creating VM $VMID..."
  run qm create "$VMID" "${args[@]}"
  CREATED=1

  [[ "$BIOS" == ovmf ]] && run qm set "$VMID" --efidisk0 "${STORAGE}:0,efitype=4m,pre-enrolled-keys=0"

  log "Importing disk (this can take a minute)..."
  run qm set "$VMID" --scsi0 "${STORAGE}:0,import-from=${IMG_PATH},discard=on,iothread=1,ssd=1"

  local cur want
  if (( ! DRY_RUN )); then
    cur="$(qemu-img info --output=json "$IMG_PATH" | awk -F'[:,]' '/"virtual-size"/{gsub(/ /,"",$2); print $2; exit}')"
    want=$(( ${DISK_SIZE%[GT]} * 1073741824 ))
    [[ "$DISK_SIZE" == *T ]] && want=$(( want * 1024 ))
    if (( want > cur )); then run qm resize "$VMID" scsi0 "$DISK_SIZE"
    else warn "Image is already $(( cur / 1073741824 ))G, keeping its size"; fi
  else run qm resize "$VMID" scsi0 "$DISK_SIZE"; fi

  log "Configuring cloud-init..."
  run qm set "$VMID" --ide2 "${STORAGE}:cloudinit" --boot order=scsi0
  local ci=(--ciuser "$CIUSER")
  [[ -n "$CIPASS" ]] && ci+=(--cipassword "$CIPASS")
  for i in "${!NIC_IPCFG[@]}"; do [[ -n "${NIC_IPCFG[i]}" ]] && ci+=("--ipconfig$i" "${NIC_IPCFG[i]}"); done
  [[ "$DNS" != host ]] && ci+=(--nameserver "$DNS")
  [[ "$SEARCHDOMAIN" != none && -n "$SEARCHDOMAIN" ]] && ci+=(--searchdomain "$SEARCHDOMAIN")
  [[ -n "$SNIP_STORE" ]] && ci+=(--cicustom "vendor=${SNIP_STORE}:snippets/${SNIP_NAME}")
  [[ -n "$SSHKEY_FILE" ]] && ci+=(--sshkeys "$SSHKEY_FILE")
  run qm set "$VMID" "${ci[@]}"
  run qm set "$VMID" --description "Created by create-vm.sh $VERSION on $(date -u +%F) from ${IMG_URL##*/}"

  case "$FINISH" in
    start)    log "Starting VM..."; run qm start "$VMID" ;;
    template) log "Converting to template..."; run qm template "$VMID" ;;
  esac
  CREATED=0
}

report() {
  hdr "Done"
  echo "  VM $VMID ($VMNAME) ${DISTRO_LABEL}: $FINISH"
  local i; for i in "${!NIC_DESC[@]}"; do echo "  net$i     : ${NIC_DESC[i]}"; done
  echo "  User     : $CIUSER"
  (( PASS_GENERATED )) && echo "  Password : $CIPASS   ${C_Y}(generated, store it now; it is not shown again)${C_0}"
  echo "  Console  : qm terminal $VMID   (Ctrl+O to exit)"
  [[ -n "$SNIP_STORE" ]] && echo "  The guest agent installs on first boot; the IP shows in the GUI after ~2 minutes."
  return 0
}

usage() {
  cat <<EOF
create-vm.sh $VERSION - interactive cloud-init VM builder for Proxmox VE

  --dry-run   ask everything, print the qm commands, change nothing
  --help      this text

Defaults can be set in $CONF_FILE (see create-vm.conf.example).
EOF
}

main() {
  while (( $# )); do
    case "$1" in
      --dry-run|-n) DRY_RUN=1 ;;
      --help|-h) usage; exit 0 ;;
      *) usage >&2; die "Unknown option: $1" ;;
    esac
    shift
  done
  [[ -t 0 ]] || die "Run interactively (stdin must be a terminal)"
  load_config
  preflight
  echo "${C_B}Proxmox cloud-init VM builder $VERSION${C_0}$( (( DRY_RUN )) && echo "  ${C_Y}[dry-run]${C_0}")"
  step_distro
  step_vm
  step_network
  step_user
  step_options
  summary
  build
  report
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
