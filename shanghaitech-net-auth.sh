#!/bin/sh

SCRIPT_NAME=${0##*/}
VERSION="0.1.0"

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
USERNAME="${USERNAME:-}"
PASSWORD="${PASSWORD:-}"
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
  command -v "$1" >/dev/null 2>&1
}

usage() {
  cat <<EOF
Usage:
  $SCRIPT_NAME [login|status|watch|probe] [options]

Commands:
  login              Perform one campus-network login. Default command.
  status             Show detected IP, portal sync result, and external reachability.
  watch              Check connectivity every N seconds and auto-login when offline.
  probe              Probe the portal endpoint only.

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
    group_perm=$(printf '%s' "$mode" | awk '{print substr($0, length($0)-1, 1)}')
    other_perm=$(printf '%s' "$mode" | awk '{print substr($0, length($0), 1)}')
    if [ "$group_perm" != "0" ] || [ "$other_perm" != "0" ]; then
      warn "Config file permissions are broad; run: chmod 600 $CONFIG_FILE"
    fi
  fi
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
  printf '%s\n' "$1" | awk -F. '
    NF != 4 { ok = 0; exit }
    BEGIN { ok = 1 }
    {
      for (i = 1; i <= 4; i++) {
        if ($i !~ /^[0-9]+$/ || $i < 0 || $i > 255) {
          ok = 0
          exit
        }
      }
    }
    END {
      if (ok == 1) {
        exit 0
      }
      exit 1
    }
  ' >/dev/null 2>&1
}

detect_ip_from_ip_route() {
  target=$1
  if have_cmd ip; then
    ip route get "$target" 2>/dev/null | awk '
      /src/ {
        for (i = 1; i <= NF; i++) {
          if ($i == "src") {
            print $(i + 1)
            exit
          }
        }
      }
    '
  fi
}

detect_ip_from_interface() {
  iface=$1
  detected=""
  if [ -z "$iface" ]; then
    return 1
  fi
  if have_cmd ip; then
    detected=$(ip -o -4 addr show dev "$iface" 2>/dev/null | awk '{split($4, a, "/"); print a[1]; exit}')
    if is_ipv4 "$detected"; then
      printf '%s\n' "$detected"
      return 0
    fi
  fi
  if have_cmd ifconfig; then
    detected=$(ifconfig "$iface" 2>/dev/null | awk '
      /inet / {
        for (i = 1; i <= NF; i++) {
          if ($i == "inet") {
            print $(i + 1)
            exit
          }
          if ($i ~ /^addr:/) {
            sub(/^addr:/, "", $i)
            print $i
            exit
          }
        }
      }
    ')
    if is_ipv4 "$detected"; then
      printf '%s\n' "$detected"
      return 0
    fi
  fi
  if have_cmd esxcli; then
    detected=$(esxcli network ip interface ipv4 get 2>/dev/null | awk -v iface="$iface" '
      $1 == iface && $2 ~ /^[0-9]+\./ {
        print $2
        exit
      }
    ')
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
    detected=$(hostname -I 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i !~ /^127\./) {print $i; exit}}')
    if is_ipv4 "$detected"; then
      printf '%s\n' "$detected"
      return 0
    fi
  fi

  if have_cmd ifconfig; then
    detected=$(ifconfig 2>/dev/null | awk '
      /inet / {
        ip = ""
        for (i = 1; i <= NF; i++) {
          if ($i == "inet") {
            ip = $(i + 1)
          } else if ($i ~ /^addr:/) {
            sub(/^addr:/, "", $i)
            ip = $i
          }
        }
        if (ip != "" && ip !~ /^127\./) {
          print ip
          exit
        }
      }
    ')
    if is_ipv4 "$detected"; then
      printf '%s\n' "$detected"
      return 0
    fi
  fi

  if have_cmd esxcli; then
    detected=$(esxcli network ip interface ipv4 get 2>/dev/null | awk '
      NR > 1 && $2 ~ /^[0-9]+\./ && $2 != "127.0.0.1" {
        print $2
        exit
      }
    ')
    if is_ipv4 "$detected"; then
      printf '%s\n' "$detected"
      return 0
    fi
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
    ch=$(printf '%s' "$input" | cut -c1)
    input=$(printf '%s' "$input" | cut -c2-)
    case "$ch" in
      [A-Za-z0-9.~_-])
        output=${output}${ch}
        ;;
      *)
        hex=$(printf '%s' "$ch" | od -An -tx1 | tr -d ' \n' | tr '[:lower:]' '[:upper:]')
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
  printf '%s' "$2" | sed -n "s/.*\"$key\"[[:space:]]*:[[:space:]]*\\(true\\|false\\).*/\\1/p" | head -n 1
}

json_get_string() {
  key=$1
  printf '%s' "$2" | sed -n "s/.*\"$key\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" | head -n 1
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

  if have_cmd wget; then
    wget_flags="-qO - --timeout=$TIMEOUT"
    if [ "$INSECURE_TLS" = "1" ]; then
      wget_flags="$wget_flags --no-check-certificate"
    fi
    wget $wget_flags --header="Content-Type: application/x-www-form-urlencoded; charset=UTF-8" --post-data="$body" "$url"
    return $?
  fi

  die "Neither curl nor wget is available."
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

  die "Neither curl nor wget is available."
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

probe_portal() {
  url=$1/portalauth/syncPortalResult
  http_post "$url" ""
}

perform_login_once() {
  base_url=$1
  login_body=$(build_login_body)
  login_url=$base_url/portalauth/login

  debug "POST $login_url"
  debug "Using IP $IP_ADDR"

  response=$(http_post "$login_url" "$login_body" 2>/dev/null) || {
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
  ensure_credentials
  ensure_ip

  if perform_login_once "$SERVER"; then
    return 0
  fi

  if [ "$FALLBACK_SERVER" != "$SERVER" ]; then
    warn "Retrying with fallback portal: $FALLBACK_SERVER"
    perform_login_once "$FALLBACK_SERVER"
    return $?
  fi

  return 1
}

perform_status() {
  ensure_ip
  log "Detected IP: $IP_ADDR"
  log "Portal:      $SERVER"

  portal_response=$(probe_portal "$SERVER" 2>/dev/null || printf '')
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
  response=$(probe_portal "$SERVER" 2>/dev/null || printf '')
  if [ -z "$response" ]; then
    die "Probe failed."
  fi
  log "$response"
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
      -v|--verbose)
        VERBOSE=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
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
  *)
    usage
    exit 1
    ;;
esac
