#!/usr/bin/env bash
# Package-managed Teleport deployment, Linux x86_64, systemd.
# SPDX-License-Identifier: MIT
set -Eeuo pipefail
umask 077
export LC_ALL=C
VERSION=2.2.0
BASE=https://flex0id.github.io/teleport
REPO_HOST=flex0id.github.io
REPO_IPS=(185.199.108.153 185.199.109.153 185.199.110.153 185.199.111.153)
REPO_FALLBACK_IP=
REPO_DNS_MODE='NOT CHECKED'
FPR=95AB1A0D022288C96B135E395D6220FDB9C74356
CONF=/etc/teleport.yaml
STATE=/var/lib/teleport-deploy
LOG=/var/log/teleport-deploy.log
DNSUNIT=teleport-doh.service
DNSCONF=/etc/teleport-doh.toml
DNSBACK=$STATE/dns-original
NMCONF=/etc/NetworkManager/conf.d/95-teleport-deploy-dns.conf
say(){ printf '%s\n' "$*"; }
fail(){ say "[ERROR] $*" >&2; return 1; }
ask(){ local v; IFS= read -r -p "$1 " v </dev/tty || exit 130; ANSWER=$v; }
yesno(){ while :; do ask "$1 [y/N]"; case "$ANSWER" in y|Y|yes|YES) return 0;; ''|n|N|no|NO) return 1;; *) say 'Enter y or n.';; esac; done; }
choice(){ while :; do ask "$1"; case "$ANSWER" in '') ANSWER=$2;; esac; if [[ $ANSWER =~ ^[0-9]$ ]] && (( ANSWER <= $3 )); then return; fi; say 'Invalid choice. Try again.'; done; }
domain_ok(){ [[ $1 =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ && $(printf %s "$1" | wc -c) -le 253 ]]; }
ip_ok(){ local a b c d x; [[ $1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1; IFS=. read -r a b c d <<<"$1"; for x in "$a" "$b" "$c" "$d"; do (( 10#$x <= 255 )) || return 1; done; }
ask_domain(){ while :; do ask "$1"; if domain_ok "$ANSWER"; then return; fi; say 'Enter a valid FQDN, without https:// or port.'; done; }
ask_name(){ while :; do ask "$1 [$2]"; ANSWER=${ANSWER:-$2}; [[ $ANSWER =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]{0,62}$ ]] && return; say 'Use ASCII letters, digits, dots, hyphens or underscores.'; done; }
run(){ local desc=$1; shift; say "$desc ..."; if "$@" >>"$LOG" 2>&1; then say '[OK]'; else say "[ERROR] See $LOG"; tail -n 12 "$LOG" >&2; return 1; fi; }
fetch(){ curl -4fsSL --retry 3 --connect-timeout 15 --max-time 120 "$1" -o "$2"; }
repo_report(){
  REPO_DNS_MODE=$1
  local message="[DNS] Repository access: $REPO_DNS_MODE"
  say "$message"
  printf '[%s] %s\n' "$(date -Is)" "$message" >>"$LOG" || say '[WARN] Could not write DNS status to log.'
}
# Only GitHub Pages downloads use this fallback. Never modify system DNS or /etc/hosts.
# curl exit 6 means the target hostname could not be resolved.
repo_probe(){
  local rc ip resolver candidate
  local -a candidates=() sources=()
  local idx source
  REPO_FALLBACK_IP=
  REPO_DNS_MODE='CHECKING'
  if curl -4fsS --connect-timeout 8 --max-time 15 "$BASE/current-release.txt" -o /dev/null; then
    repo_report 'NORMAL - system resolver; emergency fallback not used.'
    return 0
  else rc=$?; fi
  if ((rc != 6)); then
    repo_report "FAILED - normal HTTPS error (curl $rc); emergency fallback not used."
    fail "Repository HTTPS failed (curl $rc); DNS fallback not applicable."
    return 1
  fi
  say '[WARN] Repository DNS failed. Trying temporary fallback.'
  if command -v dig >/dev/null 2>&1; then
    for resolver in 9.9.9.9 1.1.1.1 8.8.8.8; do
      while IFS= read -r candidate; do
        if ip_ok "$candidate"; then candidates+=("$candidate"); sources+=("alternate DNS $resolver"); fi
      done < <(dig @"$resolver" "$REPO_HOST" A +time=2 +tries=1 +short 2>/dev/null || :)
      (("${#candidates[@]}" > 0)) && break
    done
  fi
  for ip in "${REPO_IPS[@]}"; do candidates+=("$ip"); sources+=("static GitHub Pages IP"); done
  local seen=' '
  for idx in "${!candidates[@]}"; do
    ip=${candidates[idx]}; source=${sources[idx]}
    [[ $seen != *" $ip "* ]] || continue
    seen+="$ip "
    if curl -4fsS --noproxy "$REPO_HOST" --connect-timeout 5 --max-time 12 \
      --resolve "$REPO_HOST:443:$ip" "$BASE/current-release.txt" -o /dev/null; then
      REPO_FALLBACK_IP=$ip
      repo_report "EMERGENCY - $source; verified HTTPS to $ip."
      return 0
    fi
  done
  repo_report 'FAILED - normal DNS and emergency fallback unsuccessful.'
  fail 'No reachable GitHub Pages address with valid TLS.'
}
repo_fetch(){
  local url=$1 dest=$2
  [[ $url == "$BASE/"* ]] || { fail 'Unexpected repository URL.'; return 1; }
  if [[ -n $REPO_FALLBACK_IP ]]; then
    curl -4fsSL --noproxy "$REPO_HOST" --resolve "$REPO_HOST:443:$REPO_FALLBACK_IP" \
      --retry 2 --connect-timeout 10 --max-time 120 "$url" -o "$dest"
  else
    fetch "$url" "$dest"
  fi
}
repo_run(){
  if [[ -z $REPO_FALLBACK_IP ]]; then "$@"; return $?; fi
  # A private mount namespace makes the mapping visible only to the child
  # installer and package manager; DNS tests and the host remain untouched.
  local hosts="$TMP/repository.hosts"
  command -v unshare >/dev/null && command -v mount >/dev/null || {
    fail 'Private mount namespace unavailable; restore working DNS first.'; return 1; }
  {
    printf '%s %s\n' "$REPO_FALLBACK_IP" "$REPO_HOST"
    # Remove only the exact repository alias from copied hosts entries.
    awk -v h="$REPO_HOST" '{if ($0 ~ /^[[:space:]]*#/ || NF<2) {print;next} s=$1; n=0; for(i=2;i<=NF;i++){if($i~/^#/)break; if(tolower($i)!=h){s=s" "$i;n++}} if(n) print s}' /etc/hosts
  } >"$hosts" || return 1
  chmod 644 "$hosts" || return 1
  unshare --mount --propagation private bash -c '
    mount --bind "$1" /etc/hosts || exit 1
    shift
    exec "$@"
  ' bash "$hosts" "$@"
}
detect(){
  [[ $(uname -m) == x86_64 ]] || { fail 'Only x86_64 / amd64 packages are published.'; return 1; }
  [[ -d /run/systemd/system ]] || { fail 'systemd is required.'; return 1; }
  [[ -r /etc/os-release ]] || return 1
  . /etc/os-release
  case "$ID" in ubuntu|debian) PM=apt;; rocky|almalinux|rhel|centos) PM=dnf;; *) fail "Unsupported distribution: $ID"; return 1;; esac
  command -v "$PM" >/dev/null || return 1
  say "OS: ${PRETTY_NAME:-$ID} ($PM)"
}
deps(){
  if [[ $PM == apt ]]; then
    run 'Refresh APT' apt-get -o DPkg::Lock::Timeout=120 update &&
    run 'Install prerequisites' env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 install -y ca-certificates curl gnupg python3 iproute2 openssl util-linux dnsutils
  else
    run 'Install prerequisites' dnf -y install ca-certificates curl gnupg2 python3 iproute openssl util-linux bind-utils
  fi
}
dns_test(){ local h; for h in github.com raw.githubusercontent.com flex0id.github.io; do timeout 10 getent ahostsv4 "$h" >/dev/null || return 1; done; }
dns_restore(){
  [[ -d $DNSBACK ]] || { say 'No saved DNS configuration.'; return 0; }
  cp -a "$DNSBACK/resolv.conf" /etc/.teleport-resolv-restore.$$ || return 1
  mv -Tf /etc/.teleport-resolv-restore.$$ /etc/resolv.conf || return 1
  rm -f "$NMCONF"
  if [[ -f $DNSBACK/nm ]]; then systemctl reload NetworkManager || say 'Check NetworkManager manually.'; fi
  systemctl disable --now "$DNSUNIT" >/dev/null 2>&1 || :
  rm -f "/etc/systemd/system/$DNSUNIT" "$DNSCONF"
  systemctl daemon-reload
  if dns_test; then rm -rf "$DNSBACK"; say '[OK] Original DNS restored.'; else fail "Original DNS restored but resolution failed; backup: $DNSBACK"; fi
}
dns_stamp(){
  python3 - "$@" <<'PY'
import base64,struct,sys
ip,host,path=sys.argv[1:]
def lp(s):
    b=s.encode('ascii')
    if len(b)>255: raise ValueError('field too long')
    return bytes([len(b)])+b
raw=b'\x02'+struct.pack('<Q',0)+lp(ip)+b'\x00'+lp(host)+lp(path)
print('sdns://'+base64.urlsafe_b64encode(raw).decode().rstrip('='))
PY
}
dns_change(){
  [[ ! -e $DNSBACK ]] || { say 'Restore previous DNS configuration first (menu 4).'; return 1; }
  say '1 Quad9   2 Cloudflare   3 Google   4 Cisco OpenDNS'
  say '5 NextDNS (UDP / DoH profile)   6 AdGuard   7 Custom UDP   0 Keep current'
  choice 'DNS provider [0]:' 0 7
  local p=$ANSWER ips host path=/dns-query mode ip stamp names='' i=0 bin
  case "$p" in
    0) return 0;;
    1) ips='9.9.9.9 149.112.112.112'; host=dns.quad9.net;;
    2) ips='1.1.1.1 1.0.0.1'; host=cloudflare-dns.com;;
    3) ips='8.8.8.8 8.8.4.4'; host=dns.google;;
    4) ips='208.67.222.222 208.67.220.220'; host=doh.opendns.com;;
    5) ips='45.90.28.0 45.90.30.0'; host=dns.nextdns.io;;
    6) ips='94.140.14.14 94.140.15.15'; host=dns.adguard-dns.com;;
    7) while :; do ask 'One or two IPv4 addresses, separated by space:'; ips=$ANSWER; local valid=1 count=0; for ip in $ips; do ip_ok "$ip" || valid=0; count=$((count+1)); done; ((valid && count>=1 && count<=2)) && break; say 'Invalid addresses.'; done; host='';;
  esac
  if [[ $p == 5 ]]; then
    choice '1 UDP (linked IP), 2 DoH (profile ID), 0 Cancel [2]:' 2 2; mode=$ANSWER
    if [[ $mode == 2 ]]; then
      while :; do ask 'NextDNS profile ID (6 hex characters):'; [[ $ANSWER =~ ^[a-fA-F0-9]{6}$ ]] && break; say 'Invalid profile ID.'; done
      path="/$ANSWER"
    elif [[ $mode == 1 ]]; then
      say 'Use the two IPv4 addresses listed in your NextDNS Linked IP setup.'
      while :; do ask 'Primary IPv4:'; ip_ok "$ANSWER" && { ips=$ANSWER; break; }; say 'Invalid IPv4.'; done
      while :; do ask 'Secondary IPv4:'; ip_ok "$ANSWER" && { ips="$ips $ANSWER"; break; }; say 'Invalid IPv4.'; done
    fi
  elif [[ $p == 7 ]]; then mode=1
  else choice '1 UDP DNS, 2 DNS over HTTPS, 0 Cancel [1]:' 1 2; mode=$ANSWER; fi
  [[ $mode != 0 ]] || return 0
  say 'This changes system-wide DNS and may affect private DNS names.'
  yesno 'Apply DNS configuration?' || return 0
  [[ ! -e $NMCONF && ! -e $DNSCONF && ! -e /etc/systemd/system/$DNSUNIT ]] || { fail 'Existing resolver configuration; refusing overwrite.'; return 1; }
  mkdir -m 700 "$DNSBACK" || return 1
  cp -a /etc/resolv.conf "$DNSBACK/resolv.conf" || { rmdir "$DNSBACK"; return 1; }
  DNS_PENDING=1
  if [[ $mode == 2 ]]; then
    if ! command -v dnscrypt-proxy >/dev/null; then
      if [[ $PM == apt ]]; then run 'Install DNSCrypt proxy' apt-get install -y dnscrypt-proxy || return 1
      else
        if ! run 'Install DNSCrypt proxy' dnf -y install dnscrypt-proxy; then
          if [[ $ID == rocky || $ID == almalinux ]] && yesno 'Enable EPEL to install DNSCrypt proxy?'; then
            run 'Install EPEL' dnf -y install epel-release && run 'Install DNSCrypt proxy' dnf -y install dnscrypt-proxy || return 1
          else say 'DoH unavailable; current DNS unchanged.'; return 1; fi
        fi
      fi
    fi
    bin=$(command -v dnscrypt-proxy) || return 1
  fi
  if [[ $mode == 2 ]]; then
    # Use the explicit endpoint IPs, no unencrypted bootstrap fallback.
    {
      say "listen_addresses = ['127.0.2.53:53']"
      say 'ipv4_servers = true'; say 'ipv6_servers = false'
      say 'dnscrypt_servers = false'; say 'doh_servers = true'; say 'odoh_servers = false'
      say 'ignore_system_dns = true'; say 'timeout = 5000'; say 'cache = true'
      for ip in $ips; do i=$((i+1)); names="${names:+$names, }'up$i'"; done
      say "server_names = [$names]"
      say '[static]'
      i=0; for ip in $ips; do i=$((i+1)); stamp=$(dns_stamp "$ip" "$host" "$path") || return 1; say "[static.up$i]"; say "stamp = '$stamp'"; done
    } >"$DNSCONF" || return 1
    run 'Check DoH configuration' "$bin" -config "$DNSCONF" -check || { dns_restore || :; DNS_PENDING=0; return 1; }
    cat >"/etc/systemd/system/$DNSUNIT" <<EOF
[Unit]
Description=Local Teleport deployment DoH resolver
After=network-online.target
Wants=network-online.target
[Service]
ExecStart=$bin -config $DNSCONF
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload || return 1
    run 'Start local DoH' systemctl enable --now "$DNSUNIT" || { dns_restore || :; DNS_PENDING=0; return 1; }
    local ready=0 n
    for n in {1..10}; do if dig @127.0.2.53 github.com A +time=2 +tries=1 +short | grep -Eq '^[0-9]+\.'; then ready=1; break; fi; sleep 1; done
    ((ready)) || { fail 'DoH lookup failed'; dns_restore || :; DNS_PENDING=0; return 1; }
    ips=127.0.2.53
  else
    local ready=0
    for ip in $ips; do if dig @"$ip" github.com A +time=3 +tries=1 +short | grep -Eq '^[0-9]+\.'; then ready=1; break; fi; done
    ((ready)) || { fail 'UDP DNS unavailable'; dns_restore || :; DNS_PENDING=0; return 1; }
  fi
  if systemctl is-active --quiet NetworkManager; then
    touch "$DNSBACK/nm"
    mkdir -p /etc/NetworkManager/conf.d || return 1
    printf '[main]\ndns=none\n' >"$NMCONF" || return 1
    systemctl reload NetworkManager || return 1
  fi
  # Detach from systemd-resolved stub; do not stop other network services.
  local tmp; tmp=$(mktemp /etc/.teleport-resolv.XXXXXX) || return 1
  { say '# Managed by deploy-teleport.sh'; for ip in $ips; do say "nameserver $ip"; done; say 'options timeout:2 attempts:2'; } >"$tmp" || return 1
  chmod 644 "$tmp" && mv -Tf "$tmp" /etc/resolv.conf || return 1
  if command -v restorecon >/dev/null; then restorecon /etc/resolv.conf || :; fi
  if dns_test; then DNS_PENDING=0; say '[OK] DNS configured. Use menu 4 to restore.'; say 'Check NSS/systemd-resolved and DHCP configuration if applications use another resolver or DNS changes after reboot.'; else dns_restore || :; DNS_PENDING=0; return 1; fi
}
install_package(){
  repo_probe || return 1
  repo_fetch "$BASE/install-repo.sh" "$TMP/install-repo.sh" || return 1
  run 'Configure signed Teleport repository' repo_run env TELEPORT_REPO_EXPECTED_FPR="$FPR" bash "$TMP/install-repo.sh" || return 1
  if [[ $PM == apt ]]; then
    local version; repo_fetch "$BASE/current-release.txt" "$TMP/current-release.txt" || return 1
    version=$(cat "$TMP/current-release.txt") || return 1
    version=$(printf '%s' "$version" | sed -E 's/^(teleport-v|v)//')
    apt-cache madison teleport | awk -F'|' -v v="$version" '{gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); if ($2==v && $3 ~ /https:\/\/flex0id[.]github[.]io\/teleport\/apt/) found=1} END{exit !found}' || return 1
    [[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { fail 'No valid package candidate'; return 1; }
    run "Install Teleport $version" repo_run env DEBIAN_FRONTEND=noninteractive apt-get install -y "teleport=$version"
  else
    run 'Install Teleport from managed repository' repo_run dnf -y install teleport --setopt=flex0id-teleport.priority=1
  fi
}
time_check(){
  if [[ $(timedatectl show -p NTPSynchronized --value 2>/dev/null || :) == yes ]]; then return 0; fi
  say "NTP synchronization is not confirmed. Current time: $(date -Is)"
  if yesno 'Enable system NTP?'; then timedatectl set-ntp true || :; fi
  local n; for n in {1..5}; do [[ $(timedatectl show -p NTPSynchronized --value 2>/dev/null || :) == yes ]] && return 0; sleep 2; done
  yesno 'Continue only if the displayed time is accurate?'
}
existing_guard(){
  [[ ! -e $CONF && ! -L $CONF ]] || { fail "$CONF already exists; refusing overwrite."; return 1; }
  if [[ -d /var/lib/teleport && -n $(ls -A /var/lib/teleport) ]]; then fail 'Existing Teleport data; refusing overwrite.'; return 1; fi
  if command -v teleport >/dev/null || systemctl cat teleport.service >/dev/null 2>&1; then fail 'Existing Teleport installation; use normal package updates or manual recovery.'; return 1; fi
}
open_https(){
  if systemctl is-active --quiet firewalld; then
    local iface zone
    iface=$(ip -4 route show default | awk 'NR==1{for(i=1;i<NF;i++)if($i=="dev"){print $(i+1);exit}}')
    zone=$(firewall-cmd --get-zone-of-interface="$iface" 2>/dev/null || firewall-cmd --get-default-zone)
    run 'Allow HTTPS in active firewall zone' firewall-cmd --zone="$zone" --add-service=https &&
    run 'Persist HTTPS firewall rule' firewall-cmd --permanent --zone="$zone" --add-service=https
  elif command -v ufw >/dev/null && ufw status | grep -q '^Status: active'; then
    run 'Allow HTTPS in UFW' ufw allow 443/tcp
  else say 'Ensure TCP 443 is allowed by host/provider firewall.'; fi
}
wait_cluster(){
  local n
  for n in {1..45}; do
    if systemctl is-active --quiet teleport && tctl status >/dev/null 2>&1 &&
      curl -4fsS --max-time 5 --resolve "$CLUSTER:443:127.0.0.1" "https://$CLUSTER/webapi/ping" >/dev/null 2>&1; then return 0; fi
    sleep 2
  done
  fail 'Cluster not healthy or trusted HTTPS not ready. Check journalctl -u teleport.'
}
admin(){
  local u login
  ask_name 'Teleport administrator' admin; u=$ANSWER
  while :; do ask 'Existing Linux login [root]:'; login=${ANSWER:-root}; if [[ $login =~ ^[a-z_][a-z0-9_.-]{0,31}$ ]] && id "$login" >/dev/null 2>&1; then break; fi; say 'Enter an existing local account.'; done
  # The invitation URL is displayed only in the console, not in the log.
  tctl users add "$u" --roles=editor,access --logins="$login"
}
token_menu(){
  say 'One-hour node enrollment token. Keep it private.'
  tctl tokens add --type=node --ttl=1h --format=text
}
main_install(){
  existing_guard || return 1
  ask_domain 'Cluster FQDN (public DNS points to this host):'; CLUSTER=$ANSWER
  ask_name 'Node name' "$(hostname -s)"; local node=$ANSWER email cert key mode
  choice 'TLS: 1 built-in ACME, 2 existing trusted certificate, 0 Cancel [1]:' 1 2; mode=$ANSWER
  [[ $mode != 0 ]] || return 0
  if [[ $mode == 1 ]]; then
    while :; do ask 'ACME email:'; [[ $ANSWER =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] && { email=$ANSWER; break; }; say 'Invalid email.'; done
  else
    while :; do ask 'Absolute fullchain PEM path:'; cert=$ANSWER; [[ $cert == /* && -r $cert ]] && break; say 'File not readable.'; done
    while :; do ask 'Absolute private key PEM path:'; key=$ANSWER; [[ $key == /* && -r $key ]] && break; say 'File not readable.'; done
    openssl x509 -in "$cert" -noout -checkhost "$CLUSTER" || return 1
  fi
  [[ -z $(ss -Hlt '( sport = :443 )') ]] || { fail 'TCP 443 is already in use.'; return 1; }
  getent ahostsv4 "$CLUSTER" || { fail 'Cluster domain does not resolve.'; return 1; }
  time_check || return 1
  yesno "Install cluster $CLUSTER with node $node?" || return 0
  install_package || return 1
  local -a args=(configure --cluster-name="$CLUSTER" --public-addr="$CLUSTER:443" --roles=auth,proxy,node -o stdout)
  if [[ $mode == 1 ]]; then args+=(--acme --acme-email="$email"); else args+=(--cert-file="$cert" --key-file="$key"); fi
  teleport "${args[@]}" >"$TMP/cluster.yaml" || return 1
  # Use PyYAML from the distribution to edit structured configuration.
  python3 - "$TMP/cluster.yaml" "$node" <<'PY' || return 1
import sys,yaml
p,node=sys.argv[1:]
with open(p) as f: c=yaml.safe_load(f)
c.setdefault('teleport',{})['nodename']=node
c.setdefault('auth_service',{})['listen_addr']='127.0.0.1:3025'
c['auth_service']['proxy_listener_mode']='multiplex'
c.setdefault('ssh_service',{})['listen_addr']='127.0.0.1:3022'
with open(p,'w') as f: yaml.safe_dump(c,f,sort_keys=False)
PY
  [[ ! -e $CONF ]] || { fail 'Package created a configuration; inspect manually.'; return 1; }
  teleport configure --test="$TMP/cluster.yaml" || return 1
  install -m 0600 "$TMP/cluster.yaml" "$CONF" || return 1
  if command -v restorecon >/dev/null; then restorecon "$CONF" || :; fi
  open_https || return 1
  run 'Enable Teleport' systemctl enable --now teleport || return 1
  wait_cluster || return 1
  printf '%s\n' cluster >"$STATE/role"
  say "[OK] Cluster ready: https://$CLUSTER"
  yesno 'Create administrator now?' && admin || :
  yesno 'Create enrollment token now?' && token_menu || :
  ssh_offer
}
agent_install(){
  existing_guard || return 1
  ask_domain 'Main cluster FQDN:'; local proxy=$ANSWER node token
  ask_name 'Node name' "$(hostname -s)"; node=$ANSWER
  curl -4fsS --max-time 15 "https://$proxy/webapi/ping" >"$TMP/ping.json" || { fail 'Trusted HTTPS to cluster unavailable.'; return 1; }
  local cluster_version repo_version
  cluster_version=$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("server_version", ""))' <"$TMP/ping.json") || return 1
  repo_probe || return 1
  repo_fetch "$BASE/current-release.txt" "$TMP/current-release.txt" || return 1
  repo_version=$(cat "$TMP/current-release.txt") || return 1
  cluster_version=$(printf '%s' "$cluster_version" | sed 's/^v//')
  repo_version=$(printf '%s' "$repo_version" | sed -E 's/^(teleport-v|v)//')
  if [[ ! $cluster_version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ || ! $repo_version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then fail 'Could not verify cluster and repository versions.'; return 1; fi
  if [[ ${cluster_version%%.*} != ${repo_version%%.*} ]]; then fail "Cluster $cluster_version and repository $repo_version have different major versions. Align them before joining."; return 1; fi
  say "Cluster version: $cluster_version; repository version: $repo_version"
  say 'Enter a short-lived node token generated on the main server.'
  while :; do IFS= read -r -s -p 'Join token: ' token </dev/tty || return 1; echo; [[ $token =~ ^[A-Za-z0-9_-]{16,256}$ ]] && break; say 'Invalid token, try again.'; done
  time_check || return 1
  yesno "Join $proxy as $node?" || return 0
  install_package || return 1
  printf '%s' "$token" >"$TMP/join-token" || return 1; unset token
  install -d -m 0700 /etc/teleport || return 1
  [[ ! -e /etc/teleport/join-token ]] || return 1
  install -m 0600 "$TMP/join-token" /etc/teleport/join-token || return 1
  rm -f "$TMP/join-token"
  teleport node configure --output="file://$TMP/agent.yaml" --proxy="$proxy:443" --token=/etc/teleport/join-token >/dev/null || return 1
  python3 - "$TMP/agent.yaml" "$node" <<'PY' || return 1
import sys,yaml
p,node=sys.argv[1:]
with open(p) as f:c=yaml.safe_load(f)
c.setdefault('teleport',{})['nodename']=node
with open(p,'w') as f:yaml.safe_dump(c,f,sort_keys=False)
PY
  [[ ! -e $CONF ]] || return 1
  teleport configure --test="$TMP/agent.yaml" || return 1
  install -m 0600 "$TMP/agent.yaml" "$CONF" || return 1
  if command -v restorecon >/dev/null; then restorecon "$CONF" /etc/teleport/join-token || :; fi
  run 'Enable Teleport agent' systemctl enable --now teleport || return 1
  sleep 5
  systemctl is-active --quiet teleport || { fail 'Agent not running; inspect journalctl -u teleport.'; return 1; }
  printf '%s\n' agent >"$STATE/role"
  say 'Agent process is running (not yet proof of enrollment). Confirm actual enrollment on the main server with: tctl nodes ls'
  say 'No inbound SSH port has been opened.'
  ssh_offer
}
# OpenSSH lockdown is opt-in, reversible, and never changes Teleport ports.
ssh_state(){ printf '%s/openssh-backup\n' "$STATE"; }
ssh_units(){
  local u name
  for u in ssh.socket sshd.socket ssh.service sshd.service; do
    name=$(systemctl show "$u" -p Id --value 2>/dev/null) || continue
    [[ $(systemctl show "$u" -p LoadState --value 2>/dev/null) == loaded ]] || continue
    [[ $name =~ ^(ssh|sshd)\.(service|socket)$ ]] && printf '%s\n' "$name"
  done | awk '!seen[$0]++'
}
ssh_ports(){
  local bin
  bin=$(command -v sshd || :) 
  [[ -n $bin ]] || { [[ ! -x /usr/sbin/sshd ]] || bin=/usr/sbin/sshd; }
  if [[ -n $bin ]]; then "$bin" -T 2>/dev/null | awk '$1=="port"{print $2}' || :; fi
  # Include actual OpenSSH listeners, including systemd socket activation.
  ss -Hltpn | awk '/"sshd"/{n=split($4,a,":");print a[n]}'
  local u
  for u in ssh.socket sshd.socket; do
    [[ $(systemctl show "$u" -p LoadState --value 2>/dev/null) == loaded ]] || continue
    systemctl show "$u" -p Listen --value | grep -oE ':[0-9]+ \(Stream\)|^[0-9]+ \(Stream\)' | grep -oE '[0-9]+' || :
  done
}
ssh_restore(){
  local backup u enabled active kind zone port scope
  backup=$(ssh_state)
  [[ -f $backup/units ]] || { say 'No OpenSSH changes saved by this installer.'; return 0; }
  local failed=0
  # Restore only rules removed by us, never reload or reset the firewall.
  if [[ -f $backup/firewall ]]; then
    while read -r kind zone port scope; do
      [[ -n $kind ]] || continue
      case "$kind" in
        firewalld)
          local -a opts=("--zone=$zone")
          [[ $scope != permanent ]] || opts+=(--permanent)
          if [[ $port == service:ssh ]]; then firewall-cmd "${opts[@]}" --add-service=ssh || failed=1
          else firewall-cmd "${opts[@]}" --add-port="$port/tcp" || failed=1; fi;;
        ufw) ufw delete deny in proto tcp to any port "$port" || failed=1;;
        nft) nft delete table inet teleport_ssh_lockdown 2>/dev/null || { nft list table inet teleport_ssh_lockdown >/dev/null 2>&1 && failed=1 || :; };;
      esac
    done <"$backup/firewall"
  fi
  # Restore enablement first, then the original running state.
  while read -r u enabled active; do
    case "$enabled" in
      enabled) systemctl enable "$u" || failed=1;;
      enabled-runtime) systemctl enable --runtime "$u" || failed=1;;
      disabled|static|indirect|generated|alias) :;;
      *) say "Unexpected original state for $u: $enabled"; failed=1;;
    esac
  done <"$backup/units"
  while read -r u enabled active; do
    [[ $active != active ]] || systemctl start "$u" || failed=1
  done <"$backup/units"
  if ((failed)); then fail "Restore incomplete. Backup retained: $backup"; return 1; fi
  rm -rf -- "$backup" || return 1
  say '[OK] Original OpenSSH service and firewall settings restored.'
}
ssh_ready(){
  systemctl is-active --quiet teleport || { fail 'Teleport is not running.'; return 1; }
  [[ -f $STATE/role ]] || { fail 'No successful deployment recorded by this installer.'; return 1; }
  local role; role=$(cat "$STATE/role") || return 1
  case "$role" in
    cluster) tctl status >/dev/null 2>&1 || { fail 'Teleport Auth Service is not healthy.'; return 1; };;
    agent) say 'Confirm the node is registered in the cluster (tctl nodes ls).';;
    *) fail 'Unknown deployment role.'; return 1;;
  esac
  say 'Test an actual NEW Teleport SSH session to this node from your workstation.'
  say 'Keep the VNC console available. This does not disable Teleport SSH.'
  yesno 'Confirmed working Teleport SSH login and VNC recovery?'
}
ssh_lockdown(){
  local backup u enabled active port zone scope
  backup=$(ssh_state)
  [[ ! -e $backup ]] || { fail 'OpenSSH backup already exists. Restore first.'; return 1; }
  ssh_ready || return 1
  local -a units=() ports=()
  mapfile -t units < <(ssh_units)
  (("${#units[@]}")) || { say 'No installed OpenSSH systemd units found.'; return 0; }
  mapfile -t ports < <(ssh_ports | awk '/^[0-9]+$/ && $1>0 && $1<=65535' | sort -nu)
  if (("${#ports[@]}" == 0)); then fail 'Could not determine OpenSSH ports; no changes made.'; return 1; fi
  for port in "${ports[@]}"; do
    case "$port" in 443|3022|3023|3024|3025|3080) fail "OpenSSH port $port overlaps a Teleport port; no changes made."; return 1;; esac
  done
  say "OpenSSH units: ${units[*]}"
  say "OpenSSH TCP ports: ${ports[*]}"
  # Do not block a port shared with an unrelated listener.
  for port in "${ports[@]}"; do
    if ss -Hltpn "( sport = :$port )" | grep -vE '"sshd"|"systemd"' | grep -q .; then
      fail "TCP $port has another listener; no changes made."; return 1
    fi
  done
  yesno 'Disable OpenSSH and close these ports?' || return 0
  mkdir -m 700 "$backup" || return 1
  : >"$backup/units"; : >"$backup/firewall"
  for u in "${units[@]}"; do
    enabled=$(systemctl is-enabled "$u" 2>/dev/null || :)
    active=$(systemctl is-active "$u" 2>/dev/null || :)
    case "$enabled" in enabled|enabled-runtime|disabled|static|indirect|generated|alias) :;; *) fail "Unsupported unit state $enabled for $u"; rm -rf "$backup"; return 1;; esac
    printf '%s %s %s\n' "$u" "$enabled" "$active" >>"$backup/units" || return 1
  done
  SSH_PENDING=1
  # Stop socket units before service units to avoid reactivation.
  for u in "${units[@]}"; do
    systemctl stop "$u" || return 1
    case "$(systemctl is-enabled "$u" 2>/dev/null || :)" in enabled|enabled-runtime) systemctl disable "$u" || return 1;; esac
  done
  # Remove firewalld SSH allowances in every active zone, runtime and permanent.
  # Add an explicit persistent block only when using a dedicated nftables table
  # or UFW; firewalld rich rules are managed separately below.
  if systemctl is-active --quiet firewalld; then
    local -a zones=()
    mapfile -t zones < <(firewall-cmd --get-zones | tr ' ' '\n' | sed '/^$/d')
    for zone in "${zones[@]}"; do
      for scope in runtime permanent; do
        local -a opts=("--zone=$zone")
        [[ $scope != permanent ]] || opts+=(--permanent)
        # The ssh service usually maps to port 22. Preserve unrelated services.
        if [[ " ${ports[*]} " == *" 22 "* ]] && firewall-cmd "${opts[@]}" --query-service=ssh >/dev/null 2>&1; then
          firewall-cmd "${opts[@]}" --remove-service=ssh || return 1
          printf 'firewalld %s service:ssh %s\n' "$zone" "$scope" >>"$backup/firewall" || return 1
        fi
        for port in "${ports[@]}"; do
          if firewall-cmd "${opts[@]}" --query-port="$port/tcp" >/dev/null 2>&1; then
            firewall-cmd "${opts[@]}" --remove-port="$port/tcp" || return 1
            printf 'firewalld %s %s %s\n' "$zone" "$port" "$scope" >>"$backup/firewall" || return 1
          fi
        done
      done
    done
    say 'Removed explicit OpenSSH allowances; custom rich rules/policies remain unchanged.'
  elif command -v ufw >/dev/null && ufw status | grep -q '^Status: active'; then
    for port in "${ports[@]}"; do
      # Do not adopt an existing deny rule that may belong to the administrator.
      if ufw status | grep -Eq "^$port/tcp[[:space:]]+DENY[[:space:]]+IN"; then
        say "Existing UFW deny on $port; preserved."
        continue
      fi
      ufw insert 1 deny in proto tcp to any port "$port" || return 1
      printf 'ufw - %s -\n' "$port" >>"$backup/firewall" || return 1
    done
  else
    say 'No supported active firewalld/UFW detected; OpenSSH listeners are disabled.'
    say 'Existing nftables/iptables and provider firewall remain unchanged.'
  fi
  for port in "${ports[@]}"; do
    if [[ -n $(ss -Hlt "( sport = :$port )") ]]; then fail "TCP $port still listening; rolling back."; return 1; fi
  done
  systemctl is-active --quiet teleport || { fail 'Teleport stopped; rolling back.'; return 1; }
  SSH_PENDING=0
  say '[OK] OpenSSH disabled; detected SSH ports no longer listening.'
  say 'Recovery: run this script from VNC and select menu 8, then 2.'
}
ssh_menu(){
  while :; do
    say 'OpenSSH management (Teleport remains enabled)'
    say '1 Disable OpenSSH / close SSH ports'
    say '2 Restore original OpenSSH settings'
    say '3 Show OpenSSH listeners and units'
    say '0 Back'
    choice 'Select [0]:' 0 3
    case "$ANSWER" in
      0) return 0;;
      1) ssh_lockdown || say 'OpenSSH lockdown not completed.'
         if [[ ${SSH_PENDING:-0} == 1 ]]; then ssh_restore || :; SSH_PENDING=0; fi;;
      2) yesno 'Restore saved OpenSSH settings?' && ssh_restore || :;;
      3) ssh_units; ss -Hltpn || :;;
    esac
  done
}
ssh_offer(){
  say 'Optional: disable direct OpenSSH after testing Teleport access.'
  yesno 'Open OpenSSH management menu?' && ssh_menu || :
}
cleanup(){ local rc=$?; if [[ ${SSH_PENDING:-0} == 1 ]]; then ssh_restore || :; fi; if [[ ${DNS_PENDING:-0} == 1 ]]; then dns_restore || :; fi; [[ -z ${TMP:-} ]] || rm -rf "$TMP"; exit "$rc"; }
main(){
  [[ $EUID == 0 ]] || { say 'Run as root (sudo bash tp.sh).'; exit 1; }
  [[ -r /dev/tty ]] || exit 1
  mkdir -p "$STATE"; chmod 700 "$STATE"; touch "$LOG"; chmod 600 "$LOG"
  command -v flock >/dev/null || { fail "Install util-linux first."; exit 1; }
  exec 9>/run/lock/teleport-deploy.lock; flock -n 9 || { fail 'Installer already running'; exit 1; }
  TMP=$(mktemp -d); DNS_PENDING=0; SSH_PENDING=0
  trap cleanup EXIT; trap 'exit 130' INT; trap 'exit 143' TERM
  detect || exit 1
  while :; do
    say ''; say "Teleport deploy $VERSION"
    say "Last repository DNS check: $REPO_DNS_MODE"
    say '1 Install main cluster'; say '2 Install SSH agent'; say '3 Configure DNS'; say '4 Restore original DNS'
    say '5 Create administrator (main cluster)'; say '6 Generate agent token (main cluster)'; say '7 Status / repository DNS check'; say '8 OpenSSH management'; say '0 Exit'
    choice 'Select [0]:' 0 8
    case "$ANSWER" in
      0) return 0;;
      1|2|3)
        local action=$ANSWER
        if deps; then
          if [[ $PM == apt ]]; then run 'Install YAML support' apt-get install -y python3-yaml || continue; else run 'Install YAML support' dnf -y install python3-pyyaml || continue; fi
          case "$action" in 1) main_install || say 'Installation stopped; inspect log before retrying.';; 2) agent_install || say 'Installation stopped; inspect log before retrying.';; 3) dns_change || say 'DNS change unsuccessful.'; if ((DNS_PENDING)); then dns_restore || :; DNS_PENDING=0; fi;; esac
        fi;;
      4) dns_restore || :;;
      5) admin || say 'Could not create user.';;
      6) token_menu || say 'Could not create token.';;
      8) ssh_menu;;
      7) repo_probe || :; teleport version || :; systemctl status teleport --no-pager || :; journalctl -u teleport -n 15 --no-pager || :;;
    esac
  done
}
[[ ${BASH_SOURCE[0]} != "$0" ]] || main "$@"
