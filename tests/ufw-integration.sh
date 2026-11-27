#!/usr/bin/env bash
# Run exclusively inside a dedicated mount + network namespace.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
source ./deploy-teleport.sh
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
LOG=$scratch/log
# Isolate UFW persistent files and ensure no host network rules are modified.
cp -a /etc/ufw "$scratch/ufw"
cp -a /etc/default "$scratch/default"
mount --bind "$scratch/ufw" /etc/ufw
mount --bind "$scratch/default" /etc/default
ip link set lo up
# ip netns uses a shared runtime directory; isolate it from the runner.
mkdir -p /run/netns
mkdir "$scratch/netns"
mount --bind "$scratch/netns" /run/netns
ufw --force reset
sed -i 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw
# Include an application profile even on a minimal runner.
cat > /etc/ufw/applications.d/teleport-test-openssh <<'APP'
[TeleportTestSSH]
title=OpenSSH test
description=SSH test
ports=2222/tcp
APP
ufw allow 22/tcp comment 'SSH'
ufw allow from 192.0.2.10 to any port 22 proto tcp
ufw allow TeleportTestSSH
ufw --force enable
ufw status numbered >"$scratch/before-status"
# Exercise actual TCP traffic through a veth pair (not loopback, which UFW permits).
ip netns add tp-peer
ip link add tp-host type veth peer name tp-client
ip link set tp-client netns tp-peer
ip addr add 192.0.2.1/24 dev tp-host
ip link set tp-host up
ip netns exec tp-peer ip addr add 192.0.2.10/24 dev tp-client
ip netns exec tp-peer ip link set tp-client up
# Keep the server and client alive across reload; synchronize through files.
cat >"$scratch/tcp-test.py" <<'PYTCP'
import socket,sys,time
from pathlib import Path
mode,root=sys.argv[1:]
p=Path(root)
def wait(name):
    for _ in range(200):
        if (p/name).exists(): return
        time.sleep(.1)
    raise RuntimeError("timeout: "+name)
if mode=="server":
    with socket.socket() as s:
        s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
        s.bind(("192.0.2.1",2222)); s.listen()
        (p/"listening").touch()
        c,_=s.accept()
        with c:
            c.settimeout(30)
            for expected in (b"before",b"after"):
                data=c.recv(64)
                assert data==expected,data
                c.sendall(data)
elif mode=="client":
    wait("listening")
    with socket.create_connection(("192.0.2.1",2222),timeout=5) as c:
        c.sendall(b"before"); assert c.recv(64)==b"before"
        (p/"connected").touch()
        wait("locked")
        c.sendall(b"after"); assert c.recv(64)==b"after"
        (p/"survived").touch()
elif mode=="new":
    try:
        with socket.create_connection(("192.0.2.1",2222),timeout=2):
            raise RuntimeError("new connection unexpectedly allowed")
    except TimeoutError:
        pass
PYTCP
python3 "$scratch/tcp-test.py" server "$scratch" &
server_pid=$!
ip netns exec tp-peer python3 "$scratch/tcp-test.py" client "$scratch" &
client_pid=$!
trap 'kill "$server_pid" "$client_pid" 2>/dev/null || :; ip netns del tp-peer || :; rm -rf "$scratch"' EXIT
for attempt in {1..100}; do [[ -f $scratch/connected ]] && break; sleep .1; done
[[ -f $scratch/connected ]]
mkdir "$scratch/backup"
ufw_lockdown "$scratch/backup" 22 2222
touch "$scratch/locked"
wait "$client_pid"
wait "$server_pid"
[[ -f $scratch/survived ]]
# Restart listener so a successful new handshake would be observable.
rm -f "$scratch/listening"
python3 "$scratch/tcp-test.py" server "$scratch" &
server_pid=$!
for attempt in {1..100}; do [[ -f $scratch/listening ]] && break; sleep .1; done
[[ -f $scratch/listening ]]
ip netns exec tp-peer python3 "$scratch/tcp-test.py" new "$scratch"
kill "$server_pid"
wait "$server_pid" 2>/dev/null || :
echo 'PASS actual UFW: established TCP survives and new TCP is blocked'
ufw_verify_chain iptables ufw-before-input 22 2222
if ufw_ipv6; then ufw_verify_chain ip6tables ufw6-before-input 22 2222; fi
ufw status numbered >"$scratch/locked-status"
cmp "$scratch/before-status" "$scratch/locked-status"
echo 'PASS actual UFW: comments, profile and source-specific allowances preserved and overridden'
ufw allow 8080/tcp comment 'new administrator rule'
ufw_restore_snapshot "$scratch/backup"
ufw status numbered | grep '8080/tcp'
ufw status numbered | grep 'TeleportTestSSH'
if iptables -S ufw-before-input | grep -q 'teleport-deploy-openssh'; then echo 'Negative assertion failed' >&2; exit 1; fi
echo 'PASS actual UFW: restore preserves original and new rules'
# Simulate globally disabled IPv6 with IPV6=yes remaining in UFW configuration.
if [[ -e /proc/sys/net/ipv6/conf/all/disable_ipv6 ]]; then
  sysctl -w net.ipv6.conf.all.disable_ipv6=1
  sysctl -w net.ipv6.conf.default.disable_ipv6=1
  if ufw_ipv6; then echo 'Negative assertion failed' >&2; exit 1; fi
  mkdir "$scratch/backup6"
  ufw_lockdown "$scratch/backup6" 22
  ufw_verify_chain iptables ufw-before-input 22
  if grep -q before6.rules "$scratch/backup6/ufw.managed"; then echo 'Negative assertion failed' >&2; exit 1; fi
  ufw_restore_snapshot "$scratch/backup6"
  echo 'PASS actual UFW: IPv6 disabled despite IPV6=yes'
else
  echo 'IPv6 sysctl unavailable; IPv6-disabled branch already in effect'
fi
echo 'Real UFW integration checks passed'
