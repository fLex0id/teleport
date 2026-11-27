#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
source ./deploy-teleport.sh
count=0
ok(){ count=$((count+1)); printf 'PASS %s\n' "$1"; }
accept(){ local fn=$1 value=$2; "$fn" "$value" || { echo "Unexpected rejection: $value"; exit 1; }; ok "$fn accepts $value"; }
reject(){ local fn=$1 value=$2; if "$fn" "$value"; then echo "Unexpected acceptance: $value"; exit 1; fi; ok "$fn rejects $value"; }
for d in teleport.example.com a.b example.co.uk a-1.example.com; do accept domain_ok "$d"; done
for d in '' localhost 'https://example.com' 'example.com:443' 'a..b' '-a.example.com' 'a-.example.com' 'a.example.com/path' 'a.example.com;id'; do reject domain_ok "$d"; done
for a in 0.0.0.0 9.9.9.9 255.255.255.255 149.112.112.112; do accept ip_ok "$a"; done
for a in '' 256.1.1.1 1.2.3 1.2.3.4.5 1.2.3.-1 '1.2.3.4;id'; do reject ip_ok "$a"; done
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
LOG=$scratch/log
run 'Success status' true; ok 'run preserves successful status'
if run 'Failure status' false; then exit 1; fi; ok 'run preserves failed status'
responses=(bad 8 2); idx=0
ask(){ ANSWER=${responses[idx]}; idx=$((idx+1)); }
choice 'menu' 0 7
[[ $ANSWER == 2 && $idx == 3 ]]; ok 'invalid menu input retries'
responses=(''); idx=0
choice 'menu' 3 7
[[ $ANSWER == 3 ]]; ok 'empty menu input uses default'
responses=(bad yes); idx=0
yesno 'confirmation'; [[ $idx == 2 ]]; ok 'invalid confirmation retries'
responses=(''); idx=0
if yesno 'confirmation'; then exit 1; fi; ok 'confirmation defaults to no'
stamp=$(dns_stamp 9.9.9.9 dns.quad9.net /dns-query)
python3 - "$stamp" <<'PY'
import base64,sys,struct
s=sys.argv[1].removeprefix('sdns://')
b=base64.urlsafe_b64decode(s+'='*(-len(s)%4))
assert b[0]==2 and struct.unpack('<Q',b[1:9])[0]==0
i=9
def field():
    global i
    n=b[i];i+=1
    v=b[i:i+n];i+=n
    return v
assert field()==b'9.9.9.9'
assert b[i]==0;i+=1
assert field()==b'dns.quad9.net'
assert field()==b'/dns-query'
assert i==len(b)
PY
ok 'DoH stamp binary layout'
CONF=$scratch/existing.yaml
touch "$CONF"
if existing_guard; then exit 1; fi
ok 'existing configuration protected'
# Mock network calls; no live DNS, root privileges or host modifications.
calls=$scratch/calls
TMP=$scratch
MODE=normal
curl(){
  printf '%s\n' "$*" >>"$calls"
  case "$MODE" in
    normal) return 0;;
    tls) return 60;;
    dns)
      case "$*" in *--resolve*185.199.109.153*) return 0;; *--resolve*) return 7;; *) return 6;; esac;;
    dead) case "$*" in *--resolve*) return 7;; *) return 6;; esac;;
    dynamic) case "$*" in *--resolve*192.0.2.10*) return 0;; *--resolve*) return 7;; *) return 6;; esac;;
  esac
}
dig(){ if [[ $MODE == dynamic ]]; then printf '%s\n' 'not-an-ip' '192.0.2.10'; fi; }
: >"$calls"
repo_probe
[[ -z $REPO_FALLBACK_IP && $(wc -l <"$calls") == 1 ]]
if grep -q -- --resolve "$calls"; then echo 'Negative assertion failed' >&2; exit 1; fi
[[ $REPO_DNS_MODE == NORMAL* ]]
grep -q 'Repository access: NORMAL' "$LOG"
ok 'normal DNS never uses fallback'
: >"$calls"; MODE=tls
if repo_probe; then exit 1; fi
[[ -z $REPO_FALLBACK_IP && $(wc -l <"$calls") == 1 ]]
[[ $REPO_DNS_MODE == FAILED*'emergency fallback not used.' ]]
ok 'TLS errors never trigger fallback'
: >"$calls"; MODE=dns
repo_probe
[[ $REPO_FALLBACK_IP == 185.199.109.153 ]]
grep -q -- '185.199.108.153' "$calls"
[[ $REPO_DNS_MODE == 'EMERGENCY - static GitHub Pages IP; verified HTTPS to 185.199.109.153.' ]]
grep -q 'Repository access: EMERGENCY - static GitHub Pages IP' "$LOG"
ok 'DNS failure tries another documented Pages address'
repo_fetch "$BASE/install-repo.sh" "$scratch/download"
grep -q -- "--resolve $REPO_HOST:443:185.199.109.153" "$calls"
ok 'fallback applies only to repository fetch'
if repo_fetch 'https://example.com/file' "$scratch/download"; then exit 1; fi
ok 'fallback rejects unrelated domains'
MODE=dead
if repo_probe; then exit 1; fi
[[ -z $REPO_FALLBACK_IP ]]
[[ $REPO_DNS_MODE == FAILED* ]]
ok 'all failed addresses stop safely'
MODE=dynamic
repo_probe
[[ $REPO_FALLBACK_IP == 192.0.2.10 ]]
[[ $REPO_DNS_MODE == 'EMERGENCY - alternate DNS 9.9.9.9; verified HTTPS to 192.0.2.10.' ]]
grep -q 'Repository access: EMERGENCY - alternate DNS' "$LOG"
ok 'alternate DNS result tried before static addresses'
MODE=normal
repo_probe
[[ -z $REPO_FALLBACK_IP ]]
ok 'normal DNS recovery clears fallback'
repo_run true
if repo_run false; then exit 1; fi
ok 'normal package execution preserves command result'
# The DNS menu never calls repo_probe/repo_fetch and DNS tests remain real NSS tests.
declare -f dns_change dns_test dns_restore >"$scratch/dns-functions"
if grep -Eq 'repo_probe|repo_fetch|repo_run|--resolve' "$scratch/dns-functions"; then exit 1; fi
ok 'DNS management is independent of repository fallback'


# OpenSSH tests: all system commands mocked; use only scratch state.
STATE=$scratch/state
mkdir -p "$STATE"
SSH_PENDING=0
ssh_ready(){ return 0; }
ssh_units(){ printf '%s\n' ssh.socket ssh.service; }
ssh_ports(){ printf '%s\n' 22 2222; }
ask(){ ANSWER=y; }
ss(){ :; }
systemctl(){
  printf '%s\n' "$*" >>"$scratch/systemctl"
  case "$1" in
    is-enabled) if [[ -f "$scratch/masked-$2" ]]; then echo masked; else echo enabled; fi;;
    is-active) if [[ $2 == --quiet && $3 == firewalld ]]; then return 1; else echo active; fi;;
    mask) touch "$scratch/masked-$2";;
    unmask) rm -f "$scratch/masked-$2";;
    *) :;;
  esac
}
ufw(){ if [[ $1 == status ]]; then echo 'Status: inactive'; else return 1; fi; }
ssh_lockdown
[[ $SSH_PENDING == 0 && -f $(ssh_state)/units ]]
grep -Fqx 'stop ssh.socket' "$scratch/systemctl"
grep -Fqx 'mask ssh.service' "$scratch/systemctl"
ok 'OpenSSH socket and service disabled'
ssh_restore
[[ ! -e $(ssh_state) ]]
grep -Fqx 'unmask ssh.service' "$scratch/systemctl"
grep -Fqx 'start ssh.socket' "$scratch/systemctl"
ok 'OpenSSH original service state restored'
ssh_ports(){ printf '%s\n' 443; }
if ssh_lockdown; then exit 1; fi
[[ ! -e $(ssh_state) ]]
ok 'Teleport port overlap rejected'
ssh_ports(){ printf '%s\n' 22; }
ssh_ready(){ return 1; }
if ssh_lockdown; then exit 1; fi
[[ ! -e $(ssh_state) ]]
ok 'OpenSSH changes blocked without access confirmation'

# Managed UFW blocks preserve existing rules and later administrator edits.
rules=$scratch/before.rules
cat >"$rules" <<'RULES'
*filter
:ufw-before-input - [0:0]
-A ufw-before-input -p tcp -m tcp --dport 22 -j ACCEPT
COMMIT
RULES
cp "$rules" "$scratch/original"
ufw_edit add "$rules" ufw-before-input 22 2222
grep -Fq -- '-A ufw-before-input -p tcp -m tcp --dport 22 -m conntrack --ctstate NEW -m comment --comment teleport-deploy-openssh -j DROP' "$rules"
[[ $(grep -m1 '^-A ' "$rules") == *'-j DROP' ]]
ok 'UFW blocks precede allow rules'
sed -i '/^# END TELEPORT-DEPLOY OPENSSH/i -A ufw-before-input -p tcp --dport 80 -j ACCEPT' "$rules"
ufw_edit remove "$rules" unused
grep -Fq -- '--dport 80 -j ACCEPT' "$rules"
grep -Fq -- '--dport 22 -j ACCEPT' "$rules"
if grep -q 'TELEPORT-DEPLOY' "$rules"; then echo 'Negative assertion failed' >&2; exit 1; fi
ufw_edit remove "$rules" unused
ok 'UFW restore preserves original and newly added rules; repeat is safe'
ufw_edit add "$rules" ufw-before-input 22
sed -i 's/ -m conntrack --ctstate NEW -m comment/ -m comment/' "$rules"
ufw_edit remove "$rules" unused
if grep -q 'teleport-deploy-openssh' "$rules"; then echo 'Legacy rule remains' >&2; exit 1; fi
ok 'UFW restore removes legacy 2.2.2 blocks'
mock_iptables(){ printf '%s\n' '-N ufw-before-input' '-A ufw-before-input -p tcp -m tcp --dport 22 -m conntrack --ctstate NEW -m comment --comment teleport-deploy-openssh -j DROP' '-A ufw-before-input -p tcp -m tcp --dport 2222 -m conntrack --ctstate NEW -m comment --comment teleport-deploy-openssh -j DROP'; }
ufw_verify_chain mock_iptables ufw-before-input 22 2222
if ufw_verify_chain mock_iptables ufw-before-input 2222; then exit 1; fi
ok 'UFW verifies actual rule ordering'
CONF=$scratch/missing.yaml
deployment_begin agent old.example.com
deployment_prepare agent new.example.com
grep -Fxq new.example.com "$STATE/deployment.pending"
touch "$CONF"
if deployment_prepare agent other.example.com; then exit 1; fi
rm -f "$CONF" "$STATE/deployment.pending"
ok 'pending endpoint can change only before config exists'
sleep(){ :; }
timeout(){ shift; "$@"; }
teleport(){ printf '%s\n' 'not ready (PID:1234): starting' >&2; return 1; }
if wait_agent; then exit 1; fi
teleport(){ printf '%s\n' 'ready (PID:1234)'; return 0; }
wait_agent
ok 'agent requires confirmed heartbeat, not merely active systemd'
grep -q 'Refresh APT for DoH' <<<"$(declare -f dns_change)"
ok 'DoH refreshes APT indexes even with dig installed'
printf '%s tests passed\n' "$count"
