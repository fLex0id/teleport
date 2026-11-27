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
cp -a /etc/default/ufw "$scratch/default-ufw"
mount --bind "$scratch/ufw" /etc/ufw
mount --bind "$scratch/default-ufw" /etc/default/ufw
ip link set lo up
ufw --force reset
sed -i 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw
# Include an application profile even on a minimal runner.
cat > /etc/ufw/applications.d/teleport-test-openssh <<'APP'
[TeleportTestSSH]
title=OpenSSH test
description=SSH test
ports=22/tcp
APP
ufw allow 22/tcp comment 'SSH'
ufw allow from 192.0.2.10 to any port 22 proto tcp
ufw allow TeleportTestSSH
ufw --force enable
ufw status numbered >"$scratch/before-status"
mkdir "$scratch/backup"
ufw_lockdown "$scratch/backup" 22
ufw_verify_chain iptables ufw-before-input 22
if ufw_ipv6; then ufw_verify_chain ip6tables ufw6-before-input 22; fi
ufw status numbered >"$scratch/locked-status"
cmp "$scratch/before-status" "$scratch/locked-status"
echo 'PASS actual UFW: comments, profile and source-specific allowances preserved and overridden'
ufw allow 8080/tcp comment 'new administrator rule'
ufw_restore_snapshot "$scratch/backup"
ufw status numbered | grep '8080/tcp'
ufw status numbered | grep 'TeleportTestSSH'
! iptables -S ufw-before-input | grep -q 'teleport-deploy-openssh'
echo 'PASS actual UFW: restore preserves original and new rules'
# Simulate globally disabled IPv6 with IPV6=yes remaining in UFW configuration.
if [[ -e /proc/sys/net/ipv6/conf/all/disable_ipv6 ]]; then
  sysctl -w net.ipv6.conf.all.disable_ipv6=1
  sysctl -w net.ipv6.conf.default.disable_ipv6=1
  ! ufw_ipv6
  mkdir "$scratch/backup6"
  ufw_lockdown "$scratch/backup6" 22
  ufw_verify_chain iptables ufw-before-input 22
  ! grep -q before6.rules "$scratch/backup6/ufw.managed"
  ufw_restore_snapshot "$scratch/backup6"
  echo 'PASS actual UFW: IPv6 disabled despite IPV6=yes'
else
  echo 'IPv6 sysctl unavailable; IPv6-disabled branch already in effect'
fi
echo 'Real UFW integration checks passed'
