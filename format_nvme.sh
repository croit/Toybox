#!/usr/bin/env bash
# format-nvme-4kn.sh — Format NVMe namespaces to 4Kn (4096-byte native sectors)
#
# PURPOSE
#   Iterates over all NVMe namespaces and reformats each one to the optimal
#   4096-byte data / 0-byte metadata LBA format, eliminating the 512e
#   read-modify-write penalty and reducing interrupt overhead.
#
# OS DRIVE PROTECTION
#   Automatically detects the NVMe drive hosting the running OS (whether the
#   root filesystem sits on a plain partition, LVM, ZFS, or software RAID)
#   and excludes it from formatting.
#
# WARNING
#   nvme format --force is DESTRUCTIVE — it erases the entire namespace.
#   Only run this on drives being (re)provisioned, NEVER on drives already
#   holding OSDs, pools, or any data you want to keep.
#
# REQUIREMENTS
#   - nvme-cli
#   - Run as root
#   - bash 4+ (uses extglob)
#
# USAGE
#   chmod +x format-nvme-4kn.sh
#   ./format-nvme-4kn.sh          # dry-run by default
#   ./format-nvme-4kn.sh --apply  # actually format drives

set -uo pipefail
shopt -s extglob

# ---------------------------------------------------------------------------
# Colour output helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No colour

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
skip()    { echo -e "${YELLOW}[SKIP]${NC}  $*"; }
ok()      { echo -e "${GREEN}[ OK ]${NC}  $*"; }
err()     { echo -e "${RED}[ERR ]${NC}  $*" >&2; }

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    err "This script must be run as root."
    exit 1
fi

if ! command -v nvme &>/dev/null; then
    info "nvme-cli not found — installing from apt..."
    if apt-get update -qq && apt-get install -y -qq nvme-cli; then
        ok "nvme-cli installed."
    else
        err "Failed to install nvme-cli. Check your apt sources and try: apt install nvme-cli"
        exit 1
    fi
fi

DRY_RUN=true
if [[ "${1:-}" == "--apply" ]]; then
    DRY_RUN=false
fi

if $DRY_RUN; then
    info "Running in DRY-RUN mode. No drives will be formatted."
    info "Pass --apply to actually format drives."
    echo ""
fi

# ---------------------------------------------------------------------------
# Detect NVMe device(s) backing the running OS
# ---------------------------------------------------------------------------
# We need to find every NVMe parent device that underpins the root filesystem,
# covering plain partitions, LVM, ZFS, and mdraid.

declare -A OS_DEVICES  # associative array keyed on /dev/nvmeXnY

# Helper: given a block device path (partition or whole disk), resolve to the
# parent NVMe namespace device, e.g. /dev/nvme0n1p2 -> /dev/nvme0n1
resolve_nvme_parent() {
    local dev="$1"
    local base
    base=$(basename "$dev")

    # If it's already a namespace (nvmeXnY), return as-is
    if [[ "$base" =~ ^nvme[0-9]+n[0-9]+$ ]]; then
        echo "/dev/$base"
        return
    fi

    # If it's a partition (nvmeXnYpZ), strip the partition suffix
    if [[ "$base" =~ ^(nvme[0-9]+n[0-9]+)p[0-9]+$ ]]; then
        echo "/dev/${BASH_REMATCH[1]}"
        return
    fi

    # Not an NVMe device
    return 1
}

# Method 1: Check the root mount point via findmnt + lsblk
root_source=$(findmnt -n -o SOURCE / 2>/dev/null)
root_fstype=$(findmnt -n -o FSTYPE / 2>/dev/null)

if [[ -n "$root_source" ]]; then
    # Resolve through device-mapper / LVM if needed
    # lsblk -s walks the dependency chain upward to the physical device(s)
    while IFS= read -r pkname; do
        [[ -z "$pkname" ]] && continue
        if parent=$(resolve_nvme_parent "/dev/$pkname" 2>/dev/null); then
            OS_DEVICES["$parent"]=1
        fi
    done < <(lsblk -sno PKNAME "$root_source" 2>/dev/null)

    # Also check the device itself (covers simple partition case)
    if parent=$(resolve_nvme_parent "$root_source" 2>/dev/null); then
        OS_DEVICES["$parent"]=1
    fi
fi

# Method 2: ZFS root — if / is on ZFS, find the pool's vdevs
if [[ "$root_fstype" == "zfs" ]]; then
    root_pool=$(echo "$root_source" | cut -d'/' -f1)
    if [[ -n "$root_pool" ]] && command -v zpool &>/dev/null; then
        # zpool status lists the vdev members
        while IFS= read -r vdev; do
            # vdev could be a partition name, a disk ID, or a path
            # Try /dev/$vdev first, then check /dev/disk/by-id/
            for candidate in "/dev/$vdev" "/dev/disk/by-id/$vdev"; do
                if [[ -b "$candidate" ]]; then
                    resolved=$(readlink -f "$candidate")
                    if parent=$(resolve_nvme_parent "$resolved" 2>/dev/null); then
                        OS_DEVICES["$parent"]=1
                    fi
                    break
                fi
            done
        done < <(zpool status "$root_pool" 2>/dev/null \
                 | awk '/^\t  /{print $1}' \
                 | grep -v -E '^(mirror|raidz|spare|log|cache|special)')
    fi
fi

# Method 3: mdraid — if root sits on /dev/mdX, find the member devices
if [[ -n "$root_source" ]] && [[ "$root_source" == /dev/md* ]]; then
    md_dev=$(readlink -f "$root_source" 2>/dev/null || echo "$root_source")
    md_base=$(basename "$md_dev")
    if [[ -f "/proc/mdstat" ]]; then
        while IFS= read -r member; do
            # Strip the partition indicator, e.g. nvme0n1p2[0] -> nvme0n1p2
            member="${member%%\[*\]}"
            if parent=$(resolve_nvme_parent "/dev/$member" 2>/dev/null); then
                OS_DEVICES["$parent"]=1
            fi
        done < <(grep "^$md_base " /proc/mdstat 2>/dev/null \
                 | grep -oP 'nvme\S+')
    fi
fi

# Report what we found
if [[ ${#OS_DEVICES[@]} -gt 0 ]]; then
    info "Detected OS NVMe device(s) — these will be excluded:"
    for dev in "${!OS_DEVICES[@]}"; do
        info "  $dev"
    done
else
    info "No NVMe-based OS drive detected. All NVMe namespaces are candidates."
fi
echo ""

# ---------------------------------------------------------------------------
# Main loop: format eligible NVMe namespaces to 4Kn
# ---------------------------------------------------------------------------
for dev in /dev/nvme+([0-9])n+([0-9]); do
    # Ensure the device actually exists (avoid glob non-match)
    [[ -e "$dev" ]] || continue

    # --- Per-device header: model, size, current sector format ---
    dev_model=$(nvme id-ctrl "$dev" 2>/dev/null | awk -F: '/^mn /{gsub(/^[ \t]+/,"",$2); print $2}')
    dev_size=$(lsblk -dno SIZE "$dev" 2>/dev/null || echo "unknown")
    ns_info=$(nvme id-ns -H "$dev" 2>/dev/null)
    current_lbs=$(echo "$ns_info" | grep -P 'in use' | grep -oP 'Data Size:\s*\K[0-9]+' 2>/dev/null || echo "unknown")
    echo ""
    info "────────────────────────────────────────"
    info "Device:  $dev"
    info "Model:   ${dev_model:-unknown}"
    info "Size:    ${dev_size}"
    info "Current: ${current_lbs}-byte sectors"

    # --- OS drive exclusion ---
    if [[ -n "${OS_DEVICES[$dev]+_}" ]]; then
        skip "OS drive — excluded from formatting."
        continue
    fi

    # --- Check for mounted filesystems or active users ---
    if lsblk -n -o MOUNTPOINT "$dev" 2>/dev/null | grep -q '[^[:space:]]'; then
        skip "Has mounted partitions — skipping for safety."
        continue
    fi

    # --- Find the optimal 4Kn LBA format (from cached ns_info) ---
    # Look for: Data Size 4096, Metadata Size 0, marked "Best", not already in use
    lbaf=$(echo "$ns_info" \
        | grep -P '(?=.*Metadata Size: 0)(?=.*Data Size: 4096)(?=.*Best)(?!.*in use)' \
        | awk '{found=$3} END {print (found != "" ? found : -1)}')

    if [[ "$lbaf" == "-1" || -z "$lbaf" ]]; then
        # Check if it's already 4Kn (in use) — same cached output
        if echo "$ns_info" | grep -qP '(?=.*Metadata Size: 0)(?=.*Data Size: 4096)(?=.*in use)'; then
            ok "Already 4Kn — nowt to do."
        else
            skip "No matching 4Kn LBA format available."
        fi
        continue
    fi

    # --- Format the drive ---
    if $DRY_RUN; then
        info "Action:  [DRY-RUN] Would format to 4Kn using LBA Format: $lbaf"
    else
        info "Action:  Formatting to 4Kn using LBA Format: $lbaf ..."
        if nvme format --force --lbaf="$lbaf" "$dev"; then
            ok "Formatted to 4Kn successfully."
        else
            err "Failed to format."
        fi
    fi
done

if $DRY_RUN; then
    echo ""
    warn "This were a dry run. Run with --apply to actually format the drives."
fi
