#include "LocalSafety.h"
#include <sandbox.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <unistd.h>
#include <errno.h>
#include <stdio.h>
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
int trump_deny_internet(void) {
    char *error = NULL;
    int result = sandbox_init(kSBXProfileNoInternet, SANDBOX_NAMED, &error);
    if (error) { fprintf(stderr, "Network restriction setup: %s\n", error); sandbox_free_error(error); }
    return result;
}
#pragma clang diagnostic pop
/* Only loopback addresses; no external host, DNS, packets or URL requests.
 * The named OS profile permits socket creation but denies IP connect/bind.
 */
int trump_network_is_denied(void) {
    int families[] = {AF_INET, AF_INET6};
    int kinds[] = {SOCK_STREAM, SOCK_DGRAM};
    for (unsigned f=0; f<2; f++) for (unsigned k=0; k<2; k++) {
        int fd = socket(families[f], kinds[k], 0);
        if (fd < 0) { if (errno == EPERM || errno == EACCES) continue; return 0; }
        struct sockaddr_in address4 = {0};
        address4.sin_len = sizeof(address4); address4.sin_family = AF_INET;
        address4.sin_addr.s_addr = htonl(INADDR_LOOPBACK); address4.sin_port = htons(9);
        struct sockaddr_in6 address6 = {0};
        address6.sin6_len = sizeof(address6); address6.sin6_family = AF_INET6;
        address6.sin6_addr = in6addr_loopback; address6.sin6_port = htons(9);
        struct sockaddr *address = f == 0 ? (struct sockaddr *)&address4 : (struct sockaddr *)&address6;
        socklen_t size = f == 0 ? sizeof(address4) : sizeof(address6);
        int result = connect(fd, address, size);
        int reason = errno;
        close(fd);
        if (result != -1 || (reason != EPERM && reason != EACCES)) return 0;
    }
    return 1;
}
