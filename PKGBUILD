# Maintainer: emzmo <https://github.com/emzmo>
# PKGBUILD for appletbdrm-t1-dkms
# Apple Touch Bar driver suite for T1 (2016-2017) MacBooks.
# Installs TWO DKMS modules + USB config switcher + udev seat rule.
#
# Modules:
#   appletbdrm     (v1.2) — DRM display driver for the OLED panel
#   kernel-hid-t1  (v0.2) — Patched hid-multitouch for touch input
#
# Both modules are always needed together: without appletbdrm the bar
# is dark, without kernel-hid-t1 the bar renders but doesn't respond
# to touch.

pkgname=appletbdrm-t1-dkms
pkgver=1.1.0
pkgrel=1
pkgdesc="Apple Touch Bar DKMS driver suite (display + touch) with T1 iBridge protocol fixes"
arch=('x86_64')
url="https://github.com/emzmo/appletbdrm-t1"
license=('GPL-2.0-only')
depends=('dkms')
makedepends=('git')
optdepends=('linux-headers: build against the standard Arch kernel'
            'linux-lts-headers: build against the LTS kernel'
            'linux-zen-headers: build against the zen kernel'
            'linux-omarchy-headers: build against the Omarchy kernel')
provides=('appletbdrm-dkms')
conflicts=('appletbdrm-dkms')
install=appletbdrm-t1-dkms.install
source=("git+${url}.git#tag=v${pkgver}")
sha256sums=('SKIP')

package() {
    cd "${srcdir}/appletbdrm-t1"

    ########################################################
    # DKMS module 1: appletbdrm (DRM display driver, v1.2)
    ########################################################
    local drm_dir="${pkgdir}/usr/src/appletbdrm-1.2"
    install -Dm644 src/appletbdrm/appletbdrm.c "${drm_dir}/appletbdrm.c"
    install -Dm644 src/appletbdrm/Makefile     "${drm_dir}/Makefile"
    install -Dm644 src/appletbdrm/dkms.conf    "${drm_dir}/dkms.conf"
    install -Dm644 src/appletbdrm/LICENSE      "${drm_dir}/LICENSE"

    ########################################################
    # DKMS module 2: kernel-hid-t1 (touch input patch, v0.2)
    ########################################################
    local hid_dir="${pkgdir}/usr/src/kernel-hid-t1-0.2"
    install -Dm644 src/kernel-hid-t1/dkms.conf    "${hid_dir}/dkms.conf"
    install -Dm644 src/kernel-hid-t1/Makefile     "${hid_dir}/Makefile"
    install -Dm755 src/kernel-hid-t1/pre_build.sh "${hid_dir}/pre_build.sh"
    install -Dm755 src/kernel-hid-t1/sync-from-kernel.sh "${hid_dir}/sync-from-kernel.sh"
    install -Dm644 src/kernel-hid-t1/README.md    "${hid_dir}/README.md"

    # Vendored kernel source (hid-multitouch + private headers)
    install -Dm644 src/kernel-hid-t1/src/Makefile        "${hid_dir}/src/Makefile"
    install -Dm644 src/kernel-hid-t1/src/hid-multitouch.c "${hid_dir}/src/hid-multitouch.c"
    install -Dm644 src/kernel-hid-t1/src/hid-ids.h       "${hid_dir}/src/hid-ids.h"
    install -Dm644 src/kernel-hid-t1/src/hid-haptic.h     "${hid_dir}/src/hid-haptic.h"

    # T1 patches (applied by pre_build.sh when in-tree source is available)
    install -Dm644 src/kernel-hid-t1/patches/t1-ids.patch   "${hid_dir}/patches/t1-ids.patch"
    install -Dm644 src/kernel-hid-t1/patches/t1-touch.patch  "${hid_dir}/patches/t1-touch.patch"

    ########################################################
    # USB config switcher: flips iBridge from config 1 → 2 at boot
    ########################################################
    install -Dm755 src/appletbdrm/etc/systemd/system/ibridge-config-switch.sh \
        "${pkgdir}/usr/local/sbin/ibridge-config-switch.sh"
    install -Dm644 src/appletbdrm/etc/systemd/system/ibridge-config-switch.service \
        "${pkgdir}/etc/systemd/system/ibridge-config-switch.service"

    ########################################################
    # Udev rule: seat isolation (digitizer → seat1, DRM → no seat)
    ########################################################
    install -Dm644 etc/udev/rules.d/99-touchbar-seat.rules \
        "${pkgdir}/etc/udev/rules.d/99-touchbar-seat.rules"
}