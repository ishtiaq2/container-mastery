#!/usr/bin/env bash
# =============================================================================
#  kvm-lab.sh  -  KVM learning lab: setup, images, VMs, networking, containers
#
#  File 1 of 2.  Everything you START or RUN lives in this file.
#  File 2 of 2:  kvm-cleanup.sh  puts the host back the way it was.
#
#  Run as your normal user (NOT with sudo). The script calls sudo itself and
#  prints every privileged command before it runs it, so you can learn from it.
#
#  Quick start:
#     chmod +x kvm-lab.sh kvm-cleanup.sh
#     ./kvm-lab.sh help          # list of all steps
#     ./kvm-lab.sh tour          # guided run: check -> install -> first VM
#     ./kvm-cleanup.sh           # undo everything
#
#  Sandbox rules this script follows (so cleanup can be exact):
#    * every VM, network and storage pool it creates is named  lab-*
#    * every disk lives in   /var/lib/libvirt/images/kvm-lab
#    * every file you own lives in   ~/kvm-lab   (SSH key, cloud-init, notes)
#    * it records which packages it installed in   ~/kvm-lab/state
#    * it never edits ~/.ssh, the libvirt "default" network, or VirtualBox
# =============================================================================
set -Eeuo pipefail

# ----------------------------------------------------------------------------
# Settings (override any of them with environment variables)
# ----------------------------------------------------------------------------
LAB_HOME="${KVM_LAB_HOME:-$HOME/kvm-lab}"
STATE_DIR="$LAB_HOME/state"
VMS_DIR="$LAB_HOME/vms"
SCRATCH="$LAB_HOME/scratch"
SSH_KEY="$LAB_HOME/ssh/id_ed25519"
URI="qemu:///system"                       # the system-wide libvirt daemon
POOL_NAME="lab-pool"
POOL_DIR="/var/lib/libvirt/images/kvm-lab"
BASE_DIR="$POOL_DIR/base"                  # downloaded cloud images (read-only bases)
NAT_NET="lab-nat"
NAT_SUBNET="${LAB_SUBNET:-192.168.150}"    # lab NAT network = 192.168.150.0/24
BRIDGE_NET="lab-bridge"
MACVTAP_NET="lab-macvtap"
HOST_BRIDGE="br-lab"
VM_USER="lab"
VM_PASS="lab"                              # console password (lab only!)
AUTO_YES="${LAB_YES:-0}"                   # LAB_YES=1 skips the "press Enter" pauses

# ----------------------------------------------------------------------------
# Small helpers: colours, explanations, and a "run" that shows each command
# ----------------------------------------------------------------------------
if [[ -t 1 ]]; then B=$'\e[1m'; C=$'\e[36m'; Y=$'\e[33m'; R=$'\e[31m'; G=$'\e[32m'; N=$'\e[0m'
else B=""; C=""; Y=""; R=""; G=""; N=""; fi

step()    { echo; echo "${B}${C}==== $* ====${N}"; }
explain() { sed 's/^/  | /' <<<"$*"; }
ok()      { echo "  ${G}OK${N}  $*"; }
warn()    { echo "  ${Y}WARNING${N}  $*" >&2; }
die()     { echo "  ${R}ERROR${N}  $*" >&2; exit 1; }
run()     { echo "  ${B}\$ $*${N}"; "$@"; }
pause()   { [[ "$AUTO_YES" == 1 || ! -t 0 ]] && return 0; read -rp "  ...press Enter to continue " _; }
confirm() { [[ "$AUTO_YES" == 1 ]] && return 0; read -rp "  $* [y/N] " a; [[ "$a" =~ ^[Yy] ]]; }
V()       { sudo virsh -c "$URI" "$@"; }   # virsh against the system daemon
have()    { command -v "$1" >/dev/null 2>&1; }

lab_name() { [[ "$1" == lab-* ]] && echo "$1" || echo "lab-$1"; }   # every VM is lab-*
need_install() { [[ -f "$STATE_DIR/install-done" ]] || die "Run './kvm-lab.sh install' first."; }

pkg_manager() {
  if have apt-get; then echo apt; elif have dnf; then echo dnf
  else die "Only apt (Ubuntu/Debian) and dnf (Fedora/RHEL/Alma/Rocky) hosts are supported."; fi
}

default_iface() { ip route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'; }

[[ $EUID -eq 0 ]] && die "Run as your normal user, not root. The script uses sudo where needed."

# ----------------------------------------------------------------------------
# Image catalog: name -> download URL, file name, libvirt OS id
# ----------------------------------------------------------------------------
IMAGES="ubuntu24 ubuntu22 debian12 centos9 centos10 alma9 rocky9"
image_info() {
  case "$1" in
    ubuntu24) URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"; OSI="ubuntu24.04"; DESC="Ubuntu 24.04 LTS (Noble)";;
    ubuntu22) URL="https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"; OSI="ubuntu22.04"; DESC="Ubuntu 22.04 LTS (Jammy)";;
    debian12) URL="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2"; OSI="debian12"; DESC="Debian 12 (Bookworm)";;
    centos9)  URL="https://cloud.centos.org/centos/9-stream/x86_64/images/CentOS-Stream-GenericCloud-9-latest.x86_64.qcow2"; OSI="centos-stream9"; DESC="CentOS Stream 9";;
    centos10) URL="https://cloud.centos.org/centos/10-stream/x86_64/images/CentOS-Stream-GenericCloud-10-latest.x86_64.qcow2"; OSI="centos-stream10"; DESC="CentOS Stream 10 (needs x86-64-v3 CPU)";;
    alma9)    URL="https://repo.almalinux.org/almalinux/9/cloud/x86_64/images/AlmaLinux-9-GenericCloud-latest.x86_64.qcow2"; OSI="almalinux9"; DESC="AlmaLinux 9 (RHEL compatible)";;
    rocky9)   URL="https://dl.rockylinux.org/pub/rocky/9/images/x86_64/Rocky-9-GenericCloud-Base.latest.x86_64.qcow2"; OSI="rocky9"; DESC="Rocky Linux 9 (RHEL compatible)";;
    *) die "Unknown image '$1'. Choose one of: $IMAGES";;
  esac
  FILE="${URL##*/}"
}

# =============================================================================
# STEP 1 - check: can this machine run KVM?
# =============================================================================
cmd_check() {
  step "STEP 1 - Check the host (read-only, changes nothing)"
  explain "KVM needs a CPU with hardware virtualisation (Intel VT-x = 'vmx', AMD-V = 'svm')
switched on in the BIOS/UEFI. We also look at RAM, disk space and conflicts."
  local fails=0

  local flags; flags=$(grep -Ec '(vmx|svm)' /proc/cpuinfo || true)
  if (( flags > 0 )); then ok "CPU virtualisation flags found on $flags threads"
  else warn "No vmx/svm flag. Enable Intel VT-x / AMD-V in BIOS, or (inside a VM) enable nested virtualisation."; fails=1; fi

  if [[ -e /dev/kvm ]]; then ok "/dev/kvm exists (the kernel's KVM module is loaded)"
  else echo "  ..  /dev/kvm not there yet - normal before 'install' loads the module"; fi

  local virt; virt=$(systemd-detect-virt 2>/dev/null || true)
  [[ -n "$virt" && "$virt" != none ]] && warn "This host is itself a VM ($virt). Works only with nested virtualisation, and slower."

  local mem; mem=$(awk '/MemTotal/ {printf "%d", $2/1024/1024}' /proc/meminfo)
  if (( mem >= 8 )); then ok "RAM: ${mem} GiB"; else warn "RAM: ${mem} GiB. 8 GiB+ recommended; the OpenNMS stack VM wants 6 GiB."; fi

  local free; free=$(df -BG --output=avail /var 2>/dev/null | tail -1 | tr -dc 0-9)
  if (( free >= 30 )); then ok "Free disk under /var: ${free} GiB"; else warn "Only ${free} GiB free under /var. 30 GiB+ recommended."; fi

  if lsmod | grep -q '^vboxdrv' || pgrep -f 'VBoxHeadless|VirtualBoxVM' >/dev/null; then
    warn "VirtualBox is installed/running. Do NOT run VirtualBox VMs and KVM VMs at the same time:
           both want exclusive use of VT-x. Shut VirtualBox VMs down first."
  fi

  . /etc/os-release
  ok "Host OS: $PRETTY_NAME (package manager: $(pkg_manager))"
  local ifc; ifc=$(default_iface)
  ok "Default network interface: ${ifc:-none} $( [[ -d /sys/class/net/$ifc/wireless ]] && echo '(Wi-Fi: real bridge mode is not possible on Wi-Fi)')"
  have nmcli && ok "NetworkManager present (needed only for optional bridge mode)"
  [[ -n "${SSH_CONNECTION:-}" ]] && warn "You are logged in over SSH. Avoid 'hostbridge on' from an SSH session."
  (( fails == 0 )) && echo && ok "${B}This host can run KVM.${N}" || die "Fix the items above first."
}

# =============================================================================
# STEP 2 - install: packages, daemon, lab storage pool, lab NAT network, SSH key
# =============================================================================
pkg_snapshot() {
  case "$(pkg_manager)" in
    apt) dpkg-query -W -f='${db:Status-Abbrev} ${binary:Package}\n' | awk '$1=="ii"{print $2}' | sort ;;
    dnf) rpm -qa --qf '%{NAME}\n' | sort ;;
  esac
}

pkg_install() {   # installs packages AND records exactly which ones were new
  mkdir -p "$STATE_DIR"
  local before after; before=$(mktemp); after=$(mktemp)
  pkg_snapshot >"$before"
  case "$(pkg_manager)" in
    apt) run sudo apt-get update -qq
         run sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" ;;
    dnf) run sudo dnf install -y "$@" ;;
  esac
  pkg_snapshot >"$after"
  comm -13 "$before" "$after" >>"$STATE_DIR/packages-installed-by-lab.txt"
  sort -u -o "$STATE_DIR/packages-installed-by-lab.txt" "$STATE_DIR/packages-installed-by-lab.txt"
  ok "$(comm -13 "$before" "$after" | wc -l) new packages recorded in $STATE_DIR/packages-installed-by-lab.txt"
  rm -f "$before" "$after"
}

cmd_install() {
  local gui=0; [[ "${1:-}" == "--gui" ]] && gui=1
  step "STEP 2 - Install KVM + libvirt and create the lab sandbox"
  explain "Packages:
  qemu      = emulates the PC hardware of each VM (disk, NIC, BIOS...)
  KVM       = kernel module that lets qemu run guest code directly on the CPU
  libvirt   = daemon + 'virsh' CLI that manages VMs, networks and storage
  virtinst  = 'virt-install' / 'virt-xml', the VM creation & edit tools
  qemu-utils= 'qemu-img', the disk image tool
Then we create the sandbox: storage pool '$POOL_NAME', NAT network '$NAT_NET', SSH key."
  pause
  mkdir -p "$STATE_DIR" "$VMS_DIR" "$SCRATCH" "$(dirname "$SSH_KEY")"
  # remember which libvirt dirs existed before, so cleanup can remove only new ones
  if [[ ! -f "$STATE_DIR/dirs-before.txt" ]]; then
    for d in /etc/libvirt /var/lib/libvirt /var/log/libvirt; do [[ -e $d ]] && echo "$d"; done >"$STATE_DIR/dirs-before.txt" || true
  fi

  local pkgs
  case "$(pkg_manager)" in
    apt) pkgs=(qemu-system-x86 qemu-utils libvirt-daemon-system libvirt-clients virtinst dnsmasq-base)
         (( gui )) && pkgs+=(virt-manager) ;;
    dnf) pkgs=(qemu-kvm qemu-img libvirt virt-install)
         (( gui )) && pkgs+=(virt-manager) ;;
  esac
  pkg_install "${pkgs[@]}"

  step "Start the libvirt daemon and load the KVM module"
  if systemctl list-unit-files libvirtd.service >/dev/null 2>&1; then run sudo systemctl enable --now libvirtd
  else run sudo systemctl enable --now virtqemud.socket virtnetworkd.socket virtstoraged.socket; fi
  if grep -q vmx /proc/cpuinfo; then run sudo modprobe kvm_intel || true; else run sudo modprobe kvm_amd || true; fi
  [[ -e /dev/kvm ]] && ok "/dev/kvm ready" || die "/dev/kvm missing - is virtualisation enabled in BIOS?"

  step "Create storage pool '$POOL_NAME' -> $POOL_DIR"
  explain "A storage pool is just a directory libvirt manages. All lab disks go here, nothing else."
  if ! V pool-info "$POOL_NAME" >/dev/null 2>&1; then
    run V pool-define-as "$POOL_NAME" dir --target "$POOL_DIR"
    run V pool-build "$POOL_NAME"
    run V pool-start "$POOL_NAME"
    run V pool-autostart "$POOL_NAME"
  else ok "pool exists"; fi
  run sudo mkdir -p "$BASE_DIR"

  step "Create NAT network '$NAT_NET' ($NAT_SUBNET.0/24)"
  explain "Our own NAT network, separate from libvirt's 'default' (192.168.122.0/24),
so cleanup can delete it without touching anything that was there before."
  if ! V net-info "$NAT_NET" >/dev/null 2>&1; then
    ip -4 addr | grep -q " $NAT_SUBNET\." && die "$NAT_SUBNET.0/24 is already used on this host. Re-run with LAB_SUBNET=192.168.151"
    cat >"$STATE_DIR/$NAT_NET.xml" <<EOF
<network>
  <name>$NAT_NET</name>
  <forward mode='nat'/>
  <bridge name='virbr-lab' stp='on' delay='0'/>
  <ip address='$NAT_SUBNET.1' netmask='255.255.255.0'>
    <dhcp><range start='$NAT_SUBNET.100' end='$NAT_SUBNET.200'/></dhcp>
  </ip>
</network>
EOF
    run V net-define "$STATE_DIR/$NAT_NET.xml"
    run V net-start "$NAT_NET"
    run V net-autostart "$NAT_NET"
  else ok "network exists"; fi

  local ifc; ifc=$(default_iface)
  if [[ -n "$ifc" ]] && ! V net-info "$MACVTAP_NET" >/dev/null 2>&1; then
    step "Create macvtap network '$MACVTAP_NET' on $ifc (no host changes)"
    explain "macvtap puts VMs directly on your LAN through $ifc without changing host networking.
Limit: the host itself cannot talk to those VMs (other LAN machines can)."
    cat >"$STATE_DIR/$MACVTAP_NET.xml" <<EOF
<network>
  <name>$MACVTAP_NET</name>
  <forward mode='bridge'><interface dev='$ifc'/></forward>
</network>
EOF
    run V net-define "$STATE_DIR/$MACVTAP_NET.xml"
    run V net-start "$MACVTAP_NET"
  fi

  step "Create a lab-only SSH key"
  explain "A separate key in $LAB_HOME/ssh - your own ~/.ssh is never touched."
  [[ -f "$SSH_KEY" ]] || run ssh-keygen -q -t ed25519 -N "" -C "kvm-lab" -f "$SSH_KEY"
  touch "$STATE_DIR/install-done"
  echo; ok "${B}KVM is installed.${N} Next: ./kvm-lab.sh learn-images   or   ./kvm-lab.sh create web1"
}

# =============================================================================
# STEP 3 - images: list / download cloud images
# =============================================================================
cmd_images() {
  step "Available cloud images"
  explain "Cloud images are pre-installed disks: no installer, they boot in ~30 s and are
configured on first boot by cloud-init (user, SSH key, hostname). '*' = downloaded."
  printf "  %-10s %-42s %s\n" NAME DESCRIPTION FILE
  for i in $IMAGES; do image_info "$i"
    local mark=" "; [[ -f "$BASE_DIR/$FILE" ]] && mark="*"
    printf "  %-10s %-42s %s %s\n" "$i" "$DESC" "$FILE" "$mark"
  done
}

cmd_download() {
  need_install
  image_info "${1:?usage: download <image>}"
  if sudo test -f "$BASE_DIR/$FILE"; then ok "$FILE already downloaded"; return; fi
  step "Download $DESC"
  run sudo curl -fL --progress-bar -o "$BASE_DIR/$FILE.part" "$URL"
  run sudo mv "$BASE_DIR/$FILE.part" "$BASE_DIR/$FILE"
  explain "Look at the real format - the file extension does not decide it:"
  run sudo qemu-img info -U "$BASE_DIR/$FILE"
}

# =============================================================================
# STEP 4 - learn-images: hands-on qemu-img (.qcow2 vs .img/raw, overlays, snapshots)
# =============================================================================
cmd_learn_images() {
  have qemu-img || die "qemu-img missing - run './kvm-lab.sh install' first."
  mkdir -p "$SCRATCH"; cd "$SCRATCH"; rm -f demo.* overlay.* base.*
  step "4.1  Create a 10 GiB qcow2 disk"
  explain "qcow2 = 'QEMU Copy-On-Write v2'. It grows only as data is written."
  run qemu-img create -f qcow2 demo.qcow2 10G
  run ls -lh demo.qcow2; pause

  step "4.2  Create a 10 GiB raw disk (.img)"
  explain "raw = plain byte-for-byte disk. 'ls' shows 10G, but it is sparse: 'du' shows real use."
  run qemu-img create -f raw demo.img 10G
  run ls -lh demo.img; run du -h demo.img; pause

  step "4.3  Inspect both with qemu-img info"
  explain "'virtual size' = what the VM sees, 'disk size' = what it costs on your host."
  run qemu-img info demo.qcow2; run qemu-img info demo.img; pause

  step "4.4  A '.img' that is really qcow2"
  explain "noble-server-cloudimg-amd64.img ends in .img but its format is qcow2.
Always trust 'qemu-img info', never the extension."
  if sudo test -f "$BASE_DIR/noble-server-cloudimg-amd64.img"; then
    run sudo qemu-img info -U "$BASE_DIR/noble-server-cloudimg-amd64.img"
  else echo "  (download it with './kvm-lab.sh download ubuntu24' to see this live)"; fi
  pause

  step "4.5  Backing file + overlay (how every lab VM gets its disk)"
  explain "One read-only base image, many thin overlays. Each VM writes only to its overlay,
so 10 VMs from one 600 MB image cost ~600 MB + their own changes."
  run qemu-img create -f qcow2 base.qcow2 2G
  run qemu-img create -f qcow2 -b "$SCRATCH/base.qcow2" -F qcow2 overlay.qcow2 20G
  run qemu-img info --backing-chain overlay.qcow2; pause

  step "4.6  Resize, snapshot, convert"
  run qemu-img resize overlay.qcow2 +5G
  run qemu-img snapshot -c before-change overlay.qcow2
  run qemu-img snapshot -l overlay.qcow2
  explain "Convert formats - this is how you bring old VirtualBox disks over:
   qemu-img convert -p -f vdi  -O qcow2 old-vm.vdi  old-vm.qcow2
   qemu-img convert -p -f vmdk -O qcow2 old-vm.vmdk old-vm.qcow2"
  run qemu-img convert -f qcow2 -O vdi demo.qcow2 demo.vdi
  run qemu-img convert -f vdi -O qcow2 demo.vdi demo-back.qcow2
  run ls -lh "$SCRATCH"
  ok "Done. Scratch files stay in $SCRATCH (removed by kvm-cleanup.sh)."
}

# =============================================================================
# STEP 5 - create: a VM from a cloud image (overlay disk + cloud-init + virt-install)
# =============================================================================
net_spec() {   # nat | bridge | macvtap  ->  virt-install --network value
  case "${1:-nat}" in
    nat)     echo "network=$NAT_NET,model=virtio" ;;
    bridge)  V net-info "$BRIDGE_NET" >/dev/null 2>&1 || die "Bridge not set up. Run './kvm-lab.sh hostbridge on' first."
             echo "network=$BRIDGE_NET,model=virtio" ;;
    macvtap) echo "network=$MACVTAP_NET,model=virtio" ;;
    *) die "network mode must be nat, bridge or macvtap" ;;
  esac
}

osinfo_for() {
  local list; list=$(virt-install --osinfo list 2>/dev/null || true)
  if grep -Fqw -- "$1" <<<"$list"; then echo "$1"
  elif grep -Fqw linux2022 <<<"$list"; then echo linux2022
  else echo "detect=on,require=off"; fi
}

write_cloud_init() {   # $1 = vm  $2 = extra packages  $3 = extra runcmd lines
  local vm=$1 dir="$VMS_DIR/$1"; mkdir -p "$dir"
  cat >"$dir/user-data" <<EOF
#cloud-config
hostname: $vm
users:
  - name: $VM_USER
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: false
    ssh_authorized_keys:
      - $(cat "$SSH_KEY.pub")
chpasswd:
  expire: false
  users:
    - {name: $VM_USER, password: $VM_PASS, type: text}
ssh_pwauth: false
package_update: true
packages: [qemu-guest-agent${2:+, $2}]
runcmd:
  - [systemctl, enable, --now, qemu-guest-agent]
${3:-}
EOF
  printf 'instance-id: %s\nlocal-hostname: %s\n' "$vm" "$vm" >"$dir/meta-data"
}

vm_ip() {
  local vm=$1 ip mac
  ip=$(V domifaddr "$vm" --source lease 2>/dev/null | awk '/ipv4/{split($4,a,"/");print a[1];exit}')
  [[ -z "$ip" ]] && ip=$(V domifaddr "$vm" --source agent 2>/dev/null \
        | awk '/ipv4/ && $1 !~ /^(lo|docker|br-|veth)/ {split($4,a,"/");print a[1];exit}')
  if [[ -z "$ip" ]]; then
    mac=$(V domiflist "$vm" 2>/dev/null | awk 'NR>2 && $5{print $5;exit}')
    [[ -n "$mac" ]] && ip=$(ip neigh | awk -v m="$mac" 'tolower($5)==tolower(m){print $1;exit}')
  fi
  echo "${ip:-}"
}

wait_ip() {
  local vm=$1 ip="" i
  echo -n "  waiting for $vm to get an IP "
  for i in $(seq 1 60); do ip=$(vm_ip "$vm"); [[ -n "$ip" ]] && break; echo -n "."; sleep 3; done
  echo; [[ -n "$ip" ]] && ok "$vm has IP $ip" || warn "No IP yet. Try './kvm-lab.sh ip $vm' in a minute (macvtap/bridge VMs need the guest agent)."
  echo "$ip" >"$VMS_DIR/$vm/ip" 2>/dev/null || true
}

cmd_create() {
  need_install
  local vm; vm=$(lab_name "${1:?usage: create <name> [image] [nat|bridge|macvtap] [ram-MB] [cpus] [disk-GB]}")
  local img=${2:-ubuntu24} net=${3:-nat} ram=${4:-2048} cpus=${5:-2} disk=${6:-20}
  V dominfo "$vm" >/dev/null 2>&1 && die "$vm already exists."
  image_info "$img"; local netarg; netarg=$(net_spec "$net")
  step "STEP 5 - Create VM '$vm' from $DESC ($ram MB RAM, $cpus vCPU, $disk GB, $net)"
  cmd_download "$img"

  explain "1) Thin overlay disk on top of the downloaded image (the base is never modified)."
  run sudo qemu-img create -q -f qcow2 -b "$BASE_DIR/$FILE" -F qcow2 "$POOL_DIR/$vm.qcow2" "${disk}G"

  explain "2) cloud-init 'user-data': creates user '$VM_USER' with your lab SSH key (files in $VMS_DIR/$vm)."
  write_cloud_init "$vm" "${EXTRA_PACKAGES:-}" "${EXTRA_RUNCMD:-}"

  explain "3) virt-install --import: define and boot the VM from the existing disk (no installer)."
  run sudo virt-install --connect "$URI" --name "$vm" \
      --memory "$ram" --vcpus "$cpus" --cpu host-passthrough \
      --osinfo "$(osinfo_for "$OSI")" --import \
      --disk "path=$POOL_DIR/$vm.qcow2,format=qcow2,bus=virtio" \
      --network "$netarg" \
      --graphics none --console pty,target_type=serial \
      --cloud-init "user-data=$VMS_DIR/$vm/user-data,meta-data=$VMS_DIR/$vm/meta-data" \
      --noautoconsole
  wait_ip "$vm"
  echo; ok "${B}$vm is running.${N}  ./kvm-lab.sh ssh ${vm#lab-}   |   ./kvm-lab.sh console ${vm#lab-}  (user $VM_USER / $VM_PASS, exit with Ctrl+])"
}

# =============================================================================
# Everyday VM commands
# =============================================================================
ssh_opts() { echo -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR; }

cmd_ip()      { local vm; vm=$(lab_name "${1:?usage: ip <vm>}"); local ip; ip=$(vm_ip "$vm"); [[ -n "$ip" ]] && echo "$ip" || die "no IP found for $vm"; }
cmd_ssh()     { local vm; vm=$(lab_name "${1:?usage: ssh <vm> [command]}"); shift
                local ip; ip=$(vm_ip "$vm"); [[ -n "$ip" ]] || die "no IP for $vm (is it running? macvtap VMs are not reachable from the host)"
                # shellcheck disable=SC2046
                exec ssh $(ssh_opts) "$VM_USER@$ip" "$@"; }
cmd_console() { local vm; vm=$(lab_name "${1:?usage: console <vm>}"); echo "  (leave the console with Ctrl+])"; V console "$vm"; }
cmd_start()   { run V start   "$(lab_name "${1:?}")"; }
cmd_stop()    { run V shutdown "$(lab_name "${1:?}")"; }

cmd_list() {
  step "Lab VMs"
  V list --all | awk 'NR<=2 || $2 ~ /^lab-/'
  for vm in $(V list --name | grep '^lab-' || true); do printf "  %-16s %s\n" "$vm" "$(vm_ip "$vm")"; done
  step "Lab networks";      V net-list --all  | awk 'NR<=2 || $1 ~ /^lab-/'
  step "Lab storage pool";  V pool-list --all | awk 'NR<=2 || $1 ~ /^lab-/'
}

cmd_delete() {
  local vm; vm=$(lab_name "${1:?usage: delete <vm>}")
  step "Delete $vm (its overlay disk too; base images stay)"
  V destroy "$vm" >/dev/null 2>&1 || true
  V pool-refresh "$POOL_NAME" >/dev/null 2>&1 || true
  run V undefine "$vm" --snapshots-metadata --remove-all-storage || true
  sudo rm -f "$POOL_DIR/$vm.qcow2"; rm -rf "${VMS_DIR:?}/$vm"
  ok "$vm deleted"
}

cmd_snapshot() {
  local vm; vm=$(lab_name "${1:?usage: snapshot <vm> <name>}"); local name=${2:?snapshot name}
  explain "Internal qcow2 snapshot: disk + (if running) RAM state. Revert with: ./kvm-lab.sh revert ${vm#lab-} $name"
  run V snapshot-create-as "$vm" "$name"; run V snapshot-list "$vm"
}
cmd_revert() { local vm; vm=$(lab_name "${1:?usage: revert <vm> <name>}"); run V snapshot-revert "$vm" "${2:?snapshot name}"; }

# =============================================================================
# inspect - see that a VM is "just a process" with its own virtual hardware
# =============================================================================
cmd_inspect() {
  local vm; vm=$(lab_name "${1:?usage: inspect <vm>}")
  V domstate "$vm" | grep -q running || die "$vm is not running."
  local pid; pid=$(sudo cat "/run/libvirt/qemu/$vm.pid" 2>/dev/null || pgrep -f "guest=$vm," | head -1)
  step "What the GUEST sees vs what the HOST really has - $vm (QEMU pid $pid)"
  explain "1) The whole VM is ONE ordinary host process (qemu-system-x86_64), run as an
   unprivileged user and confined by AppArmor/SELinux (the 'label' column)."
  run ps -o pid,user,%cpu,%mem,rss,etime,comm -p "$pid"
  ps -Z -p "$pid" -o label= 2>/dev/null | sed 's/^/  label: /' || true
  pause
  explain "2) Each vCPU is one THREAD of that process ('CPU n/KVM'). The host scheduler
   runs these threads on real cores; while running, the core is in guest mode."
  run ps -T -p "$pid" -o spid,comm,psr,%cpu
  run V vcpuinfo "$vm"
  pause
  explain "3) Guest RAM is memory of the QEMU process. The guest cannot reach any host memory
   outside it: the CPU's EPT/NPT page tables only map this VM's pages."
  run V dominfo "$vm"
  sudo grep -E '^(VmRSS|Threads)' "/proc/$pid/status" | sed 's/^/  /'
  pause
  explain "4) The guest's disk /dev/vda is a qcow2 FILE; its network card is a tap device."
  run V domblklist "$vm"
  run V domiflist "$vm"
  pause
  explain "5) Same VM from the inside: the guest only knows its virtual hardware."
  local ip; ip=$(vm_ip "$vm")
  # shellcheck disable=SC2046
  [[ -n "$ip" ]] && run ssh $(ssh_opts) "$VM_USER@$ip" "nproc; free -h | head -2; lsblk -d -o NAME,SIZE,TYPE; ip -br link" || true
  explain "Limits you can change (VM off, or live where supported):
   virt-xml $vm --edit --vcpus 4      virt-xml $vm --edit --memory 4096
   virsh schedinfo $vm --set cpu_shares=512      (CPU weight vs other VMs)
   virsh blkdeviotune $vm vda --total-iops-sec 500      (disk I/O cap)
   virsh domiftune $vm <vnetX> --inbound 10000          (network cap, KB/s)"
}

# =============================================================================
# STEP 6 - networking: switch modes, optional real host bridge
# =============================================================================
cmd_net() {
  local vm; vm=$(lab_name "${1:?usage: net <vm> nat|bridge|macvtap}"); local mode=${2:?mode}
  local target; case "$mode" in nat) target=$NAT_NET;; bridge) target=$BRIDGE_NET;; macvtap) target=$MACVTAP_NET;; *) die "mode: nat|bridge|macvtap";; esac
  net_spec "$mode" >/dev/null
  step "STEP 6 - Switch $vm to $mode ($target)"
  explain "virt-xml edits the VM's existing NIC in place: same MAC and PCI slot, only the network
changes. The guest then needs a restart so its DHCP client asks the new network for an IP."
  run sudo virt-xml --connect "$URI" "$vm" --edit --network "network=$target"
  if V domstate "$vm" | grep -q running; then
    run V shutdown "$vm"
    for _ in $(seq 1 30); do V domstate "$vm" | grep -q "shut off" && break; sleep 2; done
    V domstate "$vm" | grep -q "shut off" || run V destroy "$vm"
    run V start "$vm"; wait_ip "$vm"
  fi
}

cmd_hostbridge() {
  local action=${1:?usage: hostbridge on|off}
  have nmcli || die "Real bridge mode here uses NetworkManager (nmcli). Use 'macvtap' mode instead."
  case "$action" in
  on)
    local ifc; ifc=$(default_iface); [[ -n "$ifc" ]] || die "No default interface."
    [[ -d /sys/class/net/$ifc/wireless ]] && die "$ifc is Wi-Fi. Wi-Fi cannot be bridged; use 'macvtap' or 'nat'."
    [[ -n "${SSH_CONNECTION:-}" && "${FORCE:-0}" != 1 ]] && die "You are on SSH: the link drops for a few seconds. Run locally, or FORCE=1 at your own risk."
    nmcli -t con show | grep -q "^$HOST_BRIDGE:" && { ok "bridge already on"; return; }
    step "STEP 6b - Turn $ifc into a port of bridge '$HOST_BRIDGE'"
    warn "This changes host networking. Your connection drops for a few seconds.
           Safety nets: (1) auto-rollback if the bridge gets no IP in 45 s,
           (2) the bridge is NOT autoconnect - a reboot restores your old network,
           (3) './kvm-lab.sh hostbridge off' or kvm-cleanup.sh removes it."
    confirm "Continue?" || return 0
    local orig; orig=$(nmcli -g GENERAL.CONNECTION device show "$ifc")
    echo "$ifc" >"$STATE_DIR/bridge-iface"; echo "$orig" >"$STATE_DIR/bridge-orig-con"
    run sudo nmcli con add type bridge ifname "$HOST_BRIDGE" con-name "$HOST_BRIDGE" \
        bridge.stp no bridge.mac-address "$(cat /sys/class/net/"$ifc"/address)" \
        connection.autoconnect no ipv4.method auto ipv6.method auto
    run sudo nmcli con add type bridge-slave ifname "$ifc" master "$HOST_BRIDGE" \
        con-name "$HOST_BRIDGE-port" connection.autoconnect no
    run sudo nmcli con up "$HOST_BRIDGE-port" || true
    local got=""; for _ in $(seq 1 15); do
      got=$(ip -4 -o addr show "$HOST_BRIDGE" 2>/dev/null | awk '{print $4}'); [[ -n "$got" ]] && break; sleep 3; done
    if [[ -z "$got" ]]; then
      warn "Bridge got no IP - rolling back."; bridge_off "$ifc" "$orig"; die "Bridge mode not possible on this network."
    fi
    ok "Host is now on $HOST_BRIDGE with $got"
    cat >"$STATE_DIR/$BRIDGE_NET.xml" <<EOF
<network>
  <name>$BRIDGE_NET</name>
  <forward mode='bridge'/>
  <bridge name='$HOST_BRIDGE'/>
</network>
EOF
    V net-info "$BRIDGE_NET" >/dev/null 2>&1 || { run V net-define "$STATE_DIR/$BRIDGE_NET.xml"; run V net-start "$BRIDGE_NET"; }
    ok "Use it: ./kvm-lab.sh create web2 ubuntu24 bridge   or   ./kvm-lab.sh net web1 bridge" ;;
  off)
    bridge_off "$(cat "$STATE_DIR/bridge-iface" 2>/dev/null || true)" "$(cat "$STATE_DIR/bridge-orig-con" 2>/dev/null || true)" ;;
  *) die "usage: hostbridge on|off" ;;
  esac
}

bridge_off() {
  local ifc=$1 orig=$2
  V net-destroy "$BRIDGE_NET" >/dev/null 2>&1 || true; V net-undefine "$BRIDGE_NET" >/dev/null 2>&1 || true
  sudo nmcli con delete "$HOST_BRIDGE-port" >/dev/null 2>&1 || true
  sudo nmcli con delete "$HOST_BRIDGE" >/dev/null 2>&1 || true
  if [[ -n "$orig" ]]; then run sudo nmcli con up "$orig" || true
  elif [[ -n "$ifc" ]]; then run sudo nmcli device connect "$ifc" || true; fi
  rm -f "$STATE_DIR/bridge-iface" "$STATE_DIR/bridge-orig-con"
  ok "Host bridge removed, original network restored"
}

# =============================================================================
# STEP 7 - stack: Ubuntu VM with Docker running PostgreSQL + OpenNMS + Python app
# =============================================================================
write_stack_files() {
  local d="$LAB_HOME/stack"; mkdir -p "$d/app"
  local tz; tz=$(timedatectl show -p Timezone --value 2>/dev/null || echo UTC)
  cat >"$d/compose.yaml" <<EOF
# Three containers on one private Docker network "backend".
# Containers find each other by SERVICE NAME (database, horizon, app) via Docker DNS.
name: labstack
services:
  database:
    image: postgres:15
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
      POSTGRES_DB: appdb            # extra database for our Python app
    volumes: [pgdata:/var/lib/postgresql/data]
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 10s
      timeout: 5s
      retries: 10
    networks: [backend]

  horizon:
    image: opennms/horizon:latest   # pin a version (e.g. opennms/horizon:34.x.y) for real use
    command: ["-s"]                 # -s = initialise the DB schema, then start
    depends_on:
      database: {condition: service_healthy}
    environment:
      TZ: $tz
      POSTGRES_HOST: database
      POSTGRES_PORT: 5432
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
      OPENNMS_DBNAME: opennms
      OPENNMS_DBUSER: opennms
      OPENNMS_DBPASS: opennms
    volumes: [opennms-rrd:/opt/opennms/share/rrd]
    ports: ["8980:8980"]            # web UI published on the VM's IP
    networks: [backend]

  app:
    build: ./app
    depends_on:
      database: {condition: service_healthy}
    environment:
      DB_HOST: database
      DB_NAME: appdb
      DB_USER: postgres
      DB_PASSWORD: postgres
      OPENNMS_URL: http://horizon:8980/opennms
      OPENNMS_USER: admin
      OPENNMS_PASSWORD: admin
    restart: unless-stopped
    networks: [backend]

networks:
  backend: {}
volumes:
  pgdata: {}
  opennms-rrd: {}
EOF
  cat >"$d/app/Dockerfile" <<'EOF'
FROM python:3.12-slim
RUN pip install --no-cache-dir "psycopg[binary]" requests
COPY app.py /app.py
CMD ["python", "-u", "/app.py"]
EOF
  cat >"$d/app/app.py" <<'EOF'
"""Tiny demo app: asks OpenNMS for its status and stores each answer in PostgreSQL.
It shows the three containers talking: app -> horizon (HTTP) and app -> database (SQL)."""
import os, time, psycopg, requests

DB = dict(host=os.environ["DB_HOST"], dbname=os.environ["DB_NAME"],
          user=os.environ["DB_USER"], password=os.environ["DB_PASSWORD"])
URL = os.environ["OPENNMS_URL"] + "/rest/info"
AUTH = (os.environ["OPENNMS_USER"], os.environ["OPENNMS_PASSWORD"])

with psycopg.connect(**DB, autocommit=True) as conn:
    conn.execute("""CREATE TABLE IF NOT EXISTS checks (
                      id serial PRIMARY KEY, at timestamptz DEFAULT now(),
                      ok boolean, detail text)""")
    while True:
        try:
            r = requests.get(URL, auth=AUTH, timeout=5, headers={"Accept": "application/json"})
            ok, detail = r.ok, (r.json().get("displayVersion", r.text[:80]) if r.ok else f"HTTP {r.status_code}")
        except requests.RequestException as e:
            ok, detail = False, f"OpenNMS not reachable yet ({type(e).__name__})"
        conn.execute("INSERT INTO checks (ok, detail) VALUES (%s, %s)", (ok, detail))
        total = conn.execute("SELECT count(*) FROM checks").fetchone()[0]
        print(f"OpenNMS ok={ok} detail={detail!r}  rows in appdb.checks={total}", flush=True)
        time.sleep(30)
EOF
}

cmd_stack() {
  need_install
  local net=${1:-nat} vm="lab-stack"
  step "STEP 7 - Container stack: PostgreSQL + OpenNMS + Python app in one KVM VM"
  explain "KVM gives you the VM (the 'machine'); Docker runs the containers inside it,
exactly like you did on VirtualBox. Sizing: 6 GB RAM (OpenNMS alone wants ~4 GB), 2 vCPU, 30 GB disk."
  pause
  if ! V dominfo "$vm" >/dev/null 2>&1; then
    EXTRA_PACKAGES="docker.io, docker-compose-v2" \
    EXTRA_RUNCMD="  - [usermod, -aG, docker, $VM_USER]" \
      cmd_create stack ubuntu24 "$net" 6144 2 30
  fi
  local ip; ip=$(vm_ip "$vm"); [[ -n "$ip" ]] || die "No IP for $vm yet - retry './kvm-lab.sh stack' in a minute."
  # shellcheck disable=SC2046,SC2207
  local S=(ssh $(ssh_opts) "$VM_USER@$ip")
  echo -n "  waiting for SSH + cloud-init (installs Docker, 2-5 min) "
  for _ in $(seq 1 60); do "${S[@]}" true 2>/dev/null && break; echo -n "."; sleep 5; done; echo
  run "${S[@]}" "cloud-init status --wait >/dev/null || true; docker --version; docker compose version"
  write_stack_files
  explain "Copy compose.yaml + app/ (generated in $LAB_HOME/stack) to the VM and start it."
  # shellcheck disable=SC2046
  run scp -q -r $(ssh_opts) "$LAB_HOME/stack" "$VM_USER@$ip:"
  run "${S[@]}" "cd stack && sudo docker compose up -d --build"
  run "${S[@]}" "cd stack && sudo docker compose ps"
  echo; ok "${B}Stack started.${N} OpenNMS takes 3-5 minutes on first start."
  echo "     Web UI : http://$ip:8980/opennms   (admin / admin - change it)"
  echo "     Logs   : ./kvm-lab.sh ssh stack 'cd stack && sudo docker compose logs -f app'"
  echo "     SQL    : ./kvm-lab.sh ssh stack \"cd stack && sudo docker compose exec database psql -U postgres -d appdb -c 'select * from checks order by id desc limit 5'\""
}

# =============================================================================
# tour - the whole beginner path in one go
# =============================================================================
cmd_tour() {
  cmd_check; pause
  cmd_install; pause
  cmd_download ubuntu24
  cmd_learn_images; pause
  cmd_create web1 ubuntu24 nat
  step "Run a command inside the VM over SSH"
  sleep 20
  local ip; ip=$(vm_ip lab-web1)
  # shellcheck disable=SC2046
  [[ -n "$ip" ]] && run ssh $(ssh_opts) "$VM_USER@$ip" "hostnamectl; ip -br addr" || true
  cmd_list
  echo; ok "Tour finished. Try: ./kvm-lab.sh create db1 centos9 | ./kvm-lab.sh stack | ./kvm-cleanup.sh"
}

cmd_help() {
  cat <<EOF
${B}kvm-lab.sh${N} - KVM learning lab        (undo everything: ./kvm-cleanup.sh)

  ${B}Setup${N}
    check                          1  is this machine ready for KVM? (read-only)
    install [--gui]                2  install KVM/libvirt + lab sandbox (--gui adds virt-manager)
  ${B}Images${N}
    images                         3  list cloud images ($IMAGES)
    download <image>               3  download one image
    learn-images                   4  hands-on qemu-img: qcow2 vs raw, overlays, snapshots
  ${B}VMs${N}
    create <vm> [image] [net] [ram-MB] [cpus] [disk-GB]
                                   5  e.g. create web1 ubuntu24 nat 2048 2 20
    list | ip <vm> | ssh <vm> [cmd] | console <vm>
    start <vm> | stop <vm> | delete <vm>
    snapshot <vm> <name> | revert <vm> <name>
    inspect <vm>                      see the VM as a host process: threads, RAM, disk, NIC
  ${B}Networking${N}
    net <vm> nat|bridge|macvtap    6  switch a VM's network mode
    hostbridge on|off              6  optional real bridge br-lab (wired + NetworkManager)
  ${B}Containers${N}
    stack [nat|bridge]             7  VM with Docker: PostgreSQL + OpenNMS + Python app
  ${B}Guided${N}
    tour                              check -> install -> learn-images -> first VM

  VM names get a 'lab-' prefix automatically (web1 -> lab-web1).
EOF
}

# ----------------------------------------------------------------------------
cmd=${1:-help}; shift || true
case "$cmd" in
  check) cmd_check ;;               install) cmd_install "$@" ;;
  images) cmd_images ;;             download) cmd_download "$@" ;;
  learn-images) cmd_learn_images ;; create) cmd_create "$@" ;;
  list) cmd_list ;;                 ip) cmd_ip "$@" ;;
  ssh) cmd_ssh "$@" ;;              console) cmd_console "$@" ;;
  start) cmd_start "$@" ;;          stop) cmd_stop "$@" ;;
  delete) cmd_delete "$@" ;;        snapshot) cmd_snapshot "$@" ;;
  revert) cmd_revert "$@" ;;        net) cmd_net "$@" ;;
  inspect) cmd_inspect "$@" ;;
  hostbridge) cmd_hostbridge "$@" ;; stack) cmd_stack "$@" ;;
  tour) cmd_tour ;;                 help|-h|--help) cmd_help ;;
  *) cmd_help; exit 1 ;;
esac
