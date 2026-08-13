#!/usr/bin/env bash
# Intel Arc Pro SR-IOV Setup for Proxmox VE
# https://blogs.damiendye.uk/proxmox/licence-free-vdi-intel-arc-pro-sriov/
#
# Detects an Arc Pro B-series GPU, blacklists i915, generates a tmpfiles.d
# config for VF creation + xe unbind + vfio-pci bind, and applies it.
#
# Prerequisites (not handled here):
#   - GPU firmware updated via a temporary Windows VM (see blog post)
#   - BIOS: Resizable BAR, SR-IOV, IOMMU (VT-d / AMD-Vi) enabled; CSM off
#   - UEFI boot; kernel 6.17+
#
# Firmware VF limits (driver 32.0.101.8306):
#   B50 16 GB → 2    B60 24 GB → 7    B60 Dual 2×24 GB → 7 per die
#   B70 32 GB → 7    Max set in IFWI, no public tool to change it.
#
# Author:  Damien Dye (generated with Claude, 13/08/2026)
# Licence: GPL

set -euo pipefail

# Colours
R='\033[0;31m'
G='\033[0;32m'
Y='\033[1;33m'
C='\033[0;36m'
B='\033[1m'
N='\033[0m'

info() { echo -e "${C}[INFO]${N}  $*"; }
ok()   { echo -e "${G}[ OK ]${N}  $*"; }
warn() { echo -e "${Y}[WARN]${N}  $*"; }
die()  { echo -e "${R}[FAIL]${N}  $*"; exit 1; }

# Ensure address has 0000: domain prefix
full_addr() {
    local a="$1"
    if [[ "${a}" != 0000:* ]]; then
        a="0000:${a}"
    fi
    echo "${a}"
}

# Defaults
NUM_VFS=""
PCI_SLOT=""
ASPM_OFF=false
TMPFILES="/etc/tmpfiles.d/intel-arc-pro-sriov.conf"

# Parse args
while [[ $# -gt 0 ]]; do
    case "$1" in
        --num-vfs)
            NUM_VFS="$2"
            shift 2
            ;;
        --pci)
            PCI_SLOT="$2"
            shift 2
            ;;
        --aspm-off)
            ASPM_OFF=true
            shift
            ;;
        -h|--help)
            echo "Usage: sudo bash $0 [--num-vfs N] [--pci BB:DD.F] [--aspm-off]"
            exit 0
            ;;
        *)
            die "Unknown option: $1"
            ;;
    esac
done

echo -e "\n${B}  Intel Arc Pro SR-IOV Setup for Proxmox VE${N}\n"

# --- Pre-flight checks ---

[[ "$(id -u)" -eq 0 ]] || die "Must be root."
command -v pveversion &>/dev/null || die "Not a Proxmox VE host."
info "Proxmox: $(pveversion 2>/dev/null)"

IFS=. read -r KMAJ KMIN _ <<< "$(uname -r)"
if [[ "${KMAJ}" -lt 6 ]] || { [[ "${KMAJ}" -eq 6 ]] && [[ "${KMIN}" -lt 17 ]]; }; then
    die "Kernel $(uname -r) too old — need 6.17+."
fi
info "Kernel $(uname -r)"

[[ -d /sys/firmware/efi ]] || warn "Not UEFI. SR-IOV needs UEFI with CSM off."

# IOMMU — vendor-aware
CPU_VENDOR="$(grep -m1 'vendor_id' /proc/cpuinfo 2>/dev/null | awk '{print $3}')"
case "${CPU_VENDOR}" in
    GenuineIntel)
        IOMMU_PARAM="intel_iommu=on"
        BIOS_NAME="VT-d"
        ;;
    AuthenticAMD)
        IOMMU_PARAM="amd_iommu=on"
        BIOS_NAME="AMD-Vi"
        ;;
    *)
        IOMMU_PARAM="intel_iommu=on"
        BIOS_NAME="VT-d / AMD-Vi"
        ;;
esac

if ! grep -qE "${IOMMU_PARAM}|iommu=pt" /proc/cmdline; then
    warn "IOMMU not found in cmdline. Need: ${IOMMU_PARAM} iommu=pt"
    warn "BIOS: enable ${BIOS_NAME}. Then update-grub && reboot."
fi

# Blacklist i915 — xe is the correct driver for Battlemage
if ! grep -rq 'blacklist i915' /etc/modprobe.d/ 2>/dev/null; then
    info "Blacklisting i915..."
    echo "blacklist i915" > /etc/modprobe.d/blacklist-i915.conf
    if update-initramfs -u -k all 2>/dev/null; then
        ok "i915 blacklisted, initramfs rebuilt."
    else
        warn "initramfs rebuild failed — run update-initramfs -u -k all manually."
    fi
fi

# --- Detect GPU and SR-IOV capability ---

if [[ -z "${PCI_SLOT}" ]]; then
    GPU_LINE="$(lspci | grep 'VGA' | grep -iE 'Arc Pro B|Battlemage' | head -1 || true)"
    [[ -n "${GPU_LINE}" ]] || die "No Intel Arc Pro Battlemage GPU found."
    PCI_SLOT="$(awk '{print $1}' <<< "${GPU_LINE}")"
fi
info "PF: ${PCI_SLOT}"

DRIVER="$(lspci -ks "${PCI_SLOT}" | awk -F: '/Kernel driver/{print $2}' | xargs)"
[[ "${DRIVER}" == "xe" ]] || warn "PF driver is '${DRIVER}', expected xe."

# Read Total VFs from the SR-IOV capability in lspci
SRIOV_LINE="$(lspci -vvv -s "${PCI_SLOT}" 2>/dev/null | grep 'Total VFs:' || true)"
[[ -n "${SRIOV_LINE}" ]] || die "No SR-IOV capability found — check BIOS SR-IOV setting and GPU firmware."
MAX_VFS="$(echo "${SRIOV_LINE}" | awk -F'[:,]' '{gsub(/ /,"",$2); print $2}')"
info "Total VFs: ${MAX_VFS}"

if [[ -n "${NUM_VFS}" ]] && [[ "${NUM_VFS}" -gt "${MAX_VFS}" ]]; then
    die "Requested ${NUM_VFS} but firmware max is ${MAX_VFS}."
fi
NUM_VFS="${NUM_VFS:-${MAX_VFS}}"
info "Configuring ${NUM_VFS} VFs"

# Still need the sysfs path for the tmpfiles.d w directive
NUMVFS_PATH="$(find /sys/devices -path "*${PCI_SLOT}*" -name sriov_numvfs 2>/dev/null | head -1)"
[[ -n "${NUMVFS_PATH}" ]] || die "sriov_numvfs sysfs path not found."
DEV_DIR="$(dirname "${NUMVFS_PATH}")"

# --- Derive VF addresses ---

declare -a VFS=()

# Read from sysfs if VFs already exist
for link in "${DEV_DIR}"/virtfn*; do
    [[ -L "${link}" ]] || continue
    VFS+=("$(basename "$(readlink -f "${link}")")")
done

# Otherwise derive from PF slot
if [[ ${#VFS[@]} -eq 0 ]]; then
    BASE="0000:${PCI_SLOT%.*}"
    for i in $(seq 1 "${NUM_VFS}"); do
        VFS+=("${BASE}.${i}")
    done
    info "(addresses derived from PF slot)"
fi

for v in "${VFS[@]}"; do
    info "  VF: ${v}"
done

# --- Generate and apply tmpfiles.d config ---

info "Writing ${TMPFILES}..."

{
    echo "# Intel Arc Pro SR-IOV — $(date '+%d/%m/%Y %H:%M %Z')"
    echo "# PF: ${PCI_SLOT}  VFs: ${NUM_VFS}"
    echo "# https://blogs.damiendye.uk/proxmox/licence-free-vdi-intel-arc-pro-sriov/"
    echo ""
    echo "# Create virtual functions"
    echo "w ${NUMVFS_PATH} - - - - ${NUM_VFS}"
    echo ""
    echo "# Unbind VFs from xe"
    for v in "${VFS[@]}"; do
        echo "w /sys/bus/pci/drivers/xe/unbind - - - - $(full_addr "${v}")"
    done
    echo ""
    echo "# Bind VFs to vfio-pci"
    for v in "${VFS[@]}"; do
        echo "w /sys/bus/pci/drivers/vfio-pci/bind - - - - $(full_addr "${v}")"
    done
} > "${TMPFILES}"

ok "Written: ${TMPFILES}"

info "Applying..."
if systemd-tmpfiles --create "${TMPFILES}" 2>/dev/null; then
    ok "Applied."
    VFIO=0
    for v in "${VFS[@]}"; do
        d="$(lspci -ks "${v#0000:}" 2>/dev/null | awk -F: '/Kernel driver/{print $2}' | xargs)"
        if [[ "${d}" == "vfio-pci" ]]; then
            ok "  ${v} → vfio-pci"
            VFIO=$((VFIO + 1))
        else
            warn "  ${v} → ${d:-none}"
        fi
    done
    if [[ "${VFIO}" -eq "${#VFS[@]}" ]]; then
        ok "All ${VFIO} VFs ready."
    else
        warn "${VFIO}/${#VFS[@]} on vfio-pci."
    fi
else
    warn "tmpfiles apply failed — VFs will come up on next reboot."
fi

# --- Optional: ASPM off ---

if [[ "${ASPM_OFF}" == true ]] && ! grep -q pcie_aspm=off /etc/default/grub 2>/dev/null; then
    sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 pcie_aspm=off"/' /etc/default/grub
    update-grub
    ok "pcie_aspm=off added to GRUB."
fi

# --- Summary ---

echo -e "\n${B}  Done${N}"
echo "  PF: ${PCI_SLOT}  VFs: ${NUM_VFS}  Max: ${MAX_VFS}"
echo "  Config: ${TMPFILES}"
echo ""
echo "  Next: create PCI resource mappings in Proxmox GUI, add to VMs,"
echo "  install VirtIO + Intel Arc Pro drivers in each Windows guest."
echo "  Do NOT tick 'Primary GPU' until RDP or similar is working."
echo ""
