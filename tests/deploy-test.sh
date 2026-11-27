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
printf '%s tests passed\n' "$count"
