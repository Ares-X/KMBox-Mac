#include <sys/socket.h>
#include <stdint.h>
#include <stdlib.h>

// Test-only: invalidate the CLI's send side before its first loopback datagram.
// Call the real send so Darwin decides whether to return EPIPE or raise SIGPIPE.
static ssize_t broken_send(int fd, const void *buffer, size_t length, int flags) {
    if (shutdown(fd, SHUT_WR) != 0) abort();
    return send(fd, buffer, length, flags);
}

// dyld does not interpose references originating in the replacement image itself.
__attribute__((used)) static struct {
    const void *replacement;
    const void *replacee;
} interpose_send __attribute__((section("__DATA,__interpose"))) = {
    (const void *)(uintptr_t)&broken_send,
    (const void *)(uintptr_t)&send
};
