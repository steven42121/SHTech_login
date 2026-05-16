# ShanghaiTech Campus Network Terminal Auth
# 如果帮助到你了记得给给star！之后会一直维护
This project provides a small POSIX `sh` script for ShanghaiTech campus-network login on headless machines such as Linux servers and ESXi hosts.

It is not based only on an old GitHub implementation. I re-validated the live portal on `2026-04-27` from your machine:

- Portal host reachable: `https://10.15.145.16:19008`
- Live login endpoint: `POST /portalauth/login`
- Current minimal accepted fields: `userName`, `userPass`, `authType=1`, `uaddress`, `agreed=1`

That means the script does not depend on the old front-end fields unless you explicitly want to add them back.

## Files

- [shanghaitech-net-auth.sh](./shanghaitech-net-auth.sh)
- [shanghaitech-net-auth.conf.example](./shanghaitech-net-auth.conf.example)

## Requirements

For HTTPS POST login, at least one of:

- `curl`
- Python 3

And a few standard tools that are commonly present on Linux / BusyBox / ESXi:

- `sed`
- `od`

For automatic IP detection, one of these helps:

- `ip`
- `ifconfig`
- `esxcli` (ESXi)

`wget` is only used for simple GET connectivity checks when `curl` is unavailable. BusyBox `wget` on ESXi usually cannot send the login POST by itself, so the script falls back to Python 3 there.

## Quick Start

```sh
cp shanghaitech-net-auth.conf.example shanghaitech-net-auth.conf
chmod 600 shanghaitech-net-auth.conf
vi shanghaitech-net-auth.conf
chmod +x shanghaitech-net-auth.sh
./shanghaitech-net-auth.sh login
```

If you do not want to store the password in a file:

```sh
./shanghaitech-net-auth.sh login -u 2025XXXXXXX -I eth0
```

The script will prompt for the password.

You can also pass the username as the first positional argument:

```sh
./shanghaitech-net-auth.sh login 2025XXXXXXX -I vmk0
```

## Common Usage

Login once:

```sh
./shanghaitech-net-auth.sh login -u 2025XXXXXXX -I eth0
```

Check status:

```sh
./shanghaitech-net-auth.sh status -c ./shanghaitech-net-auth.conf
```

Keep retrying every 30 seconds:

```sh
./shanghaitech-net-auth.sh watch -c ./shanghaitech-net-auth.conf --interval 30
```

Probe the current portal backend only:

```sh
./shanghaitech-net-auth.sh probe
```

Diagnose routing and portal reachability without entering credentials:

```sh
./shanghaitech-net-auth.sh doctor -I vmk0
```

On Linux, `doctor` and `login` can also open the portal TCP port in the local firewall if `firewalld`, `ufw`, or `iptables` is present. Disable that behavior with `--no-firewall`.

## Linux Server Notes

For a wired server, the important part is usually the campus IP bound to the NIC:

```sh
./shanghaitech-net-auth.sh login -u 2025XXXXXXX -I ens192
```

If autodetection is wrong, force the IP:

```sh
./shanghaitech-net-auth.sh login -u 2025XXXXXXX -i 10.19.123.45
```

## ESXi Notes

ESXi often exposes the management address on `vmk0`.

Example:

```sh
./shanghaitech-net-auth.sh login -u 2025XXXXXXX -I vmk0
```

If `watch` mode is needed on ESXi, wire it into your own startup or scheduled task. The script itself stays plain `sh`; it does not assume `systemd`.

Validated on an ESXi 6.7 test VM:

- `/bin/sh` parses the script
- `vmk0` IP detection works through `esxcli`
- HTTPS POST uses Python 3 when `curl` is absent
- portal network timeout is reported explicitly instead of being hidden as a script failure
- `doctor` prints interface, route, DNS, and portal TCP reachability
- `login` performs a TCP preflight before prompting for password unless `--skip-preflight` is set
- `doctor`/`login` can auto-open the portal port on Linux or ESXi when a local firewall is present

## Cron Example

The simplest cron pattern is to attempt a login periodically:

```cron
*/2 * * * * /path/to/shanghaitech-net-auth.sh login -c /path/to/shanghaitech-net-auth.conf >/var/log/shtech-auth.log 2>&1
```

If you want continuous monitoring, use `watch` under `systemd`, `supervisord`, `nohup`, or your ESXi startup flow instead of launching an infinite loop from cron.

## Behavior

The script will:

1. detect the local campus IP from `--ip`, `--interface`, routing, `ifconfig`, or `esxcli`
2. `POST` credentials to `https://10.15.145.16:19008/portalauth/login`
3. fall back to `https://net-auth.shanghaitech.edu.cn:19008` if the raw IP endpoint fails

## Current Caveat

`10.10.10.10` itself timed out in the current shell session, so this repo does not depend on the browser redirect page. It talks to the live backend endpoint directly instead.
