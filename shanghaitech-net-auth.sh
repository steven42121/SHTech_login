#!/bin/sh

SCRIPT_NAME=${0##*/}
VERSION="0.1.4"

HOME_DIR=${HOME:-.}
DEFAULT_CONFIG="./shanghaitech-net-auth.conf"
USER_CONFIG="$HOME_DIR/.config/shanghaitech-net-auth.conf"
SERVER_DEFAULT="https://10.15.145.16:19008"
FALLBACK_SERVER_DEFAULT="https://net-auth.shanghaitech.edu.cn:19008"
CHECK_URL_DEFAULT="http://www.msftconnecttest.com/connecttest.txt"
CHECK_EXPECT_DEFAULT="Microsoft Connect Test"
TIMEOUT_DEFAULT="8"
INTERVAL_DEFAULT="60"

ACTION=""
CONFIG_FILE=""
USERNAME="${SH_NETAUTH_USERNAME:-}"
PASSWORD="${SH_NETAUTH_PASSWORD:-}"
IP_ADDR="${IP_ADDR:-}"
INTERFACE="${INTERFACE:-}"
SERVER="${SERVER:-$SERVER_DEFAULT}"
FALLBACK_SERVER="${FALLBACK_SERVER:-$FALLBACK_SERVER_DEFAULT}"
AUTH_TYPE="${AUTH_TYPE:-1}"
AGREED="${AGREED:-1}"
SSID="${SSID:-}"
VALID_CODE="${VALID_CODE:-}"
ACIP="${ACIP:-}"
UMAC="${UMAC:-}"
PUSH_PAGE_ID="${PUSH_PAGE_ID:-}"
TIMEOUT="${TIMEOUT:-$TIMEOUT_DEFAULT}"
CHECK_URL="${CHECK_URL:-$CHECK_URL_DEFAULT}"
CHECK_EXPECT="${CHECK_EXPECT:-$CHECK_EXPECT_DEFAULT}"
INTERVAL="${INTERVAL:-$INTERVAL_DEFAULT}"
INSECURE_TLS="${INSECURE_TLS:-1}"
VERBOSE=0
SKIP_PREFLIGHT="${SKIP_PREFLIGHT:-0}"
AUTO_FIREWALL="${AUTO_FIREWALL:-1}"
USERNAME_FROM_CLI=0
POSITIONAL_USERNAME_USED=0

log() {
  printf '%s\n' "$*"
}

warn() {
  printf 'WARN: %s\n' "$*" >&2
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

debug() {
  if [ "$VERBOSE" -eq 1 ]; then
    printf 'DEBUG: %s\n' "$*" >&2
  fi
}

have_cmd() {
  type "$1" >/dev/null 2>&1
}

choose_python() {
  if have_cmd python3 && python3 -c 'import sys; sys.exit(0 if sys.version_info[0] >= 3 else 1)' >/dev/null 2>&1; then
    printf '%s\n' python3
    return 0
  fi
  if have_cmd python && python -c 'import sys; sys.exit(0 if sys.version_info[0] >= 3 else 1)' >/dev/null 2>&1; then
    printf '%s\n' python
    return 0
  fi
  return 1
}

usage() {
  while IFS= read -r line; do
    printf '%s\n' "$line"
  done <<EOF
Usage:
  $SCRIPT_NAME [login|status|watch|probe|doctor] [options]

Commands:
  login              Perform one campus-network login. Default command.
  status             Show detected IP, portal sync result, and external reachability.
  watch              Check connectivity every N seconds and auto-login when offline.
  probe              Probe the portal endpoint only.
  doctor             Diagnose IP, route, DNS, and portal TCP connectivity without credentials.

Options:
  -c, --config PATH        Config file path
  -u, --username USER      ShanghaiTech username / student id
  -p, --password PASS      Password
  -i, --ip IP              Local campus IP to authenticate
  -I, --interface IFACE    Detect IP from a specific interface (eth0, ens192, vmk0, ...)
  -s, --server URL         Primary portal base URL
      --fallback-server    Fallback portal base URL
      --auth-type N        Auth type, default 1
      --ssid VALUE         Optional SSID override
      --valid-code VALUE   Optional validCode override
      --acip VALUE         Optional acip override
      --umac VALUE         Optional umac override
      --check-url URL      External URL used by status/watch
      --check-expect TEXT  Expected content used by status/watch
      --interval SEC       Watch interval, default 60
  -t, --timeout SEC        HTTP timeout, default 8
      --secure-tls         Verify TLS certificate
      --skip-preflight     Skip portal TCP preflight before prompting for password
      --no-firewall        Do not auto-open local firewall for the portal port
  -v, --verbose            Verbose output
  -h, --help               Show help

Config file format:
  Plain shell variables, for example:
    USERNAME=2025xxxxxxx
    PASSWORD='your-password'
    INTERFACE=eth0
    SERVER=https://10.15.145.16:19008

Examples:
  $SCRIPT_NAME login -u 2025xxxxxxx -I eth0
  $SCRIPT_NAME login 2025xxxxxxx -I eth0
  $SCRIPT_NAME doctor -I eth0
  $SCRIPT_NAME status -c ./shanghaitech-net-auth.conf
  $SCRIPT_NAME watch -c ./shanghaitech-net-auth.conf --interval 30
EOF
}

find_config_path() {
  next_is_value=0
  for arg in "$@"; do
    if [ "$next_is_value" = "1" ]; then
      printf '%s\n' "$arg"
      return 0
    fi
    case "$arg" in
      -c|--config)
        next_is_value=1
        ;;
      --config=*)
        printf '%s\n' "${arg#*=}"
        return 0
        ;;
    esac
  done
  return 1
}

load_config() {
  if [ -n "$1" ] && [ -f "$1" ]; then
    debug "Loading config from $1"
    # shellcheck disable=SC1090
    . "$1"
  fi
}

warn_if_config_world_readable() {
  mode=""
  if [ -z "$CONFIG_FILE" ] || [ ! -f "$CONFIG_FILE" ]; then
    return 0
  fi
  if have_cmd stat; then
    mode=$(stat -c '%a' "$CONFIG_FILE" 2>/dev/null || stat -f '%Lp' "$CONFIG_FILE" 2>/dev/null)
  fi
  if [ -n "$mode" ]; then
    case "$mode" in
      *00) ;;
      *) warn "Config file permissions are broad; run: chmod 600 $CONFIG_FILE" ;;
    esac
  fi
}

python_http_request() {
  method=$1
  url=$2
  body=$3
  py=$(choose_python) || return 1

  SH_NETAUTH_METHOD=$method \
  SH_NETAUTH_URL=$url \
  SH_NETAUTH_BODY=$body \
  SH_NETAUTH_TIMEOUT=$TIMEOUT \
  SH_NETAUTH_INSECURE_TLS=$INSECURE_TLS \
  "$py" - <<'PY'
import os
import ssl
import sys
import urllib.request
import urllib.error

method = os.environ.get("SH_NETAUTH_METHOD", "GET").upper()
url = os.environ.get("SH_NETAUTH_URL", "")
body = os.environ.get("SH_NETAUTH_BODY", "")
timeout = float(os.environ.get("SH_NETAUTH_TIMEOUT", "8"))
insecure = os.environ.get("SH_NETAUTH_INSECURE_TLS", "1") == "1"

if not url:
    sys.exit(1)

data = body.encode("utf-8") if method == "POST" else None
req = urllib.request.Request(url, data=data, method=method)
if method == "POST":
    req.add_header("Content-Type", "application/x-www-form-urlencoded; charset=UTF-8")

ctx = ssl._create_unverified_context() if insecure else ssl.create_default_context()

try:
    with urllib.request.urlopen(req, timeout=timeout, context=ctx) as resp:
        payload = resp.read().decode("utf-8", "ignore")
        sys.stdout.write(payload)
except Exception as exc:
    sys.stderr.write(str(exc) + "\n")
    sys.exit(1)
PY
}

prompt_secret() {
  prompt_text=$1
  value=""
  if have_cmd stty; then
    saved_tty=$(stty -g 2>/dev/null || printf '')
    stty -echo 2>/dev/null || true
    printf '%s' "$prompt_text" >&2
    IFS= read -r value
    if [ -n "$saved_tty" ]; then
      stty "$saved_tty" 2>/dev/null || stty echo 2>/dev/null || true
    else
      stty echo 2>/dev/null || true
    fi
    printf '\n' >&2
  else
    printf '%s' "$prompt_text" >&2
    IFS= read -r value
  fi
  PASSWORD=$value
}

ensure_credentials() {
  if [ -z "$USERNAME" ]; then
    printf 'Username: ' >&2
    IFS= read -r USERNAME
  fi
  if [ -z "$PASSWORD" ]; then
    prompt_secret 'Password: '
  fi
  [ -n "$USERNAME" ] || die "Username is required"
  [ -n "$PASSWORD" ] || die "Password is required"
}

is_ipv4() {
  ip=$1
  old_ifs=$IFS
  IFS=.
  set -- $ip
  IFS=$old_ifs
  [ $# -eq 4 ] || return 1
  for octet in "$1" "$2" "$3" "$4"; do
    case $octet in
      ''|*[!0-9]*)
        return 1
        ;;
    esac
    [ "$octet" -ge 0 ] 2>/dev/null || return 1
    [ "$octet" -le 255 ] 2>/dev/null || return 1
  done
  return 0
}

detect_ip_from_ip_route() {
  target=$1
  if have_cmd ip; then
    ip route get "$target" 2>/dev/null | sed -n 's/.* src \([0-9.][0-9.]*\).*/\1/p' | sed -n '1p'
  fi
}

detect_ip_from_interface() {
  iface=$1
  detected=""
  if [ -z "$iface" ]; then
    return 1
  fi
  if have_cmd ip; then
    detected=$(ip -o -4 addr show dev "$iface" 2>/dev/null | sed -n 's/.* inet \([0-9.][0-9.]*\)\/.*/\1/p' | sed -n '1p')
    if is_ipv4 "$detected"; then
      printf '%s\n' "$detected"
      return 0
    fi
  fi
  if have_cmd ifconfig; then
    detected=$(ifconfig "$iface" 2>/dev/null | sed -n 's/.*inet \(addr:\)\{0,1\}\([0-9.][0-9.]*\).*/\2/p' | sed -n '1p')
    if is_ipv4 "$detected"; then
      printf '%s\n' "$detected"
      return 0
    fi
  fi
  if have_cmd esxcli; then
    detected=$(esxcli network ip interface ipv4 get 2>/dev/null | sed -n "/^$iface[[:space:]]/s/^[^[:space:]]*[[:space:]][[:space:]]*\([0-9.][0-9.]*\).*/\1/p" | sed -n '1p')
    if is_ipv4 "$detected"; then
      printf '%s\n' "$detected"
      return 0
    fi
  fi
  return 1
}

detect_ip_auto() {
  detected=$(detect_ip_from_ip_route 10.10.10.10)
  if is_ipv4 "$detected"; then
    printf '%s\n' "$detected"
    return 0
  fi

  detected=$(detect_ip_from_ip_route 1.1.1.1)
  if is_ipv4 "$detected"; then
    printf '%s\n' "$detected"
    return 0
  fi

  if have_cmd hostname; then
    for candidate in $(hostname -I 2>/dev/null); do
      case $candidate in
        127.*) continue ;;
      esac
      if is_ipv4 "$candidate"; then
        printf '%s\n' "$candidate"
        return 0
      fi
    done
    :
  fi

  if have_cmd ifconfig; then
    while IFS= read -r line; do
      candidate=$(printf '%s\n' "$line" | sed -n 's/.*inet \(addr:\)\{0,1\}\([0-9.][0-9.]*\).*/\2/p' | sed -n '1p')
      case $candidate in
        ''|127.*) continue ;;
      esac
      if is_ipv4 "$candidate"; then
        printf '%s\n' "$candidate"
        return 0
      fi
    done <<EOF
$(ifconfig 2>/dev/null)
EOF
  fi

  if have_cmd esxcli; then
    while IFS= read -r line; do
      candidate=$(printf '%s\n' "$line" | sed -n 's/^[^[:space:]]*[[:space:]][[:space:]]*\([0-9.][0-9.]*\).*/\1/p' | sed -n '1p')
      case $candidate in
        ''|127.*) continue ;;
      esac
      if is_ipv4 "$candidate"; then
        printf '%s\n' "$candidate"
        return 0
      fi
    done <<EOF
$(esxcli network ip interface ipv4 get 2>/dev/null)
EOF
  fi

  return 1
}

ensure_ip() {
  if is_ipv4 "$IP_ADDR"; then
    return 0
  fi
  if [ -n "$INTERFACE" ]; then
    IP_ADDR=$(detect_ip_from_interface "$INTERFACE")
  else
    IP_ADDR=$(detect_ip_auto)
  fi
  if ! is_ipv4 "$IP_ADDR"; then
    die "Could not detect a valid local IPv4 address. Use --ip or --interface."
  fi
}

urlencode() {
  input=$1
  output=""
  while [ -n "$input" ]; do
    ch=${input%"${input#?}"}
    input=${input#?}
    case "$ch" in
      [A-Za-z0-9.~_-])
        output=${output}${ch}
        ;;
      *)
        hex=$(printf '%s' "$ch" | od -An -tx1)
        hex=${hex# }
        hex=${hex%% *}
        output=${output}%${hex}
        ;;
    esac
  done
  printf '%s' "$output"
}

build_login_body() {
  body="userName=$(urlencode "$USERNAME")"
  body="${body}&userPass=$(urlencode "$PASSWORD")"
  body="${body}&authType=$(urlencode "$AUTH_TYPE")"
  body="${body}&uaddress=$(urlencode "$IP_ADDR")"
  body="${body}&agreed=$(urlencode "$AGREED")"

  if [ -n "$SSID" ]; then
    body="${body}&ssid=$(urlencode "$SSID")"
  fi
  if [ -n "$VALID_CODE" ]; then
    body="${body}&validCode=$(urlencode "$VALID_CODE")"
  fi
  if [ -n "$ACIP" ]; then
    body="${body}&acip=$(urlencode "$ACIP")"
  fi
  if [ -n "$UMAC" ]; then
    body="${body}&umac=$(urlencode "$UMAC")"
  fi
  if [ -n "$PUSH_PAGE_ID" ]; then
    body="${body}&pushPageId=$(urlencode "$PUSH_PAGE_ID")"
  fi

  printf '%s' "$body"
}

json_get_bool() {
  key=$1
  json=$2
  json=${json#*\"$key\"}
  json=${json#*:}
  json=${json#"${json%%[! ]*}"}
  case "$json" in
    true*) printf '%s\n' true ;;
    false*) printf '%s\n' false ;;
  esac
}

json_get_string() {
  key=$1
  json=$2
  json=${json#*\"$key\"}
  json=${json#*:}
  json=${json#*\"}
  printf '%s\n' "${json%%\"*}"
}

lookup_error() {
  case "$1" in
    1006) printf '%s\n' 'Logout failed or the session already expired.' ;;
    10101) printf '%s\n' 'Portal rejected the request because required fields are missing.' ;;
    10102) printf '%s\n' 'authType is invalid.' ;;
    10103) printf '%s\n' 'The supplied client IP is invalid.' ;;
    10503) printf '%s\n' 'Username or password is incorrect.' ;;
    10508) printf '%s\n' 'The account is disabled.' ;;
    10513) printf '%s\n' 'The account password is expired.' ;;
    10515) printf '%s\n' 'The access policy rejected this device.' ;;
    10516) printf '%s\n' 'Too many terminals are already logged in for this account.' ;;
    10517) printf '%s\n' 'The account is missing required access parameters.' ;;
    10518) printf '%s\n' 'The device MAC address does not match the bound policy.' ;;
    10519) printf '%s\n' 'The device IP does not match the bound policy.' ;;
    10542) printf '%s\n' 'Authentication is happening too frequently; retry later.' ;;
    10560) printf '%s\n' 'The portal reported an invalid ticket.' ;;
    10561) printf '%s\n' 'The portal session expired.' ;;
    10605|10713) printf '%s\n' 'No remaining traffic quota or session time is available.' ;;
    10711|10712) printf '%s\n' 'The number of online users for this account has reached the limit.' ;;
    10810) printf '%s\n' 'The portal reported a network error.' ;;
    20104) printf '%s\n' 'Portal authentication request timed out.' ;;
    "") return 1 ;;
    *) return 1 ;;
  esac
}

http_post() {
  url=$1
  body=$2
  if have_cmd curl; then
    curl_flags="-sS --connect-timeout $TIMEOUT --max-time $((TIMEOUT + 5))"
    if [ "$INSECURE_TLS" = "1" ]; then
      curl_flags="$curl_flags -k"
    fi
    curl $curl_flags -H "Content-Type: application/x-www-form-urlencoded; charset=UTF-8" --data "$body" "$url"
    return $?
  fi

  if choose_python >/dev/null 2>&1; then
    response=$(python_http_request POST "$url" "$body" 2>&1)
    rc=$?
    if [ "$rc" -ne 0 ]; then
      warn "HTTP POST failed: $response"
      return "$rc"
    fi
    printf '%s' "$response"
    return 0
  fi

  die "Neither curl nor Python 3 is available for HTTP POST."
}

http_get() {
  url=$1
  if have_cmd curl; then
    curl_flags="-sS --connect-timeout $TIMEOUT --max-time $((TIMEOUT + 5))"
    if [ "$INSECURE_TLS" = "1" ]; then
      curl_flags="$curl_flags -k"
    fi
    curl $curl_flags "$url"
    return $?
  fi

  if have_cmd wget; then
    wget_flags="-qO - --timeout=$TIMEOUT"
    if [ "$INSECURE_TLS" = "1" ]; then
      wget_flags="$wget_flags --no-check-certificate"
    fi
    wget $wget_flags "$url"
    return $?
  fi

  if choose_python >/dev/null 2>&1; then
    response=$(python_http_request GET "$url" "" 2>&1)
    rc=$?
    if [ "$rc" -ne 0 ]; then
      warn "HTTP GET failed: $response"
      return "$rc"
    fi
    printf '%s' "$response"
    return 0
  fi

  die "Neither curl, wget, nor Python 3 is available for HTTP GET."
}

check_online() {
  content=$(http_get "$CHECK_URL" 2>/dev/null || printf '')
  if [ -n "$CHECK_EXPECT" ]; then
    case "$content" in
      *"$CHECK_EXPECT"*)
        return 0
        ;;
      *)
        return 1
        ;;
    esac
  fi
  [ -n "$content" ]
}

extract_host_port() {
  url=$1
  rest=${url#*://}
  hostport=${rest%%/*}
  host=${hostport%%:*}
  port=${hostport#*:}
  if [ "$port" = "$hostport" ]; then
    case "$url" in
      https://*) port=443 ;;
      http://*) port=80 ;;
      *) port=443 ;;
    esac
  fi
  printf '%s %s\n' "$host" "$port"
}

esxi_firewall_ruleset_name() {
  port=$1
  printf 'shtechAuth%s\n' "$port"
}

ensure_esxi_portal_firewall() {
  base_url=$1
  have_cmd esxcli || return 0

  set -- $(extract_host_port "$base_url")
  port=$2
  case "$port" in
    ''|*[!0-9]*)
      warn "ESXi firewall setup skipped for invalid port: $port"
      return 1
      ;;
    80|443)
      return 0
      ;;
  esac

  ruleset=$(esxi_firewall_ruleset_name "$port")
  firewall_file="/etc/vmware/firewall/${ruleset}.xml"

  if ! cat > "$firewall_file" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<ConfigRoot>
  <service id='9000'>
    <id>$ruleset</id>
    <rule id='0000'>
      <direction>outbound</direction>
      <protocol>tcp</protocol>
      <porttype>dst</porttype>
      <port>$port</port>
    </rule>
    <enabled>true</enabled>
    <required>false</required>
  </service>
</ConfigRoot>
EOF
  then
    warn "Failed to write ESXi firewall service: $firewall_file"
    return 1
  fi

  chmod 644 "$firewall_file" 2>/dev/null || true

  if ! esxcli network firewall refresh >/dev/null 2>&1; then
    warn "Failed to refresh ESXi firewall after updating $ruleset"
    return 1
  fi

  esxcli network firewall ruleset set -r "$ruleset" -e true >/dev/null 2>&1 || true
  debug "ESXi firewall rule ensured: $ruleset -> tcp/$port"
  return 0
}

linux_firewall_cmd() {
  if have_cmd firewall-cmd; then
    printf '%s\n' firewalld
    return 0
  fi
  if have_cmd ufw; then
    printf '%s\n' ufw
    return 0
  fi
  if have_cmd iptables; then
    printf '%s\n' iptables
    return 0
  fi
  return 1
}

ensure_linux_portal_firewall() {
  base_url=$1
  [ "$AUTO_FIREWALL" = "1" ] || return 0
  have_cmd esxcli && return 0

  set -- $(extract_host_port "$base_url")
  port=$2
  case "$port" in
    ''|*[!0-9]*)
      return 1
      ;;
    80|443)
      return 0
      ;;
  esac

  backend=$(linux_firewall_cmd) || return 0

  case "$backend" in
    firewalld)
      if firewall-cmd --state >/dev/null 2>&1; then
        if firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null 2>&1; then
          firewall-cmd --reload >/dev/null 2>&1 || true
          debug "Linux firewall rule ensured via firewalld: tcp/$port"
        fi
      fi
      ;;
    ufw)
      if ufw status >/dev/null 2>&1; then
        if ufw allow "${port}/tcp" >/dev/null 2>&1; then
          debug "Linux firewall rule ensured via ufw: tcp/$port"
        fi
      fi
      ;;
    iptables)
      if iptables -C OUTPUT -p tcp --dport "$port" -j ACCEPT >/dev/null 2>&1; then
        return 0
      fi
      if iptables -I OUTPUT -p tcp --dport "$port" -j ACCEPT >/dev/null 2>&1; then
        debug "Linux firewall rule ensured via iptables: tcp/$port"
      fi
      ;;
  esac
}

resolve_host() {
  host=$1
  resolved=""

  if is_ipv4 "$host"; then
    printf '%s\n' "$host"
    return 0
  fi

  if have_cmd getent; then
    resolved=$(getent ahostsv4 "$host" 2>/dev/null | sed -n 's/^\([0-9.][0-9.]*\)[[:space:]].*/\1/p' | sed -n '1p')
    if is_ipv4 "$resolved"; then
      printf '%s\n' "$resolved"
      return 0
    fi
  fi

  py=$(choose_python 2>/dev/null) || return 1
  resolved=$(SH_NETAUTH_HOST="$host" "$py" - <<'PY'
import os
import socket
import sys

host = os.environ.get("SH_NETAUTH_HOST", "")
try:
    infos = socket.getaddrinfo(host, None, socket.AF_INET, socket.SOCK_STREAM)
    for info in infos:
        addr = info[4][0]
        if addr:
            print(addr)
            raise SystemExit(0)
except Exception:
    pass
sys.exit(1)
PY
)
  if is_ipv4 "$resolved"; then
    printf '%s\n' "$resolved"
    return 0
  fi

  return 1
}

tcp_check_python() {
  host=$1
  port=$2
  py=$(choose_python) || return 1
  SH_NETAUTH_HOST=$host \
  SH_NETAUTH_PORT=$port \
  SH_NETAUTH_TIMEOUT=$TIMEOUT \
  "$py" - <<'PY'
import os
import socket
import sys

host = os.environ.get("SH_NETAUTH_HOST", "")
port = int(os.environ.get("SH_NETAUTH_PORT", "0"))
timeout = float(os.environ.get("SH_NETAUTH_TIMEOUT", "8"))

try:
    with socket.create_connection((host, port), timeout=timeout):
        pass
except Exception as exc:
    sys.stderr.write(str(exc) + "\n")
    sys.exit(1)
PY
}

tcp_check() {
  host=$1
  port=$2

  if have_cmd nc; then
    nc -vz -w "$TIMEOUT" "$host" "$port" >/dev/null 2>&1
    return $?
  fi

  if have_cmd nc.openbsd; then
    nc.openbsd -vz -w "$TIMEOUT" "$host" "$port" >/dev/null 2>&1
    return $?
  fi

  if choose_python >/dev/null 2>&1; then
    tcp_check_python "$host" "$port" >/dev/null 2>&1
    return $?
  fi

  return 2
}

print_tcp_result() {
  label=$1
  base_url=$2
  set -- $(extract_host_port "$base_url")
  host=$1
  port=$2

  if tcp_check "$host" "$port"; then
    log "$label TCP:  reachable ($host:$port)"
    return 0
  fi

  rc=$?
  if [ "$rc" -eq 2 ]; then
    log "$label TCP:  unknown ($host:$port, no nc or Python 3)"
  else
    log "$label TCP:  not reachable ($host:$port)"
  fi
  return "$rc"
}

print_dns_result() {
  label=$1
  host=$2

  if resolve_host "$host" >/dev/null 2>&1; then
    log "$label DNS: resolved ($host)"
    return 0
  fi

  log "$label DNS: cannot resolve ($host)"
  return 1
}

check_portal_reachable() {
  set -- $(extract_host_port "$SERVER")
  host=$1
  port=$2

  if tcp_check "$host" "$port"; then
    return 0
  fi

  if [ "$FALLBACK_SERVER" != "$SERVER" ]; then
    set -- $(extract_host_port "$FALLBACK_SERVER")
    host=$1
    port=$2
    if ! resolve_host "$host" >/dev/null 2>&1; then
      return 1
    fi
    if tcp_check "$host" "$port"; then
      return 0
    fi
  fi

  return 1
}

print_command_output() {
  title=$1
  shift
  log ""
  log "== $title =="
  "$@" 2>&1 || true
}

probe_portal() {
  url=$1/portalauth/syncPortalResult
  http_post "$url" ""
}

perform_login_once() {
  base_url=$1
  login_url=$base_url/portalauth/login

  debug "POST $login_url"
  debug "Using IP $IP_ADDR"

  login_body=$(build_login_body)
  response=$(http_post "$login_url" "$login_body") || {
    warn "Request to $login_url failed."
    return 1
  }

  debug "Raw response: $response"

  success=$(json_get_bool success "$response")
  errorcode=$(json_get_string errorcode "$response")

  if [ "$success" = "true" ]; then
    log "Login succeeded. Authenticated IP: $IP_ADDR"
    return 0
  fi

  error_message=$(lookup_error "$errorcode" 2>/dev/null || printf '')
  if [ -n "$error_message" ]; then
    warn "$error_message (code=$errorcode)"
  elif [ -n "$errorcode" ]; then
    warn "Login failed with code=$errorcode"
  else
    warn "Login failed. Portal response: $response"
  fi
  return 1
}

perform_login() {
  ensure_ip

  if have_cmd esxcli; then
    ensure_esxi_portal_firewall "$SERVER" || true
    if [ "$FALLBACK_SERVER" != "$SERVER" ]; then
      ensure_esxi_portal_firewall "$FALLBACK_SERVER" || true
    fi
  else
    ensure_linux_portal_firewall "$SERVER" || true
    if [ "$FALLBACK_SERVER" != "$SERVER" ]; then
      ensure_linux_portal_firewall "$FALLBACK_SERVER" || true
    fi
  fi

  if [ "$SKIP_PREFLIGHT" != "1" ]; then
    if ! check_portal_reachable; then
      warn "Portal TCP preflight failed before password input."
      warn "This machine cannot reach $SERVER or $FALLBACK_SERVER on the auth port."
      warn "Fix network/routing first, or run '$SCRIPT_NAME doctor -I ${INTERFACE:-IFACE}' for details."
      return 1
    fi
  fi

  ensure_credentials

  if perform_login_once "$SERVER"; then
    return 0
  fi

  if [ "$FALLBACK_SERVER" != "$SERVER" ]; then
    set -- $(extract_host_port "$FALLBACK_SERVER")
    fallback_host=$1
    if resolve_host "$fallback_host" >/dev/null 2>&1; then
      warn "Retrying with fallback portal: $FALLBACK_SERVER"
      perform_login_once "$FALLBACK_SERVER"
      return $?
    fi
    warn "Skipping fallback portal because DNS cannot resolve: $fallback_host"
  fi

  return 1
}

perform_status() {
  ensure_ip
  log "Detected IP: $IP_ADDR"
  log "Portal:      $SERVER"
  print_tcp_result "Portal" "$SERVER" || true
  if [ "$FALLBACK_SERVER" != "$SERVER" ]; then
    print_tcp_result "Fallback" "$FALLBACK_SERVER" || true
    set -- $(extract_host_port "$FALLBACK_SERVER")
    print_dns_result "Fallback host" "$1" || true
  fi

  portal_response=$(probe_portal "$SERVER" || printf '')
  if [ -n "$portal_response" ]; then
    portal_success=$(json_get_bool success "$portal_response")
    portal_error=$(json_get_string errorcode "$portal_response")
    log "Portal sync: success=${portal_success:-unknown} code=${portal_error:-none}"
  else
    log "Portal sync: request failed"
  fi

  if check_online; then
    log "Internet:    reachable"
  else
    log "Internet:    not reachable"
  fi
}

perform_probe() {
  log "Portal: $SERVER"
  response=$(probe_portal "$SERVER" || printf '')
  if [ -z "$response" ]; then
    die "Probe failed."
  fi
  log "$response"
}

perform_doctor() {
  ensure_ip
  if have_cmd esxcli; then
    ensure_esxi_portal_firewall "$SERVER" || true
    if [ "$FALLBACK_SERVER" != "$SERVER" ]; then
      ensure_esxi_portal_firewall "$FALLBACK_SERVER" || true
    fi
  else
    ensure_linux_portal_firewall "$SERVER" || true
    if [ "$FALLBACK_SERVER" != "$SERVER" ]; then
      ensure_linux_portal_firewall "$FALLBACK_SERVER" || true
    fi
  fi
  log "ShanghaiTech network auth doctor"
  log "Version:     $VERSION"
  log "Detected IP: $IP_ADDR"
  if [ -n "$INTERFACE" ]; then
    log "Interface:   $INTERFACE"
  fi
  log "Portal:      $SERVER"
  log "Fallback:    $FALLBACK_SERVER"
  log "Timeout:     ${TIMEOUT}s"
  log ""
  print_tcp_result "Portal" "$SERVER" || true
  if [ "$FALLBACK_SERVER" != "$SERVER" ]; then
    print_tcp_result "Fallback" "$FALLBACK_SERVER" || true
    set -- $(extract_host_port "$FALLBACK_SERVER")
    print_dns_result "Fallback host" "$1" || true
  fi
  print_tcp_result "Redirect probe" "http://10.10.10.10:80" || true

  if check_online; then
    log "Internet:    reachable"
  else
    log "Internet:    not reachable through $CHECK_URL"
  fi

  if have_cmd esxcli; then
    print_command_output "ESXi IPv4 interfaces" esxcli network ip interface ipv4 get
    print_command_output "ESXi IPv4 routes" esxcli network ip route ipv4 list
    print_command_output "ESXi DNS servers" esxcli network ip dns server list
  else
    if have_cmd ip; then
      print_command_output "ip addr" ip -4 addr
      print_command_output "ip route" ip route
    fi
    if have_cmd ifconfig; then
      print_command_output "ifconfig" ifconfig
    fi
  fi

  log ""
  if check_portal_reachable; then
    log "Result: portal auth backend is reachable from this machine."
  else
    warn "Result: portal auth backend is NOT reachable from this machine."
    warn "On your Windows host the backend is reachable from campus IP 10.19.73.3."
    warn "If this host only has 192.168.x.x, it is probably behind a NAT/management network that cannot reach the campus auth backend."
  fi
}

perform_watch() {
  ensure_credentials
  ensure_ip
  log "Watching connectivity every ${INTERVAL}s"
  log "Detected IP: $IP_ADDR"

  while :; do
    timestamp=$(date '+%F %T' 2>/dev/null || printf 'now')
    if check_online; then
      log "[$timestamp] Internet reachable"
    else
      warn "[$timestamp] Internet unreachable, trying campus login..."
      perform_login || warn "[$timestamp] Login attempt failed."
    fi
    sleep "$INTERVAL"
  done
}

apply_arguments() {
  while [ $# -gt 0 ]; do
    case "$1" in
      login|status|watch|probe)
        ACTION=$1
        shift
        ;;
      doctor)
        ACTION=$1
        shift
        ;;
      -c|--config)
        CONFIG_FILE=$2
        shift 2
        ;;
      --config=*)
        CONFIG_FILE=${1#*=}
        shift
        ;;
      -u|--username)
        USERNAME=$2
        USERNAME_FROM_CLI=1
        shift 2
        ;;
      -p|--password)
        PASSWORD=$2
        shift 2
        ;;
      -i|--ip)
        IP_ADDR=$2
        shift 2
        ;;
      -I|--interface)
        INTERFACE=$2
        shift 2
        ;;
      -s|--server)
        SERVER=$2
        shift 2
        ;;
      --fallback-server)
        FALLBACK_SERVER=$2
        shift 2
        ;;
      --auth-type)
        AUTH_TYPE=$2
        shift 2
        ;;
      --ssid)
        SSID=$2
        shift 2
        ;;
      --valid-code)
        VALID_CODE=$2
        shift 2
        ;;
      --acip)
        ACIP=$2
        shift 2
        ;;
      --umac)
        UMAC=$2
        shift 2
        ;;
      --check-url)
        CHECK_URL=$2
        shift 2
        ;;
      --check-expect)
        CHECK_EXPECT=$2
        shift 2
        ;;
      --interval)
        INTERVAL=$2
        shift 2
        ;;
      -t|--timeout)
        TIMEOUT=$2
        shift 2
        ;;
      --secure-tls)
        INSECURE_TLS=0
        shift
        ;;
      --skip-preflight)
        SKIP_PREFLIGHT=1
        shift
        ;;
      --no-firewall)
        AUTO_FIREWALL=0
        shift
        ;;
      -v|--verbose)
        VERBOSE=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      -*)
        die "Unknown argument: $1"
        ;;
      *)
        if [ -z "$ACTION" ]; then
          ACTION="login"
        fi
        if [ "$ACTION" = "login" ] && [ "$POSITIONAL_USERNAME_USED" -eq 0 ] && [ "$USERNAME_FROM_CLI" -eq 0 ]; then
          USERNAME=$1
          USERNAME_FROM_CLI=1
          POSITIONAL_USERNAME_USED=1
          shift
          continue
        fi
        die "Unknown argument: $1"
        ;;
    esac
  done
}

pre_config=$(find_config_path "$@" 2>/dev/null || printf '')
if [ -n "$pre_config" ]; then
  CONFIG_FILE=$pre_config
elif [ -f "$DEFAULT_CONFIG" ]; then
  CONFIG_FILE=$DEFAULT_CONFIG
elif [ -f "$USER_CONFIG" ]; then
  CONFIG_FILE=$USER_CONFIG
fi

if [ -n "$CONFIG_FILE" ] && [ -f "$CONFIG_FILE" ]; then
  load_config "$CONFIG_FILE"
fi

apply_arguments "$@"
warn_if_config_world_readable

if [ -z "$ACTION" ]; then
  ACTION="login"
fi

case "$ACTION" in
  login)
    perform_login
    ;;
  status)
    perform_status
    ;;
  watch)
    perform_watch
    ;;
  probe)
    perform_probe
    ;;
  doctor)
    perform_doctor
    ;;
  *)
    usage
    exit 1
    ;;
esac
