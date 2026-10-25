#!/bin/bash
#
# appletbdrm-t1 — universal install script (no PKGBUILD needed)
#
# Installs both DKMS modules (appletbdrm + kernel-hid-t1), the USB
# config switcher service, and the udev seat rule.
#
# Works on any Linux distro that has:
#   - bash, dkms, gcc, make, kernel headers
#
# Usage:
#   sudo ./install.sh              # install everything
#   sudo ./install.sh uninstall    # remove everything
#   ./install.sh status            # show installation status
#
# After install: reboot to activate the Touch Bar.

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Module versions (must match dkms.conf files)
DRM_NAME="appletbdrm"
DRM_VERSION="1.2"
HID_NAME="kernel-hid-t1"
HID_VERSION="0.2"

# Source directories (relative to repo root)
DRM_SRC="${SCRIPT_DIR}/src/appletbdrm"
HID_SRC="${SCRIPT_DIR}/src/kernel-hid-t1"

# Install destinations
USR_SRC="/usr/src"
SBIN_DIR="/usr/local/sbin"
SYSTEMD_DIR="/etc/systemd/system"
UDEV_DIR="/etc/udev/rules.d"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
step()  { echo -e "\n${BLUE}=== $* ===${NC}"; }

check_root() {
    if [ "$EUID" -ne 0 ]; then
        error "Run as root: sudo ./install.sh"
    fi
}

check_deps() {
    info "Checking dependencies..."
    local missing=()

    command -v dkms >/dev/null 2>&1 || missing+=("dkms")
    command -v gcc  >/dev/null 2>&1 || missing+=("gcc")
    command -v make >/dev/null 2>&1 || missing+=("make")

    # Kernel headers: check that the build dir for the running kernel exists
    local kbuild="/lib/modules/$(uname -r)/build"
    if [ ! -d "$kbuild" ]; then
        missing+=("kernel-headers (for $(uname -r))")
    fi

    if [ ${#missing[@]} -gt 0 ]; then
        error "Missing: ${missing[*]}\n\nInstall them first, e.g.:\n  Arch:   sudo pacman -S dkms gcc make linux-headers\n  Debian: sudo apt install dkms build-essential linux-headers-$(uname -r)\n  Fedora: sudo dnf install dkms gcc make kernel-devel"
    fi
    info "All dependencies satisfied"
}

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------

install_dkms_module() {
    local name="$1" version="$2" src_dir="$3"

    step "DKMS module: ${name}/${version}"

    # Remove old installation if exists
    if dkms status "${name}/${version}" >/dev/null 2>&1; then
        warn "Removing existing ${name}/${version}..."
        dkms remove "${name}/${version}" --all 2>/dev/null || true
    fi

    # Fresh copy to /usr/src
    local dest="${USR_SRC}/${name}-${version}"
    if [ ! -d "$src_dir" ]; then
        error "Source directory not found: ${src_dir}\nAre you running from the repo root?"
    fi
    rm -rf "$dest"
    mkdir -p "$dest"
    info "Copying source to ${dest}..."
    # Copy contents (including dotfiles) but exclude build artifacts
    cp -r "${src_dir}/." "$dest/"
    # Clean any stale build artifacts that may have been copied
    find "$dest" \( -name '*.ko' -o -name '*.o' -o -name '*.mod' -o -name '*.mod.c' \
        -o -name '.*.cmd' -o -name 'Module.symvers' -o -name 'modules.order' \
        -o -name '.tmp_versions' \) -exec rm -rf {} + 2>/dev/null || true
    chmod +x "${dest}/pre_build.sh" 2>/dev/null || true
    chmod +x "${dest}/sync-from-kernel.sh" 2>/dev/null || true

    # DKMS add, build, install
    info "Adding ${name}/${version} to DKMS..."
    dkms add -m "$name" -v "$version"

    info "Building ${name}/${version}..."
    dkms build -m "$name" -v "$version"

    info "Installing ${name}/${version}..."
    dkms install -m "$name" -v "$version"
}

install_config_switch() {
    step "USB config switcher"

    info "Installing ibridge-config-switch.sh → ${SBIN_DIR}/"
    install -Dm755 "${DRM_SRC}/etc/systemd/system/ibridge-config-switch.sh" \
        "${SBIN_DIR}/ibridge-config-switch.sh"

    info "Installing ibridge-config-switch.service → ${SYSTEMD_DIR}/"
    install -Dm644 "${DRM_SRC}/etc/systemd/system/ibridge-config-switch.service" \
        "${SYSTEMD_DIR}/ibridge-config-switch.service"

    info "Enabling service..."
    systemctl daemon-reload
    systemctl enable ibridge-config-switch.service
}

install_udev_rule() {
    step "Udev seat rule"

    info "Installing 99-touchbar-seat.rules → ${UDEV_DIR}/"
    install -Dm644 "${SCRIPT_DIR}/etc/udev/rules.d/99-touchbar-seat.rules" \
        "${UDEV_DIR}/99-touchbar-seat.rules"

    info "Reloading udev rules..."
    udevadm control --reload-rules 2>/dev/null || warn "udevadm reload failed (may need reboot)"
}

do_install() {
    check_root
    check_deps

    echo -e "\n${BLUE}appletbdrm-t1 driver suite — installation${NC}"
    echo    "Modules: appletbdrm/${DRM_VERSION} + kernel-hid-t1/${HID_VERSION}"
    echo    "Target kernel: $(uname -r)"
    echo    ""

    install_dkms_module "$DRM_NAME" "$DRM_VERSION" "$DRM_SRC"
    install_dkms_module "$HID_NAME" "$HID_VERSION" "$HID_SRC"
    install_config_switch
    install_udev_rule

    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  Installation complete!${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    echo "Next step: reboot to activate the Touch Bar."
    echo ""
    show_status
}

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------

do_uninstall() {
    check_root

    step "Removing appletbdrm-t1 driver suite"

    # Stop and disable service
    info "Disabling ibridge-config-switch.service..."
    systemctl stop ibridge-config-switch.service 2>/dev/null || true
    systemctl disable ibridge-config-switch.service 2>/dev/null || true
    rm -f "${SYSTEMD_DIR}/ibridge-config-switch.service"
    systemctl daemon-reload

    # Remove DKMS modules
    for mod in "${DRM_NAME}/${DRM_VERSION}" "${HID_NAME}/${HID_VERSION}"; do
        if dkms status "$mod" >/dev/null 2>&1; then
            info "Removing DKMS module ${mod}..."
            dkms remove "$mod" --all 2>/dev/null || true
        fi
    done

    # Remove source directories
    rm -rf "${USR_SRC}/${DRM_NAME}-${DRM_VERSION}"
    rm -rf "${USR_SRC}/${HID_NAME}-${HID_VERSION}"

    # Remove config switch script
    rm -f "${SBIN_DIR}/ibridge-config-switch.sh"

    # Remove udev rule
    rm -f "${UDEV_DIR}/99-touchbar-seat.rules"
    udevadm control --reload-rules 2>/dev/null || true

    echo ""
    echo -e "${GREEN}Uninstallation complete.${NC}"
    echo "Reboot to fully unload the modules."
}

# ---------------------------------------------------------------------------
# Status
# ---------------------------------------------------------------------------

show_status() {
    echo ""
    echo "========================================="
    echo "  appletbdrm-t1 driver status"
    echo "========================================="
    echo ""

    # appletbdrm module
    if lsmod 2>/dev/null | grep -q appletbdrm; then
        echo -e "appletbdrm module:    ${GREEN}LOADED${NC}"
    else
        echo -e "appletbdrm module:    ${YELLOW}NOT LOADED${NC}"
    fi

    if dkms status "${DRM_NAME}/${DRM_VERSION}" 2>/dev/null | grep -q installed; then
        echo -e "appletbdrm DKMS:       ${GREEN}INSTALLED${NC}"
    else
        echo -e "appletbdrm DKMS:       ${YELLOW}NOT INSTALLED${NC}"
    fi

    # kernel-hid-t1 module
    if lsmod 2>/dev/null | grep -q hid_multitouch; then
        echo -e "hid-multitouch module: ${GREEN}LOADED${NC}"
    else
        echo -e "hid-multitouch module: ${YELLOW}NOT LOADED${NC}"
    fi

    if dkms status "${HID_NAME}/${HID_VERSION}" 2>/dev/null | grep -q installed; then
        echo -e "kernel-hid-t1 DKMS:    ${GREEN}INSTALLED${NC}"
    else
        echo -e "kernel-hid-t1 DKMS:    ${YELLOW}NOT INSTALLED${NC}"
    fi

    # Config switch
    if [ -x "${SBIN_DIR}/ibridge-config-switch.sh" ]; then
        echo -e "config switch script:  ${GREEN}INSTALLED${NC}"
    else
        echo -e "config switch script:  ${YELLOW}NOT INSTALLED${NC}"
    fi

    if systemctl is-enabled ibridge-config-switch.service >/dev/null 2>&1; then
        echo -e "config switch service: ${GREEN}ENABLED${NC}"
    else
        echo -e "config switch service: ${YELLOW}NOT ENABLED${NC}"
    fi

    # Udev rule
    if [ -f "${UDEV_DIR}/99-touchbar-seat.rules" ]; then
        echo -e "udev seat rule:        ${GREEN}INSTALLED${NC}"
    else
        echo -e "udev seat rule:        ${YELLOW}NOT INSTALLED${NC}"
    fi

    # USB config
    local bridge=""
    for dev in /sys/bus/usb/devices/*/idVendor; do
        if [ "$(cat "$dev" 2>/dev/null)" = "05ac" ] && \
           [ "$(cat "$(dirname "$dev")/idProduct" 2>/dev/null)" = "8600" ]; then
            bridge="$(dirname "$dev")"
            break
        fi
    done

    if [ -n "$bridge" ]; then
        local config
        config="$(cat "${bridge}/bConfigurationValue" 2>/dev/null)"
        if [ "$config" = "2" ]; then
            echo -e "USB config:            ${GREEN}2 (Touch Bar mode)${NC}"
        else
            echo -e "USB config:            ${YELLOW}${config} (needs switch)${NC}"
        fi
    else
        echo -e "USB config:            ${YELLOW}iBridge not found${NC}"
    fi

    # DRM device
    if readlink /sys/class/drm/card*/device/driver 2>/dev/null | grep -q appletbdrm; then
        echo -e "DRM device:            ${GREEN}present${NC}"
    else
        echo -e "DRM device:            ${YELLOW}NOT PRESENT${NC}"
    fi

    echo ""
    echo "Kernel: $(uname -r)"
    echo ""
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

usage() {
    echo "appletbdrm-t1 driver suite"
    echo ""
    echo "Usage: $0 [command]"
    echo ""
    echo "Commands:"
    echo "  install     Install everything (default)"
    echo "  uninstall   Remove all components"
    echo "  status      Show installation status"
    echo "  help        Show this help"
    echo ""
}

case "${1:-install}" in
    install)
        do_install
        ;;
    uninstall|remove)
        do_uninstall
        ;;
    status)
        show_status
        ;;
    help|--help|-h)
        usage
        ;;
    *)
        error "Unknown command: $1\nRun '$0 help' for usage"
        ;;
esac