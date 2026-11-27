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
! grep -q -- --resolve "$calls"
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

printf '%s tests passed\n' "$count"
