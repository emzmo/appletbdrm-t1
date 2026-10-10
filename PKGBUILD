# Maintainer: emzmo <https://github.com/emzmo>
# PKGBUILD for appletbdrm-t1-dkms
# Apple Touch Bar DRM driver (DKMS) with T1 protocol dialect fixes.
# Supports both T1 (2016-2017, 05ac:8600) and T2 (2018-2020, 05ac:8302) Macs.

pkgname=appletbdrm-t1-dkms
pkgver=1.0.0
pkgrel=1
pkgdesc="Apple Touch Bar DRM driver (DKMS) with T1 iBridge protocol fixes"
arch=('x86_64')
url="https://github.com/emzmo/appletbdrm-t1"
license=('GPL-2.0-only')
depends=('dkms' 'linux-headers')
makedepends=('git')
provides=('appletbdrm-dkms')
conflicts=('appletbdrm-dkms')
source=("git+${url}.git#tag=v1.0.0-phase0-complete")
sha256sums=('SKIP')

package() {
    cd "${srcdir}/appletbdrm-t1"

    # --- DKMS kernel module ---
    # Copy the source tree to /usr/src for DKMS to build against installed kernels.
    # The dkms.conf, Makefile, and appletbdrm.c are all that DKMS needs.
    local dkms_dir="${pkgdir}/usr/src/appletbdrm-${pkgver}"
    install -Dm644 src/appletbdrm/dkms.conf "${dkms_dir}/dkms.conf"
    install -Dm644 src/appletbdrm/Makefile "${dkms_dir}/Makefile"
    install -Dm644 src/appletbdrm/appletbdrm.c "${dkms_dir}/appletbdrm.c"
    install -Dm644 src/appletbdrm/LICENSE "${dkms_dir}/LICENSE"

    # Patch dkms.conf to use the PKGBUILD version instead of the hardcoded 1.2
    sed -i "s/PACKAGE_VERSION=\"1.2\"/PACKAGE_VERSION=\"${pkgver}\"/" "${dkms_dir}/dkms.conf"

    # --- udev rule: Touch Bar seat isolation ---
    # DRM card: GOTO seat_end (no seat, daemon finds by aspect ratio)
    # Digitizer: ID_SEAT=seat1 (D-Bus safe, no hyphen)
    install -Dm644 etc/udev/rules.d/99-touchbar-seat.rules \
        "${pkgdir}/etc/udev/rules.d/99-touchbar-seat.rules"

    # --- ibridge-config-switch: auto-switch USB config 1→2 at boot ---
    install -Dm755 src/appletbdrm/etc/systemd/system/ibridge-config-switch.sh \
        "${pkgdir}/usr/local/sbin/ibridge-config-switch.sh"
    install -Dm644 src/appletbdrm/etc/systemd/system/ibridge-config-switch.service \
        "${pkgdir}/etc/systemd/system/ibridge-config-switch.service"
}