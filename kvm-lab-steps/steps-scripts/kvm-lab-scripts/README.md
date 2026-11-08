# KVM lab scripts

Small scripts, one per step of `STEP-BY-STEP.md` (script number = guide step - 1).
Every script loads `lab.env` itself and prints what it checks, with the expected result.
Generated files (`state/`, `scratch/`, `vms/`, `ssh/`, `export/`, `stack/`, `*.xml`) stay in this folder and are git-ignored.

| Script | What it does |
| --- | --- |
| `01_check_host.sh` | Read-only check: CPU virtualisation, RAM, disk, network card |
| `02_install_kvm.sh` | Installs KVM/libvirt and records what changed (details below) |
| `03_create_storage_pool.sh` | Storage pool `lab-pool` in `/var/lib/libvirt/images/kvm-lab` |
| `04_create_nat_network.sh` | NAT network `lab-nat` (192.168.150.0/24) |
| `05_learn_images.sh` | qemu-img practice in `scratch/` |
| `06_download_image.sh [image]` | Downloads and verifies a cloud image (`ubuntu24`, `centos9`, ...) |
| `07_create_disk.sh [vm] [image] [GB]` | Overlay disk for a VM |
| `08_cloud_init.sh [vm]` | Lab SSH key and cloud-init files |
| `09_boot_vm.sh [vm] [ram] [cpus] [net]` | Boots the VM, waits for IP and SSH |
| `10_inspect_vm.sh [vm]` | The VM seen as a host process |
| `11_snapshot_demo.sh [vm]` | Stop/start and a snapshot round trip |
| `12_other_os.sh [image] [vm]` | Another distribution with steps 06-09 |
| `13_centos_podman_host.sh` / `13_ubuntu_podman_host.sh` | VM with Podman + podman-compose |
| `13b_deploy_containers.sh <folder> [vm]` | Copies your container folder in, PostgreSQL first, then the rest |
| `14_bridge.sh on / vm <vm> / off` | Bridged LAN: each VM gets its own IP (NetworkManager hosts) |
| `15_remote.sh ...` | Deploy VMs to a remote KVM host (see its header) |
| `16_cleanup.sh` | Removes everything the lab created; keeps the scripts |

## 02_install_kvm.sh

Prepares this host to run KVM virtual machines and records exactly what it changed, so `16_cleanup.sh` can undo it.

1. **"Before" picture (2.1).** Saves the list of installed packages and the libvirt directories that already exist to `state/packages-before.txt` and `state/dirs-before.txt`. It is taken only on the first run, so a re-run never overwrites it.
   Check: `wc -l state/packages-before.txt`
2. **Install the packages (2.2).** `qemu-system-x86 qemu-utils libvirt-daemon-system libvirt-clients virtinst dnsmasq-base bridge-utils cloud-utils libguestfs-tools rsync` with apt (a shorter list with dnf).
3. **"After" picture (2.3).** Saves only the new packages to `state/packages-installed-by-lab.txt` and prints how many there are. `0` means they were all installed before the first run, so cleanup will keep KVM installed.
   Check: `cat state/packages-installed-by-lab.txt`
4. **Start libvirt and check KVM (2.4).** Starts `libvirtd`, shows the `kvm` kernel modules and `/dev/kvm`, and runs `virt-host-validate qemu`. WARN lines about IOMMU or secure guest support are fine.
   Check: `systemctl is-active libvirtd` prints `active`
5. **Groups (2.5).** Adds your user to `libvirt` and `kvm` (one marker file per group added in `state/`), so `virsh` works without `sudo`.
   Check: log out and back in, then `groups` lists `libvirt kvm`, and `virsh list --all` shows no permission error.
