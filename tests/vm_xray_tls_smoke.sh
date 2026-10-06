set -euo pipefail
CLI=/usr/local/bin/vpn-cli
user=codextls$(openssl rand -hex 4)
tmp=/run/vpn/tls-smoke-$user
mkdir -m 700 "$tmp"
client_pid=
http_pid=
cleanup(){ [[ -z "$client_pid" ]] || kill "$client_pid" 2>/dev/null || true; [[ -z "$http_pid" ]] || kill "$http_pid" 2>/dev/null || true; "$CLI" delete --service vmess --user "$user" >/dev/null 2>&1 || true; rm -rf "$tmp"; }
trap cleanup EXIT
result=$("$CLI" create --service vmess --user "$user" --days 1)
uuid=$(printf '%s' "$result" | jq -r '.data.meta.uuid')
python3 -m http.server 18081 --bind 127.0.0.1 >"$tmp/http.log" 2>&1 & http_pid=$!
TLS_TEST_UUID="$uuid" TLS_TEST_HOST=vm1.brutalx.my.id python3 - "$tmp/client.json" <<'PY'
import json,os,sys
config={"log":{"loglevel":"error"},"inbounds":[{"listen":"127.0.0.1","port":18089,"protocol":"socks","settings":{"auth":"noauth","udp":False}}],"outbounds":[{"protocol":"vmess","settings":{"vnext":[{"address":"127.0.0.1","port":443,"users":[{"id":os.environ['TLS_TEST_UUID'],"alterId":0,"security":"auto"}]}]},"streamSettings":{"network":"ws","security":"tls","tlsSettings":{"serverName":os.environ['TLS_TEST_HOST']},"wsSettings":{"path":"/vmess"}}}]}
with open(sys.argv[1],'w') as f: json.dump(config,f)
PY
/usr/local/bin/xray run -config "$tmp/client.json" >"$tmp/xray.log" 2>&1 & client_pid=$!
for i in $(seq 1 15); do
 code=$(curl --silent --show-error --max-time 3 --socks5-hostname 127.0.0.1:18089 -o /dev/null -w '%{http_code}' http://127.0.0.1:18081/ 2>/dev/null || true)
 if [[ "$code" == 200 ]]; then echo 'TLS VMess WebSocket route test passed (valid HTTPS SNI/certificate and HTTP 200 through proxy).'; exit 0; fi
 sleep 1
done
echo "TLS VMess route failed (last HTTP status $code)" >&2; tail -15 "$tmp/xray.log" >&2; exit 1
