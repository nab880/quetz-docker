#!/bin/sh
# Apply Quetz MMIO overlay into an extracted QEMU ${QEMU_VERSION} source tree.
# Fail loud on any error — we cannot silently degrade.
set -eu
QEMU_SRC="${1:-.}"
OVERLAY="$(cd "$(dirname "$0")" && pwd)"

[ -d "$QEMU_SRC/hw/misc" ] || { echo "ERROR: $QEMU_SRC does not look like QEMU"; exit 1; }

cp "$OVERLAY/hw/misc/sst_mmio_bridge.c" "$QEMU_SRC/hw/misc/sst_mmio_bridge.c"
cp "$OVERLAY/quetz_ipc_client.c"        "$QEMU_SRC/hw/misc/quetz_ipc_client.c"

mkdir -p "$QEMU_SRC/include/quetz"
cp "$OVERLAY/include/quetz/quetz_ipc_client.h" "$QEMU_SRC/include/quetz/"
cp "$OVERLAY/include/quetz/quetz_ipc_types.h"  "$QEMU_SRC/include/quetz/"

# Append softmmu source registrations to hw/misc/meson.build.
HW_MESON="$QEMU_SRC/hw/misc/meson.build"
if ! grep -q sst_mmio_bridge.c "$HW_MESON"; then
    cat >> "$HW_MESON" <<'EOF'

# Quetz MMIO bridge (added by sst overlay)
system_ss.add(files('sst_mmio_bridge.c'))
system_ss.add(files('quetz_ipc_client.c'))
EOF
fi

# Mark device user-creatable through default Kconfig (sst-mmio-bridge is built
# unconditionally; no Kconfig symbol needed).

echo "Quetz QEMU overlay applied under $QEMU_SRC"
