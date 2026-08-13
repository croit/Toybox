#!/usr/bin/env bash
# setup-ptp-kvm.sh — Detect a KVM guest and configure ptp_kvm + chrony
#
# Based on: https://blogs.damiendye.uk/proxmox/vm-time-ptp-kvm/
#
# Order matters:
#   1. Check we're on a KVM guest
#   2. udev rule FIRST (so the symlink is created when the device appears)
#   3. Load ptp_kvm module (udev catches the add event, symlink appears)
#   4. Configure chrony with PHC refclock, comment out NTP pools
#   5. Restart chrony and verify
#
# Run as root.  Supports Debian/Ubuntu and RHEL/Rocky/Alma/Fedora/SUSE.

set -euo pipefail

# --- Output helpers -------------------------------------------------------

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info() { printf "${BLUE}[INFO]${NC}  %s\n" "$*"; }
ok()   { printf "${GREEN}[OK]${NC}    %s\n" "$*"; }
warn() { printf "${YELLOW}[WARN]${NC}  %s\n" "$*"; }
fail() { printf "${RED}[FAIL]${NC}  %s\n" "$*"; }
die()  { fail "$*"; exit 1; }

# --- KVM detection --------------------------------------------------------

check_kvm() {
    [[ $EUID -eq 0 ]] || die "Must be run as root (or with sudo)."

    # systemd-detect-virt is the most reliable when present
    if command -v systemd-detect-virt &>/dev/null; then
        [[ "$(systemd-detect-virt --vm 2>/dev/null || true)" == "kvm" ]] && { ok "KVM guest (systemd-detect-virt)."; return 0; }
    fi

    # DMI strings — covers QEMU/KVM on x86
    for dmi in /sys/class/dmi/id/product_name /sys/class/dmi/id/sys_vendor; do
        [[ -f "$dmi" ]] && grep -qiE 'qemu|kvm' "$dmi" 2>/dev/null && { ok "KVM/QEMU guest ($(basename "$dmi"): $(cat "$dmi"))."; return 0; }
    done

    # kvm-clock as clocksource is a strong signal
    local cs="/sys/devices/system/clocksource/clocksource0/current_clocksource"
    [[ -f "$cs" ]] && [[ "$(cat "$cs" 2>/dev/null)" == "kvm-clock" ]] && { ok "KVM guest (clocksource: kvm-clock)."; return 0; }

    die "Not a KVM/QEMU guest — nowt to do here."
}

# --- Distro detection -----------------------------------------------------

detect_distro() {
    [[ -f /etc/os-release ]] || die "/etc/os-release missing — cannot determine distro."
    # shellcheck disable=SC1091
    . /etc/os-release

    case "${ID:-}" in
        debian|ubuntu|linuxmint|pop)
            CHRONY_CONF="/etc/chrony/chrony.conf"; CHRONY_SERVICE="chrony"; CHRONY_GROUP="_chrony" ;;
        *)
            CHRONY_CONF="/etc/chrony.conf"; CHRONY_SERVICE="chronyd"; CHRONY_GROUP="chrony" ;;
    esac
    ok "Distro: ${PRETTY_NAME:-${ID}} — chrony config: ${CHRONY_CONF}"
}

# --- Ensure chrony is installed -------------------------------------------

ensure_chrony() {
    command -v chronyd &>/dev/null && { ok "chrony installed."; return 0; }

    info "Installing chrony..."
    case "${ID:-}" in
        debian|ubuntu|linuxmint|pop) apt-get update -qq && apt-get install -y -qq chrony ;;
        *)
            if command -v dnf &>/dev/null; then dnf install -y -q chrony
            elif command -v zypper &>/dev/null; then zypper install -y chrony
            else yum install -y -q chrony
            fi ;;
    esac
    ok "chrony installed."
}

# --- udev rule (BEFORE module load) --------------------------------------

setup_udev() {
    local udev_file="/etc/udev/rules.d/90-ptp-kvm.rules"
    local rule='ACTION=="add", SUBSYSTEM=="ptp", ATTR{clock_name}=="kvm", SYMLINK+="ptp_kvm", GROUP="'"${CHRONY_GROUP}"'", MODE="0660"'

    if [[ -f "$udev_file" ]] && grep -qF 'ATTR{clock_name}=="kvm"' "$udev_file"; then
        ok "udev rule already exists."
    else
        [[ -f "$udev_file" ]] && cp "$udev_file" "${udev_file}.bak.$(date +%Y%m%d%H%M%S)"
        echo "$rule" > "$udev_file"
        ok "udev rule created at ${udev_file}."
    fi

    udevadm control --reload-rules
    ok "udev rules reloaded — ready for module load."
}

# --- Load module ----------------------------------------------------------

setup_module() {
    local modules_file="/etc/modules-load.d/ptp_kvm.conf"

    if ! lsmod | grep -q '^ptp_kvm'; then
        modprobe ptp_kvm 2>/dev/null || die "Failed to load ptp_kvm — kernel may lack CONFIG_PTP_1588_CLOCK_KVM."
        ok "ptp_kvm module loaded."
    else
        ok "ptp_kvm module already loaded."
    fi

    grep -qsx 'ptp_kvm' "$modules_file" 2>/dev/null || { echo "ptp_kvm" > "$modules_file"; }
    ok "Module persisted in ${modules_file}."

    # udev rule was in place before modprobe, so the symlink should exist
    sleep 1
    if [[ -L /dev/ptp_kvm ]]; then
        ok "/dev/ptp_kvm symlink present."
    else
        warn "/dev/ptp_kvm symlink missing — try: udevadm trigger --subsystem-match=ptp"
    fi
}

# --- Configure chrony -----------------------------------------------------

configure_chrony() {
    local refclock="refclock PHC /dev/ptp_kvm poll 2 stratum 1 delay 0.0004"

    [[ -f "$CHRONY_CONF" ]] || die "chrony config not found at ${CHRONY_CONF}."

    # Already done?
    if grep -qF 'PHC /dev/ptp_kvm' "$CHRONY_CONF"; then
        ok "chrony already has ptp_kvm refclock."
    else
        cp "$CHRONY_CONF" "${CHRONY_CONF}.bak.$(date +%Y%m%d%H%M%S)"
        printf '\n# ptp_kvm — host clock via hypercall, sub-microsecond, no network\n%s\n' "$refclock" >> "$CHRONY_CONF"
        ok "Refclock line appended to ${CHRONY_CONF}."
    fi

    # Comment out pool/server lines in main config and any sources.d files
    sed -i 's/^\(\s*\(pool\|server\)\s\)/#\1/' "$CHRONY_CONF"
    if [[ -d /etc/chrony/sources.d ]]; then
        for f in /etc/chrony/sources.d/*.sources; do
            [[ -f "$f" ]] && sed -i 's/^\(\s*\(pool\|server\)\s\)/#\1/' "$f" && info "Commented out pools in ${f}"
        done
    fi
    ok "NTP pool/server lines commented out."
}

# --- Restart and verify ---------------------------------------------------

verify() {
    systemctl enable --now "${CHRONY_SERVICE}" &>/dev/null
    systemctl restart "${CHRONY_SERVICE}"
    ok "${CHRONY_SERVICE} restarted."

    info "Waiting for chrony to lock onto PHC source..."
    sleep 4

    echo ""
    info "=== Verification ==="
    [[ -L /dev/ptp_kvm ]] && ok "/dev/ptp_kvm: $(ls -l /dev/ptp_kvm)" || warn "/dev/ptp_kvm symlink missing."

    echo ""
    chronyc sources -v 2>/dev/null || warn "chronyc sources failed."
    echo ""
    chronyc tracking 2>/dev/null || warn "chronyc tracking failed."

    echo ""
    local src
    src="$(chronyc sources 2>/dev/null || true)"
    if echo "$src" | grep -q '#\*.*PHC'; then
        ok "PHC refclock selected — reight good, job done."
    elif echo "$src" | grep -q 'PHC'; then
        warn "PHC listed but not selected — check permissions on /dev/ptp_kvm (group: ${CHRONY_GROUP})."
    else
        fail "PHC not appearing in chrony sources — check module and symlink."
    fi

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    info "Reminders:"
    echo "  - The HOST must have proper NTP/PTP — guests inherit its error."
    echo "  - Apply to every Linux guest, not just some (one time authority)."
    echo "  - Live migration is fine — guest reads the new host's clock."
    echo "  - Original chrony config backed up alongside the current one."
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# --- Dry run --------------------------------------------------------------

if [[ "${1:-}" == "--check" ]] || [[ "${1:-}" == "--dry-run" ]]; then
    info "Dry run — checking only, no changes."
    echo ""
    check_kvm
    detect_distro
    echo ""
    modinfo ptp_kvm &>/dev/null && ok "ptp_kvm module available." || fail "ptp_kvm module not found."
    lsmod | grep -q '^ptp_kvm' && ok "ptp_kvm loaded." || info "ptp_kvm not loaded."
    [[ -L /dev/ptp_kvm ]] && ok "/dev/ptp_kvm exists." || info "/dev/ptp_kvm not yet present."
    if [[ -f "${CHRONY_CONF}" ]]; then
        grep -qF 'PHC /dev/ptp_kvm' "${CHRONY_CONF}" && ok "chrony has ptp_kvm." || info "chrony not yet configured."
        grep -qE '^\s*(pool|server)\s' "${CHRONY_CONF}" && warn "Active pool/server lines would be commented out."
    fi
    echo ""
    info "Run without --check to apply."
    exit 0
fi

# --- Main -----------------------------------------------------------------

echo ""
echo "  setup-ptp-kvm.sh — configuring ptp_kvm + chrony"
echo ""
check_kvm
detect_distro
ensure_chrony
setup_udev
setup_module
configure_chrony
verify
