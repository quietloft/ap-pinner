# ap-pinner

**Keep a Wi-Fi client on one access point — permanently — on OpenWrt networks.**

```sh
./ap-pinner.sh --config mydevices.conf            # dry run: shows what it would do
./ap-pinner.sh --config mydevices.conf --apply    # applies it
./ap-pinner.sh --config mydevices.conf --revert   # puts everything back
```

## The problem this solves

Cheap IoT devices — Shelly relays, ESP-based switches, many IP cameras — **do not
roam**. A device associates with an access point once and then stays there: if a
firmware update, a power cut or a reboot brings it up on the wrong node, it will
keep talking to the weakest, busiest AP it can find. In the vendor app you see it
"come and go": commands work, then vanish, then work again.

What people try first, and why it does not work:

| Attempt | Why it fails |
| --- | --- |
| Power-cycle the device | It picks the strongest AP again — the same wrong one |
| Deauthenticate it (`iw station del`) | It re-associates within seconds, usually back where it was |
| Move the device physically | Only works when you control the position |
| Reduce TX power on the wrong AP | Blast radius: you degrade every other client too |

## What this does instead

On every access point where the device **must not** live, it sets

```
macfilter=deny
maclist=<the device MAC>
```

on each client radio, commits `wireless`, and reloads. The device can now only
associate with the AP you allowed for it. The rule lives in `/etc/config/wireless`,
so it **survives reboots and sysupgrades** (it is part of your config backup).

## Requirements

- OpenWrt access points reachable over SSH from a gateway you can SSH into
- `root` access (or a user allowed to run `uci` and `wifi reload`)
- the client radios are the usual `default_radio0/1/2` sections
  (check with `uci show wireless | grep 'default_radio[0-9]*='`)

## What it costs — read before `--apply`

A macfilter change requires **`wifi reload` on that node: 15-20 seconds in which
every client of that node drops**. On an AP uplinked wirelessly, this can drop the
very link you are working through — which is why the reload is launched detached
from the session. The script waits `SETTLE` seconds between nodes for this reason.

## Safety

- dry run by default: nothing is written unless you pass `--apply`
- before touching anything it saves `/etc/config/wireless` to
  `/root/wireless.bak.appinner.<date>` on each node, and never overwrites a
  previous backup
- `--revert` restores the newest backup and reloads
- the MAC list is updated idempotently: running it twice does **not** duplicate
  entries

## Configuration

See [`examples/devices.conf`](examples/devices.conf). The essential part:

```sh
AP_NODES="1=192.168.1.2 2=192.168.1.3 3=192.168.1.4"
DEVICES="
Shelly bathroom light|AA:BB:CC:11:22:33|2
Shelly bedroom shutter|AA:BB:CC:44:55:66|3
"
```
The third field is the index of the AP where the device **must stay**; the script
denies that MAC on all the *other* nodes.

## Finding the MAC of a device

On the OpenWrt node:
```sh
for i in $(uci show wireless | grep -o 'default_radio[0-9]*'); do
  echo "== $i"; iwinfo ${i#default_} assoclist
done
```

## License

MIT. No warranty: you are changing the wireless config of your own access points.

Built by [theblackcloud](https://theblackcloud.ai) while solving exactly this
problem at home.
