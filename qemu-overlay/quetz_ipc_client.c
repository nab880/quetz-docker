/* Standalone Quetz IPC client for patched QEMU (C, no SST dependency). */
#include "quetz/quetz_ipc_client.h"
#include "quetz/quetz_ipc_types.h"

#include <fcntl.h>
#include <linux/futex.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>

struct QuetzInternalSharedData {
    uint32_t expectedChildren;
    size_t   shmSegSize;
    size_t   numBuffers;
    size_t   offsets[1];
};

struct QuetzIpcClient {
    int               fd;
    void             *map;
    size_t            map_size;
    QuetzSharedData  *shared;
};

static int map_shmem(const char *shmname, QuetzIpcClient *c)
{
    c->fd = shm_open(shmname, O_RDWR, 0600);
    if (c->fd < 0)
        return -1;

    void *hdr = mmap(NULL, sizeof(struct QuetzInternalSharedData),
                     PROT_READ, MAP_SHARED, c->fd, 0);
    if (hdr == MAP_FAILED) {
        close(c->fd);
        c->fd = -1;
        return -1;
    }

    size_t map_size = ((struct QuetzInternalSharedData *)hdr)->shmSegSize;
    size_t shared_off = ((struct QuetzInternalSharedData *)hdr)->offsets[0];
    munmap(hdr, sizeof(struct QuetzInternalSharedData));

    if (map_size < sizeof(QuetzSharedData))
        map_size = 4 * 1024 * 1024;

    c->map = mmap(NULL, map_size, PROT_READ | PROT_WRITE, MAP_SHARED, c->fd, 0);
    if (c->map == MAP_FAILED) {
        close(c->fd);
        c->fd = -1;
        return -1;
    }
    c->map_size = map_size;
    c->shared = (QuetzSharedData *)((uint8_t *)c->map + shared_off);
    return 0;
}

QuetzIpcClient *quetz_ipc_attach(const char *shmname)
{
    QuetzIpcClient *c = calloc(1, sizeof(*c));
    if (!c)
        return NULL;
    c->fd = -1;
    if (map_shmem(shmname, c) != 0) {
        free(c);
        return NULL;
    }
    return c;
}

void quetz_ipc_detach(QuetzIpcClient *client)
{
    if (!client)
        return;
    if (client->map)
        munmap(client->map, client->map_size);
    if (client->fd >= 0)
        close(client->fd);
    free(client);
}

static void clear_slot(QuetzSharedData *sd, unsigned vcpu)
{
    sd->mmio_slot[vcpu].ready = 0;
    sd->mmio_slot[vcpu].value = 0;
}

static void wait_slot(QuetzSharedData *sd, unsigned vcpu, uint64_t *out)
{
    /* Block (rather than busy-spin) until SST posts the response, so an offload
     * that stalls the vCPU doesn't burn a host core. FUTEX_WAIT returns at once
     * if ready != 0; the 1ms timeout is a safety re-poll so a missed wake
     * self-heals instead of hanging. The futex word lives in cross-process shmem. */
    uint32_t *ready = (uint32_t *)&sd->mmio_slot[vcpu].ready;
    while (*ready == 0) {
        struct timespec ts = { 0, 1000000 };
        syscall(SYS_futex, ready, FUTEX_WAIT, 0, &ts, NULL, 0);
    }
    *out = sd->mmio_slot[vcpu].value;
    sd->mmio_slot[vcpu].ready = 0;
    __sync_synchronize();
}

uint64_t quetz_ipc_mmio_read(QuetzIpcClient *client, unsigned vcpu,
                             uint64_t addr, unsigned size)
{
    QuetzSharedData *sd = client->shared;
    if (!sd || vcpu >= QUETZ_MAX_MMIO_VCORES)
        return 0;

    clear_slot(sd, vcpu);
    QuetzMmioSyncRequest *req = &sd->mmio_req[vcpu];
    req->addr = addr;
    req->size = size;
    req->write_val = 0;
    req->cmd = QUETZ_CMD_MMIO_READ_REQ;
    __sync_synchronize();
    req->pending = 1;

    uint64_t value = 0;
    wait_slot(sd, vcpu, &value);
    return value;
}

void quetz_ipc_mmio_write(QuetzIpcClient *client, unsigned vcpu,
                          uint64_t addr, unsigned size, uint64_t value)
{
    QuetzSharedData *sd = client->shared;
    if (!sd || vcpu >= QUETZ_MAX_MMIO_VCORES)
        return;

    clear_slot(sd, vcpu);
    QuetzMmioSyncRequest *req = &sd->mmio_req[vcpu];
    req->addr = addr;
    req->size = size;
    req->write_val = value;
    req->cmd = QUETZ_CMD_MMIO_WRITE_REQ;
    __sync_synchronize();
    req->pending = 1;

    uint64_t ack = 0;
    wait_slot(sd, vcpu, &ack);
}
