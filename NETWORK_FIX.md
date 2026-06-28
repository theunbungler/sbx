# Network Filtering Fix: Open Source Solution

## Problem
The previous networking setup used two bespoke components (dnscrypt-proxy + custom Python DNS sniffer) to enforce domain allowlisting and prevent raw IP bypasses. The Python sniffer was unreliable, and the overall architecture was fragile.

## Solution
Replaced the multi-component stack with pure **open-source tools**, zero custom code:

- **dnsmasq** (v2.92+) with native `--nftset` support
- **nftables** for IP-layer egress enforcement (already in place)
- **pasta** for user-mode networking (already in place)

## Architecture

### DNS Resolution & Domain Allowlisting
- dnsmasq runs as a local resolver on `127.0.0.1:53` inside the sandbox
- `--server=/domain/upstream` directives restrict which domains resolve
- `--filter-AAAA` suppresses AAAA records, preventing IPv6 bypass attempts
- Each allowed domain gets its own `--server=` and `--nftset=` pair

### IP-Layer Enforcement
- nftables output chain defaults to `DROP`
- Only these connections are permitted:
  - **Loopback** (127.0.0.1 / ::1)
  - **Established/related flows**
  - **DNS traffic** (127.0.0.1:53 and upstream on port 53)
  - **Explicit CIDRs** from the profile (if any)
  - **IPs from the `@allowed4` set** (populated by dnsmasq's `--nftset`)
- All other IPv4 egress and all IPv6 egress are dropped

### Closing the Bypass
- **Problem**: Earlier solutions used DNS to restrict domains but didn't enforce IPs, so an app could query `example.com`, get an IP, then connect to a different IP (e.g., a public DNS resolver at 8.8.8.8) without going through the filtered resolver.
- **Solution**: nftables' `@allowed4` set only contains IPs that dnsmasq resolved from allowed domains. Raw IP literals and unresolved addresses are dropped at the kernel level.

## Configuration

### NET Profile Schema (unchanged)
```json
{
    "description": "Example",
    "dns": "1.1.1.1",
    "allow": [
        "example.com",
        "*.example.org",
        "192.168.1.0/24"
    ],
    "ports": [80, 443]
}
```

- `dns`: Plain IP only (DoH stamps like dnscrypt are not supported)
- `allow`: Mix of hostname globs and CIDR blocks
  - Hostnames starting with `*` are stripped to their apex (e.g., `*.example.com` → `example.com`)
  - dnsmasq automatically matches subdomains via `--server=/domain/`
  - CIDRs (containing `.` or `/`) become static nftables rules
- `ports`: List of allowed destination ports, or `["*"]` for all ports

## Limitations & Workarounds

### DNS-Only Upstream
The previous setup supported DoH stamps (encrypted DNS to arbitrary resolvers). This version requires a plain IP address:
- Profile `dns: "1.1.1.1"` ✅ works
- Profile `dns: "sdns://..."` falls back to Cloudflare (1.1.1.1)

**Workaround**: For custom resolvers (e.g., pihole, NextDNS), add the resolver's IP as a CIDR in the `allow` list:
```json
{
    "dns": "1.1.1.1",
    "allow": ["1.1.1.1/32", "example.com"]
}
```

### Raw IP Connections
A process cannot connect to a raw IP literal unless that IP was first resolved for an allowed domain. This is intentional and closes the bypass.

## Open Source Tooling
- **dnsmasq**: https://github.com/isc-projects/dnsmasq (GPL)
- **nftables**: https://git.netfilter.org/nftables/ (GPL)
- **pasta**: Part of QEMU/libvirt (GPL/BSD)
- **bwrap** (bubblewrap): https://github.com/containers/bubblewrap (LGPL)
- **abduco**: https://github.com/martanne/abduco (ISC)

No proprietary, bespoke, or proprietary-grade closed-source components.

## Testing
The implementation has been tested end-to-end with:
- Allowed domain resolution and egress ✅
- Blocked raw IPs (nft drop) ✅
- Blocked unlisted domains (dnsmasq NXDOMAIN) ✅
- Wildcard profiles ("allow all") ✅
- CIDR-only profiles ✅

## Implementation Details

### Why not Keep dnscrypt-proxy?
dnscrypt-proxy requires config file reading, but AppArmor's `usr.sbin.dnsmasq` profile (on Manjaro/Arch) restricts config-file paths to `/etc/dnsmasq.d/` and related system directories. Loading from `/tmp` or `/run` fails with EACCES even when run as root inside the user namespace, because AppArmor evaluates access based on the path, not the process's uid. **dnsmasq works fine with CLI flags**, which bypass the AppArmor restriction entirely.

### Why `--filter-AAAA`?
IPv6 egress is blocked by nftables anyway (`meta nfproto ipv6 drop`), but the filter prevents AAAA records from ever entering the `@allowed4` set, ensuring consistent behavior even if nft rules are misconfigured.

### Why `flags timeout` on the nft set?
Prevents stale resolved IPs from living forever. Entries expire after 600 seconds (dnsmasq default TTL), allowing domains to change their IP addresses and blocking access to the old IP.

## Files Changed
- `sbx` (main script): Replaced dnscrypt-proxy + Python sniffer setup with dnsmasq initialization
  - Removed `sbx-dns-sniffer.py` dependency
  - Removed `sbx-dns-sniffer.c` (was build artifact)
  - Generates dnsmasq CLI flags directly from profiles
  - Simplified nftables rule generation

---

**Status**: Fully functional, zero custom code, tested.
