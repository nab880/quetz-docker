/*
 * linux-user synchronous MMIO for Quetz (RV64, non-compressed insns at fault PC).
 */

#include "qemu/osdep.h"
#include "qemu.h"
#include "sst_mmio.h"
#include "include/quetz/quetz_ipc_client.h"

#if !defined(TARGET_RISCV64)
#error "sst_mmio.c is RV64-only"
#endif

#include <sys/mman.h>
#include <string.h>
#include <stdlib.h>

#define MAX_RANGES 8
static struct SstMmioRange ranges[MAX_RANGES];
static int range_count;
static QuetzIpcClient *ipc_client;

void sst_mmio_register_range(const char *spec)
{
    if (range_count >= MAX_RANGES || !spec)
        return;
    struct SstMmioRange *r = &ranges[range_count++];
    memset(r, 0, sizeof(*r));
    r->vcpu_id = 0;
    char *copy = g_strdup(spec);
    char *tok = strtok(copy, ",");
    while (tok) {
        if (strncmp(tok, "shmname=", 8) == 0)
            g_strlcpy(r->shmname, tok + 8, sizeof(r->shmname));
        else if (strncmp(tok, "base=", 5) == 0)
            r->base = strtoull(tok + 5, NULL, 0);
        else if (strncmp(tok, "size=", 5) == 0)
            r->size = strtoull(tok + 5, NULL, 0);
        else if (strncmp(tok, "vcpu_id=", 8) == 0)
            r->vcpu_id = (unsigned)strtoul(tok + 8, NULL, 0);
        tok = strtok(NULL, ",");
    }
    g_free(copy);
    if (!ipc_client && r->shmname[0])
        ipc_client = quetz_ipc_attach(r->shmname);
}

void sst_mmio_apply_mprotect(void)
{
    for (int i = 0; i < range_count; i++) {
        if (ranges[i].size == 0)
            continue;
        mprotect((void *)(uintptr_t)ranges[i].base, (size_t)ranges[i].size, PROT_NONE);
    }
}

static const struct SstMmioRange *find_range(uint64_t addr)
{
    for (int i = 0; i < range_count; i++) {
        if (addr >= ranges[i].base && addr < ranges[i].base + ranges[i].size)
            return &ranges[i];
    }
    return NULL;
}

static int decode_ldst(uint32_t insn, int *is_store, unsigned *size,
                       int *rd, int *rs2)
{
    unsigned opcode = insn & 0x7f;
    unsigned funct3 = (insn >> 12) & 7;
    *rd = (insn >> 7) & 0x1f;
    *rs2 = (insn >> 20) & 0x1f;
    if (opcode == 0x03) {
        *is_store = 0;
        switch (funct3) {
        case 0: *size = 1; return 1; /* LB */
        case 1: *size = 2; return 1; /* LH */
        case 2: *size = 4; return 1; /* LW */
        case 3: *size = 8; return 1; /* LD */
        case 4: *size = 1; return 1; /* LBU */
        case 5: *size = 2; return 1; /* LHU */
        case 6: *size = 4; return 1; /* LWU */
        default: return 0;
        }
    }
    if (opcode == 0x23) {
        *is_store = 1;
        switch (funct3) {
        case 0: *size = 1; return 1;
        case 1: *size = 2; return 1;
        case 2: *size = 4; return 1;
        case 3: *size = 8; return 1;
        default: return 0;
        }
    }
    return 0;
}

int sst_mmio_handle_fault(uint64_t guest_addr, void *cpu_env, uint64_t guest_pc)
{
    const struct SstMmioRange *r = find_range(guest_addr);
    if (!r || !ipc_client)
        return 0;

    CPUArchState *env = cpu_env;
    uint32_t insn = 0;
    int is_store = 0, rd = 0, rs2 = 0;
    unsigned size = 0;

    if (get_user_u32(insn, guest_pc, env) != 0)
        return 0;
    if (!decode_ldst(insn, &is_store, &size, &rd, &rs2))
        return 0;

    if (is_store) {
        uint64_t val = env->gpr[rs2];
        quetz_ipc_mmio_write(ipc_client, r->vcpu_id, guest_addr, size, val);
    } else {
        uint64_t val = quetz_ipc_mmio_read(ipc_client, r->vcpu_id, guest_addr, size);
        env->gpr[rd] = val;
    }
    env->pc = guest_pc + 4;
    return 1;
}
