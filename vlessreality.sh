#!/usr/bin/env bash
set -euo pipefail

COMMAND="deploy"
CLI_TAG_SET=0
CLI_SERVER_SET=0
CLI_SERVER_PORT_SET=0
CLI_SNI_SET=0
CLI_HANDSHAKE_SERVER_SET=0
CLI_HANDSHAKE_PORT_SET=0
CLI_FLOW_SET=0
CLI_FINGERPRINT_SET=0
CLI_UUID_SET=0
CLI_SHORT_ID_SET=0
CLI_PRIVATE_KEY_SET=0
CLI_PUBLIC_KEY_SET=0
TAG="${TAG:-}"
SERVER="${SERVER:-}"
SERVER_PORT="${SERVER_PORT:-443}"
SNI="${SNI:-}"
HANDSHAKE_SERVER="${HANDSHAKE_SERVER:-}"
HANDSHAKE_PORT="${HANDSHAKE_PORT:-443}"
FLOW="${FLOW:-xtls-rprx-vision}"
FINGERPRINT="${FINGERPRINT:-chrome}"
UUID="${UUID:-}"
SHORT_ID="${SHORT_ID:-}"
PRIVATE_KEY="${PRIVATE_KEY:-}"
PUBLIC_KEY="${PUBLIC_KEY:-}"
AUTO_INSTALL="${AUTO_INSTALL:-1}"
JSON_ONLY=0

CONFIG_DIR="${CONFIG_DIR:-/etc/sing-box}"
CONFIG_PATH="${CONFIG_PATH:-$CONFIG_DIR/config.json}"
STATE_PATH="${STATE_PATH:-$CONFIG_DIR/vless-reality.env}"
SERVICE_PATH="${SERVICE_PATH:-/etc/systemd/system/sing-box.service}"
BIN_PATH="${BIN_PATH:-/usr/local/bin/sing-box}"
LATEST_JSON_URL="${LATEST_JSON_URL:-https://github.com/SagerNet/sing-box/releases/latest/download/latest.json}"
GITHUB_RELEASE_API="${GITHUB_RELEASE_API:-https://api.github.com/repos/SagerNet/sing-box/releases/latest}"
BBR_SYSCTL_PATH="${BBR_SYSCTL_PATH:-/etc/sysctl.d/99-vless-reality-bbr.conf}"

domains=(
    tag.demandbase.com
    ms-python.gallerycdn.vsassets.io
    ipv6.6sc.co
    download.amd.com
    a0.awsstatic.com
    s0.awsstatic.com
    cdn.userway.org
    assets-www.xbox.com
    www.icloud.com
    apps.apple.com
    d3agakyjgjv5i8.cloudfront.net
    aadcdn.msftauth.net
    devblogs.microsoft.com
    rum.hlx.page
    www.sony.com
    intelcorp.scene7.com
    iosapps.itunes.apple.com
    beacon.gtv-pub.com
    gray.video-player.arcpublishing.com
    ds-aksb-a.akamaihd.net
    se-edge.itunes.apple.com
    res-1.cdn.office.net
    prod.us-east-1.ui.gcr-chat.marketing.aws.dev
    downloadmirror.intel.com
    azure.microsoft.com
    s.go-mpulse.net
    static.cloud.coveo.com
    consent.trustarc.com
    logx.optimizely.com
    www.bing.com
    amd.com
)

usage() {
  cat <<'EOF'
Usage:
  ./vlessreality.sh [deploy] [options]
  ./vlessreality.sh update [options]
  ./vlessreality.sh outbound [options]
  ./vlessreality.sh status

Commands:
  deploy      Install/update sing-box, enable BBR, write server config, start service, print outbound. Default.
  update      Download the latest sing-box binary and restart the existing service.
  outbound    Print the sing-box outbound from saved/generated values only.
  status      Show sing-box service status and saved outbound values.

Options:
  --server <host>           Client-facing server address. Default: auto-detected public IP.
  --port <port>             VLESS server port. Default: 443. Interactive deploy prompts when omitted.
  --uuid <uuid>             Reuse an existing VLESS UUID.
  --short-id <hex>          Reuse an existing Reality short_id.
  --private-key <key>       Reuse an existing Reality private key.
  --public-key <key>        Reuse an existing Reality public key.
  --tag <tag>               Override generated outbound tag.
  --flow <flow>             VLESS flow. Default: xtls-rprx-vision.
  --fingerprint <name>      uTLS fingerprint. Default: chrome.
  --sni <host>              Reality SNI. Default: fastest host from domains array.
  --handshake-server <host> Reality server-side handshake host. Default: fastest host from domains array.
  --handshake-port <port>   Reality server-side handshake port. Default: 443.
  --config <path>           sing-box config path. Default: /etc/sing-box/config.json.
  --state <path>            Saved generated values path. Default: /etc/sing-box/vless-reality.env.
  --bin <path>              sing-box binary path. Default: /usr/local/bin/sing-box.
  --no-install              Do not install missing system packages automatically.
  --json-only               Print only the outbound JSON object.
  -h, --help                Show this help.

Environment variables with the same uppercase names can also be used.
EOF
}

log_line() {
  local level="$1"
  shift
  printf '[%s] %s\n' "$level" "$*" >&2
}

log() {
  log_line INFO "$@"
}

log_warn() {
  log_line WARN "$@"
}

log_error() {
  log_line ERROR "$@"
}

need_value() {
  local option="$1"
  local value="${2:-}"
  if [[ -z "$value" ]]; then
    printf 'Missing value for %s\n' "$option" >&2
    exit 2
  fi
}

pick_command() {
  if [[ $# -gt 0 ]]; then
    case "$1" in
      deploy|install|update|outbound|status)
        COMMAND="$1"
        [[ "$COMMAND" == "install" ]] && COMMAND="deploy"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
    esac
  fi
  REMAINING_ARGS=("$@")
}

parse_options() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --server)
        need_value "$1" "${2:-}"
        SERVER="$2"
        CLI_SERVER_SET=1
        shift 2
        ;;
      --port)
        need_value "$1" "${2:-}"
        SERVER_PORT="$2"
        CLI_SERVER_PORT_SET=1
        shift 2
        ;;
      --uuid)
        need_value "$1" "${2:-}"
        UUID="$2"
        CLI_UUID_SET=1
        shift 2
        ;;
      --short-id)
        need_value "$1" "${2:-}"
        SHORT_ID="$2"
        CLI_SHORT_ID_SET=1
        shift 2
        ;;
      --private-key)
        need_value "$1" "${2:-}"
        PRIVATE_KEY="$2"
        CLI_PRIVATE_KEY_SET=1
        shift 2
        ;;
      --public-key)
        need_value "$1" "${2:-}"
        PUBLIC_KEY="$2"
        CLI_PUBLIC_KEY_SET=1
        shift 2
        ;;
      --tag)
        need_value "$1" "${2:-}"
        TAG="$2"
        CLI_TAG_SET=1
        shift 2
        ;;
      --flow)
        need_value "$1" "${2:-}"
        FLOW="$2"
        CLI_FLOW_SET=1
        shift 2
        ;;
      --fingerprint)
        need_value "$1" "${2:-}"
        FINGERPRINT="$2"
        CLI_FINGERPRINT_SET=1
        shift 2
        ;;
      --sni)
        need_value "$1" "${2:-}"
        SNI="$2"
        CLI_SNI_SET=1
        shift 2
        ;;
      --handshake-server)
        need_value "$1" "${2:-}"
        HANDSHAKE_SERVER="$2"
        CLI_HANDSHAKE_SERVER_SET=1
        shift 2
        ;;
      --handshake-port)
        need_value "$1" "${2:-}"
        HANDSHAKE_PORT="$2"
        CLI_HANDSHAKE_PORT_SET=1
        shift 2
        ;;
      --config)
        need_value "$1" "${2:-}"
        CONFIG_PATH="$2"
        CONFIG_DIR="$(dirname "$CONFIG_PATH")"
        shift 2
        ;;
      --state)
        need_value "$1" "${2:-}"
        STATE_PATH="$2"
        shift 2
        ;;
      --bin)
        need_value "$1" "${2:-}"
        BIN_PATH="$2"
        shift 2
        ;;
      --no-install)
        AUTO_INSTALL=0
        shift
        ;;
      --json-only)
        JSON_ONLY=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        printf 'Unknown option: %s\n' "$1" >&2
        usage >&2
        exit 2
        ;;
    esac
  done
}

require_root() {
  if (( EUID != 0 )); then
    printf 'This command must run as root.\n' >&2
    exit 1
  fi
}

find_python() {
  if command -v python3 >/dev/null 2>&1; then
    printf '%s\n' python3
    return 0
  fi
  if command -v python >/dev/null 2>&1; then
    printf '%s\n' python
    return 0
  fi
  return 1
}

have_python() {
  command -v python3 >/dev/null 2>&1 || command -v python >/dev/null 2>&1
}

install_base_packages() {
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update >&2
    env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends curl ca-certificates openssl coreutils python3 gawk tar gzip iproute2 procps kmod >&2
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y curl ca-certificates openssl coreutils python3 gawk tar gzip iproute procps-ng kmod >&2
  elif command -v yum >/dev/null 2>&1; then
    yum install -y curl ca-certificates openssl coreutils python3 gawk tar gzip iproute procps-ng kmod >&2
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache curl ca-certificates openssl coreutils python3 gawk tar gzip iproute2 procps kmod >&2
  elif command -v pacman >/dev/null 2>&1; then
    pacman -Sy --noconfirm --needed curl ca-certificates openssl coreutils python gawk tar gzip iproute2 procps-ng kmod >&2
  elif command -v zypper >/dev/null 2>&1; then
    zypper --non-interactive install --no-recommends curl ca-certificates openssl coreutils python3 gawk tar gzip iproute2 procps kmod >&2
  else
    printf 'No supported package manager found. Install curl, ca-certificates, openssl, coreutils, python3, awk, tar, gzip, iproute, sysctl, and kmod manually.\n' >&2
    exit 1
  fi
  hash -r 2>/dev/null || true
}

missing_dependencies() {
  command -v curl >/dev/null 2>&1 || printf '%s\n' curl
  command -v openssl >/dev/null 2>&1 || printf '%s\n' openssl
  command -v timeout >/dev/null 2>&1 || printf '%s\n' timeout
  command -v awk >/dev/null 2>&1 || printf '%s\n' awk
  command -v tar >/dev/null 2>&1 || printf '%s\n' tar
  command -v gzip >/dev/null 2>&1 || printf '%s\n' gzip
  command -v sysctl >/dev/null 2>&1 || printf '%s\n' sysctl
  command -v modprobe >/dev/null 2>&1 || printf '%s\n' modprobe
  have_python || printf '%s\n' python3
}

ensure_dependencies() {
  local missing
  missing="$(missing_dependencies)"
  if [[ -z "$missing" ]]; then
    return
  fi
  if [[ "$AUTO_INSTALL" == "0" ]]; then
    printf 'Missing required commands:\n%s\n' "$missing" >&2
    exit 1
  fi
  require_root
  log "Installing dependencies | missing=$(printf '%s' "$missing" | tr '\n' ',' | sed 's/,$//')"
  install_base_packages

  missing="$(missing_dependencies)"
  if [[ -n "$missing" ]]; then
    printf 'Dependencies are still missing after installation:\n%s\n' "$missing" >&2
    exit 1
  fi
  log "Dependencies ready"
}

now_ms() {
  local value python_bin
  value="$(date +%s%3N 2>/dev/null || true)"
  if [[ "$value" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$value"
    return
  fi

  python_bin="$(find_python)" || {
    printf 'python3 is required when date does not support millisecond output.\n' >&2
    exit 1
  }
  "$python_bin" - <<'PY'
import time
print(int(time.time() * 1000))
PY
}

json_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\n'/\\n}"
  printf '%s' "$value"
}

shell_quote() {
  printf '%q' "$1"
}

load_state() {
  if [[ ! -f "$STATE_PATH" ]]; then
    return 0
  fi

  local old_tag="$TAG"
  local old_server="$SERVER"
  local old_server_port="$SERVER_PORT"
  local old_sni="$SNI"
  local old_handshake_server="$HANDSHAKE_SERVER"
  local old_handshake_port="$HANDSHAKE_PORT"
  local old_flow="$FLOW"
  local old_fingerprint="$FINGERPRINT"
  local old_uuid="$UUID"
  local old_short_id="$SHORT_ID"
  local old_private_key="$PRIVATE_KEY"
  local old_public_key="$PUBLIC_KEY"

  # shellcheck disable=SC1090
  source "$STATE_PATH"

  if (( CLI_TAG_SET == 1 )); then TAG="$old_tag"; fi
  if (( CLI_SERVER_SET == 1 )); then SERVER="$old_server"; fi
  if (( CLI_SERVER_PORT_SET == 1 )); then SERVER_PORT="$old_server_port"; fi
  if (( CLI_SNI_SET == 1 )); then SNI="$old_sni"; fi
  if (( CLI_HANDSHAKE_SERVER_SET == 1 )); then HANDSHAKE_SERVER="$old_handshake_server"; fi
  if (( CLI_HANDSHAKE_PORT_SET == 1 )); then HANDSHAKE_PORT="$old_handshake_port"; fi
  if (( CLI_FLOW_SET == 1 )); then FLOW="$old_flow"; fi
  if (( CLI_FINGERPRINT_SET == 1 )); then FINGERPRINT="$old_fingerprint"; fi
  if (( CLI_UUID_SET == 1 )); then UUID="$old_uuid"; fi
  if (( CLI_SHORT_ID_SET == 1 )); then SHORT_ID="$old_short_id"; fi
  if (( CLI_PRIVATE_KEY_SET == 1 )); then PRIVATE_KEY="$old_private_key"; fi
  if (( CLI_PUBLIC_KEY_SET == 1 )); then PUBLIC_KEY="$old_public_key"; fi
}

save_state() {
  require_root
  mkdir -p "$(dirname "$STATE_PATH")"
  chmod 700 "$(dirname "$STATE_PATH")"
  {
    printf 'TAG=%s\n' "$(shell_quote "$TAG")"
    printf 'SERVER=%s\n' "$(shell_quote "$SERVER")"
    printf 'SERVER_PORT=%s\n' "$(shell_quote "$SERVER_PORT")"
    printf 'SNI=%s\n' "$(shell_quote "$SNI")"
    printf 'HANDSHAKE_SERVER=%s\n' "$(shell_quote "$HANDSHAKE_SERVER")"
    printf 'HANDSHAKE_PORT=%s\n' "$(shell_quote "$HANDSHAKE_PORT")"
    printf 'FLOW=%s\n' "$(shell_quote "$FLOW")"
    printf 'FINGERPRINT=%s\n' "$(shell_quote "$FINGERPRINT")"
    printf 'UUID=%s\n' "$(shell_quote "$UUID")"
    printf 'SHORT_ID=%s\n' "$(shell_quote "$SHORT_ID")"
    printf 'PRIVATE_KEY=%s\n' "$(shell_quote "$PRIVATE_KEY")"
    printf 'PUBLIC_KEY=%s\n' "$(shell_quote "$PUBLIC_KEY")"
  } > "$STATE_PATH"
  chmod 600 "$STATE_PATH"
}

validate_port() {
  local name="$1"
  local value="$2"
  if ! [[ "$value" =~ ^[0-9]+$ ]] || (( value < 1 || value > 65535 )); then
    printf '%s must be a port from 1 to 65535: %s\n' "$name" "$value" >&2
    exit 2
  fi
}

prompt_server_port() {
  if (( CLI_SERVER_PORT_SET == 1 )) || [[ ! -t 0 ]]; then
    return
  fi

  local input default_port
  default_port="${SERVER_PORT:-443}"
  printf '[INPUT] VLESS listen port [%s]: ' "$default_port" >&2
  read -r input || input=""
  if [[ -n "$input" ]]; then
    SERVER_PORT="$input"
  else
    SERVER_PORT="$default_port"
  fi
}

validate_uuid() {
  if ! [[ "$UUID" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
    printf 'UUID is not valid: %s\n' "$UUID" >&2
    exit 2
  fi
}

validate_short_id() {
  if ! [[ "$SHORT_ID" =~ ^[0-9a-fA-F]{0,16}$ ]] || (( ${#SHORT_ID} % 2 != 0 )); then
    printf 'SHORT_ID must be an even-length hex string from 0 to 16 characters: %s\n' "$SHORT_ID" >&2
    exit 2
  fi
  SHORT_ID="$(printf '%s' "$SHORT_ID" | tr 'A-F' 'a-f')"
}

validate_reality_key() {
  local name="$1"
  local value="$2"
  if ! [[ "$value" =~ ^[A-Za-z0-9_-]{43}$ ]]; then
    printf '%s must be a 32-byte unpadded base64url Reality key: %s\n' "$name" "$value" >&2
    exit 2
  fi
}

needs_domain_scan() {
  [[ -z "$SNI" || -z "$HANDSHAKE_SERVER" ]]
}

has_domain_candidates() {
  local d
  for d in "${domains[@]}"; do
    [[ -n "$d" ]] && return 0
  done
  return 1
}

validate_domain_candidates() {
  if needs_domain_scan && ! has_domain_candidates; then
    printf 'Add at least one domain to the domains array before running this script.\n' >&2
    exit 2
  fi
}

select_fastest_domain() {
  if [[ -n "$SNI" && -n "$HANDSHAKE_SERVER" ]]; then
    return
  fi

  local d t1 t2 elapsed best_domain="" best_elapsed=""
  for d in "${domains[@]}"; do
    [[ -z "$d" ]] && continue
    t1=$(now_ms)

    if timeout 1 openssl s_client -connect "$d:443" -servername "$d" </dev/null &>/dev/null; then
      t2=$(now_ms)
      elapsed=$((t2 - t1))
      if [[ -z "$best_elapsed" || "$elapsed" -lt "$best_elapsed" ]]; then
        best_elapsed="$elapsed"
        best_domain="$d"
      fi
    fi
  done

  if [[ -z "$best_domain" ]]; then
    printf 'No usable Reality SNI candidate responded on port 443.\n' >&2
    exit 1
  fi

  SNI="${SNI:-$best_domain}"
  HANDSHAKE_SERVER="${HANDSHAKE_SERVER:-$best_domain}"
  log "Reality domain selected | sni=$SNI handshake=$HANDSHAKE_SERVER latency=${best_elapsed}ms"
}

ensure_bbr() {
  require_root

  local current available previous
  previous="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"
  current="$previous"
  if [[ "$current" == "bbr" ]]; then
    log "BBR ready | congestion_control=bbr"
    return
  fi

  if command -v modprobe >/dev/null 2>&1; then
    modprobe tcp_bbr 2>/dev/null || true
  fi

  available="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"
  if ! printf '%s\n' "$available" | grep -qw bbr; then
    log_error "BBR unavailable | available=${available:-unknown}"
    exit 1
  fi

  mkdir -p "$(dirname "$BBR_SYSCTL_PATH")"
  cat > "$BBR_SYSCTL_PATH" <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF

  if ! sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1; then
    log_warn "Could not set net.core.default_qdisc=fq at runtime"
  fi
  sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null

  current="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"
  if [[ "$current" != "bbr" ]]; then
    log_error "Failed to enable BBR | current=${current:-unknown}"
    exit 1
  fi

  log "BBR enabled | previous=${previous:-unknown} current=bbr config=$BBR_SYSCTL_PATH"
}

detect_public_ip() {
  if [[ -n "$SERVER" ]]; then
    return
  fi

  local endpoint ip
  for endpoint in \
    "https://api.ipify.org" \
    "https://checkip.amazonaws.com" \
    "https://icanhazip.com" \
    "https://ifconfig.me/ip"; do
    ip="$(curl -fsSL --connect-timeout 3 --max-time 8 "$endpoint" 2>/dev/null | tr -d '[:space:]' || true)"
    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ || "$ip" =~ ^[0-9a-fA-F:]+$ ]]; then
      SERVER="$ip"
      return
    fi
  done

  printf 'Could not auto-detect public server IP. Use --server <host>.\n' >&2
  exit 1
}

detect_country_code() {
  local ip="$1"
  local endpoint code
  for endpoint in \
    "https://ipapi.co/${ip}/country/" \
    "https://api.country.is/${ip}" \
    "https://ipinfo.io/${ip}/country"; do
    case "$endpoint" in
      *api.country.is*)
        code="$(curl -fsSL --connect-timeout 3 --max-time 8 "$endpoint" 2>/dev/null | sed -n 's/.*"country"[[:space:]]*:[[:space:]]*"\([A-Za-z][A-Za-z]\)".*/\1/p' | head -n 1 || true)"
        ;;
      *)
        code="$(curl -fsSL --connect-timeout 3 --max-time 8 "$endpoint" 2>/dev/null | tr -dc 'A-Za-z' | head -c 2 || true)"
        ;;
    esac
    if [[ "$code" =~ ^[A-Za-z]{2}$ ]]; then
      printf '%s\n' "$code" | tr 'A-Z' 'a-z'
      return
    fi
  done

  printf 'Could not detect country code for %s.\n' "$ip" >&2
  exit 1
}

generate_tag_from_ip() {
  if (( CLI_TAG_SET == 1 )); then
    return
  fi
  if [[ -n "$TAG" && ! "$TAG" =~ ^vless-reality$ ]]; then
    return
  fi
  if [[ ! "$SERVER" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
    printf 'Automatic tag generation requires an IPv4 server address. Use --tag for non-IPv4 server values: %s\n' "$SERVER" >&2
    exit 2
  fi

  local country first second fourth second_first
  country="$(detect_country_code "$SERVER")"
  first="${BASH_REMATCH[1]}"
  second="${BASH_REMATCH[2]}"
  fourth="${BASH_REMATCH[4]}"
  second_first="${second:0:1}"
  TAG="${country}-${first}${second_first}${fourth}"
}

extract_named_key() {
  local name="$1"
  awk -F': *' -v name="$name" 'tolower($1) ~ name { print $2; exit }'
}

python_reality_keypair() {
  local private_arg="${1:-}"
  local python_bin
  python_bin="$(find_python)" || {
    printf 'Install sing-box or python3 to generate Reality keys.\n' >&2
    exit 1
  }

  "$python_bin" - "$private_arg" <<'PY'
import base64
import os
import sys

P = 2**255 - 19
A24 = 121665

def b64u(raw):
    return base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")

def unb64u(value):
    value = value.strip()
    value += "=" * ((4 - len(value) % 4) % 4)
    return base64.urlsafe_b64decode(value.encode("ascii"))

def clamp(raw):
    key = bytearray(raw)
    if len(key) != 32:
        raise SystemExit("Reality private key must decode to 32 bytes")
    key[0] &= 248
    key[31] &= 127
    key[31] |= 64
    return bytes(key)

def x25519(scalar, u=9):
    k = int.from_bytes(clamp(scalar), "little")
    x1 = u
    x2, z2 = 1, 0
    x3, z3 = u, 1
    swap = 0

    for t in range(254, -1, -1):
        kt = (k >> t) & 1
        swap ^= kt
        if swap:
            x2, x3 = x3, x2
            z2, z3 = z3, z2
        swap = kt

        a = (x2 + z2) % P
        aa = (a * a) % P
        b = (x2 - z2) % P
        bb = (b * b) % P
        e = (aa - bb) % P
        c = (x3 + z3) % P
        d = (x3 - z3) % P
        da = (d * a) % P
        cb = (c * b) % P

        x3 = ((da + cb) * (da + cb)) % P
        z3 = (x1 * (da - cb) * (da - cb)) % P
        x2 = (aa * bb) % P
        z2 = (e * (aa + A24 * e)) % P

    if swap:
        x2, x3 = x3, x2
        z2, z3 = z3, z2

    return (x2 * pow(z2, P - 2, P) % P).to_bytes(32, "little")

private_arg = sys.argv[1] if len(sys.argv) > 1 else ""
private_key = unb64u(private_arg) if private_arg else clamp(os.urandom(32))
public_key = x25519(private_key)

print("PrivateKey: " + b64u(private_key))
print("PublicKey: " + b64u(public_key))
PY
}

generate_reality_keypair() {
  if [[ -n "$PRIVATE_KEY" && -n "$PUBLIC_KEY" ]]; then
    return
  fi

  local output=""
  if [[ -n "$PRIVATE_KEY" && -z "$PUBLIC_KEY" ]]; then
    output="$(python_reality_keypair "$PRIVATE_KEY")"
  elif [[ -x "$BIN_PATH" ]]; then
    output="$("$BIN_PATH" generate reality-keypair 2>/dev/null || true)"
  elif command -v sing-box >/dev/null 2>&1; then
    output="$(sing-box generate reality-keypair 2>/dev/null || true)"
  elif command -v xray >/dev/null 2>&1; then
    output="$(xray x25519 2>/dev/null || true)"
  else
    output="$(python_reality_keypair)"
  fi

  if [[ -z "$PRIVATE_KEY" ]]; then
    PRIVATE_KEY="$(printf '%s\n' "$output" | extract_named_key private)"
  fi
  if [[ -z "$PUBLIC_KEY" ]]; then
    PUBLIC_KEY="$(printf '%s\n' "$output" | extract_named_key public)"
  fi

  if [[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" ]]; then
    printf 'Could not parse Reality keypair output.\n' >&2
    exit 1
  fi
}

generate_uuid() {
  if [[ -n "$UUID" ]]; then
    return
  fi

  if command -v uuidgen >/dev/null 2>&1; then
    UUID="$(uuidgen | tr 'A-F' 'a-f')"
    return
  fi
  if [[ -r /proc/sys/kernel/random/uuid ]]; then
    UUID="$(tr 'A-F' 'a-f' < /proc/sys/kernel/random/uuid)"
    return
  fi
  if command -v openssl >/dev/null 2>&1; then
    local hex variant
    hex="$(openssl rand -hex 16)"
    variant="$(printf '%x' "$(( (0x${hex:16:1} & 0x3) | 0x8 ))")"
    UUID="${hex:0:8}-${hex:8:4}-4${hex:13:3}-${variant}${hex:17:3}-${hex:20:12}"
    return
  fi

  local python_bin
  python_bin="$(find_python)" || {
    printf 'Install uuidgen, openssl, or python3 to generate UUIDs.\n' >&2
    exit 1
  }
  UUID="$("$python_bin" - <<'PY'
import uuid
print(uuid.uuid4())
PY
)"
}

generate_short_id() {
  if [[ -n "$SHORT_ID" ]]; then
    return
  fi

  if command -v openssl >/dev/null 2>&1; then
    SHORT_ID="$(openssl rand -hex 8)"
    return
  fi
  if command -v od >/dev/null 2>&1 && [[ -r /dev/urandom ]]; then
    SHORT_ID="$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
    return
  fi

  local python_bin
  python_bin="$(find_python)" || {
    printf 'Install openssl or python3 to generate Reality short_id.\n' >&2
    exit 1
  }
  SHORT_ID="$("$python_bin" - <<'PY'
import os
print(os.urandom(8).hex())
PY
)"
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) printf '%s\n' amd64 ;;
    i386|i686|x86) printf '%s\n' 386 ;;
    aarch64|arm64|armv8*) printf '%s\n' arm64 ;;
    armv7*|armv7l) printf '%s\n' armv7 ;;
    armv6*) printf '%s\n' armv6 ;;
    armv5*) printf '%s\n' armv5 ;;
    s390x) printf '%s\n' s390x ;;
    ppc64le) printf '%s\n' ppc64le ;;
    riscv64) printf '%s\n' riscv64 ;;
    loongarch64) printf '%s\n' loong64 ;;
    mips64le) printf '%s\n' mips64le ;;
    mips64) printf '%s\n' mips64 ;;
    mipsle) printf '%s\n' mipsle ;;
    mips) printf '%s\n' mips ;;
    *)
      printf 'Unsupported CPU architecture: %s\n' "$(uname -m)" >&2
      exit 1
      ;;
  esac
}

detect_libc() {
  if ldd --version 2>&1 | grep -qi musl; then
    printf '%s\n' musl
  else
    printf '%s\n' glibc
  fi
}

select_sing_box_asset() {
  local json_file="$1"
  local arch="$2"
  local libc="$3"
  local python_bin
  python_bin="$(find_python)"
  "$python_bin" - "$json_file" "$arch" "$libc" <<'PY'
import json
import os
import re
import sys
from urllib.parse import urlparse

path, arch, libc = sys.argv[1:4]
data = json.load(open(path, "r", encoding="utf-8"))

assets = []

def add(name, url):
    if not name and url:
        name = os.path.basename(urlparse(url).path)
    if not name:
        return
    assets.append((str(name), str(url or "")))

def walk(value):
    if isinstance(value, dict):
        name = value.get("name") or value.get("filename") or value.get("file") or value.get("asset")
        url = (
            value.get("browser_download_url")
            or value.get("download_url")
            or value.get("url")
            or value.get("download")
        )
        if name or (isinstance(url, str) and "sing-box" in url):
            add(name, url)
        for child in value.values():
            walk(child)
    elif isinstance(value, list):
        for child in value:
            walk(child)
    elif isinstance(value, str):
        if "sing-box" in value and ".tar.gz" in value:
            if value.startswith("http://") or value.startswith("https://"):
                add("", value)
            else:
                add(os.path.basename(value), "")

walk(data)

def tag_name():
    for key in ("tag_name", "tag", "version"):
        value = data.get(key) if isinstance(data, dict) else None
        if isinstance(value, str) and value:
            return value
    return ""

tag = tag_name()

def candidate_score(item):
    name, url = item
    lower = name.lower()
    if not lower.endswith(".tar.gz"):
        return None
    if "sing-box-" not in lower:
        return None
    if "android" in lower or "darwin" in lower or "windows" in lower or "openwrt" in lower:
        return None
    if f"linux-{arch}" not in lower:
        return None

    score = 10
    if lower.endswith(f"linux-{arch}-{libc}.tar.gz"):
        score += 100
    elif lower.endswith(f"linux-{arch}.tar.gz"):
        score += 80
    elif f"linux-{arch}-" in lower:
        score += 20
    if "softfloat" in lower:
        score -= 30
    if url:
        score += 5
    return score

candidates = []
for item in assets:
    score = candidate_score(item)
    if score is not None:
        candidates.append((score, item))

if not candidates:
    raise SystemExit(2)

candidates.sort(key=lambda entry: (-entry[0], entry[1][0]))
name, url = candidates[0][1]
if not url:
    raise SystemExit(3)
print(f"{tag}\t{url}\t{name}")
PY
}

resolve_sing_box_asset() {
  local arch libc tmp result
  arch="$(detect_arch)"
  libc="$(detect_libc)"
  tmp="$(mktemp)"

  if curl -fsSL --connect-timeout 10 --max-time 60 "$LATEST_JSON_URL" -o "$tmp"; then
    if result="$(select_sing_box_asset "$tmp" "$arch" "$libc" 2>/dev/null)"; then
      rm -f "$tmp"
      printf '%s\n' "$result"
      return
    fi
    log "latest.json did not contain a usable linux-$arch asset; falling back to GitHub API."
  else
    log "latest.json is unavailable; falling back to GitHub API."
  fi

  curl -fsSL --connect-timeout 10 --max-time 60 "$GITHUB_RELEASE_API" -o "$tmp"
  result="$(select_sing_box_asset "$tmp" "$arch" "$libc")"
  rm -f "$tmp"
  printf '%s\n' "$result"
}

install_or_update_sing_box() {
  require_root
  ensure_dependencies

  local meta version url name tmpdir archive binary installed_version
  meta="$(resolve_sing_box_asset)"
  IFS=$'\t' read -r version url name <<< "$meta"

  tmpdir="$(mktemp -d)"
  archive="$tmpdir/$name"
  log "Downloading sing-box | version=${version:-latest} asset=$name"
  curl -fL --retry 3 --connect-timeout 15 --max-time 300 -o "$archive" "$url"
  tar -xzf "$archive" -C "$tmpdir"

  binary="$(find "$tmpdir" -type f -name sing-box | head -n 1)"
  if [[ -z "$binary" ]]; then
    rm -rf "$tmpdir"
    printf 'Downloaded archive did not contain sing-box binary.\n' >&2
    exit 1
  fi

  install -m 0755 "$binary" "$BIN_PATH"
  rm -rf "$tmpdir"
  installed_version="$("$BIN_PATH" version 2>/dev/null | head -n 1)"
  log "sing-box installed | path=$BIN_PATH version=$installed_version"
}

write_sing_box_config() {
  require_root
  mkdir -p "$CONFIG_DIR"
  chmod 700 "$CONFIG_DIR"

  local tag uuid flow sni handshake_server private_key short_id
  tag="$(json_escape "$TAG")"
  uuid="$(json_escape "$UUID")"
  flow="$(json_escape "$FLOW")"
  sni="$(json_escape "$SNI")"
  handshake_server="$(json_escape "$HANDSHAKE_SERVER")"
  private_key="$(json_escape "$PRIVATE_KEY")"
  short_id="$(json_escape "$SHORT_ID")"

  cat > "$CONFIG_PATH" <<EOF
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "${tag}-in",
      "listen": "::",
      "listen_port": $SERVER_PORT,
      "users": [
        {
          "name": "$tag",
          "uuid": "$uuid",
          "flow": "$flow"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$sni",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "$handshake_server",
            "server_port": $HANDSHAKE_PORT
          },
          "private_key": "$private_key",
          "short_id": [
            "$short_id"
          ]
        }
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF
  chmod 600 "$CONFIG_PATH"
  log "Config written | path=$CONFIG_PATH port=$SERVER_PORT"
}

write_systemd_service() {
  require_root
  if ! command -v systemctl >/dev/null 2>&1; then
    printf 'systemctl was not found; this deploy mode requires systemd.\n' >&2
    exit 1
  fi

  cat > "$SERVICE_PATH" <<EOF
[Unit]
Description=sing-box Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$BIN_PATH run -c $CONFIG_PATH
Restart=on-failure
RestartSec=10s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  log "systemd service written | path=$SERVICE_PATH"
}

check_sing_box_config() {
  if "$BIN_PATH" check -c "$CONFIG_PATH" >/dev/null; then
    log "Config check passed | path=$CONFIG_PATH"
    return
  fi
  "$BIN_PATH" check "$CONFIG_PATH" >/dev/null
  log "Config check passed | path=$CONFIG_PATH"
}

restart_sing_box() {
  require_root
  systemctl enable sing-box >/dev/null
  if systemctl is-active --quiet sing-box; then
    systemctl restart sing-box
  else
    systemctl start sing-box
  fi
  sleep 2
  if ! systemctl is-active --quiet sing-box; then
    journalctl -u sing-box --no-pager -n 80 >&2 || true
    printf 'sing-box service failed to start.\n' >&2
    exit 1
  fi
  log "Service active | name=sing-box"
}

open_local_firewall_port() {
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi active; then
    ufw allow "${SERVER_PORT}/tcp" >/dev/null || true
    log "Firewall updated | ufw port=${SERVER_PORT}/tcp"
  fi
  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --add-port="${SERVER_PORT}/tcp" --permanent >/dev/null || true
    firewall-cmd --reload >/dev/null || true
    log "Firewall updated | firewalld port=${SERVER_PORT}/tcp"
  fi
}

verify_service() {
  systemctl is-active --quiet sing-box
  if command -v ss >/dev/null 2>&1; then
    if ! ss -ltn | awk '{print $4}' | grep -Eq "(:|\\])${SERVER_PORT}$"; then
      printf 'sing-box is active, but port %s was not found in ss output.\n' "$SERVER_PORT" >&2
      exit 1
    fi
  fi
  log "Service verified | port=$SERVER_PORT"
}

print_summary() {
  log "Outbound ready | tag=$TAG server=$SERVER port=$SERVER_PORT sni=$SNI handshake=${HANDSHAKE_SERVER}:${HANDSHAKE_PORT}"
}

print_outbound() {
  local tag server uuid flow sni fingerprint public_key short_id
  tag="$(json_escape "$TAG")"
  server="$(json_escape "$SERVER")"
  uuid="$(json_escape "$UUID")"
  flow="$(json_escape "$FLOW")"
  sni="$(json_escape "$SNI")"
  fingerprint="$(json_escape "$FINGERPRINT")"
  public_key="$(json_escape "$PUBLIC_KEY")"
  short_id="$(json_escape "$SHORT_ID")"

  cat <<EOF
{
  "type": "vless",
  "tag": "$tag",
  "server": "$server",
  "server_port": $SERVER_PORT,
  "uuid": "$uuid",
  "flow": "$flow",
  "tls": {
    "enabled": true,
    "server_name": "$sni",
    "utls": {
      "enabled": true,
      "fingerprint": "$fingerprint"
    },
    "reality": {
      "enabled": true,
      "public_key": "$public_key",
      "short_id": "$short_id"
    }
  }
}
EOF
}

validate_generated_values() {
  validate_port SERVER_PORT "$SERVER_PORT"
  validate_port HANDSHAKE_PORT "$HANDSHAKE_PORT"
  validate_uuid
  validate_short_id
  validate_reality_key PRIVATE_KEY "$PRIVATE_KEY"
  validate_reality_key PUBLIC_KEY "$PUBLIC_KEY"
}

prepare_generated_values() {
  local prompt_port="${1:-0}"
  if [[ "$prompt_port" == "1" ]]; then
    prompt_server_port
  fi
  validate_port SERVER_PORT "$SERVER_PORT"
  validate_port HANDSHAKE_PORT "$HANDSHAKE_PORT"
  validate_domain_candidates
  ensure_dependencies
  detect_public_ip
  generate_tag_from_ip
  select_fastest_domain
  generate_uuid
  generate_short_id
  generate_reality_keypair
  validate_generated_values
}

command_deploy() {
  require_root
  prepare_generated_values 1
  ensure_bbr
  install_or_update_sing_box
  write_sing_box_config
  check_sing_box_config
  write_systemd_service
  open_local_firewall_port
  restart_sing_box
  verify_service
  save_state
  if (( JSON_ONLY == 0 )); then
    print_summary
  fi
  print_outbound
}

command_update() {
  require_root
  install_or_update_sing_box
  if [[ -f "$CONFIG_PATH" ]]; then
    check_sing_box_config
  fi
  if [[ -f "$SERVICE_PATH" ]]; then
    systemctl daemon-reload
    if systemctl is-active --quiet sing-box; then
      systemctl restart sing-box
    fi
  fi
  "$BIN_PATH" version
}

command_outbound() {
  prepare_generated_values 0
  if (( JSON_ONLY == 0 )); then
    print_summary
  fi
  print_outbound
}

command_status() {
  if command -v systemctl >/dev/null 2>&1 && [[ -f "$SERVICE_PATH" ]]; then
    systemctl status sing-box --no-pager -l || true
  else
    printf 'sing-box systemd service is not installed.\n'
  fi
  if [[ -n "$UUID" && -n "$PUBLIC_KEY" ]]; then
    print_summary
    print_outbound
  elif [[ -f "$STATE_PATH" ]]; then
    printf 'State file exists at %s but did not load complete values.\n' "$STATE_PATH"
  fi
  return 0
}

main() {
  pick_command "$@"
  parse_options "${REMAINING_ARGS[@]}"
  case "$COMMAND" in
    deploy|outbound|status)
      load_state
      ;;
  esac

  case "$COMMAND" in
    deploy) command_deploy ;;
    update) command_update ;;
    outbound) command_outbound ;;
    status) command_status ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
}

main "$@"
