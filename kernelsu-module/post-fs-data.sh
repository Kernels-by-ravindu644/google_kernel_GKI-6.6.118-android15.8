#!/system/bin/sh
# Overlay files come up with a random label; mt76x0u needs vendor_fw_file to read its firmware.
# Done here, before the module is mounted, so the overlay inherits the right label.
MODDIR="${0%/*}"

chcon -R u:object_r:vendor_fw_file:s0 "${MODDIR}/system/vendor/firmware"
