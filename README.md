# ShanghaiTech Campus Network Terminal Auth

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

At least one of:

- `curl`
- `wget`

And a few standard tools that are commonly present on Linux / BusyBox / ESXi:

- `awk`
- `sed`
- `cut`
- `od`

For automatic IP detection, one of these helps:

- `ip`
- `ifconfig`
- `esxcli` (ESXi)

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
