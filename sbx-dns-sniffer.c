/*
 * sbx-dns-sniffer — DNS forwarder that populates an nftables allow-set.
 *
 * Compile:  cc -std=c99 -O2 -s -o sbx-dns-sniffer sbx-dns-sniffer.c
 *
 * What it does:
 *   - Listen on LISTEN_ADDR:53 (UDP + TCP)
 *   - Forward every query to UPSTREAM_ADDR:5300 (dnscrypt-proxy)
 *   - Parse A records from the reply
 *   - Add those IPs to an nftables set (inet sbx_filter allowed4)
 *   - Return the reply unchanged
 *
 * Why C instead of Python:
 *   - 50 KB static binary vs. 10 MB Python interpreter
 *   - Zero runtime dependencies (no Python, no modules)
 *   - No setgroups() / privilege dropping — runs fine in pasta's userns
 *   - Fast: single-process, event-driven, no thread-per-query overhead
 */

#define _GNU_SOURCE
#include <arpa/inet.h>
#include <ctype.h>
#include <errno.h>
#include <netinet/in.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define LISTEN_ADDR   "[IP_ADDRESS]"
#define LISTEN_PORT   53
#define UPSTREAM_ADDR "[IP_ADDRESS]"
#define UPSTREAM_PORT 5300
#define NFT_FAMILY   "inet"
#define NFT_TABLE    "sbx_filter"
#define NFT_SET      "allowed4"
#define BUFSIZE      4096
#define MAX_IPS      64          /* max A records per reply */
#define SEEN_BUCKETS 256         /* hash table for IP dedup */

/* ---- IP set (deduplication) -------------------------------------------- */

typedef struct seen_node {
    uint32_t           ip;
    struct seen_node  *next;
} seen_node_t;

static seen_node_t *seen[SEEN_BUCKETS];

static int seen_add(uint32_t ip) {
    unsigned h = ip % SEEN_BUCKETS;
    for (seen_node_t *n = seen[h]; n; n = n->next)
        if (n->ip == ip) return 0;          /* already seen */
    seen_node_t *n = calloc(1, sizeof(*n));
    if (!n) return 0;
    n->ip = ip;
    n->next = seen[h];
    seen[h] = n;
    return 1;
}

/* ---- nft add element --------------------------------------------------- */

static int nft_add(uint32_t *ips, int count) {
    if (count == 0) return 0;

    char cmd[4096], *p = cmd;
    int  w = snprintf(p, sizeof(cmd),
                      "nft add element %s %s %s { ",
                      NFT_FAMILY, NFT_TABLE, NFT_SET);
    if (w < 0 || (size_t)w >= sizeof(cmd)) return -1;
    p += w;

    for (int i = 0; i < count; i++) {
        struct in_addr a = { .s_addr = ips[i] };
        w = snprintf(p, sizeof(cmd) - (size_t)(p - cmd),
                     "%s%s", i ? ", " : "", inet_ntoa(a));
        if (w < 0 || (size_t)w >= sizeof(cmd) - (size_t)(p - cmd)) return -1;
        p += w;
    }

    w = snprintf(p, sizeof(cmd) - (size_t)(p - cmd), " }");
    if (w < 0 || (size_t)w >= sizeof(cmd) - (size_t)(p - cmd)) return -1;

    pid_t pid = fork();
    if (pid < 0) return -1;
    if (pid == 0) {
        /* child: close inherited fds, exec nft */
        for (int fd = 3; fd < 256; fd++) close(fd);
        execlp("nft", "nft", "add", "element",
               NFT_FAMILY, NFT_TABLE, NFT_SET, cmd + 4, NULL);
        _exit(1);
    }
    int status;
    waitpid(pid, &status, 0);
    return WIFEXITED(status) && WEXITSTATUS(status) == 0 ? 0 : -1;
}

/* ---- DNS packet parsing ------------------------------------------------ */

/* Skip a DNS name (including compression pointers). Returns offset past name
 * or -1 on error. */
static int skip_name(const uint8_t *msg, int msglen, int off) {
    while (off < msglen) {
        uint8_t len = msg[off];
        if (len == 0) return off + 1;
        if (len & 0xC0) {        /* compression pointer */
            if (off + 1 >= msglen) return -1;
            return off + 2;
        }
        off += 1 + len;
        if (off > msglen) return -1;
    }
    return -1;
}

/* Extract IPv4 A records from the answer section. Returns number of IPs
 * written to `out` (up to `max`). */
static int extract_ips(const uint8_t *msg, int msglen,
                       uint32_t *out, int max) {
    if (msglen < 12) return 0;
    uint16_t qdcount = (msg[4]  << 8) | msg[5];
    uint16_t ancount = (msg[6]  << 8) | msg[7];
    int      off     = 12;
    int      n       = 0;

    /* skip question section */
    for (int i = 0; i < qdcount; i++) {
        off = skip_name(msg, msglen, off);
        if (off < 0 || off + 4 > msglen) return n;
        off += 4;  /* QTYPE + QCLASS */
    }

    /* parse answer section */
    for (int i = 0; i < ancount && n < max; i++) {
        off = skip_name(msg, msglen, off);
        if (off < 0 || off + 10 > msglen) return n;
        uint16_t rtype  = (msg[off]     << 8) | msg[off + 1];
        uint16_t rclass = (msg[off + 2] << 8) | msg[off + 3];
        uint16_t rdlen  = (msg[off + 8] << 8) | msg[off + 9];
        off += 10;
        if (off + rdlen > msglen) return n;
        if (rtype == 1 && rclass == 1 && rdlen == 4) {   /* A / IN */
            uint32_t ip;
            memcpy(&ip, msg + off, 4);
            if (ip != 0x0100007f && seen_add(ip))      /* skip [IP_ADDRESS] */
                out[n++] = ip;
        }
        off += rdlen;
    }
    return n;
}

/* ---- UDP forwarding ---------------------------------------------------- */

static int recv_exact(int fd, void *buf, size_t n, int flags) {
    ssize_t r;
    size_t  got = 0;
    while (got < n) {
        r = recv(fd, (char *)buf + got, n - got, flags);
        if (r <= 0) return -1;
        got += (size_t)r;
    }
    return 0;
}

/* Forward a TCP DNS query (length-prefixed) and return the reply. */
static int forward_tcp(int client_fd, struct sockaddr_in *upstream) {
    uint8_t lenbuf[2], query[BUFSIZE], reply[BUFSIZE];
    int     s;

    if (recv_exact(client_fd, lenbuf, 2, 0) < 0) return -1;
    uint16_t qlen = (lenbuf[0] << 8) | lenbuf[1];
    if (qlen > BUFSIZE || recv_exact(client_fd, query, qlen, 0) < 0) return -1;

    s = socket(AF_INET, SOCK_STREAM, 0);
    if (s < 0) return -1;
    struct timeval tv = { .tv_sec = 5 };
    setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    if (connect(s, (struct sockaddr *)upstream, sizeof(*upstream)) < 0) {
        close(s); return -1;
    }
    lenbuf[0] = (uint8_t)(qlen >> 8);
    lenbuf[1] = (uint8_t)(qlen);
    if (send(s, lenbuf, 2, 0) != 2 || send(s, query, qlen, 0) != (ssize_t)qlen) {
        close(s); return -1;
    }
    if (recv_exact(s, lenbuf, 2, 0) < 0) { close(s); return -1; }
    uint16_t rlen = (lenbuf[0] << 8) | lenbuf[1];
    if (rlen > BUFSIZE || recv_exact(s, reply, rlen, 0) < 0) { close(s); return -1; }
    close(s);

    uint32_t ips[MAX_IPS];
    int      n = extract_ips(reply, rlen, ips, MAX_IPS);
    if (n > 0) nft_add(ips, n);

    lenbuf[0] = (uint8_t)(rlen >> 8);
    lenbuf[1] = (uint8_t)(rlen);
    if (send(client_fd, lenbuf, 2, 0) != 2 ||
        send(client_fd, reply, rlen, 0) != (ssize_t)rlen) return -1;
    return 0;
}

/* ---- main -------------------------------------------------------------- */

static volatile sig_atomic_t running = 1;

static void sighandler(int sig) { (void)sig; running = 0; }

int main(void) {
    struct sockaddr_in listen_addr = {0}, upstream_addr = {0};
    int                udp_fd, tcp_fd;

    listen_addr.sin_family      = AF_INET;
    listen_addr.sin_port        = htons(LISTEN_PORT);
    listen_addr.sin_addr.s_addr = inet_addr(LISTEN_ADDR);

    upstream_addr.sin_family      = AF_INET;
    upstream_addr.sin_port        = htons(UPSTREAM_PORT);
    upstream_addr.sin_addr.s_addr = inet_addr(UPSTREAM_ADDR);

    /* UDP socket */
    udp_fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (udp_fd < 0) { perror("udp socket"); return 1; }
    { int one = 1; setsockopt(udp_fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one)); }
    if (bind(udp_fd, (struct sockaddr *)&listen_addr, sizeof(listen_addr)) < 0) {
        perror("udp bind"); return 1;
    }

    /* TCP socket */
    tcp_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (tcp_fd < 0) { perror("tcp socket"); return 1; }
    { int one = 1; setsockopt(tcp_fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one)); }
    if (bind(tcp_fd, (struct sockaddr *)&listen_addr, sizeof(listen_addr)) < 0) {
        perror("tcp bind"); return 1;
    }
    if (listen(tcp_fd, 64) < 0) { perror("tcp listen"); return 1; }

    signal(SIGTERM, sighandler);
    signal(SIGINT,  sighandler);

    /* Announce readiness (parent process reads this) */
    printf("sbx-dns-sniffer listening on %s:%d -> %s:%d\n",
           LISTEN_ADDR, LISTEN_PORT, UPSTREAM_ADDR, UPSTREAM_PORT);
    fflush(stdout);

    /* Fork a child to handle TCP accepts (non-blocking, single-threaded) */
    pid_t tcp_pid = fork();
    if (tcp_pid < 0) { perror("fork"); return 1; }
    if (tcp_pid == 0) {
        /* TCP child */
        while (running) {
            struct sockaddr_in client_addr;
            socklen_t clen = sizeof(client_addr);
            int cfd = accept(tcp_fd, (struct sockaddr *)&client_addr, &clen);
            if (cfd < 0) {
                if (errno == EINTR) continue;
                break;
            }
            pid_t p = fork();
            if (p < 0) { close(cfd); continue; }
            if (p == 0) {
                /* grandchild: handle one TCP connection */
                forward_tcp(cfd, &upstream_addr);
                close(cfd);
                _exit(0);
            }
            close(cfd);
            /* reap zombies without blocking */
            while (waitpid(-1, NULL, WNOHANG) > 0);
        }
        _exit(0);
    }

    /* UDP loop (parent) */
    uint8_t buf[BUFSIZE];
    while (running) {
        struct sockaddr_in client_addr;
        socklen_t          clen = sizeof(client_addr);
        ssize_t n = recvfrom(udp_fd, buf, BUFSIZE, 0,
                             (struct sockaddr *)&client_addr, &clen);
        if (n < 0) {
            if (errno == EINTR) continue;
            break;
        }

        /* forward to dnscrypt */
        int s = socket(AF_INET, SOCK_DGRAM, 0);
        if (s < 0) continue;
        struct timeval tv = { .tv_sec = 5 };
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
        sendto(s, buf, n, 0, (struct sockaddr *)&upstream_addr, sizeof(upstream_addr));

        uint8_t reply[BUFSIZE];
        ssize_t rn = recvfrom(s, reply, BUFSIZE, 0, NULL, NULL);
        close(s);

        if (rn > 0) {
            uint32_t ips[MAX_IPS];
            int      nip = extract_ips(reply, (int)rn, ips, MAX_IPS);
            if (nip > 0) nft_add(ips, nip);
            sendto(udp_fd, reply, rn, 0,
                   (struct sockaddr *)&client_addr, clen);
        }
    }

    kill(tcp_pid, SIGTERM);
    waitpid(tcp_pid, NULL, 0);
    return 0;
}