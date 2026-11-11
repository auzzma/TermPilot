/* Test-only macOS bind interposition. Never linked into the shipped engine.
 * Change only IPv4 UDP binds to 5900/5901; preserve all remote endpoints and
 * protocol bytes. Log port numbers only, never credentials or packet data.
 */
#include <arpa/inet.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#ifdef PORT_PROBE_SELFTEST
int main(void) {
    int sockets[2];
    unsigned ports[2];
    for (int i = 0; i < 2; i++) {
        sockets[i] = socket(AF_INET, SOCK_DGRAM, 0);
        struct sockaddr_in address = {0};
        address.sin_len = sizeof(address);
        address.sin_family = AF_INET;
        address.sin_port = htons(5900 + i);
        if (sockets[i] < 0 || bind(sockets[i], (void *)&address, sizeof(address)))
            return 1;
        socklen_t size = sizeof(address);
        if (getsockname(sockets[i], (void *)&address, &size)) return 2;
        ports[i] = ntohs(address.sin_port);
    }
    printf("[%u,%u]\n", ports[0], ports[1]);
    for (int i = 0; i < 2; i++) close(sockets[i]);
    return 0;
}
#else
static int probe_bind(int fd, const struct sockaddr *address, socklen_t size) {
    const char *mode = getenv("TERMPILOT_UDP_PORT_PROBE");
    int kind = 0;
    socklen_t kind_size = sizeof(kind);
    if (!mode || (strcmp(mode, "fixed") && strcmp(mode, "ephemeral")) ||
        size < sizeof(struct sockaddr_in) || address->sa_family != AF_INET ||
        getsockopt(fd, SOL_SOCKET, SO_TYPE, &kind, &kind_size) || kind != SOCK_DGRAM)
        return bind(fd, address, size);
    struct sockaddr_in local = *(const struct sockaddr_in *)address;
    unsigned requested = ntohs(local.sin_port);
    if (requested != 5900 && requested != 5901) return bind(fd, address, size);
    if (!strcmp(mode, "ephemeral")) local.sin_port = 0;
    int status = bind(fd, (void *)&local, sizeof(local));
    int saved_errno = errno;
    socklen_t local_size = sizeof(local);
    unsigned actual = 0;
    if (!status && !getsockname(fd, (void *)&local, &local_size))
        actual = ntohs(local.sin_port);
    dprintf(STDERR_FILENO,
            "UDP_PORT_PROBE {\"mode\":\"%s\",\"requested\":%u,\"actual\":%u,\"status\":%d,\"errno\":%d}\n",
            mode, requested, actual, status, status ? saved_errno : 0);
    errno = saved_errno;
    return status;
}
__attribute__((used)) static const struct {
    const void *replacement;
    const void *original;
} interpose_bind __attribute__((section("__DATA,__interpose"))) = {
    (const void *)probe_bind, (const void *)bind
};
#endif
