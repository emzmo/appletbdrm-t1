#!/bin/bash
# Apple Touch Bar T1 Driver Suite - Install Script
# Installs: appletbdrm kernel module + ibridge-switcher + systemd service

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DKMS_NAME="appletbdrm"
DKMS_VERSION="1.2"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

info() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

check_root() {
    if [ "$EUID" -ne 0 ]; then
        error "Please run as root (sudo ./install.sh)"
    fi
}

check_deps() {
    info "Checking dependencies..."
    
    local missing=()
    
    command -v dkms >/dev/null 2>&1 || missing+=("dkms")
    command -v gcc >/dev/null 2>&1 || missing+=("gcc")
    pkg-config --exists libusb-1.0 2>/dev/null || missing+=("libusb-1.0-dev")
    
    if [ -n "${missing[*]}" ]; then
        error "Missing dependencies: ${missing[*]}\nInstall with: pacman -S ${missing[*]}"
    fi
    
    info "All dependencies satisfied"
}

build_userspace() {
    info "Building ibridge-switcher..."
    cd "$SCRIPT_DIR"
    
    if [ ! -f "ibridge_switcher.c" ]; then
        error "ibridge_switcher.c not found"
    fi
    
    gcc -o ibridge-switcher ibridge_switcher.c -lusb-1.0 || error "Failed to build ibridge-switcher"
    info "Built ibridge-switcher successfully"
}

install_userspace() {
    info "Installing ibridge-switcher to /usr/local/bin..."
    install -m 755 "$SCRIPT_DIR/ibridge-switcher" /usr/local/bin/
    info "Installed ibridge-switcher"
}

install_dkms() {
    info "Installing kernel module via DKMS..."
    
    # Remove old installation if exists
    if dkms status "$DKMS_NAME/$DKMS_VERSION" >/dev/null 2>&1; then
        warn "Removing existing DKMS module..."
        dkms remove "$DKMS_NAME/$DKMS_VERSION" --all 2>/dev/null || true
    fi
    
    # Remove old source
    rm -rf "/usr/src/${DKMS_NAME}-${DKMS_VERSION}"
    
    # Copy source
    info "Copying source to /usr/src/${DKMS_NAME}-${DKMS_VERSION}..."
    mkdir -p "/usr/src/${DKMS_NAME}-${DKMS_VERSION}"
    cp "$SCRIPT_DIR"/{appletbdrm.c,Makefile,dkms.conf} "/usr/src/${DKMS_NAME}-${DKMS_VERSION}/"
    
    # DKMS add, build, install
    info "Adding to DKMS..."
    dkms add -m "$DKMS_NAME" -v "$DKMS_VERSION"
    
    info "Building module..."
    dkms build -m "$DKMS_NAME" -v "$DKMS_VERSION"
    
    info "Installing module..."
    dkms install -m "$DKMS_NAME" -v "$DKMS_VERSION"
    
    info "Kernel module installed successfully"
}

install_service() {
    info "Installing systemd service..."
    
    # Check if macbook-quirks.service exists (it unbinds/rebinds USB, resetting config)
    if systemctl list-unit-files macbook-quirks.service >/dev/null 2>&1; then
        info "Detected macbook-quirks.service - configuring to run after it"
        cat > /etc/systemd/system/ibridge-switcher.service << 'EOF'
[Unit]
Description=Apple iBridge T1 USB Configuration Switcher
# Run AFTER macbook-quirks which unbinds/rebinds the USB device
After=macbook-quirks.service
Requires=macbook-quirks.service

[Service]
Type=oneshot
# Small delay to ensure device is stable after rebind
ExecStartPre=/bin/sleep 1
# Retry up to 10 times with 1 second delay
ExecStart=/bin/sh -c 'for i in 1 2 3 4 5 6 7 8 9 10; do /usr/local/bin/ibridge-switcher && exit 0; sleep 1; done; exit 1'
RemainAfterExit=yes
TimeoutStartSec=30

[Install]
WantedBy=multi-user.target
EOF
    else
        info "No macbook-quirks.service - configuring for early boot"
        cat > /etc/systemd/system/ibridge-switcher.service << 'EOF'
[Unit]
Description=Apple iBridge T1 USB Configuration Switcher
# Run early, after udev but before most services
DefaultDependencies=no
After=systemd-udevd.service
Before=basic.target
Wants=systemd-udevd.service

[Service]
Type=oneshot
# Retry up to 10 times with 1 second delay
ExecStart=/bin/sh -c 'for i in 1 2 3 4 5 6 7 8 9 10; do /usr/local/bin/ibridge-switcher && exit 0; sleep 1; done; exit 1'
RemainAfterExit=yes
TimeoutStartSec=30

[Install]
WantedBy=sysinit.target
EOF
    fi

    systemctl daemon-reload
    systemctl enable ibridge-switcher.service
    
    info "Systemd service installed and enabled"
}

uninstall() {
    info "Uninstalling Apple Touch Bar T1 driver suite..."
    
    # Stop and disable service
    systemctl stop ibridge-switcher.service 2>/dev/null || true
    systemctl disable ibridge-switcher.service 2>/dev/null || true
    rm -f /etc/systemd/system/ibridge-switcher.service
    systemctl daemon-reload
    
    # Remove DKMS module
    if dkms status "$DKMS_NAME/$DKMS_VERSION" >/dev/null 2>&1; then
        dkms remove "$DKMS_NAME/$DKMS_VERSION" --all 2>/dev/null || true
    fi
    rm -rf "/usr/src/${DKMS_NAME}-${DKMS_VERSION}"
    
    # Remove userspace tool
    rm -f /usr/local/bin/ibridge-switcher
    
    # Clean up any old udev rules we may have created
    rm -f /etc/udev/rules.d/90-ibridge-config.rules
    rm -f /etc/udev/rules.d/90-ibridge-config.rules.disabled
    udevadm control --reload-rules 2>/dev/null || true
    
    info "Uninstallation complete"
}

show_status() {
    echo ""
    echo "========================================="
    echo "  Apple Touch Bar T1 Driver Status"
    echo "========================================="
    echo ""
    
    # Check kernel module
    if lsmod | grep -q appletbdrm; then
        echo -e "Kernel module:  ${GREEN}LOADED${NC}"
    else
        echo -e "Kernel module:  ${YELLOW}NOT LOADED${NC}"
    fi
    
    # Check DKMS
    if dkms status "$DKMS_NAME/$DKMS_VERSION" 2>/dev/null | grep -q installed; then
        echo -e "DKMS:           ${GREEN}INSTALLED${NC}"
    else
        echo -e "DKMS:           ${YELLOW}NOT INSTALLED${NC}"
    fi
    
    # Check userspace tool
    if [ -x /usr/local/bin/ibridge-switcher ]; then
        echo -e "ibridge-switcher: ${GREEN}INSTALLED${NC}"
    else
        echo -e "ibridge-switcher: ${YELLOW}NOT INSTALLED${NC}"
    fi
    
    # Check service
    if systemctl is-enabled ibridge-switcher.service >/dev/null 2>&1; then
        echo -e "Systemd service: ${GREEN}ENABLED${NC}"
    else
        echo -e "Systemd service: ${YELLOW}NOT ENABLED${NC}"
    fi
    
    # Check USB config
    if [ -f /sys/bus/usb/devices/1-3/bConfigurationValue ]; then
        local config=$(cat /sys/bus/usb/devices/1-3/bConfigurationValue)
        if [ "$config" = "2" ]; then
            echo -e "USB Config:     ${GREEN}2 (Touch Bar mode)${NC}"
        else
            echo -e "USB Config:     ${YELLOW}$config (needs switch)${NC}"
        fi
    else
        echo -e "USB Config:     ${YELLOW}Device not found${NC}"
    fi
    
    # Check DRM device
    if [ -e /dev/dri/card1 ]; then
        echo -e "DRM device:     ${GREEN}/dev/dri/card1${NC}"
    else
        echo -e "DRM device:     ${YELLOW}NOT PRESENT${NC}"
    fi
    
    echo ""
}

usage() {
    echo "Apple Touch Bar T1 Driver Suite - Installer"
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

main() {
    case "${1:-install}" in
        install)
            check_root
            check_deps
            build_userspace
            install_userspace
            install_dkms
            install_service
            echo ""
            info "Installation complete!"
            info "Reboot to activate the Touch Bar"
            show_status
            ;;
        uninstall)
            check_root
            uninstall
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
}

main "$@"
