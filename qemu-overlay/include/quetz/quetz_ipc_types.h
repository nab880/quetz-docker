/* Mirror of sst-elements/quetz/quetz_ipc_types.h for QEMU builds (C-compatible). */
#ifndef QUETZ_IPC_TYPES_H
#define QUETZ_IPC_TYPES_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum QuetzShmemCmd {
    QUETZ_CMD_NOP            = 0,
    QUETZ_CMD_READ           = 1,
    QUETZ_CMD_WRITE          = 2,
    QUETZ_CMD_EXIT           = 3,
    QUETZ_CMD_MMIO_READ_REQ  = 4,
    QUETZ_CMD_MMIO_WRITE_REQ = 5,
};

typedef struct QuetzMmioResponseSlot {
    volatile uint32_t ready;
    uint32_t          _pad;
    uint64_t          value;
} QuetzMmioResponseSlot;

#define QUETZ_MAX_MMIO_VCORES 256

typedef struct QuetzMmioSyncRequest {
    volatile uint32_t pending;
    uint32_t          cmd;
    uint32_t          size;
    uint32_t          _pad;
    uint64_t          addr;
    uint64_t          write_val;
} QuetzMmioSyncRequest;

/* Reverse (SST -> guest) IRQ mailbox: one slot per (vcore, machine IRQ line).
 *
 * Single-writer seqlock, no handshake: SST (the only writer) stores `level`
 * and then release-stores an incremented `seq`; the QEMU bridge polls with an
 * acquire-load of `seq` and re-applies qemu_set_irq(level) whenever seq moved.
 * QEMU never writes the slot, so there is no lost-update window — a consumer
 * that pairs a stale seq with a newer level merely re-applies the same level
 * on its next poll tick. Level semantics (not edges): the device holds the
 * line raised until the guest acks it through the device's MMIO ack register.
 */
#define QUETZ_MAX_IRQ_LINES 64

typedef struct QuetzIrqSlot {
    volatile uint32_t seq;    /* release-store by SST, acquire-load by QEMU */
    uint32_t          level;  /* 1 = raise, 0 = lower */
} QuetzIrqSlot;

typedef struct QuetzSharedData {
    size_t            numCores;
    uint64_t          simTime;
    uint64_t          simCycles;
    volatile uint32_t child_attached;
    uint32_t          _pad0;
    QuetzMmioResponseSlot mmio_slot[QUETZ_MAX_MMIO_VCORES];
    QuetzMmioSyncRequest  mmio_req[QUETZ_MAX_MMIO_VCORES];
    QuetzIrqSlot          irq_slot[QUETZ_MAX_MMIO_VCORES][QUETZ_MAX_IRQ_LINES];
} QuetzSharedData;

#ifdef __cplusplus
}
#endif

#endif
