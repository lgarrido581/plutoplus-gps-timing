# Using the Pluto as an NTP server

Once flashed and **GPS-locked** (`chronyc tracking` → `Leap status: Normal`), the Pluto serves NTP
to clients in the `allow` ranges in `/etc/chrony.conf` (private IPv4 + IPv6 link-local `fe80::/10`).
It will **not** serve before it's locked (won't hand out bad time).

**On the Pluto — confirm it's serving / see clients:**
```sh
chronyc tracking            # Leap status: Normal = serving GPS time
chronyc clients             # hosts that have queried it
netstat -anu | grep ':123'  # confirms it's listening on UDP 123
chronyc allow all           # runtime-only test widen (resets on reboot)
```

**Query it from a client:**
```sh
# Windows:
w32tm /stripchart /computer:pluto.local  /samples:3   # over IPv6 (eth0)
w32tm /stripchart /computer:192.168.2.1  /samples:3   # over USB IPv4
# Linux/macOS:
sntp pluto.local            # or: ntpdate -q 192.168.2.1
```

**Make a client actually sync to it:**
```bat
:: Windows (elevated cmd) — ,0x8 forces client mode
w32tm /config /manualpeerlist:"pluto.local,0x8" /syncfromflags:manual /update
net stop w32time && net start w32time
w32tm /resync
w32tm /query /status        :: Source should show pluto.local
```
```sh
# Linux chrony client: add to /etc/chrony.conf, then restart chrony
server pluto.local iburst
```

**Networking notes**
- The `allow` list covers private IPv4 + IPv6 link-local. Queries that resolve to the Pluto's
  `fe80::` address (common via `pluto.local`) are allowed by `fe80::/10`. (An IPv4-only allow list
  silently drops IPv6 queries — that was the v1.1→v1.2 fix.)
- For **LAN-wide** serving, give `eth0` a routable IPv4 (DHCP from your router or a static IP). Out
  of the box `eth0` only has an IPv6 link-local + a `169.254` APIPA address, so it isn't reachable
  by a normal LAN IPv4 until configured.
