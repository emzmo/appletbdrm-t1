#!/bin/bash
# pre_build.sh — DKMS pre-build hook for kernel-hid-t1
#
# Strategy: DKMS modules must ship their own source (kernel header packages
# don't include drivers/hid/*.c). We ship a vendored hid-multitouch.c + headers
# snapshotted from a specific kernel version.
#
# This hook does two things:
#   1. Enforces minimum kernel version (6.11 — needs on_hid_hw_open/close APIs)
#   2. If a full kernel source tree is available, extracts the in-tree
#      hid-multitouch.c + hid-ids.h + hid-haptic.h, applies the T1 touch patch,
#      and uses those (always compatible with the running kernel).
#      Falls back to the vendored copies if no source tree is found.
#
# Environment variables:
#   KERNEL_SRC_DIR  — path to full kernel source tree (overrides auto-detection)
#
set -euo pipefail

# DKMS passes: $1 = module, $2 = version, $3 = arch, $4 = kernelver
MODULE="${1:-kernel-hid-t1}"
VERSION="${2:-0.1}"
ARCH="${3:-x86_64}"
KERNELVER="${4:-$(uname -r)}"

KBUILD_DIR="/lib/modules/${KERNELVER}/build"
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
VENDORED_DIR="$SRC_DIR/src"
PATCH_DIR="$SRC_DIR/patches"
WORK_DIR="$SRC_DIR/_build_src"

# --- 1. Kernel version guard ---
MIN_MAJOR=6
MIN_MINOR=11

KVER_MAJOR=$(echo "$KERNELVER" | sed 's/\([0-9]*\)\.\([0-9]*\).*/\1/')
KVER_MINOR=$(echo "$KERNELVER" | sed 's/\([0-9]*\)\.\([0-9]*\).*/\2/')

if [ "$KVER_MAJOR" -lt "$MIN_MAJOR" ] || \
   { [ "$KVER_MAJOR" -eq "$MIN_MAJOR" ] && [ "$KVER_MINOR" -lt "$MIN_MINOR" ]; }; then
    echo "ERROR: kernel-hid-t1 requires kernel >= ${MIN_MAJOR}.${MIN_MINOR} (got ${KERNELVER})" >&2
    echo "       The on_hid_hw_open/on_hid_hw_close HID driver callbacks are needed." >&2
    exit 1
fi

echo "[kernel-hid-t1] pre_build: kernel ${KERNELVER} (>= ${MIN_MAJOR}.${MIN_MINOR} OK)"

# --- 2. Locate full kernel source tree (if available) ---
find_kernel_src() {
    # Check env override first
    if [ -n "${KERNEL_SRC_DIR:-}" ] && [ -f "$KERNEL_SRC_DIR/drivers/hid/hid-multitouch.c" ]; then
        echo "$KERNEL_SRC_DIR"
        return 0
    fi
    # Check common locations
    for candidate in \
        "/usr/src/linux-${KERNELVER}" \
        "/usr/src/linux" \
        "/usr/src/linux-lts" \
        "/usr/lib/modules/${KERNELVER}/source" \
        "/lib/modules/${KERNELVER}/source"; do
        if [ -f "$candidate/drivers/hid/hid-multitouch.c" ]; then
            echo "$candidate"
            return 0
        fi
    done
    return 1
}

# --- 3. Try to use in-tree source + patch ---
use_intree_source() {
    local ksrc="$1"
    local in_tree_dir="$ksrc/drivers/hid"
    local in_tree_mt="$in_tree_dir/hid-multitouch.c"
    local in_tree_ids="$in_tree_dir/hid-ids.h"
    local in_tree_haptic="$in_tree_dir/hid-haptic.h"

    echo "[kernel-hid-t1] Found full kernel source at: $ksrc"

    # Check if patch already applied (ID already present)
    if grep -q "USB_DEVICE_ID_APPLE_IBRIDGE" "$in_tree_mt" 2>/dev/null; then
        echo "[kernel-hid-t1] T1 patch already present in in-tree source — using as-is"
        rm -rf "$WORK_DIR"
        mkdir -p "$WORK_DIR"
        cp "$in_tree_mt" "$WORK_DIR/"
        [ -f "$in_tree_ids" ] && cp "$in_tree_ids" "$WORK_DIR/"
        [ -f "$in_tree_haptic" ] && cp "$in_tree_haptic" "$WORK_DIR/"
        return 0
    fi

    # Apply patches
    rm -rf "$WORK_DIR"
    mkdir -p "$WORK_DIR/drivers/hid"
    cp "$in_tree_mt" "$WORK_DIR/drivers/hid/"
    [ -f "$in_tree_ids" ] && cp "$in_tree_ids" "$WORK_DIR/drivers/hid/"
    [ -f "$in_tree_haptic" ] && cp "$in_tree_haptic" "$WORK_DIR/drivers/hid/"

    # Apply the T1 id patch (adds USB_DEVICE_ID_APPLE_IBRIDGE to hid-ids.h)
    if [ -f "$WORK_DIR/drivers/hid/hid-ids.h" ] && [ -f "$PATCH_DIR/t1-ids.patch" ]; then
        if patch -p1 -d "$WORK_DIR" --forward < "$PATCH_DIR/t1-ids.patch" 2>/dev/null; then
            echo "[kernel-hid-t1] Applied t1-ids.patch to hid-ids.h"
        else
            echo "[kernel-hid-t1] WARN: t1-ids.patch failed (may already have the ID) — continuing"
        fi
        rm -f "$WORK_DIR/drivers/hid/"*.rej
    fi

    # Apply the T1 touch patch (adds mt_devices[] entry for 0x8600)
    if [ -f "$PATCH_DIR/t1-touch.patch" ]; then
        if patch -p1 -d "$WORK_DIR" --forward < "$PATCH_DIR/t1-touch.patch" 2>/dev/null; then
            echo "[kernel-hid-t1] Applied t1-touch.patch to hid-multitouch.c"
        else
            echo "[kernel-hid-t1] WARN: t1-touch.patch failed — falling back to vendored copy"
            return 1
        fi
        rm -f "$WORK_DIR/drivers/hid/"*.rej
    fi

    # Move files to WORK_DIR root for copying
    mv "$WORK_DIR/drivers/hid/"* "$WORK_DIR/"
    rmdir "$WORK_DIR/drivers/hid" "$WORK_DIR/drivers" 2>/dev/null || true

    return 0
}

# --- 4. Main logic ---
KERNEL_SRC=$(find_kernel_src || true)

if [ -n "$KERNEL_SRC" ]; then
    if use_intree_source "$KERNEL_SRC"; then
        echo "[kernel-hid-t1] Using patched in-tree source (always compatible with ${KERNELVER})"
        # Replace src/ with the patched files for the build
        cp "$WORK_DIR/hid-multitouch.c" "$VENDORED_DIR/"
        [ -f "$WORK_DIR/hid-ids.h" ] && cp "$WORK_DIR/hid-ids.h" "$VENDORED_DIR/"
        [ -f "$WORK_DIR/hid-haptic.h" ] && cp "$WORK_DIR/hid-haptic.h" "$VENDORED_DIR/"
        rm -rf "$WORK_DIR"
        exit 0
    fi
fi

# Fallback: use vendored copies
echo "[kernel-hid-t1] No full kernel source found — using vendored copies"
echo "[kernel-hid-t1] Vendored from 6.18-era kernel; may not compile on ${KERNELVER}"
echo "[kernel-hid-t1] If build fails, install full kernel source and set KERNEL_SRC_DIR env var"
rm -rf "$WORK_DIR"
exit 0