#ifndef QUETZ_IPC_CLIENT_H
#define QUETZ_IPC_CLIENT_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct QuetzIpcClient QuetzIpcClient;

QuetzIpcClient *quetz_ipc_attach(const char *shmname);
void quetz_ipc_detach(QuetzIpcClient *client);
uint64_t quetz_ipc_mmio_read(QuetzIpcClient *client, unsigned vcpu,
                             uint64_t addr, unsigned size);
void quetz_ipc_mmio_write(QuetzIpcClient *client, unsigned vcpu,
                          uint64_t addr, unsigned size, uint64_t value);

#ifdef __cplusplus
}
#endif

#endif
