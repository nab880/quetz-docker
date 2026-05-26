/*
 * sst_mmio_bridge.c — QEMU device: synchronous MMIO via Quetz shmem IPC.
 *
 * Plain TYPE_DEVICE (not SysBusDevice) so it can be instantiated with
 * `-device sst-mmio-bridge,shmname=...,base=...,size=...` on any machine.
 * Realize maps a MemoryRegion at `base` directly into system memory.
 */

#include "qemu/osdep.h"
#include "qemu/log.h"
#include "qemu/module.h"
#include "hw/qdev-core.h"
#include "hw/qdev-properties.h"
#include "exec/address-spaces.h"
#include "exec/memory.h"
#include "qapi/error.h"

#include <errno.h>

#include "quetz/quetz_ipc_client.h"

#define TYPE_SST_MMIO_BRIDGE "sst-mmio-bridge"
OBJECT_DECLARE_SIMPLE_TYPE(SstMmioBridgeState, SST_MMIO_BRIDGE)

struct SstMmioBridgeState {
    DeviceState parent_obj;
    MemoryRegion mmio;
    QuetzIpcClient *ipc;
    char *shmname;
    uint64_t base;
    uint64_t size;
    uint32_t vcpu_id;
    bool mapped;
};

static uint64_t sst_mmio_read(void *opaque, hwaddr offset, unsigned size)
{
    SstMmioBridgeState *s = opaque;
    return quetz_ipc_mmio_read(s->ipc, s->vcpu_id, s->base + offset, size);
}

static void sst_mmio_write(void *opaque, hwaddr offset, uint64_t value,
                           unsigned size)
{
    SstMmioBridgeState *s = opaque;
    quetz_ipc_mmio_write(s->ipc, s->vcpu_id, s->base + offset, size, value);
}

static const MemoryRegionOps sst_mmio_ops = {
    .read = sst_mmio_read,
    .write = sst_mmio_write,
    .endianness = DEVICE_NATIVE_ENDIAN,
    .valid = { .min_access_size = 1, .max_access_size = 8 },
    .impl  = { .min_access_size = 1, .max_access_size = 8 },
};

static void sst_mmio_bridge_realize(DeviceState *dev, Error **errp)
{
    SstMmioBridgeState *s = SST_MMIO_BRIDGE(dev);

    if (!s->shmname || !s->shmname[0]) {
        error_setg(errp, "sst-mmio-bridge: shmname property required");
        return;
    }
    if (s->size == 0) {
        error_setg(errp, "sst-mmio-bridge: size must be > 0");
        return;
    }

    s->ipc = quetz_ipc_attach(s->shmname);
    if (!s->ipc) {
        error_setg(errp,
                   "sst-mmio-bridge: failed to attach shmem '%s' (errno=%d)",
                   s->shmname, errno);
        return;
    }

    memory_region_init_io(&s->mmio, OBJECT(dev), &sst_mmio_ops, s,
                          TYPE_SST_MMIO_BRIDGE, s->size);
    memory_region_add_subregion_overlap(get_system_memory(),
                                        s->base, &s->mmio, 1);
    s->mapped = true;
}

static void sst_mmio_bridge_unrealize(DeviceState *dev)
{
    SstMmioBridgeState *s = SST_MMIO_BRIDGE(dev);
    if (s->mapped) {
        memory_region_del_subregion(get_system_memory(), &s->mmio);
        s->mapped = false;
    }
    if (s->ipc) {
        quetz_ipc_detach(s->ipc);
        s->ipc = NULL;
    }
}

static Property sst_mmio_bridge_properties[] = {
    DEFINE_PROP_STRING("shmname", SstMmioBridgeState, shmname),
    DEFINE_PROP_UINT64("base", SstMmioBridgeState, base, 0),
    DEFINE_PROP_UINT64("size", SstMmioBridgeState, size, 0x400),
    DEFINE_PROP_UINT32("vcpu_id", SstMmioBridgeState, vcpu_id, 0),
    DEFINE_PROP_END_OF_LIST(),
};

static void sst_mmio_bridge_class_init(ObjectClass *klass, void *data)
{
    DeviceClass *dc = DEVICE_CLASS(klass);

    dc->realize = sst_mmio_bridge_realize;
    dc->unrealize = sst_mmio_bridge_unrealize;
    dc->user_creatable = true;
    device_class_set_props(dc, sst_mmio_bridge_properties);
    set_bit(DEVICE_CATEGORY_MISC, dc->categories);
}

static const TypeInfo sst_mmio_bridge_info = {
    .name          = TYPE_SST_MMIO_BRIDGE,
    .parent        = TYPE_DEVICE,
    .instance_size = sizeof(SstMmioBridgeState),
    .class_init    = sst_mmio_bridge_class_init,
};

static void sst_mmio_bridge_register_types(void)
{
    type_register_static(&sst_mmio_bridge_info);
}

type_init(sst_mmio_bridge_register_types)
