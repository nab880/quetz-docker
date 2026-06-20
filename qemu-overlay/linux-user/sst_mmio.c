/*
 * linux-user synchronous MMIO for Quetz (P6).
 *
 * In system mode the sst-mmio-bridge device intercepts the doorbell aperture;
 * user mode has no device map, so we reserve the aperture as PROT_NONE and route
 * the resulting SIGSEGV through the same sync mailbox. Ported to QEMU 9.2.1:
 * the fault is handled inside host_sigsegv_handler via cpu_restore_state (to
 * recover the guest PC) + cpu_loop_exit (to resume), not by returning from the
 * host signal handler.
 *
 * Decoder: RV64 (base + RVC compressed). (Big-endian m68k follows.)
 */

#include "qemu/osdep.h"
#include "qemu.h"
#include "exec/cpu_ldst.h"
#include "exec/exec-all.h"
#include "user-mmap.h"
#include "sst_mmio.h"
#include "quetz/quetz_ipc_client.h"

#include <sys/mman.h>

#define MAX_RANGES 8
static struct SstMmioRange ranges[MAX_RANGES];
static int range_count;
static QuetzIpcClient *ipc_client;

void sst_mmio_register_range(const char *spec)
{
    if (range_count >= MAX_RANGES || !spec) {
        return;
    }
    struct SstMmioRange *r = &ranges[range_count++];
    memset(r, 0, sizeof(*r));
    r->vcpu_id = 0;
    char *copy = g_strdup(spec);
    char *save = NULL;
    for (char *tok = strtok_r(copy, ",", &save); tok;
         tok = strtok_r(NULL, ",", &save)) {
        if (strncmp(tok, "shmname=", 8) == 0) {
            g_strlcpy(r->shmname, tok + 8, sizeof(r->shmname));
        } else if (strncmp(tok, "base=", 5) == 0) {
            r->base = strtoull(tok + 5, NULL, 0);
        } else if (strncmp(tok, "size=", 5) == 0) {
            r->size = strtoull(tok + 5, NULL, 0);
        } else if (strncmp(tok, "vcpu_id=", 8) == 0) {
            r->vcpu_id = (unsigned)strtoul(tok + 8, NULL, 0);
        }
    }
    g_free(copy);
    if (!ipc_client && r->shmname[0]) {
        ipc_client = quetz_ipc_attach(r->shmname);
    }
}

/*
 * Reserve each aperture in the guest address space as PROT_NONE so guest
 * loads/stores fault. Must run after guest_base is established (post
 * target_cpu_copy_regs).
 */
void sst_mmio_apply_reservation(void)
{
    for (int i = 0; i < range_count; i++) {
        if (ranges[i].size == 0) {
            continue;
        }
        abi_ulong base = (abi_ulong)ranges[i].base;
        abi_ulong size = (abi_ulong)ranges[i].size;
        abi_long rv = target_mmap(base, size, PROT_NONE,
                                  MAP_ANONYMOUS | MAP_PRIVATE | MAP_FIXED,
                                  -1, 0);
        if (rv == -1) {
            fprintf(stderr,
                    "quetz: failed to reserve MMIO aperture 0x%" PRIx64
                    "+0x%" PRIx64 "\n", ranges[i].base, ranges[i].size);
        }
    }
}

static const struct SstMmioRange *find_range(uint64_t addr)
{
    for (int i = 0; i < range_count; i++) {
        if (addr >= ranges[i].base &&
            addr < ranges[i].base + ranges[i].size) {
            return &ranges[i];
        }
    }
    return NULL;
}

#if defined(TARGET_RISCV64)
/*
 * Decode an RV load/store at the fault PC; returns the instruction length
 * (2 for compressed, 4 for base) or 0 if it is not a recognized load/store.
 * Only the data register + size + direction matter — the faulting address is
 * already known from the SIGSEGV.
 */
static int decode_ldst(uint32_t insn, int *is_store, unsigned *size,
                       int *rd, int *rs2, int *is_signed)
{
    *is_signed = 0;
    /* Compressed (RVC), quadrant 0: C.LW/C.LD/C.SW/C.SD (pointer-register
     * form — what the compiler emits for `*(volatile T *)mmio`). The 3-bit
     * register field maps to x8..x15. */
    if ((insn & 0x3) != 0x3) {
        unsigned cq = insn & 0x3;
        unsigned cfunct3 = (insn >> 13) & 0x7;
        unsigned creg = 8 + ((insn >> 2) & 0x7);
        if (cq != 0) {
            return 0; /* q1 = arithmetic, q2 = sp-relative (not aperture) */
        }
        switch (cfunct3) {
        case 2: *is_store = 0; *size = 4; *rd = creg; *is_signed = 1; return 2; /* C.LW */
        case 3: *is_store = 0; *size = 8; *rd  = creg; return 2; /* C.LD */
        case 6: *is_store = 1; *size = 4; *rs2 = creg; return 2; /* C.SW */
        case 7: *is_store = 1; *size = 8; *rs2 = creg; return 2; /* C.SD */
        default: return 0; /* C.FLD/C.FSD etc */
        }
    }

    unsigned opcode = insn & 0x7f;
    unsigned funct3 = (insn >> 12) & 7;
    *rd = (insn >> 7) & 0x1f;
    *rs2 = (insn >> 20) & 0x1f;
    if (opcode == 0x03) { /* LOAD */
        *is_store = 0;
        switch (funct3) {
        case 0: *size = 1; *is_signed = 1; return 4; /* LB  */
        case 1: *size = 2; *is_signed = 1; return 4; /* LH  */
        case 2: *size = 4; *is_signed = 1; return 4; /* LW  */
        case 3: *size = 8; return 4; /* LD  */
        case 4: *size = 1; return 4; /* LBU */
        case 5: *size = 2; return 4; /* LHU */
        case 6: *size = 4; return 4; /* LWU */
        default: return 0;
        }
    }
    if (opcode == 0x23) { /* STORE */
        *is_store = 1;
        switch (funct3) {
        case 0: *size = 1; return 4; /* SB */
        case 1: *size = 2; return 4; /* SH */
        case 2: *size = 4; return 4; /* SW */
        case 3: *size = 8; return 4; /* SD */
        default: return 0;
        }
    }
    return 0;
}

#endif

/*
 * Unblock SIGSEGV/SIGBUS (the kernel blocked them on handler entry) and resume
 * the guest. We leave via cpu_loop_exit (siglongjmp), which skips the kernel's
 * sigreturn that would otherwise restore the mask — without this the next
 * aperture fault wedges the process. Does not return.
 */
static G_NORETURN void sst_mmio_resume(CPUState *cpu)
{
    sigset_t set;
    sigemptyset(&set);
    sigaddset(&set, SIGSEGV);
    sigaddset(&set, SIGBUS);
    sigprocmask(SIG_UNBLOCK, &set, NULL);
    cpu_loop_exit(cpu);
}

/*
 * Called from host_sigsegv_handler. If guest_addr is in an aperture, recover the
 * faulting guest instruction, service it through the mailbox, advance the guest
 * PC and resume via cpu_loop_exit (does not return). Otherwise returns so the
 * normal SEGV path runs.
 */
void sst_mmio_handle_fault(CPUState *cpu, abi_ptr guest_addr, uintptr_t host_pc)
{
    const struct SstMmioRange *r = find_range(guest_addr);
    if (!r || !ipc_client) {
        return;
    }

    /* Recover guest CPU state (env->pc) at the faulting instruction. */
    cpu_restore_state(cpu, host_pc);

#if defined(TARGET_RISCV64)
    CPURISCVState *env = cpu_env(cpu);
    target_ulong guest_pc = env->pc;

    uint32_t insn = 0;
    if (get_user_u32(insn, guest_pc) != 0) {
        return;
    }
    int is_store = 0, rd = 0, rs2 = 0, len, is_signed = 0;
    unsigned size = 0;
    len = decode_ldst(insn, &is_store, &size, &rd, &rs2, &is_signed);
    if (!len) {
        return;
    }

    if (is_store) {
        uint64_t val = env->gpr[rs2];
        quetz_ipc_mmio_write(ipc_client, r->vcpu_id, guest_addr, size, val);
    } else {
        uint64_t val = quetz_ipc_mmio_read(ipc_client, r->vcpu_id,
                                           guest_addr, size);
        if (size < 8) {
            /* The device returns the low `size` bytes; widen to the 64-bit GPR
             * per the load's signedness (sign-extend LB/LH/LW/C.LW, else zero). */
            unsigned shift = 64 - size * 8;
            val = is_signed ? (uint64_t)(((int64_t)(val << shift)) >> shift)
                            : (val & ((1ull << (size * 8)) - 1));
        }
        if (rd != 0) {
            env->gpr[rd] = val;
        }
    }
    env->pc = guest_pc + len;
    sst_mmio_resume(cpu); /* does not return */

#else
    (void)host_pc;
#endif
}
