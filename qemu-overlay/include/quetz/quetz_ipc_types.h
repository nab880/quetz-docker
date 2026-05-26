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

typedef struct QuetzSharedData {
    size_t            numCores;
    uint64_t          simTime;
    uint64_t          simCycles;
    volatile uint32_t child_attached;
    uint32_t          _pad0;
    QuetzMmioResponseSlot mmio_slot[QUETZ_MAX_MMIO_VCORES];
    QuetzMmioSyncRequest  mmio_req[QUETZ_MAX_MMIO_VCORES];
} QuetzSharedData;

#ifdef __cplusplus
}
#endif

#endif
