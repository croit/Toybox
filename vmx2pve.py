#!/usr/bin/env python3
"""
vmx2pve.py — Convert VMware .vmx VM configuration to Proxmox VE .conf format.

Overview
--------
Parses a VMware .vmx configuration file and produces a Proxmox VE
qemu-server .conf file ready to drop into /etc/pve/qemu-server/<vmid>.conf.
Designed for VMware-to-Proxmox migrations where VMs are backed by an NFS
datastore and VMDK disk images are used directly (no disk conversion).

Supported guest operating systems
----------------------------------
  Linux   — any distro running kernel 2.6 or greater
  Windows — 10, 11, Server 2016, 2019, 2022, 2025

Unsupported guests (legacy Windows, BSD, Solaris, macOS, DOS) are rejected
with a non-zero exit code.

What gets mapped
----------------
  CPU          numvcpus + cpuid.coresPerSocket -> sockets + cores
  Memory       memSize -> memory (with balloon at 75% minimum)
  Firmware     firmware -> bios (seabios or ovmf)
  Secure Boot  uefi.secureBoot.enabled -> pre-enrolled-keys on EFI disk
  Disks        scsi/ide/sata/nvme VMDK references -> scsi devices on NFS
               All SCSI disks: SSD emulation + discard (TRIM) enabled
  CD-ROMs      IDE/SATA optical drives -> empty SATA devices (sata2+)
  Network      All adapters -> virtio, MAC addresses preserved
               Linux guests: multi-queue set to match core count
  Boot order   bios.bootOrder -> Proxmox boot device ordering
  Display      Always VirtIO-GPU
  RTC          localtime for Windows, UTC for Linux
  RNG          virtio-rng from /dev/urandom for Linux guests
  Serial       serial0 -> socket (if present in source)
  USB          USB controller -> spice USB3 (if present in source)
  Machine type Always Q35
  CPU type     Always host (native passthrough)
  Guest agent  Always enabled
  Ballooning   Enabled, minimum RAM set to 75% of configured memory

What is NOT in the .conf (created post-migration via qm set)
------------------------------------------------------------
  EFI disk     VMware has no equivalent; created by Proxmox as
               <vmid>-uefi.qcow2 with correct Secure Boot setting
  TPM 2.0      Required for Win11/Server 2022+; created by Proxmox as
               <vmid>-tpm2.qcow2

Migration workflow
------------------
  1. Run this script against each .vmx file
  2. Create the VMID image directory on the NFS store
  3. Copy the VMDK files into that directory (no conversion needed)
  4. Copy the generated .conf to /etc/pve/qemu-server/<vmid>.conf
  5. Run the qm set commands from the checklist (EFI disk, TPM)
  6. Install qemu-guest-agent inside the VM
  7. For Windows: mount virtio-win ISO, install drivers, and enable the
     paravirt SCSI driver to load at boot using:
     https://github.com/croit/load-virtio-scsi-on-boot

Usage
-----
  Single VM:
    python3 vmx2pve.py server.vmx --vmid 200 --storage nfs-vmware

  With all options:
    python3 vmx2pve.py server.vmx --vmid 200 --storage nfs-vmware \\
        --bridge vmbr0 --scsihw virtio-scsi-pci --onboot -o 200.conf

  Batch conversion:
    for f in /export/vmware/*.vmx; do
        vmid=$((vmid_counter++))
        python3 vmx2pve.py "$f" --vmid "$vmid" --storage nfs-vmware \\
            -o "/etc/pve/qemu-server/${vmid}.conf"
    done

Exit codes
----------
  0  Success
  1  Unsupported guest OS or file not found
  2  Invalid CLI arguments

Author:  Damien Dye / croit GmbH
Licence: MIT
"""

import argparse
import re
import subprocess
import sys
from pathlib import Path


# ---------------------------------------------------------------------------
# VMware -> Proxmox mapping tables
# ---------------------------------------------------------------------------

# Guest OS string -> Proxmox ostype
#
# VMware stores the guest OS as a string like "ubuntu-64", "rhel8-64",
# or "windows2019srvNext-64".  The architecture suffix (-64, -32) and
# version digits are stripped during matching — only the prefix matters.
#
# Proxmox uses a smaller set of ostype values:
#   l26    — Linux kernel 2.6 or later (covers all modern distros)
#   win10  — Windows 10, Server 2016, Server 2019
#   win11  — Windows 11, Server 2022, Server 2025
#
# Any guest OS not in this map is rejected.  This is deliberate — we only
# support migration of modern operating systems that will run well on the
# Proxmox target platform.

OSTYPE_MAP = {
    # Linux — all modern distros run kernel 2.6+
    "ubuntu":       "l26",
    "debian":       "l26",
    "centos":       "l26",
    "rhel":         "l26",
    "redhat":       "l26",
    "sles":         "l26",
    "suse":         "l26",
    "opensuse":     "l26",
    "fedora":       "l26",
    "oracle":       "l26",
    "rocky":        "l26",
    "alma":         "l26",
    "amazonlinux":  "l26",
    "other3xlinux": "l26",
    "other4xlinux": "l26",
    "other5xlinux": "l26",
    "other6xlinux": "l26",
    "other26xlinux":"l26",
    "otherlinux":   "l26",
    "linux":        "l26",
    "coreos":       "l26",
    "photon":       "l26",
    "asianux":      "l26",
    # Windows 10+ / Server 2016+
    "windows2025":  "win11",
    "windows2022":  "win11",
    "windows2019":  "win10",
    "windows2016":  "win10",
    "windows9":     "win10",    # VMware's internal name for Windows 10
    "windows11":    "win11",
    "windows10":    "win10",
}

# Valid Proxmox SCSI controller types for --scsihw CLI validation.
VALID_SCSIHW = [
    "virtio-scsi-pci",      # Recommended default — best performance
    "virtio-scsi-single",   # One queue per disk — useful for high-IOPS NVMe
    "lsi",                  # LSI 53C895A — broad compatibility
    "lsi53c810",            # Older LSI variant
    "megasas",              # LSI MegaRAID SAS
    "pvscsi",               # VMware paravirtual (supported in Proxmox/QEMU)
]


# ---------------------------------------------------------------------------
# .vmx parser
# ---------------------------------------------------------------------------

def parse_vmx(path: str) -> dict:
    """
    Parse a VMware .vmx file into a flat dictionary.

    The .vmx format is a simple key = "value" text file.  Keys are
    lowercased for case-insensitive matching.  Comments (#) and blank
    lines are skipped.  Non-UTF-8 bytes are replaced to handle files
    from different locales.

    Returns a dict of {key: value} pairs with quotes stripped.
    Exits with code 1 if the file does not exist.
    """
    data = {}
    vmx_path = Path(path)
    if not vmx_path.is_file():
        print(f"Error: file not found — {path}", file=sys.stderr)
        sys.exit(1)

    with vmx_path.open("r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if "=" not in line:
                continue
            key, _, val = line.partition("=")
            key = key.strip().lower()
            val = val.strip().strip('"')
            data[key] = val
    return data


# ---------------------------------------------------------------------------
# VmxConverter — encapsulates the full conversion pipeline
# ---------------------------------------------------------------------------

class VmxConverter:
    """
    Converts a parsed VMware .vmx configuration to Proxmox VE format.

    Usage:
        converter = VmxConverter(vmx_data, vmid=200, storage="nfs-vmware")
        converter.extract_all()

        conf = converter.build_conf()       # .conf file content
        cmds = converter.build_post_cmds()  # shell commands for qm set
        notices = converter.notices         # warnings for the operator

    All output generation is separated from extraction.  Nothing is
    printed to stdout or stderr — the caller decides when and where
    to write each piece.
    """

    def __init__(self, vmx: dict, vmid: int, storage: str,
                 bridge: str = "vmbr0", scsihw: str = "virtio-scsi-pci",
                 onboot: bool = False, source_file: str = ""):
        # Source data
        self.vmx = vmx
        self.source_file = source_file

        # Target parameters
        self.vmid = vmid
        self.storage = storage
        self.bridge = bridge
        self.scsihw = scsihw
        self.onboot = onboot

        # Extracted VM properties (populated by extract methods)
        self.name = ""
        self.ostype = None
        self.guest_raw = ""
        self.hw_version = 0
        self.sockets = 1
        self.cores = 1
        self.memory = 1024
        self.bios = "unknown"
        self.secure_boot = False
        self.vmware_scsi = "unknown"
        self.is_windows = False
        self.is_linux = False

        # Extracted device lists
        self.disks = []
        self.cdroms = []
        self.nets = []
        self.boot_order = ""

        # Deferred output — never printed inside the class
        self.notices = []

    # --- Extraction methods ------------------------------------------------

    def extract_ostype(self):
        """Map VMware guestOS string to Proxmox ostype."""
        self.guest_raw = self.vmx.get("guestos", "(not set)")
        guest = self.guest_raw.lower()
        for prefix, ostype in sorted(OSTYPE_MAP.items(),
                                     key=lambda x: -len(x[0])):
            if guest.startswith(prefix):
                self.ostype = ostype
                break
        if self.ostype is not None:
            self.is_windows = self.ostype.startswith("win")
            self.is_linux = self.ostype == "l26"

    def extract_hw_version(self):
        """
        Check the ESXi virtual hardware version.

        The virtualHW.version field in the .vmx indicates which ESXi
        feature set the VM was built against.  Version 14 (ESXi 6.7)
        is the minimum supported for migration.  Older hardware
        versions may use device types or features that do not map
        cleanly to Proxmox.

        Exits with code 1 if the version is missing or below 14.
        """
        raw = self.vmx.get("virtualhw.version", "")
        try:
            self.hw_version = int(raw)
        except ValueError:
            print(
                f"ERROR: virtualHW.version not found or invalid"
                f" (got '{raw or '(missing)'}').\n"
                f"  The .vmx must contain a valid hardware version.\n",
                file=sys.stderr
            )
            sys.exit(1)

        if self.hw_version < 14:
            print(
                f"ERROR: unsupported virtual machine hardware"
                f" version {self.hw_version}.\n"
                f"  Minimum supported version is 14 (ESXi 6.7).\n"
                f"  Not dealing with unsupported nonsense,"
                f" fix it in VMware first.\n",
                file=sys.stderr
            )
            sys.exit(1)

    def extract_cpu(self):
        """Extract CPU topology: sockets and cores per socket."""
        total_vcpus = int(self.vmx.get("numvcpus", "1"))
        cores_per_socket = int(self.vmx.get("cpuid.corespersocket", "1"))
        if cores_per_socket < 1:
            cores_per_socket = 1
        self.sockets = max(1, total_vcpus // cores_per_socket)
        self.cores = cores_per_socket

    def extract_memory(self):
        """Extract VM memory in MB."""
        self.memory = int(self.vmx.get("memsize", "1024"))

    def extract_name(self):
        """Extract and sanitise the VM display name for Proxmox."""
        name = self.vmx.get("displayname", "converted-vm")
        name = re.sub(r"[^a-zA-Z0-9._-]", "-", name)
        self.name = name[:63]

    def extract_firmware(self):
        """
        Extract BIOS type and Secure Boot setting.

        Explicitly checks for known firmware values.  VMware uses
        'bios' for legacy BIOS and 'efi' for UEFI.  If the firmware
        field is missing or contains an unrecognised value, the
        conversion is aborted with an error.
        """
        fw = self.vmx.get("firmware", "").lower()

        if fw == "efi":
            self.bios = "ovmf"
        elif fw == "bios":
            self.bios = "seabios"
        else:
            label = fw if fw else "(missing)"
            print(
                f"ERROR: firmware type not found or unrecognised"
                f" (got '{label}').\n"
                f"  The .vmx must contain: firmware = \"bios\" or"
                f" firmware = \"efi\"\n",
                file=sys.stderr
            )
            sys.exit(1)

        self.secure_boot = (
            self.vmx.get("uefi.secureboot.enabled", "").lower() == "true"
        )

    def extract_vmware_scsi_controller(self):
        """Extract original VMware SCSI controller type for reference."""
        for key, val in self.vmx.items():
            if re.match(r"scsi\d+\.virtualdev", key):
                self.vmware_scsi = val
                return
        self.vmware_scsi = "unknown"

    def extract_disks(self):
        """
        Extract VMDK disk references as Proxmox SCSI devices.

        QEMU reads VMDK natively — no disk conversion needed.
        All SCSI disks get SSD emulation and discard enabled.
        CD-ROM/ISO references are skipped (see extract_cdroms).
        """
        self.disks = []
        disk_index = {"scsi": 0, "ide": 0, "sata": 0, "nvme": 0}
        pattern = re.compile(r"^(scsi|ide|sata|nvme)(\d+):(\d+)\.filename$")

        for key, val in sorted(self.vmx.items()):
            m = pattern.match(key)
            if not m:
                continue
            bus = m.group(1)
            if val.lower().endswith(".iso") or val.lower() == "auto detect":
                continue
            if not val.lower().endswith(".vmdk") and val != "":
                continue

            idx = disk_index[bus]
            disk_index[bus] += 1

            size_key = f"{bus}{m.group(2)}:{m.group(3)}.size"
            size_mb = self.vmx.get(size_key, None)
            size_g = None
            if size_mb:
                try:
                    size_val = int(size_mb)
                    if size_val > 1048576:
                        size_g = max(1, size_val // (1024 * 1024))
                    else:
                        size_g = max(1, size_val // 1024)
                except ValueError:
                    pass

            pve_bus = "scsi" if bus == "nvme" else bus
            size_str = f",size={size_g}G" if size_g else ""
            ssd_str = ",ssd=1,discard=on" if pve_bus == "scsi" else ""
            vmdk_name = Path(val).name
            conf_key = f"{pve_bus}{idx}"
            conf_val = f"{self.storage}:{self.vmid}/{vmdk_name}{size_str}{ssd_str}"
            self.disks.append((conf_key, conf_val, val))

    def extract_cdroms(self):
        """
        Extract CD-ROM devices as empty SATA drives starting at sata2.

        sata0-1 are left free for AHCI fallback if virtio drivers are
        not preloaded on Windows guests.
        """
        self.cdroms = []
        sata_idx = 2
        pattern = re.compile(r"^(scsi|ide|sata)(\d+):(\d+)\.filename$")

        for key, val in sorted(self.vmx.items()):
            m = pattern.match(key)
            if not m:
                continue
            unit_key = f"{m.group(1)}{m.group(2)}:{m.group(3)}"
            device_type = self.vmx.get(f"{unit_key}.devicetype", "").lower()
            is_cdrom = ("cdrom" in device_type
                        or val.lower().endswith(".iso")
                        or val.lower() == "auto detect")
            if not is_cdrom:
                continue
            self.cdroms.append((f"sata{sata_idx}", "none,media=cdrom"))
            sata_idx += 1

        if not self.cdroms:
            self.cdroms.append(("sata2", "none,media=cdrom"))

    def extract_networks(self):
        """
        Extract network adapters as Proxmox virtio NICs.

        MAC addresses are preserved.  Linux guests get multi-queue
        matching the core count.  Missing MACs generate a notice.
        """
        self.nets = []
        pattern = re.compile(r"^ethernet(\d+)\.virtualdev$")
        indices = sorted(
            int(m.group(1)) for key in self.vmx
            if (m := pattern.match(key)))

        for i, eth_idx in enumerate(indices):
            vdev = self.vmx.get(
                f"ethernet{eth_idx}.virtualdev", "unknown").lower()
            mac = self.vmx.get(
                f"ethernet{eth_idx}.address",
                self.vmx.get(f"ethernet{eth_idx}.generatedaddress", ""))
            net_name = self.vmx.get(f"ethernet{eth_idx}.networkname", "")

            if not mac:
                self.notices.append(
                    f"WARNING: no MAC address found for ethernet{eth_idx}"
                    f" — Proxmox will generate a new one"
                )

            mac_str = f"={mac}" if mac else ""
            comment_parts = []
            if net_name:
                comment_parts.append(f"net: {net_name}")
            if vdev != "unknown":
                comment_parts.append(f"was: {vdev}")
            comment = f"  # {', '.join(comment_parts)}" if comment_parts else ""

            queues = f",queues={self.cores}" if self.is_linux and self.cores > 1 else ""
            conf_val = f"virtio{mac_str},bridge={self.bridge},firewall=1{queues}"
            self.nets.append((f"net{i}", conf_val, comment))

    def extract_boot_order(self):
        """
        Map VMware bios.bootOrder to Proxmox device ordering.

        hdd -> SCSI disks, cdrom -> SATA CD-ROMs, net -> NICs.
        Default order if absent: hdd,cdrom,net.
        """
        vmware_order = self.vmx.get("bios.bootorder", "hdd,cdrom,net")
        boot_types = [t.strip().lower() for t in vmware_order.split(",")]

        disk_keys = [k for k, _, _ in self.disks]
        net_keys = [k for k, _, _ in self.nets]
        cdrom_keys = [k for k, _ in self.cdroms]

        items = []
        for bt in boot_types:
            if bt == "hdd":
                items.extend(disk_keys)
            elif bt == "cdrom":
                items.extend(cdrom_keys)
            elif bt == "net":
                items.extend(net_keys)

        seen = set()
        unique = [x for x in items if not (x in seen or seen.add(x))]
        self.boot_order = ("order=" + ";".join(unique)
                           if unique else "order=scsi0;net0")

    def extract_notices(self):
        """Collect operator notices based on guest type."""
        if self.is_windows:
            self.notices.append(
                f"NOTICE: {self.guest_raw} is a Windows guest.\n"
                f"  Virtio drivers MUST be preloaded before first boot on Proxmox.\n"
                f"  The paravirt SCSI driver must be enabled to load at boot or\n"
                f"  Windows will BSOD on a virtio-scsi controller.\n"
                f"  See: https://github.com/croit/load-virtio-scsi-on-boot\n"
                f"\n"
                f"  If virtio drivers are not preloaded, temporarily remap the\n"
                f"  disks to sata0/sata1 (AHCI) so Windows can boot without\n"
                f"  additional drivers, then install virtio-win and switch back."
            )

    def extract_all(self):
        """
        Run the full extraction pipeline.

        Must be called before build_conf() or build_post_cmds().
        Order matters — boot order depends on disks, cdroms, and nets.
        Exits with code 1 if the guest OS is not supported.
        """
        self.extract_hw_version()
        self.extract_ostype()
        if self.ostype is None:
            print(
                f"ERROR: unsupported guest OS '{self.guest_raw}'.\n\n"
                f"Supported guests:\n"
                f"  Linux  — kernel 2.6 or greater (all modern distros)\n"
                f"  Windows — 10, 11, Server 2016, 2019, 2022, 2025\n",
                file=sys.stderr)
            sys.exit(1)

        self.extract_cpu()
        self.extract_memory()
        self.extract_name()
        self.extract_firmware()
        self.extract_vmware_scsi_controller()
        self.extract_disks()
        self.extract_cdroms()
        self.extract_networks()
        self.extract_boot_order()
        self.extract_notices()

    # --- Output methods ----------------------------------------------------

    def build_conf(self) -> str:
        """
        Build the Proxmox .conf file content.

        Returns the complete .conf as a string.  Does NOT include the
        qm set commands — those are in build_post_cmds().
        """
        v = self.vmid
        s = self.storage
        balloon_min = int(self.memory * 0.75)
        lines = []

        # Header
        guest_os = self.vmx.get('guestos', 'unknown')
        display_name = self.vmx.get('displayname', 'unknown')
        lines.append(f"# Converted from: {self.source_file}")
        lines.append(f"# Source guest OS: {guest_os}")
        lines.append(f"# Original display name: {display_name}")
        lines.append(f"# Source SCSI controller: {self.vmware_scsi}")
        lines.append(f"# Source hardware version: {self.hw_version}")
        lines.append("")

        # Core settings
        lines.append("agent: 1")
        lines.append(f"bios: {self.bios}")
        lines.append(f"boot: {self.boot_order}")
        lines.append(f"cores: {self.cores}")
        lines.append("cpu: host")
        lines.append("machine: q35")
        lines.append(f"memory: {self.memory}")
        lines.append(f"balloon: {balloon_min}")
        lines.append(f"name: {self.name}")
        lines.append(f"ostype: {self.ostype}")
        lines.append(f"scsihw: {self.scsihw}")
        lines.append(f"sockets: {self.sockets}")
        cpu_hotplug = self.vmx.get("vcpu.hotadd", "").lower() == "true"
        mem_hotplug = self.vmx.get("mem.hotadd", "").lower() == "true"
        numa = 1 if self.sockets > 1 or cpu_hotplug or mem_hotplug else 0
        lines.append(f"numa: {numa}")
        lines.append(f"onboot: {1 if self.onboot else 0}")
        lines.append(f"localtime: {1 if self.is_windows else 0}")
        if self.is_linux:
            lines.append("rng0: source=/dev/urandom")
        lines.append("")

        # Disks
        lines.append("# --- Disks ---")
        lines.append("# QEMU reads VMDK natively — no conversion needed.")
        lines.append(f"# Copy VMDKs into: /mnt/pve/{s}/images/{v}/")
        lines.append(f"#   mkdir -p /mnt/pve/{s}/images/{v}")
        lines.append("")
        for conf_key, conf_val, _ in self.disks:
            lines.append(f"{conf_key}: {conf_val}")
        lines.append("")

        # Networks
        lines.append("# --- Network ---")
        for conf_key, conf_val, comment in self.nets:
            lines.append(f"{conf_key}: {conf_val}{comment}")
        lines.append("")

        # CD-ROMs
        lines.append("# --- CD-ROM (SATA) ---")
        for conf_key, conf_val in self.cdroms:
            lines.append(f"{conf_key}: {conf_val}")
        lines.append("")

        # Peripherals
        if self.vmx.get("serial0.present", "").lower() == "true":
            lines.append("serial0: socket")
        if self.vmx.get("usb.present", "").lower() == "true":
            lines.append("usb0: spice,usb3=1")
        lines.append("vga: virtio")
        lines.append("")

        # Checklist
        lines.append("# --- Post-migration checklist ---")
        lines.append(f"# 1. mkdir -p /mnt/pve/{s}/images/{v}")
        lines.append("# 2. Copy VMDK files (no conversion needed)")
        lines.append(f"# 3. Copy this .conf to /etc/pve/qemu-server/{v}.conf")
        lines.append("# 4. Run post-migration commands from stderr")
        lines.append("# 5. Install qemu-guest-agent inside the VM")
        lines.append("# 6. Linux: ensure virtio drivers are in initramfs")
        lines.append("# 7. Windows: preload virtio drivers BEFORE first boot")
        lines.append("#    a) Mount virtio-win ISO on SATA CD-ROM")
        lines.append("#    b) Install virtio-scsi, virtio-net, balloon drivers")
        lines.append("#    c) Enable paravirt SCSI at boot:")
        lines.append("#       https://github.com/croit/load-virtio-scsi-on-boot")
        lines.append("#    Without (c) Windows will BSOD on virtio-scsi")
        lines.append("#    Fallback: remap disks to sata0/sata1 (AHCI),")
        lines.append("#    boot, install virtio-win, then switch back")
        lines.append("# 8. Review bridge mapping (default: vmbr0)")
        lines.append("# 9. MAC addresses preserved from source .vmx")
        lines.append(f"# 10. SCSI hw: {self.scsihw} (was: {self.vmware_scsi})")

        return "\n".join(lines)

    def build_post_cmds(self) -> list:
        """
        Build post-migration shell commands.

        Must be run AFTER the .conf is in /etc/pve/qemu-server/.
        Creates the image directory, UEFI disk, and TPM disk.

        Returns a list of (comment, command) tuples.  Comments are
        for display; commands are the executable strings.
        """
        v = self.vmid
        s = self.storage
        cmds = []

        cmds.append((
            "Create VMID image directory",
            f"mkdir -p /mnt/pve/{s}/images/{v}"
        ))

        if self.bios == "ovmf":
            pre = 1 if self.secure_boot else 0
            sb = "Secure Boot ON" if self.secure_boot else "Secure Boot OFF"
            cmds.append((
                f"Allocate EFI disk ({sb})",
                f"pvesm alloc {s} {v} {v}-uefi.qcow2 528K"
            ))
            cmds.append((
                "Attach EFI disk",
                f"qm set {v} --efidisk0 {s}:{v}/{v}-uefi.qcow2,efitype=4m,pre-enrolled-keys={pre}"
            ))

        if self.ostype in ("win11",):
            cmds.append((
                "Allocate TPM 2.0 state disk",
                f"pvesm alloc {s} {v} {v}-tpm2.qcow2 4M"
            ))
            cmds.append((
                "Attach TPM 2.0 disk",
                f"qm set {v} --tpmstate0 {s}:{v}/{v}-tpm2.qcow2,version=v2.0"
            ))

        return cmds

    def format_post_cmds(self) -> str:
        """
        Format the post-migration commands as a readable string.

        Used when printing commands without executing them.
        """
        cmds = self.build_post_cmds()
        lines = []
        lines.append(f"# Post-migration commands for VMID {self.vmid} ({self.name})")
        lines.append(f"# Run AFTER .conf is in /etc/pve/qemu-server/{self.vmid}.conf")
        lines.append("")
        for comment, cmd in cmds:
            lines.append(f"# {comment}")
            lines.append(cmd)
        return "\n".join(lines)

    def run_post_cmds(self) -> bool:
        """
        Execute the post-migration commands on the local system.

        Runs each command via subprocess.  Prints each command and its
        result to stderr.  Stops on the first failure.

        Returns True if all commands succeeded, False otherwise.
        """
        cmds = self.build_post_cmds()
        all_ok = True

        print(f"\nRunning post-migration commands for VMID {self.vmid} ({self.name})...",
              file=sys.stderr)

        for comment, cmd in cmds:
            print(f"  {comment}", file=sys.stderr)
            print(f"  $ {cmd}", file=sys.stderr)

            result = subprocess.run(
                cmd, shell=True, capture_output=True, text=True
            )

            if result.stdout.strip():
                print(f"    {result.stdout.strip()}", file=sys.stderr)

            if result.returncode != 0:
                err = result.stderr.strip()
                print(f"  FAILED (exit {result.returncode}): {err}",
                      file=sys.stderr)
                all_ok = False
                break
            else:
                print(f"    OK", file=sys.stderr)

        return all_ok


# ---------------------------------------------------------------------------
# CLI entry point
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="Convert a VMware .vmx file to a Proxmox VE .conf file.",
        epilog=(
            "Examples:\n"
            "  %(prog)s server.vmx --vmid 200 --storage nfs-vmware\n"
            "  %(prog)s server.vmx --vmid 200 --storage nfs-vmware "
            "--onboot -o 200.conf\n"
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("vmx_file", help="Path to the .vmx file")
    parser.add_argument("--vmid", type=int, default=100,
                        help="Proxmox VM ID (default: 100)")
    parser.add_argument("--storage", default="nfs-vmware",
                        help="Proxmox storage name (default: nfs-vmware)")
    parser.add_argument("--bridge", default="vmbr0",
                        help="Proxmox network bridge (default: vmbr0)")
    parser.add_argument("--scsihw", default="virtio-scsi-pci",
                        choices=VALID_SCSIHW,
                        help="Proxmox SCSI controller (default: "
                             "virtio-scsi-pci)")
    parser.add_argument("--onboot", action="store_true", default=False,
                        help="Start VM on host boot (default: off)")
    parser.add_argument("-o", "--output", default=None,
                        help="Output .conf path (default: <vmid>.conf "
                             "in current directory)")
    args = parser.parse_args()

    # Parse source .vmx
    vmx = parse_vmx(args.vmx_file)

    # Build converter and extract all properties
    converter = VmxConverter(
        vmx,
        vmid=args.vmid,
        storage=args.storage,
        bridge=args.bridge,
        scsihw=args.scsihw,
        onboot=args.onboot,
        source_file=Path(args.vmx_file).name,
    )
    converter.extract_all()

    # Step 1: Write the .conf to file
    out_path = Path(args.output) if args.output else Path(f"{args.vmid}.conf")
    conf = converter.build_conf()
    out_path.write_text(conf + "\n", encoding="utf-8")
    print(f"Written: {out_path}", file=sys.stderr)

    # Step 2: Print notices to stderr (after the .conf is written)
    for notice in converter.notices:
        print("", file=sys.stderr)
        print(notice, file=sys.stderr)

    # Step 3: Execute post-migration commands
    if not converter.run_post_cmds():
        sys.exit(1)


if __name__ == "__main__":
    main()
