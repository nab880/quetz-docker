#ifndef SST_MMIO_H
#define SST_MMIO_H

#include <stdint.h>

struct SstMmioRange {
    char     shmname[256];
    uint64_t base;
    uint64_t size;
    unsigned vcpu_id;
};

void sst_mmio_register_range(const char *spec);
void sst_mmio_apply_mprotect(void);
int  sst_mmio_handle_fault(uint64_t guest_addr, void *cpu_env,
                           uint64_t guest_pc);

#endif
