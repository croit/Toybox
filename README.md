# Toybox

Scripts for rapidly fixing and migrating Proxmox Virtual Environment (Proxmox VE) estates.

This is a field toolbox, not a framework. Each script stands alone. There is
nothing to install, no shared library and no config file. Copy the one you need
onto the box, run it, move on.

They exist because the same jobs keep coming up on migrations and new builds,
and doing them by hand across a cluster is slow. Two broad jobs are covered:
**migration**, moving guests off VMware or off physical hardware onto Proxmox VE,
and **rapid fixes**, the host and guest settings that want sorting quickly across
a lot of nodes.

They are opinionated on purpose. They assume Proxmox VE, they prefer VirtIO (the
paravirtualised device drivers), and they apply the settings that are right in
most cases rather than asking a lot of questions.

> **Read the safety notes before you run anything.** Several of these scripts
> make destructive or connectivity-affecting changes to the host they run on.
> They carry no warranty, and running them outside a croit consultancy engagement
> is at your own risk — see [Disclaimer and liability](#disclaimer-and-liability).

---

## Contents

**Migration — VMware or physical to Proxmox VE**

| Script | Runs on | What it does |
| --- | --- | --- |
| [`vmx2pve.py`](#vmx2pvepy) | Proxmox VE host | Converts a VMware `.vmx` file into a Proxmox `qemu-server` `.conf` |
| [`Move-IpToVirtio.ps1`](#move-iptovirtiops1) | Windows guest | Moves static addressing from an emulated Network Interface Card (NIC) to the VirtIO NIC with the same Media Access Control (MAC) address |

**Rapid fixes — host and guest build settings**

| Script | Runs on | What it does |
| --- | --- | --- |
| [`fix_bonds.sh`](#fix_bondssh) | Proxmox VE host | Sets jumbo frames and sane Link Aggregation Control Protocol (LACP) options on a bond and its slaves |
| [`format_nvme.sh`](#format_nvmesh) | Any Linux host | Reformats Non-Volatile Memory Express (NVMe) namespaces to 4K native, excluding the operating system drive |
| [`setup_ptp_kvm.sh`](#setup_ptp_kvmsh) | Linux KVM guest | Configures `ptp_kvm` and chrony so the guest takes time from its host |
| [`create_arc_virtual_functions.sh`](#create_arc_virtual_functionssh) | Proxmox VE host | Sets up Intel Arc Pro virtual functions for Virtual Desktop Infrastructure (VDI) |

---

## Requirements

Nothing here needs installing as a package.

- **`vmx2pve.py`** — Python 3.8 or later, no third-party modules. Run it on the
  Proxmox VE host.
- **`Move-IpToVirtio.ps1`** — Windows PowerShell 5.1 or PowerShell 7, as Administrator.
- **`*.sh`** — Bash 4 or later, as root. `create_arc_virtual_functions.sh` and
  `fix_bonds.sh` expect Proxmox VE. `format_nvme.sh` needs `nvme-cli` and will
  install it from apt if it is missing. `setup_ptp_kvm.sh` needs chrony, which it
  will install, and a kernel built with `CONFIG_PTP_1588_CLOCK_KVM`.

## Getting them onto a host

```bash
git clone https://github.com/<your-account>/Toybox.git
cd Toybox
chmod +x *.sh vmx2pve.py
```

Or pull a single file down with `curl` or `scp`. None of them depend on the others.

---

## Safety notes

| Script | What can go wrong | What to do about it |
| --- | --- | --- |
| `format_nvme.sh` | **Erases every eligible NVMe namespace** | It is dry-run by default. It detects the operating system drive and excludes it, and it skips any device with a mounted filesystem. Read the dry-run output device by device before you pass `--apply`. |
| `fix_bonds.sh` | Drops host networking if the switch side does not match | Copy `/etc/network/interfaces` first. Have out-of-band access working — Intelligent Platform Management Interface (IPMI), iDRAC or iLO — before you start. |
| `create_arc_virtual_functions.sh` | Rebinds the Graphics Processing Unit (GPU) and edits GRUB and the initramfs | Expect a reboot. Do not tick "Primary GPU" on a guest until remote access to that guest works. |
| `setup_ptp_kvm.sh` | Comments out your existing Network Time Protocol (NTP) sources | It backs up `chrony.conf` first and supports `--check` for a dry run. The host clock becomes your only time source, so discipline the host properly first. |
| `Move-IpToVirtio.ps1` | Removes the old adapter and can leave the guest unreachable | Run it from the console, not over Remote Desktop Protocol (RDP). `-RemoveOld:$false` keeps the old adapter in place. |
| `vmx2pve.py` | **Executes `qm` and `pvesm` commands** against the local host after writing the `.conf` | Run it on the target Proxmox VE host, with the VM ID you actually intend to use. |

---

## `vmx2pve.py`

Parses a VMware `.vmx` configuration and writes a Proxmox VE `qemu-server`
`.conf`, ready to drop into `/etc/pve/qemu-server/<vmid>.conf`. It is built for
migrations where the VMDK disk images sit on a Network File System (NFS)
datastore and are used directly. There is no disk conversion step.

What it maps:

- CPU topology, from `numvcpus` and `cpuid.coresPerSocket` to sockets and cores
- Memory, with ballooning enabled and a floor of 75% of the configured amount
- Firmware, SeaBIOS or Open Virtual Machine Firmware (OVMF), and Secure Boot state
- Disks. Everything becomes Small Computer System Interface (SCSI) with solid-state
  drive emulation and discard (TRIM) enabled
- Optical drives, which become empty SATA devices
- Network adapters. All become VirtIO with the MAC address preserved, and Linux
  guests get multi-queue matched to the core count
- Boot order, display (always VirtIO-GPU), real-time clock (UTC for Linux,
  localtime for Windows), random number generator, serial and USB

Machine type is always Q35, CPU type is always `host`, and the guest agent is
always enabled.

Supported guests are Linux on kernel 2.6 or later, and Windows 10, 11, Server
2016, 2019, 2022 and 2025. Anything else exits with code 1. That is deliberate —
the conversion is only worth trusting on platforms that will run well on the
target.

### Usage

```bash
python3 vmx2pve.py server.vmx --vmid 200 --storage nfs-vmware
```

| Option | Default | Meaning |
| --- | --- | --- |
| `vmx_file` | — | Path to the source `.vmx` (positional, required) |
| `--vmid` | `100` | Proxmox VM ID |
| `--storage` | `nfs-vmware` | Proxmox storage name |
| `--bridge` | `vmbr0` | Network bridge for all adapters |
| `--scsihw` | `virtio-scsi-pci` | SCSI controller model |
| `--onboot` | off | Start the guest when the host boots |
| `-o`, `--output` | `<vmid>.conf` | Where to write the generated config |

Exit codes: `0` success. `1` unsupported guest, missing file, or a failed
post-migration command. `2` invalid arguments.

### It does more than write a file

Once the `.conf` is written, the script runs the post-migration commands against
the local host and stops at the first failure:

- `mkdir -p /mnt/pve/<storage>/images/<vmid>`
- For OVMF guests, `pvesm alloc` for the Extensible Firmware Interface (EFI) disk,
  then `qm set --efidisk0` with `pre-enrolled-keys` matching the source Secure
  Boot setting
- For Windows 11 and Server 2022 or later, `pvesm alloc` for the Trusted Platform
  Module (TPM) state disk, then `qm set --tpmstate0`

So run it on the host, not on your laptop.

### Migration workflow

1. Run the script against each `.vmx`.
2. Copy the VMDK files into the image directory the script created. No conversion
   needed.
3. Copy the generated `.conf` to `/etc/pve/qemu-server/<vmid>.conf`.
4. Confirm the EFI and TPM disks exist.
5. Install `qemu-guest-agent` in the guest.
6. On Windows, mount the virtio-win ISO, install the drivers, and make the
   paravirtualised SCSI driver load at boot using
   [load-virtio-scsi-on-boot](https://github.com/croit/load-virtio-scsi-on-boot).
7. Boot the guest. On Windows, run [`Move-IpToVirtio.ps1`](#move-iptovirtiops1) to
   bring the static addressing across.

### Batch conversion

```bash
vmid=200
for f in /export/vmware/*.vmx; do
    python3 vmx2pve.py "$f" --vmid "$vmid" --storage nfs-vmware \
        -o "/etc/pve/qemu-server/${vmid}.conf"
    vmid=$((vmid + 1))
done
```

---

## `Move-IpToVirtio.ps1`

After a migration, Windows treats the VirtIO NIC as a new adapter and leaves the
static addressing stranded on the old one, which is now hidden. This finds
adapter pairs that share a MAC address where one is VirtIO and the other is not.
It copies the IPv4 and IPv6 addresses, default gateways and Domain Name System
(DNS) servers across, then removes the old adapter.

That covers virtual-to-virtual moves from VMware (E1000, E1000E or VMXNET3 to
VirtIO), physical-to-virtual moves (Intel, Broadcom or Realtek to VirtIO), and
any driver swap after an import.

Three behaviours worth knowing:

- Dynamic addressing is left alone. If every address in a family comes from
  Dynamic Host Configuration Protocol (DHCP) or Stateless Address
  Autoconfiguration (SLAAC), that family is skipped and the VirtIO adapter gets
  its own lease.
- Link-local addresses (`169.254.*` and `fe80::`) are skipped. Windows
  regenerates them.
- Documentation, benchmarking, multicast, loopback and other non-production
  ranges are skipped, each with a warning naming the relevant Request for
  Comments (RFC).

### Usage

Run it from the guest console. The old adapter is removed as part of the job, so
an RDP session will drop.

```powershell
# Move the config and remove the old adapter
.\Move-IpToVirtio.ps1

# Keep the old adapter
.\Move-IpToVirtio.ps1 -RemoveOld:$false
```

If execution policy blocks it:

```powershell
powershell -ExecutionPolicy Bypass -File .\Move-IpToVirtio.ps1
```

---

## `fix_bonds.sh`

Sets jumbo frames on a bond and all its slave interfaces, live and persistently
in `/etc/network/interfaces`.

If the bond runs 802.3ad it also sets two things that matter. `bond-lacp-rate
fast` brings failover detection down to seconds, where the default of slow sits
at 30-second intervals. `bond-xmit-hash-policy layer3+4` spreads traffic across
both links on source and destination IP and port, rather than MAC address alone,
so you get the bandwidth you paid for.

Useful when you have a cluster of nodes to sort and no appetite for clicking
through the web interface on each one.

### Usage

All arguments are positional and optional.

```bash
sudo bash fix_bonds.sh                 # bond1, MTU 9000, /etc/network/interfaces
sudo bash fix_bonds.sh bond0           # different bond, still 9000
sudo bash fix_bonds.sh bond1 1500      # back to the standard frame size
sudo bash fix_bonds.sh bond1 9000 /etc/network/interfaces.new
```

| Position | Default | Meaning |
| --- | --- | --- |
| 1 | `bond1` | Bond interface to update |
| 2 | `9000` | Maximum Transmission Unit (MTU) value |
| 3 | `/etc/network/interfaces` | Config file to edit |

It edits the config file in place, reloads networking, then prints the resulting
MTU and LACP state so you can confirm the change stuck.

Jumbo frames only work end to end. The switch ports and everything else on the
same layer 2 segment have to match, or large frames get black-holed silently.

---

## `format_nvme.sh`

Walks every NVMe namespace on the host and reformats it to the 4096-byte data,
zero-byte metadata Logical Block Addressing (LBA) format, known as 4K native. That
removes the 512-byte emulation read-modify-write penalty and cuts interrupt
overhead. Typically run when provisioning drives for Ceph Object Storage Daemons
(OSDs).

It erases the whole namespace, which is why it is dry-run by default.

Three protections are built in. It works out which NVMe device backs the running
operating system, covering plain partitions, Logical Volume Manager (LVM), ZFS
and software RAID, and excludes it. It skips any device with a mounted
filesystem. It skips devices already running 4K native, and devices with no
suitable LBA format on offer.

### Usage

```bash
sudo ./format_nvme.sh           # dry run
sudo ./format_nvme.sh --apply   # format
```

Read the dry-run output device by device and confirm each one is a drive you are
happy to wipe. Do not run this on a host with live OSDs or pools.

---

## `setup_ptp_kvm.sh`

Configures a Linux Kernel-based Virtual Machine (KVM) guest to take its time
directly from the host through the `ptp_kvm` paravirtualised clock, rather than
over the network. You get sub-microsecond accuracy and no time traffic at all.

Background: <https://blogs.damiendye.uk/proxmox/vm-time-ptp-kvm/>

The order matters, and the script holds to it. Confirm the guest is KVM. Install
the udev rule first, so the `/dev/ptp_kvm` symlink is created the moment the
device appears. Load and persist the `ptp_kvm` module. Add the PTP Hardware Clock
(PHC) reference clock to chrony and comment out the NTP pools. Restart chrony and
verify.

It supports Debian and Ubuntu alongside RHEL, Rocky, Alma, Fedora and SUSE, and
picks the right chrony config path, service name and group for each.

### Usage

```bash
sudo ./setup_ptp_kvm.sh --check   # dry run, no changes
sudo ./setup_ptp_kvm.sh           # apply
```

`chrony.conf` is backed up to `chrony.conf.bak.<timestamp>` before it is edited.

### Three things to hold in mind

- The host needs proper NTP or Precision Time Protocol (PTP). Guests inherit its
  error exactly.
- Apply it to every Linux guest, not some of them. One time authority, or none.
- Live migration is fine. The guest reads the new host's clock.

---

## `create_arc_virtual_functions.sh`

Sets up Single Root I/O Virtualisation (SR-IOV) virtual functions on an Intel Arc
Pro B-series (Battlemage) GPU, so a Proxmox VE host can hand GPU slices to Windows
VDI guests without a per-seat licence cost.

It detects the card, blacklists `i915` because `xe` is the correct driver for
Battlemage, writes a `tmpfiles.d` config that creates the virtual functions,
unbinds them from `xe` and binds them to `vfio-pci`, then applies it.

Background: <https://blogs.damiendye.uk/proxmox/licence-free-vdi-intel-arc-pro-sriov/>

### Prerequisites the script does not handle

- GPU firmware updated. This needs a temporary Windows guest — see the blog post.
- In the system firmware: Resizable BAR, SR-IOV and the Input/Output Memory
  Management Unit (IOMMU, marketed as VT-d on Intel and AMD-Vi on AMD) all
  enabled, and the Compatibility Support Module (CSM) off.
- Unified Extensible Firmware Interface (UEFI) boot, kernel 6.17 or later.

Virtual function counts are fixed in the Integrated Firmware Image and no public
tool changes them. On driver 32.0.101.8306: B50 16 GB gives 2, B60 24 GB gives 7,
B60 Dual 2×24 GB gives 7 per die, B70 32 GB gives 7.

### Usage

```bash
sudo bash create_arc_virtual_functions.sh                 # auto-detect, firmware maximum
sudo bash create_arc_virtual_functions.sh --num-vfs 4     # fewer functions
sudo bash create_arc_virtual_functions.sh --pci 03:00.0   # pick the card explicitly
sudo bash create_arc_virtual_functions.sh --aspm-off      # also add pcie_aspm=off to GRUB
```

`--aspm-off` disables Active State Power Management, which is worth trying if you
see the card drop under load.

The generated config lands at `/etc/tmpfiles.d/intel-arc-pro-sriov.conf` and is
reapplied at every boot.

### Afterwards

Create PCI resource mappings in the Proxmox VE web interface, attach one to each
guest, then install the VirtIO and Intel Arc Pro drivers inside the guest. Leave
"Primary GPU" unticked until RDP or an equivalent remote session works, or you
lose the console.

---

## Conventions

Anything new here should follow the same rules:

- Shell scripts use `set -euo pipefail` where it is safe, colour-coded
  `[INFO]`, `[ OK ]`, `[WARN]` and `[FAIL]` output, and are idempotent. Running
  one twice does not make things worse.
- Destructive behaviour is dry-run by default or gated behind an explicit flag.
- Config files are backed up with a timestamp before being edited.
- British English throughout, with the odd Yorkshire word in the output.

## Support and consultancy

If you want help with a Proxmox VE migration, a cluster design, or a review of an
existing environment, croit sells consultancy for exactly that work. Talk to croit
sales: <https://croit.io>. Work done under an engagement comes with defined scope
and terms, which is the difference that matters — see
[Disclaimer and liability](#disclaimer-and-liability).

Questions about the scripts themselves belong in an issue on this repository. I am
happy to go deeper on any of it.

## Contributing

Issues and pull requests are welcome. If you are adding a script:

- Keep it self-contained. No shared helpers, no install step.
- Put a header comment at the top covering purpose, prerequisites, usage and risk.
- Make destructive behaviour opt-in, and check for root before you do anything.
- Run `shellcheck` over shell scripts before you open the pull request.
- Add a row to the contents table and a section to this file.

## Licence

GNU General Public License version 2 (GPL-2.0-only). The full text is in
[`LICENSE`](LICENSE).

Every script carries a matching `SPDX-License-Identifier: GPL-2.0-only` tag and
copyright line in its header.

## Author

Written by Damien Dye / croit GmbH, with Claude AI assistance.

Everything here was reviewed and tested by hand before it was published.

Damien Dye — <https://blogs.damiendye.uk> · croit — <https://croit.io>

## Disclaimer and liability

These scripts are published as-is. There is no warranty of any kind, express or
implied, and no guarantee that any of them is fit for your environment.

They are written by a croit engineer, but they are not a croit product. They are
not covered by any croit support agreement, subscription or service level
agreement. Nothing here has been validated against your hardware, your network or
your data.

If you run them yourself, outside a paid croit consultancy engagement, you do so
at your own risk and you own the outcome. croit accepts no responsibility or
liability for any loss, downtime, data loss or damage arising from their use in
that context.

Where the same work is carried out as part of a croit consultancy engagement, the
terms of that engagement govern, and this disclaimer does not apply to it.

They change system configuration, and one of them erases disks. Test them
somewhere you can afford to break before you point them at production.
