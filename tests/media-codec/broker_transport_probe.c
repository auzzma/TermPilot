/* macOS validation adapter: engine UDP sockets use loopback IPC to a separate
 * broker. TCP/authentication/media bytes remain unchanged. Not shipped. */
#include <arpa/inet.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

static int is_udp4(int fd, const struct sockaddr *address, socklen_t size) {
    int kind = 0;
    socklen_t n = sizeof(kind);
    return address && size >= sizeof(struct sockaddr_in) && address->sa_family == AF_INET &&
        !getsockopt(fd, SOL_SOCKET, SO_TYPE, &kind, &n) && kind == SOCK_DGRAM;
}
static int probe_bind(int fd, const struct sockaddr *address, socklen_t size) {
    if (!getenv("TERMPILOT_BROKER_REMOTE") || !is_udp4(fd, address, size))
        return bind(fd, address, size);
    struct sockaddr_in local = *(const struct sockaddr_in *)address;
    unsigned port = ntohs(local.sin_port);
    if (port != 5900 && port != 5901) return bind(fd, address, size);
    local.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    local.sin_port = 0;
    return bind(fd, (void *)&local, sizeof(local));
}
static int probe_connect(int fd, const struct sockaddr *address, socklen_t size) {
    const char *host = getenv("TERMPILOT_BROKER_REMOTE");
    if (!host || !is_udp4(fd, address, size)) return connect(fd, address, size);
    struct sockaddr_in remote = *(const struct sockaddr_in *)address;
    struct in_addr expected;
    unsigned port = ntohs(remote.sin_port);
    if (inet_pton(AF_INET, host, &expected) != 1 || remote.sin_addr.s_addr != expected.s_addr ||
        (port != 5900 && port != 5901)) return connect(fd, address, size);
    const char *value = getenv(port == 5900 ? "TERMPILOT_BROKER_AUDIO" : "TERMPILOT_BROKER_VIDEO");
    char *end = NULL;
    long relay = value ? strtol(value, &end, 10) : 0;
    if (!value || !end || *end || relay < 1024 || relay > 65535) { errno = EINVAL; return -1; }
    remote.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    remote.sin_port = htons((unsigned)relay);
    int status = connect(fd, (void *)&remote, sizeof(remote));
    int saved_errno = errno;
    struct sockaddr_in local;
    socklen_t n = sizeof(local);
    unsigned local_port = !getsockname(fd, (void *)&local, &n) ? ntohs(local.sin_port) : 0;
    dprintf(STDERR_FILENO,
        "UDP_BROKER_PROBE {\"remote\":\"%s\",\"remotePort\":%u,\"relayPort\":%ld,\"localPort\":%u,\"status\":%d}\n",
        host, port, relay, local_port, status);
    errno = saved_errno;
    return status;
}
#define INTERPOSE(replacement, original) \
    __attribute__((used)) static const struct { const void *a; const void *b; } \
    entry_##original __attribute__((section("__DATA,__interpose"))) = \
    { (const void *)replacement, (const void *)original }
INTERPOSE(probe_bind, bind);
INTERPOSE(probe_connect, connect);
