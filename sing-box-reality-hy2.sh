#!/bin/sh
# sing-box REALITY + Hysteria2 installer (Debian/Ubuntu, POSIX sh).
# No Python or pinned sing-box version. Only REALITY-maintained SNI candidates.
set -eu
umask 077

CONFIG_DIR=${CONFIG_DIR:-/etc/sing-box}
CONFIG_FILE=$CONFIG_DIR/config.json
REALITY_CLIENT=$CONFIG_DIR/reality-client.json
HY2_CLIENT=$CONFIG_DIR/hysteria2-client.json
HY2_CERT_FILE=$CONFIG_DIR/hysteria2.crt
HY2_KEY_FILE=$CONFIG_DIR/hysteria2.key
HY2_HOP_FILE=$CONFIG_DIR/hysteria2-hop.nft
ACME_DATA_DIR=${ACME_DATA_DIR:-/var/lib/sing-box/acme}
BIN_FILE=${BIN_FILE:-/usr/local/bin/sing-box}
UNIT_FILE=${UNIT_FILE:-/etc/systemd/system/sing-box.service}
BACKUP_ROOT=${BACKUP_ROOT:-/var/backups/sing-box}
REPORT_FILE=${REPORT_FILE:-/var/log/sing-box-connection-check.log}
RELEASE_API=${RELEASE_API:-https://api.github.com/repos/SagerNet/sing-box/releases/latest}
REALITY_LIST_URL=${REALITY_LIST_URL:-https://raw.githubusercontent.com/meower1/Reality-SNI-finder/main/sni.txt}

COMMAND=deploy
# Deployment always enables both; test detects protocols in the saved config.
USE_REALITY=1
USE_HY2=1
REALITY_PORT=443
HY2_PORT=443
REALITY_PORT_SET=0
HY2_DOMAIN=${HY2_DOMAIN:-}
HY2_INTERFACE=${HY2_INTERFACE:-}
CF_API_TOKEN=${CF_API_TOKEN:-${CF_Token:-}}
CF_ZONE_TOKEN=${CF_ZONE_TOKEN:-}
ACME_EMAIL=${ACME_EMAIL:-}
readonly HY2_HOP_START=20000 HY2_HOP_END=50000 HY2_HOP_INTERVAL=30s
NFT_BIN=
TTY_STATE=
SERVER=
SNI=
TAG=
YES=0
SKIP_TEST=0
NO_DOWNLOAD=0
SCAN_LIMIT=160
SCAN_JOBS=8
STAGE=
BACKUP=
COMMIT=0
OLD_ACTIVE=0
OLD_ENABLED=0
REPLACE_BINARY=0
PROBE_PID=
TEST_SOCKS_PORT=
CHECK_PHASE=INIT
CHECK_PROTO=
CHECK_REASON=
NEW_BIN=
UUID=
SHORT_ID=
PRIVATE_KEY=
PUBLIC_KEY=
HY2_PASSWORD=
HY2_OBFS_PASSWORD=

info() { printf '[INFO] %s\n' "$*" >&2; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

usage() {
cat <<'HELP'
Usage: sh sing-box-reality-hy2.sh [deploy|reconfigure|show|test|status] [options]

Every deployment installs both REALITY (TCP) and Hysteria2 (UDP).

  --port N                 REALITY TCP port (default 443; alias for --reality-port).
  --reality-port N         REALITY TCP port.
  --hy2-port N             Internal HY2 listener; external hopping stays 20000-50000.
  --hy2-domain DOMAIN      Cloudflare DNS-only domain pointing to this VPS; required.
  --acme-email EMAIL       Optional ACME account email.
  --server HOST_OR_IP      REALITY address; default autodetect IPv4.
  --sni DOMAIN            REALITY SNI; default benchmark the online REALITY list.
  --tag NAME              Generic client tag; default based on server address.
  --scan-limit N          SNI candidates (default 160).
  --scan-jobs N           Parallel SNI TLS checks (default 8, max 16).
  --yes                   Accept reconfiguration, use defaults and skip prompts.
  --skip-test             Explicitly skip local real-protocol checks.
  --no-download           Reuse the existing sing-box binary.

Commands:
  deploy / reconfigure    Configure, replace, then verify both protocols.
  show                    Show saved outbound JSON and import URIs.
  test                    Re-test saved protocols without touching credentials.
  status                  Show service status and sockets.

HY2 always uses Cloudflare DNS-01 ACME, Gecko and UDP port hopping 20000-50000.
Set CF_API_TOKEN (or CF_Token); optional CF_ZONE_TOKEN supplies Zone:Read.
The token needs Zone:DNS:Edit and Zone:Read for the domain's zone.
Interactive token input is hidden. DNS-01 does not require TCP port 80.
Allow UDP 20000-50000 in the VPS/security-group firewall; keep Cloudflare DNS-only.
Failed deployment restores the previous configuration and service.
HELP
}

require_arg() { [ "$#" -ge 2 ] && [ -n "$2" ] || die "Missing value for $1"; }
parse_args() {
  case "${1:-}" in
    deploy|reconfigure|show|test|status) COMMAND=$1; shift ;;
    -h|--help) usage; exit 0 ;;
  esac
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --port|--reality-port) require_arg "$@"; REALITY_PORT=$2; REALITY_PORT_SET=1; shift 2 ;;
      --hy2-port) require_arg "$@"; HY2_PORT=$2; shift 2 ;;
      --hy2-domain) require_arg "$@"; HY2_DOMAIN=$2; shift 2 ;;
      --acme-email) require_arg "$@"; ACME_EMAIL=$2; shift 2 ;;
      --server) require_arg "$@"; SERVER=$2; shift 2 ;;
      --sni) require_arg "$@"; SNI=$2; shift 2 ;;
      --tag) require_arg "$@"; TAG=$2; shift 2 ;;
      --scan-limit) require_arg "$@"; SCAN_LIMIT=$2; shift 2 ;;
      --scan-jobs) require_arg "$@"; SCAN_JOBS=$2; shift 2 ;;
      --yes) YES=1; shift ;;
      --skip-test) SKIP_TEST=1; shift ;;
      --no-download) NO_DOWNLOAD=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "Unknown option: $1" ;;
    esac
  done
}

require_root() { [ "$(id -u)" -eq 0 ] || die 'Run as root'; }

ensure_dependencies() {
  [ -f /etc/debian_version ] || die 'Only Debian/Ubuntu (apt) is supported.'
  command -v apt-get >/dev/null 2>&1 || die 'apt-get is required.'
  command -v systemctl >/dev/null 2>&1 || die 'systemd is required.'
  [ -d /run/systemd/system ] || die 'systemd must be PID 1.'
  needed=
  for tool in curl jq openssl tar timeout ss ip awk sha256sum nft; do
    command -v "$tool" >/dev/null 2>&1 || needed="$needed $tool"
  done
  if [ -n "$needed" ]; then
    info "Installing required tools through apt:$needed"
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      ca-certificates curl jq openssl tar gzip coreutils iproute2 procps gawk nftables
  fi
  for tool in curl jq openssl tar timeout ss ip awk sha256sum nft; do
    command -v "$tool" >/dev/null 2>&1 || die "Missing tool: $tool"
  done
  NFT_BIN=$(command -v nft)
  if [ "$USE_REALITY" -eq 1 ]; then
    curl -V | grep -q HTTP2 || die 'curl needs HTTP/2 for REALITY candidate checks.'
  fi
}

confirm_reconfiguration() {
  if [ -f "$CONFIG_FILE" ] || [ -f "$REALITY_CLIENT" ] || [ -f "$HY2_CLIENT" ] || [ -f "$UNIT_FILE" ]; then
    if [ "$YES" -eq 0 ]; then
      [ -t 0 ] || die 'Non-interactive overwrite requires --yes.'
      printf '重新生成并覆盖配置？[Y/n]（回车默认同意）: ' >&2
      answer=n
      IFS= read -r answer || answer=n
      case "$answer" in ''|y|Y|yes|YES|Yes) : ;; *) info 'Cancelled.'; exit 0 ;; esac
    fi
  fi
}

prompt_port() {
  label=$1
  val=$2
  [ "$YES" -eq 0 ] && [ -t 0 ] || { printf '%s\n' "$val"; return; }
  printf '%s [%s]（回车默认）: ' "$label" "$val" >&2
  answer=
  IFS= read -r answer || answer=
  printf '%s\n' "${answer:-$val}"
}

prompt_settings() {
  if [ "$USE_REALITY" -eq 1 ] && [ "$REALITY_PORT_SET" -eq 0 ]; then
    REALITY_PORT=$(prompt_port 'REALITY TCP 端口' "$REALITY_PORT")
  fi
  if [ "$USE_HY2" -eq 1 ]; then
    info "HY2 已开启 UDP 端口跳跃：$HY2_HOP_START-$HY2_HOP_END"
    if [ -z "$HY2_DOMAIN" ]; then
      HY2_DOMAIN=$(prompt_port 'HY2 Cloudflare 域名（灰云 DNS-only）' '')
    fi
    if [ -z "$CF_API_TOKEN" ] && [ "$YES" -eq 0 ] && [ -t 0 ]; then
      printf 'Cloudflare API Token（隐藏输入）: ' >&2
      TTY_STATE=$(stty -g)
      stty -echo
      IFS= read -r CF_API_TOKEN || CF_API_TOKEN=
      stty "$TTY_STATE"
      TTY_STATE=
      printf '\n' >&2
    fi
  fi
}

validate_number() {
  case "$2" in ''|*[!0-9]*) die "$1 must be a positive integer: $2" ;; esac
  awk -v val="$2" -v max="$3" 'BEGIN{exit !(val+0>=1 && val+0<=max && val ~ /^[0-9]+$/)}' || die "$1 must be between 1 and $3"
}

validate_settings() {
  [ "$USE_REALITY" -eq 0 ] || validate_number REALITY_PORT "$REALITY_PORT" 65535
  [ "$USE_HY2" -eq 0 ] || validate_number HY2_PORT "$HY2_PORT" 65535
  validate_number SCAN_LIMIT "$SCAN_LIMIT" 1000
  validate_number SCAN_JOBS "$SCAN_JOBS" 16
  validate_hy2_domain
  [ -n "$CF_API_TOKEN" ] || die 'Set CF_API_TOKEN (or CF_Token) for Cloudflare DNS-01.'
  case "$CF_API_TOKEN$CF_ZONE_TOKEN" in *[!A-Za-z0-9_-]*) die 'Invalid Cloudflare API token format.' ;; esac
  REALITY_PORT=$(awk -v n="$REALITY_PORT" 'BEGIN{printf "%d",n+0}')
  HY2_PORT=$(awk -v n="$HY2_PORT" 'BEGIN{printf "%d",n+0}')
  SCAN_LIMIT=$(awk -v n="$SCAN_LIMIT" 'BEGIN{printf "%d",n+0}')
  SCAN_JOBS=$(awk -v n="$SCAN_JOBS" 'BEGIN{printf "%d",n+0}')
}

validate_domain() {
  printf '%s\n' "$1" | LC_ALL=C awk '
    length($0)>253 || length($0)<4 || $0 !~ /\./ {exit 1}
    $0 !~ /^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$/ {exit 1}
    /\.\./ {exit 1}
    {n=split($0,a,"."); for(i=1;i<=n;i++) if(length(a[i])<1 || length(a[i])>63 || a[i] ~ /^-/ || a[i] ~ /-$/) exit 1}
  ' || die "Invalid hostname: $1"
}

validate_hy2_domain() {
  [ -n "$HY2_DOMAIN" ] || die 'HY2 requires --hy2-domain with a Cloudflare domain; IP certificates are disabled.'
  HY2_DOMAIN=$(printf '%s' "$HY2_DOMAIN" | tr 'A-Z' 'a-z')
  validate_domain "$HY2_DOMAIN"
  case "$HY2_DOMAIN" in *[!0-9.]*) : ;; *) die 'HY2 domain must be a DNS hostname, not an IP address.' ;; esac
}

validate_server() {
  [ -n "$SERVER" ] || die 'Could not detect public IPv4; use --server.'
  case "$SERVER" in *[!A-Za-z0-9.:_-]*|*/*|*'?'*|*'#'*) die "Invalid address: $SERVER" ;; esac
  [ "${#SERVER}" -le 253 ] || die 'Server address is too long.'
}

public_server_address() {
  ip -4 -o addr show scope global 2>/dev/null | LC_ALL=C awk '
    {split($4,a,"/"); n=split(a[1],b,"."); x=b[1]+0; y=b[2]+0
     if(n==4 && x>0 && x<224 && x!=10 && x!=127 && x!=169 &&
       !(x==172 && y>=16 && y<=31) && !(x==192 && y==168) &&
       !(x==100 && y>=64 && y<=127) && !(x==198 && (y==18 || y==19))) {print a[1]; exit}}
  '
}

resolve_server() {
  if [ -z "$SERVER" ]; then SERVER=$(public_server_address); fi
  if [ -z "$SERVER" ]; then
    SERVER=$(curl -q -4fsSL --connect-timeout 4 --max-time 10 https://api.ipify.org 2>/dev/null || :)
  fi
  validate_server
  if [ -z "$TAG" ]; then
    TAG=$(printf 'node-%s' "$SERVER" | tr ':.' '--' | tr -cd 'A-Za-z0-9._-' | cut -c 1-52)
  fi
  [ -n "$TAG" ] && [ "${#TAG}" -le 70 ] || die 'Invalid client tag.'
}

fetch_candidates() {
  candidates_raw=$STAGE/candidates.raw

  info 'Downloading REALITY SNI candidates...'
  curl -q -fsSL --connect-timeout 7 --max-time 25 \
    -o "$STAGE/reality-sni.txt" "$REALITY_LIST_URL" \
    || die 'REALITY SNI candidate list download failed.'

  # REALITY-specific community list is the only automatic source.
  # Ignore comments and optional :443 suffixes; validate and deduplicate below.
  sed 's/#.*$//;s/:443$//' "$STAGE/reality-sni.txt" > "$candidates_raw"
  LC_ALL=C awk '
    {
      gsub(/\r/,""); gsub(/^[ \t]+|[ \t]+$/,"",$0)
      d=tolower($0); sub(/:443$/, "", d)
      if(length(d)<4 || length(d)>253 || d !~ /\./ || d ~ /\.\./) next
      if(d !~ /^[a-z0-9][a-z0-9.-]*[a-z0-9]$/) next
      n=split(d,a,"."); ok=1
      for (i=1;i<=n;i++) if(length(a[i])>63 || a[i] ~ /^-/ || a[i] ~ /-$/)ok=0
      if(ok && !seen[d]++) print d
    }
  ' "$candidates_raw" | head -n "$SCAN_LIMIT" > "$STAGE/candidates"
  total=$(wc -l < "$STAGE/candidates" | tr -d ' ')
  [ "$total" -gt 0 ] || die 'The REALITY SNI list contained no usable hostnames.'
  info "Loaded $total REALITY SNI candidates."
}

# One genuine direct TLS 1.3 certificate-verified HTTPS request (HTTP/2 required).
# Writes <TLS-connect-ms> <hostname> into an individual result file if successful.
probe_domain() {
  hostname=$1
  result_file=$2
  : > "$result_file"
  metrics=$(curl -q --noproxy '*' -sS --http2 \
    --tlsv1.3 --tls-max 1.3 --connect-timeout 3 --max-time 7 \
    -o /dev/null -w '%{time_appconnect} %{http_version} %{ssl_verify_result}' \
    "https://$hostname/" 2>/dev/null) || return 0
  set -- $metrics
  [ "$#" -eq 3 ] || return 0
  [ "$2" = 2 ] && [ "$3" = 0 ] || return 0
  millis=$(LC_ALL=C awk -v n="$1" 'BEGIN {if (n+0>0 && n+0<7) printf "%d", (n+0)*1000+0.5; else exit 1}') || return 0
  printf '%s %s\n' "$millis" "$hostname" > "$result_file"
}

select_sni() {
  if [ -n "$SNI" ]; then
    validate_domain "$SNI"
    info "Using explicit SNI $SNI (checking live TLS 1.3 / HTTP/2 + certificate)."
    probe_domain "$SNI" "$STAGE/explicit-probe"
    [ -s "$STAGE/explicit-probe" ] || die "Custom SNI failed TLS 1.3/certificate/HTTP2 check: $SNI"
    return 0
  fi

  fetch_candidates
  mkdir -p "$STAGE/probes"
  info "Benchmarking $total SNI candidates from THIS VPS, concurrency=$SCAN_JOBS..."
  count=0
  active=0
  while IFS= read -r hostname; do
    count=$((count + 1))
    probe_domain "$hostname" "$STAGE/probes/$count" &
    active=$((active + 1))
    if [ "$active" -ge "$SCAN_JOBS" ]; then
      wait
      active=0
    fi
  done < "$STAGE/candidates"
  wait
  cat "$STAGE"/probes/* 2>/dev/null | sort -n > "$STAGE/ranked" || :
  [ -s "$STAGE/ranked" ] || die 'No domain passed HTTPS TLS 1.3 + certificate + HTTP/2 validation.'

  # Recheck top candidates, to avoid one-off latency spikes/false winners.
  head -n 6 "$STAGE/ranked" > "$STAGE/finalists"
  : > "$STAGE/retested"
  while read -r initial_ms hostname; do
    probe_domain "$hostname" "$STAGE/recheck"
    if [ -s "$STAGE/recheck" ]; then
      read -r second_ms unused < "$STAGE/recheck"
      printf '%s %s\n' "$((initial_ms + second_ms))" "$hostname" >> "$STAGE/retested"
      : > "$STAGE/recheck"
    fi
  done < "$STAGE/finalists"
  [ -s "$STAGE/retested" ] || die 'Fastest SNI candidates all failed revalidation.'
  SNI=$(sort -n "$STAGE/retested" | head -n 1 | awk '{print $2}')
  validate_domain "$SNI"
  info "Automatically selected SNI=$SNI (TLS 1.3 + HTTP/2, certified, twice checked)."
  info 'SNI and REALITY handshake target will be the SAME domain.'
}

select_release() {
  if [ "$NO_DOWNLOAD" -eq 1 ]; then
    [ -x "$BIN_FILE" ] || die "--no-download requires existing $BIN_FILE"
    NEW_BIN=$BIN_FILE
    info "Offline override: keeping $($BIN_FILE version | head -n 1)"
    return 0
  fi

  info 'Resolving latest official stable sing-box release (no pinned version)...'
  curl -q -fsSL --connect-timeout 9 --max-time 35 \
    -o "$STAGE/release.json" "$RELEASE_API" || die 'Cannot fetch official stable release metadata.'
  jq -e '.prerelease == false and .draft == false' "$STAGE/release.json" >/dev/null || die 'Release metadata is not a stable version.'
  release_tag=$(jq -er '.tag_name' "$STAGE/release.json") || die 'Missing release tag.'
  printf '%s\n' "$release_tag" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$' || die "Unexpected stable release version: $release_tag"
  version=${release_tag#v}
  case "$(uname -m)" in
    x86_64|amd64) arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    i686|i386) arch=386 ;;
    *) die "Unsupported CPU architecture: $(uname -m)" ;;
  esac
  archive_name="sing-box-$version-linux-$arch.tar.gz"
  info "Latest stable=$version, architecture=$arch"
  if [ -x "$BIN_FILE" ] && "$BIN_FILE" version 2>/dev/null | grep -Fq "sing-box version $version"; then
    NEW_BIN=$BIN_FILE
    info 'Current binary is already latest stable; no re-download needed.'
    return 0
  fi
  asset_url=$(jq -er --arg filename "$archive_name" '.assets[] | select(.name==$filename) | .browser_download_url' "$STAGE/release.json") || die "Official asset unavailable: $archive_name"
  asset_digest=$(jq -er --arg filename "$archive_name" '.assets[] | select(.name==$filename) | .digest // empty' "$STAGE/release.json") || die 'No official SHA256 digest for release asset.'
  case "$asset_url" in
    "https://github.com/SagerNet/sing-box/releases/download/$release_tag/"*) : ;;
    *) die "Unexpected binary download URL: $asset_url" ;;
  esac
  case "$asset_digest" in
    sha256:*) asset_sha=${asset_digest#sha256:} ;;
    *) die "Unexpected digest format: $asset_digest" ;;
  esac
  printf '%s\n' "$asset_sha" | grep -Eq '^[0-9a-fA-F]{64}$' || die 'Invalid SHA256 digest in release metadata.'
  info "Downloading official $archive_name..."
  curl -q -fL --retry 2 --connect-timeout 15 --max-time 300 -o "$STAGE/$archive_name" "$asset_url" || die 'Download failed.'
  printf '%s  %s\n' "$asset_sha" "$STAGE/$archive_name" | sha256sum -c - >/dev/null || die 'SHA256 does not match official release metadata.'
  # Validate safe expected archive member path, rather than extracting arbitrary tar paths as root.
  archive_member="sing-box-$version-linux-$arch/sing-box"
  tar -tzf "$STAGE/$archive_name" | grep -Fxq "$archive_member" || die 'Official tarball does not contain expected sing-box path.'
  mkdir -p "$STAGE/extracted"
  tar -xOzf "$STAGE/$archive_name" "$archive_member" > "$STAGE/extracted/sing-box" || die 'Could not extract official sing-box binary.'
  chmod 700 "$STAGE/extracted/sing-box"
  "$STAGE/extracted/sing-box" version >/dev/null || die 'Downloaded sing-box binary could not start.'
  NEW_BIN=$STAGE/extracted/sing-box
  REPLACE_BINARY=1
  info 'Verified official release checksum and executable.'
}


# Do not hardcode sing-box version. HY2 with ACME/Gecko requires 1.14+.
require_recent_binary() {
  [ "$USE_HY2" -eq 1 ] || return 0
  v=$("$NEW_BIN" version | awk '/^sing-box version / {print $3; exit}')
  [ -n "$v" ] || die 'Could not determine sing-box version.'
  printf '%s\n' "$v" | awk -F. '{exit !(($1>1) || ($1==1 && $2>=14))}' || die 'HY2 configuration needs sing-box 1.14 or newer.'
  "$NEW_BIN" version | grep -q with_acme || die 'sing-box binary must be built with with_acme.'
}

generate_credentials() {
  if [ "$USE_REALITY" -eq 1 ]; then
    UUID=$(cat /proc/sys/kernel/random/uuid)
    SHORT_ID=$(openssl rand -hex 4)
    key_output=$("$NEW_BIN" generate reality-keypair) || die 'Could not generate REALITY keys.'
    PRIVATE_KEY=$(printf '%s\n' "$key_output" | awk -F ': *' 'tolower($1) ~ /private/ {print $2;exit}')
    PUBLIC_KEY=$(printf '%s\n' "$key_output" | awk -F ': *' 'tolower($1) ~ /public/ {print $2;exit}')
    for k in "$PRIVATE_KEY" "$PUBLIC_KEY"; do
      printf '%s\n' "$k" | grep -Eq '^[A-Za-z0-9_-]{43}$' || die 'Unexpected REALITY key format.'
    done
  fi
  if [ "$USE_HY2" -eq 1 ]; then
    HY2_PASSWORD=$(openssl rand -hex 24)
    HY2_OBFS_PASSWORD=$(openssl rand -hex 24)
  fi
}

build_configs() {
  if [ -z "$HY2_INTERFACE" ]; then
    HY2_INTERFACE=$(ip -4 route show default | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1);exit}}')
  fi
  case "$HY2_INTERFACE" in ''|*[!A-Za-z0-9_.:@-]*) die 'Cannot identify HY2 ingress interface; set HY2_INTERFACE.' ;; esac
  # Each inbound is an independent JSON object, joined by jq (not string concatenation).
  : > "$STAGE/inbounds.jsonl"
  if [ "$USE_REALITY" -eq 1 ]; then
    jq -cn --arg uuid "$UUID" --arg sid "$SHORT_ID" --arg priv "$PRIVATE_KEY" \
      --arg sni "$SNI" --argjson port "$REALITY_PORT" '
      {type:"vless",tag:"reality-in",listen:"0.0.0.0",listen_port:$port,
       users:[{uuid:$uuid,flow:"xtls-rprx-vision"}],
       tls:{enabled:true,server_name:$sni,reality:{enabled:true,
          handshake:{server:$sni,server_port:443},private_key:$priv,short_id:[$sid]}}}
    ' >> "$STAGE/inbounds.jsonl"

    jq -n --arg name "$TAG-reality" --arg address "$SERVER" --argjson port "$REALITY_PORT" \
      --arg uuid "$UUID" --arg sid "$SHORT_ID" --arg pub "$PUBLIC_KEY" --arg sni "$SNI" '
      {type:"vless",tag:$name,server:$address,server_port:$port,uuid:$uuid,
       flow:"xtls-rprx-vision",tls:{enabled:true,server_name:$sni,
       utls:{enabled:true,fingerprint:"chrome"},
       reality:{enabled:true,public_key:$pub,short_id:$sid}}}
    ' > "$STAGE/reality-client.json"
  fi

  if [ "$USE_HY2" -eq 1 ]; then
    # Keep the DNS credential in a private file/stdin, never in jq's argv or clients.
    printf '%s' "$CF_API_TOKEN" > "$STAGE/cf-api-token"
    printf '%s' "$CF_ZONE_TOKEN" > "$STAGE/cf-zone-token"
    jq -n --arg domain "$HY2_DOMAIN" --arg directory "$ACME_DATA_DIR" --arg email "$ACME_EMAIL" \
      --rawfile token "$STAGE/cf-api-token" --rawfile zone "$STAGE/cf-zone-token" '
      {enabled:true,server_name:$domain,certificate_provider:{type:"acme",domain:[$domain],
       data_directory:$directory,default_server_name:$domain,email:$email,provider:"letsencrypt",
       key_type:"p256",disable_http_challenge:true,disable_tls_alpn_challenge:true,
       dns01_challenge:({provider:"cloudflare",api_token:$token} +
         (if $zone!="" then {zone_token:$zone} else {} end))}}
    ' > "$STAGE/hy2-tls.json"
    rm -f "$STAGE/cf-api-token" "$STAGE/cf-zone-token"
    jq -n --arg domain "$HY2_DOMAIN" '{enabled:true,server_name:$domain,insecure:false}' > "$STAGE/hy2-client-tls.json"
    jq -cn --arg pwd "$HY2_PASSWORD" \
      --arg obfs_pass "$HY2_OBFS_PASSWORD" --argjson port "$HY2_PORT" \
      --slurpfile tls "$STAGE/hy2-tls.json" '
      {type:"hysteria2",tag:"hy2-in",listen:"0.0.0.0",listen_port:$port,
       users:[{name:"client",password:$pwd}],ignore_client_bandwidth:true,
       bbr_profile:"standard",tls:$tls[0],obfs:{type:"gecko",password:$obfs_pass}}
    ' >> "$STAGE/inbounds.jsonl"

    jq -n --arg name "$TAG-hy2" --arg address "$HY2_DOMAIN" \
      --arg ports "$HY2_HOP_START:$HY2_HOP_END" --arg interval "$HY2_HOP_INTERVAL" \
      --arg pwd "$HY2_PASSWORD" --arg obfs_pass "$HY2_OBFS_PASSWORD" \
      --slurpfile tls "$STAGE/hy2-client-tls.json" '
      {type:"hysteria2",tag:$name,server:$address,server_ports:[$ports],hop_interval:$interval,
       password:$pwd,bbr_profile:"standard",tls:$tls[0],obfs:{type:"gecko",password:$obfs_pass}}
    ' > "$STAGE/hysteria2-client.json"
  fi

  jq -s '{log:{level:"info",timestamp:true},inbounds:.,outbounds:[{type:"direct",tag:"direct"}]}' \
    "$STAGE/inbounds.jsonl" > "$STAGE/config.json"

  cat > "$STAGE/hysteria2-hop.nft" <<EOF
# Only this table is owned by sing-box. A single nft transaction is repeatable.
add table inet sing_box_hy2
flush table inet sing_box_hy2
table inet sing_box_hy2 {
  chain prerouting {
    type nat hook prerouting priority dstnat; policy accept;
    iifname "$HY2_INTERFACE" udp dport $HY2_HOP_START-$HY2_HOP_END counter redirect to :$HY2_PORT
  }
}
EOF
  "$NFT_BIN" -c -f "$STAGE/hysteria2-hop.nft" || die 'HY2 port hopping rules could not be validated.'

  cat > "$STAGE/sing-box.service" <<EOF
[Unit]
Description=sing-box Proxy Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStartPre=$NFT_BIN -f $HY2_HOP_FILE
ExecStartPre=$BIN_FILE check -c $CONFIG_FILE
ExecStart=$BIN_FILE run -c $CONFIG_FILE
ExecStopPost=-$NFT_BIN delete table inet sing_box_hy2
Restart=on-failure
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
  "$NEW_BIN" check -c "$STAGE/config.json" || die 'Generated server configuration is invalid.'
  if [ "$USE_REALITY" -eq 1 ]; then
    jq -e '.type=="vless" and .tls.reality.enabled==true' "$STAGE/reality-client.json" >/dev/null || die 'Invalid REALITY client.'
  fi
  if [ "$USE_HY2" -eq 1 ]; then
    jq -e '.type=="hysteria2" and .tls.enabled==true' "$STAGE/hysteria2-client.json" >/dev/null || die 'Invalid Hysteria2 client.'
    jq '{outbounds:[.]}' "$STAGE/hysteria2-client.json" > "$STAGE/hy2-client-check.json"
    "$NEW_BIN" check -c "$STAGE/hy2-client-check.json" || die 'Generated HY2 client configuration is invalid.'
  fi
}

check_socket_conflict() {
  label=$1
  number=$2
  case "$label" in tcp) result=$(ss -H -ltnp "sport = :$number" 2>/dev/null || :) ;;
    udp) result=$(ss -H -lunp "sport = :$number" 2>/dev/null || :) ;;
  esac
  [ -z "$result" ] && return 0
  case "$result" in
    *sing-box*) info "Existing sing-box listener on $label/$number will be replaced." ;;
    *) warn "$result"; die "$label/$number already belongs to another service." ;;
  esac
}

check_ports() {
  [ "$USE_REALITY" -eq 0 ] || check_socket_conflict tcp "$REALITY_PORT"
  [ "$USE_HY2" -eq 0 ] || check_socket_conflict udp "$HY2_PORT"
  result=$(ss -H -lunp "( sport >= :$HY2_HOP_START and sport <= :$HY2_HOP_END )" 2>/dev/null | grep -v sing-box || :)
  [ -z "$result" ] || { warn "$result"; die 'HY2 hopping range overlaps another UDP listener.'; }
}

backup_old() {
  BACKUP=$BACKUP_ROOT/$(date +%Y%m%d-%H%M%S)-$$
  mkdir -p "$BACKUP"
  chmod 700 "$BACKUP"
  for file in "$CONFIG_FILE" "$REALITY_CLIENT" "$HY2_CLIENT" "$HY2_CERT_FILE" "$HY2_KEY_FILE" "$HY2_HOP_FILE" "$UNIT_FILE"; do
    [ ! -e "$file" ] || cp -p "$file" "$BACKUP/$(basename "$file")"
  done
  "$NFT_BIN" list table inet sing_box_hy2 > "$BACKUP/hysteria2-hop.table" 2>/dev/null || rm -f "$BACKUP/hysteria2-hop.table"
  if [ "$REPLACE_BINARY" -eq 1 ] && [ -e "$BIN_FILE" ]; then
    cp -p "$BIN_FILE" "$BACKUP/$(basename "$BIN_FILE")"
  fi
  systemctl is-active --quiet sing-box && OLD_ACTIVE=1 || :
  systemctl is-enabled --quiet sing-box && OLD_ENABLED=1 || :
  info "Backup: $BACKUP"
}

restore_one() {
  file=$1
  base=$(basename "$file")
  if [ -f "$BACKUP/$base" ]; then
    cp -p "$BACKUP/$base" "$file" || warn "Could not restore $file"
  else
    rm -f "$file" || warn "Could not delete $file"
  fi
}

rollback() {
  warn 'Deployment failed, restoring previous service and configuration.'
  COMMIT=0
  systemctl stop sing-box >/dev/null 2>&1 || :
  "$NFT_BIN" delete table inet sing_box_hy2 >/dev/null 2>&1 || :
  for file in "$CONFIG_FILE" "$REALITY_CLIENT" "$HY2_CLIENT" "$HY2_CERT_FILE" "$HY2_KEY_FILE" "$HY2_HOP_FILE" "$UNIT_FILE"; do
    restore_one "$file"
  done
  if [ "$REPLACE_BINARY" -eq 1 ]; then restore_one "$BIN_FILE"; fi
  systemctl daemon-reload >/dev/null 2>&1 || :
  if [ "$OLD_ENABLED" -eq 1 ]; then systemctl enable sing-box >/dev/null 2>&1 || :
  else systemctl disable sing-box >/dev/null 2>&1 || :; fi
  if [ "$OLD_ACTIVE" -eq 1 ]; then
    systemctl restart sing-box >/dev/null 2>&1 || warn 'Previous sing-box service failed to restart.'
  else systemctl stop sing-box >/dev/null 2>&1 || :; fi
  # Restore after service hooks have run, including the inactive-service case.
  if [ -f "$BACKUP/hysteria2-hop.table" ]; then
    { printf 'add table inet sing_box_hy2\nflush table inet sing_box_hy2\n'; cat "$BACKUP/hysteria2-hop.table"; } |
      "$NFT_BIN" -f - || warn 'Could not restore previous HY2 hopping rules.'
  fi
  warn "Backup retained: $BACKUP"
}

stop_test_client() {
  if [ -n "$PROBE_PID" ]; then
    kill "$PROBE_PID" >/dev/null 2>&1 || :
    wait "$PROBE_PID" >/dev/null 2>&1 || :
    PROBE_PID=
  fi
}

cleanup() {
  code=$1
  if [ -n "$TTY_STATE" ]; then stty "$TTY_STATE" 2>/dev/null || :; fi
  trap - 0 1 2 3 15
  stop_test_client
  if [ "$COMMIT" -eq 1 ]; then rollback; fi
  if [ -n "$STAGE" ] && [ -d "$STAGE" ]; then rm -rf "$STAGE"; fi
  exit "$code"
}

check_log() { printf '%s\n' "$*" | tee -a "$REPORT_FILE" >&2; }
start_check_report() {
  mkdir -p "$(dirname "$REPORT_FILE")" || return 1
  (umask 077; : > "$REPORT_FILE") || return 1
  chmod 600 "$REPORT_FILE" || :
  check_log '========== sing-box protocol connection check =========='
  check_log "Time: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
  check_log "sing-box: $("$BIN_FILE" version 2>/dev/null | head -n 1)"
}

redact_logs() {
  # Cloudflare tokens may appear in upstream ACME errors; redact exact values.
  CF_REDACT_TOKEN=$CF_API_TOKEN CF_REDACT_ZONE=$CF_ZONE_TOKEN awk '
    BEGIN {a=ENVIRON["CF_REDACT_TOKEN"]; b=ENVIRON["CF_REDACT_ZONE"]}
    function mask(t,s, out,p) {
      if(s=="") return t
      out=""
      while((p=index(t,s))>0){out=out substr(t,1,p-1) "<CF_TOKEN>"; t=substr(t,p+length(s))}
      return out t
    }
    {print mask(mask($0,a),b)}
  ' |
  sed -E \
    -e 's/[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}/<UUID>/g' \
    -e 's/[[:xdigit:]]{48,}/<SECRET>/g' \
    -e 's/[A-Za-z0-9_-]{43}/<KEY>/g'
}

collect_diagnostics() {
  check_log "Diagnostic file: $REPORT_FILE"
  {
    printf '\n--- Service status ---\n'
    systemctl status sing-box --no-pager -l 2>&1 | tail -n 35 || :
    printf '\n--- Listeners ---\n'
    if [ "$USE_REALITY" -eq 1 ]; then ss -H -ltnp "sport = :$REALITY_PORT" 2>&1 || :; fi
    if [ "$USE_HY2" -eq 1 ]; then ss -H -lunp "sport = :$HY2_PORT" 2>&1 || :; fi
    if [ -n "$TEST_SOCKS_PORT" ]; then ss -H -ltnp "sport = :$TEST_SOCKS_PORT" 2>&1 || :; fi
    printf '\n--- Server config check ---\n'
    "$BIN_FILE" check -c "$CONFIG_FILE" 2>&1 || :
    printf '\n--- Temporary client config check ---\n'
    if [ -f "$STAGE/probe.json" ]; then "$BIN_FILE" check -c "$STAGE/probe.json" 2>&1 || :; fi
    printf '\n--- Temporary client log ---\n'
    [ ! -f "$STAGE/probe.log" ] || tail -n 100 "$STAGE/probe.log"
    printf '\n--- HTTPS through proxy ---\n'
    for name in first second; do
      [ ! -f "$STAGE/curl-$name.log" ] || {
        printf '\n%s (exit: ' "$name"
        cat "$STAGE/curl-$name.exit" 2>/dev/null || printf '?'
        printf '):\n'
        tail -n 65 "$STAGE/curl-$name.log"
        cat "$STAGE/curl-$name.out" 2>/dev/null || :
      }
    done
    printf '\n--- Server journal ---\n'
    journalctl -u sing-box -n 100 --no-pager -o short-iso 2>&1 || :
    printf '\n--- Direct HTTPS baseline ---\n'
    curl -q --noproxy '*' --connect-timeout 5 --max-time 12 -fsS -o /dev/null \
      -w 'HTTP=%{http_code} TLS_VERIFY=%{ssl_verify_result}\n' \
      https://api.ipify.org/ 2>&1 || :
    if [ "$CHECK_PROTO" = REALITY ] && [ -n "$SNI" ]; then
      printf '\n--- REALITY destination TLS handshake ---\n'
      timeout 8 openssl s_client -brief -tls1_3 -connect "$SNI:443" -servername "$SNI" \
        </dev/null 2>&1 | tail -n 25 || :
    fi
    printf '\n--- End diagnostics ---\n'
  } 2>&1 | redact_logs | tee -a "$REPORT_FILE" >&2
}

check_fail() {
  CHECK_REASON=$1
  check_log "CHECK FAIL | protocol=$CHECK_PROTO | phase=$CHECK_PHASE | reason=$CHECK_REASON"
  collect_diagnostics
  return 1
}

read_saved_protocols() {
  [ -s "$CONFIG_FILE" ] || die "Missing server config: $CONFIG_FILE"
  USE_REALITY=$(jq -r '[.inbounds[] | select(.type=="vless")] | length>0' "$CONFIG_FILE")
  USE_HY2=$(jq -r '[.inbounds[] | select(.type=="hysteria2")] | length>0' "$CONFIG_FILE")
  [ "$USE_REALITY" = true ] && USE_REALITY=1 || USE_REALITY=0
  [ "$USE_HY2" = true ] && USE_HY2=1 || USE_HY2=0
  [ "$USE_REALITY" -eq 1 ] || [ "$USE_HY2" -eq 1 ] || die 'No supported protocols in saved config.'
  if [ "$USE_REALITY" -eq 1 ]; then
    [ -f "$REALITY_CLIENT" ] || die 'REALITY outbound JSON is missing.'
    REALITY_PORT=$(jq -er '.server_port' "$REALITY_CLIENT")
    SNI=$(jq -er '.tls.server_name' "$REALITY_CLIENT")
  fi
  if [ "$USE_HY2" -eq 1 ]; then
    [ -f "$HY2_CLIENT" ] || die 'Hysteria2 outbound JSON is missing.'
    HY2_PORT=$(jq -er '.inbounds[] | select(.type=="hysteria2") | .listen_port' "$CONFIG_FILE")
    HY2_DOMAIN=$(jq -er '.tls.server_name' "$HY2_CLIENT")
    CF_API_TOKEN=$(jq -r '.inbounds[] | select(.type=="hysteria2") | .tls.certificate_provider.dns01_challenge.api_token // ""' "$CONFIG_FILE")
    CF_ZONE_TOKEN=$(jq -r '.inbounds[] | select(.type=="hysteria2") | .tls.certificate_provider.dns01_challenge.zone_token // ""' "$CONFIG_FILE")
  fi
}

crosscheck() {
  CHECK_PHASE=CONFIG
  if ! "$BIN_FILE" check -c "$CONFIG_FILE" > "$STAGE/config-check.log" 2>&1; then
    check_fail 'sing-box rejected saved server config.'
    return 1
  fi
  if [ "$USE_REALITY" -eq 1 ]; then
    CHECK_PROTO=REALITY
    if ! jq -e -n --slurpfile s "$CONFIG_FILE" --slurpfile c "$REALITY_CLIENT" '
      ($s[0].inbounds | map(select(.type=="vless")) | .[0]) as $i |
      $c[0] as $o | ($i!=null and $o.type=="vless"
        and $i.listen_port==$o.server_port
        and ($i.users|any(.uuid==$o.uuid and .flow==$o.flow))
        and $i.tls.server_name==$o.tls.server_name
        and $i.tls.reality.handshake.server==$o.tls.server_name
        and ($i.tls.reality.short_id|index($o.tls.reality.short_id))!=null)
    ' >/dev/null 2>&1; then
      check_fail 'REALITY server/client UUID, flow, SNI, Short ID or port mismatch.'
      return 1
    fi
    check_log "CONFIG CHECK PASS | REALITY TCP/$REALITY_PORT"
  fi
  if [ "$USE_HY2" -eq 1 ]; then
    CHECK_PROTO=HY2
    if ! jq -e -n --slurpfile s "$CONFIG_FILE" --slurpfile c "$HY2_CLIENT" '
      ($s[0].inbounds | map(select(.type=="hysteria2")) | .[0]) as $i |
      $c[0] as $o | ($i!=null and $o.type=="hysteria2"
        and $o.server_ports==["20000:50000"] and $o.server_port==null
        and $o.hop_interval=="30s"
        and ($i.users|any(.password==$o.password))
        and $i.bbr_profile=="standard" and $o.bbr_profile=="standard"
        and $i.ignore_client_bandwidth==true
        and ($i | has("up_mbps")|not) and ($o | has("up_mbps")|not)
        and ($i.obfs // null)==($o.obfs // null)
        and $i.obfs.type=="gecko"
        and $i.tls.certificate_provider.type=="acme"
        and $i.tls.certificate_provider.dns01_challenge.provider=="cloudflare"
        and $i.tls.certificate_provider.domain==[$o.server]
        and $i.tls.server_name==$o.server and $o.tls.server_name==$o.server
        and $i.tls.enabled==true and $o.tls.enabled==true
        and $o.tls.insecure==false)
    ' >/dev/null 2>&1; then
      check_fail 'HY2 server/client password, obfs, BBR, port or TLS mismatch.'
      return 1
    fi
    check_log "CONFIG CHECK PASS | HY2 $HY2_DOMAIN, Cloudflare DNS-01, Gecko, UDP 20000-50000 -> $HY2_PORT"
  fi
}

check_service() {
  CHECK_PHASE=SERVICE
  CHECK_PROTO=SERVICE
  # DNS-01 may need propagation time on the first start. Wait before declaring
  # missing listeners a failure; issuance and renewal remain owned by sing-box.
  waited=0
  while [ "$waited" -lt 180 ]; do
    ready=1
    systemctl is-active --quiet sing-box || ready=0
    if [ "$USE_REALITY" -eq 1 ]; then
      ss -H -ltn "sport = :$REALITY_PORT" 2>/dev/null | grep -q LISTEN || ready=0
    fi
    if [ "$USE_HY2" -eq 1 ]; then
      ss -H -lun "sport = :$HY2_PORT" 2>/dev/null | grep -q UNCONN || ready=0
    fi
    [ "$ready" -eq 0 ] || break
    systemctl is-failed --quiet sing-box && break
    if [ "$((waited % 30))" -eq 0 ]; then check_log "Waiting for sing-box / ACME DNS-01 ($waited/180s)..."; fi
    sleep 2
    waited=$((waited + 2))
  done
  if ! systemctl is-active --quiet sing-box; then
    check_fail 'sing-box service is not active.'
    return 1
  fi
  if [ "$USE_REALITY" -eq 1 ]; then
    CHECK_PROTO=REALITY
    if ! ss -H -ltn "sport = :$REALITY_PORT" 2>/dev/null | grep -q LISTEN; then
      check_fail "No REALITY TCP listener on $REALITY_PORT."
      return 1
    fi
    check_log "SERVICE CHECK PASS | REALITY TCP/$REALITY_PORT listening"
  fi
  if [ "$USE_HY2" -eq 1 ]; then
    CHECK_PROTO=HY2
    if ! ss -H -lun "sport = :$HY2_PORT" 2>/dev/null | grep -q UNCONN; then
      check_fail "No HY2 UDP listener on $HY2_PORT."
      return 1
    fi
    check_log "SERVICE CHECK PASS | HY2 UDP/$HY2_PORT listening"
    if ! "$NFT_BIN" -j list table inet sing_box_hy2 | jq -e --argjson port "$HY2_PORT" '
      [.nftables[] | .rule? | select(.chain=="prerouting") | .expr[]] as $e |
      any($e[]; .match.left.payload.protocol=="udp" and .match.left.payload.field=="dport"
        and .match.right.range==[20000,50000]) and any($e[]; .redirect.port==$port)
    ' >/dev/null 2>&1; then
      check_fail 'HY2 UDP port hopping rule is missing or inconsistent.'
      return 1
    fi
    check_log 'SERVICE CHECK PASS | HY2 UDP 20000-50000 redirect rule installed'
  fi
}

choose_socks_port() {
  TEST_SOCKS_PORT=37071
  while [ "$TEST_SOCKS_PORT" -le 37100 ]; do
    used=$(ss -H -ltn "sport = :$TEST_SOCKS_PORT" 2>/dev/null || :)
    [ -n "$used" ] || return 0
    TEST_SOCKS_PORT=$((TEST_SOCKS_PORT + 1))
  done
  check_fail 'No free local SOCKS port (37071..37100).'
  return 1
}

build_probe() {
  proto=$1
  case "$proto" in
    REALITY) node=$REALITY_CLIENT ;;
    HY2) node=$HY2_CLIENT ;;
    *) check_fail "Unknown protocol $proto"; return 1 ;;
  esac
  choose_socks_port || return 1
  # Loopback bypasses PREROUTING, so the local HY2 protocol check dials the
  # listener directly. Public hopping is verified separately from this probe.
  if ! jq -n --arg proto "$proto" --argjson listener "$HY2_PORT" \
    --argjson port "$TEST_SOCKS_PORT" --slurpfile node "$node" '
    {log:{level:"debug",timestamp:true},
     inbounds:[{type:"socks",tag:"probe-in",listen:"127.0.0.1",listen_port:$port}],
     outbounds:[($node[0] | .server="127.0.0.1" |
       if $proto=="HY2" then del(.server_ports,.hop_interval,.hop_interval_max) | .server_port=$listener else . end)],
     route:{final:$node[0].tag}}
  ' > "$STAGE/probe.json" 2> "$STAGE/probe-config.log"; then
    check_fail 'Could not generate temporary sing-box client.'
    return 1
  fi
  if ! "$BIN_FILE" check -c "$STAGE/probe.json" >> "$STAGE/probe-config.log" 2>&1; then
    check_fail 'sing-box rejected temporary client JSON.'
    return 1
  fi
}

probe_url() {
  label=$1
  url=$2
  if curl -q --fail -sS -v --noproxy '' --proxy "socks5h://127.0.0.1:$TEST_SOCKS_PORT" \
    --connect-timeout 8 --max-time 26 -o /dev/null \
    -w 'HTTP=%{http_code} TLS_VERIFY=%{ssl_verify_result} TOTAL_SEC=%{time_total}\n' \
    "$url" > "$STAGE/curl-$label.out" 2> "$STAGE/curl-$label.log"; then
    printf '0\n' > "$STAGE/curl-$label.exit"
    return 0
  else
    status=$?
    printf '%s\n' "$status" > "$STAGE/curl-$label.exit"
    return 1
  fi
}

start_test_client() {
  "$BIN_FILE" run -c "$STAGE/probe.json" > "$STAGE/probe.log" 2>&1 &
  PROBE_PID=$!
  count=0
  while [ "$count" -lt 24 ]; do
    if ss -H -ltn "sport = :$TEST_SOCKS_PORT" 2>/dev/null | grep -q LISTEN; then return 0; fi
    kill -0 "$PROBE_PID" 2>/dev/null || break
    sleep 0.25
    count=$((count + 1))
  done
  check_fail 'Temporary SOCKS client never opened its local port.'
  return 1
}

probe_protocol() {
  CHECK_PROTO=$1
  CHECK_PHASE=CLIENT
  rm -f "$STAGE"/probe.json "$STAGE"/probe.log "$STAGE"/curl-*.log "$STAGE"/curl-*.out "$STAGE"/curl-*.exit
  build_probe "$1" || return 1
  start_test_client || return 1
  check_log "CLIENT CHECK PASS | $1 local SOCKS initialized"
  CHECK_PHASE=HTTPS
  if [ "$1" = REALITY ]; then
    first_url="https://$SNI/"
  else
    first_url='https://api.ipify.org/'
  fi
  attempts=1
  if [ "$1" = HY2 ]; then attempts=4; fi
  attempt=1
  while [ "$attempt" -le "$attempts" ]; do
    if probe_url first "$first_url" || probe_url second 'https://www.cloudflare.com/cdn-cgi/trace'; then
      check_log "HTTPS CHECK PASS | $1 | authenticated and proxied request succeeded"
      stop_test_client
      return 0
    fi
    [ "$attempt" -ge "$attempts" ] && break
    check_log "HTTPS CHECK RETRY | $1 ($attempt/$attempts)"
    sleep 5
    attempt=$((attempt + 1))
  done
  check_fail "Real $1 handshake/authentication or HTTPS forwarding failed."
  stop_test_client
  return 1
}

run_checks() {
  start_check_report || die "Cannot open report: $REPORT_FILE"
  crosscheck || return 1
  check_service || return 1
  if [ "$USE_REALITY" -eq 1 ]; then probe_protocol REALITY || return 1; fi
  if [ "$USE_HY2" -eq 1 ]; then probe_protocol HY2 || return 1; fi
  check_log 'CHECK PASS'
}

print_clients() {
  if [ -f "$REALITY_CLIENT" ]; then
    printf '\n--- REALITY sing-box outbound ---\n'
    cat "$REALITY_CLIENT"
    printf '\n--- VLESS URI ---\n'
    jq -r '
      . as $c | $c.tls as $t |
      (if ($c.server | contains(":")) then "["+$c.server+"]" else $c.server end) as $host |
      "vless://\($c.uuid)@\($host):\($c.server_port)?encryption=none&security=reality&type=tcp&flow=\($c.flow)&sni=\($t.server_name|@uri)&fp=\($t.utls.fingerprint|@uri)&pbk=\($t.reality.public_key|@uri)&sid=\($t.reality.short_id)&#\($c.tag|@uri)"
    ' "$REALITY_CLIENT"
  fi
  if [ -f "$HY2_CLIENT" ]; then
    printf '\n--- Hysteria2 sing-box outbound ---\n'
    cat "$HY2_CLIENT"
    if ! jq -e '.tls.certificate != null' "$HY2_CLIENT" >/dev/null; then
      printf '\n--- Hysteria2 URI ---\n'
      jq -r '
        . as $c | (if ($c.server|contains(":")) then "["+$c.server+"]" else $c.server end) as $host |
        (if $c.server_ports then ($c.server_ports|map(gsub(":";"-"))|join(",")) else ($c.server_port|tostring) end) as $ports |
        "hysteria2://\($c.password|@uri)@\($host):\($ports)/?sni=\($c.tls.server_name|@uri)" +
        (if $c.obfs then "&obfs=\($c.obfs.type|@uri)&obfs-password=\($c.obfs.password|@uri)" else "" end) +
        "#\($c.tag|@uri)"
      ' "$HY2_CLIENT"
    fi
  fi
}

deploy() {
  require_root
  USE_REALITY=1
  USE_HY2=1
  info 'Installing REALITY (TCP) + Hysteria2 (UDP).'
  confirm_reconfiguration
  prompt_settings
  validate_settings
  ensure_dependencies
  resolve_server
  STAGE=$(mktemp -d)
  select_sni
  select_release
  require_recent_binary
  generate_credentials
  build_configs
  check_ports
  mkdir -p "$CONFIG_DIR" "$(dirname "$UNIT_FILE")" "$(dirname "$BIN_FILE")"
  chmod 700 "$CONFIG_DIR"
  backup_old
  COMMIT=1
  if [ "$REPLACE_BINARY" -eq 1 ]; then install -m 755 "$NEW_BIN" "$BIN_FILE"; fi
  install -m 600 "$STAGE/config.json" "$CONFIG_FILE"
  install -m 600 "$STAGE/reality-client.json" "$REALITY_CLIENT"
  install -m 600 "$STAGE/hysteria2-client.json" "$HY2_CLIENT"
  install -m 600 "$STAGE/hysteria2-hop.nft" "$HY2_HOP_FILE"
  rm -f "$HY2_CERT_FILE" "$HY2_KEY_FILE"
  mkdir -p "$ACME_DATA_DIR"
  chmod 700 "$ACME_DATA_DIR"
  install -m 644 "$STAGE/sing-box.service" "$UNIT_FILE"
  systemctl daemon-reload
  systemctl enable sing-box >/dev/null
  if ! systemctl restart sing-box; then
    start_check_report || :
    CHECK_PHASE=SERVICE
    CHECK_PROTO=SERVICE
    check_fail 'systemctl restart sing-box failed.' || :
    die "CHECK FAIL | report=$REPORT_FILE"
  fi
  sleep 2
  if [ "$SKIP_TEST" -eq 0 ]; then
    run_checks || die "CHECK FAIL | report=$REPORT_FILE"
  else
    systemctl is-active --quiet sing-box || die 'sing-box service is not active.'
    warn 'CHECK SKIPPED (--skip-test)'
  fi
  COMMIT=0
  info "Installed: REALITY TCP/$REALITY_PORT + HY2 $HY2_DOMAIN (Cloudflare DNS-01, Gecko, UDP 20000-50000)"
  info 'Allow UDP 20000-50000 in the VPS/security-group firewall; use Cloudflare DNS-only.'
  print_clients
}

main() {
  parse_args "$@"
  trap 'cleanup $?' 0
  trap 'exit 130' 2
  trap 'exit 143' 15
  case "$COMMAND" in
    deploy|reconfigure) deploy ;;
    show) require_root; command -v jq >/dev/null 2>&1 || die 'jq required'; print_clients ;;
    status) require_root; systemctl status sing-box --no-pager -l || :; ss -ltunp | grep sing-box || : ;;
    test)
      require_root
      # Only test tools are needed; existing config is never regenerated.
      command -v jq >/dev/null 2>&1 || die 'jq required for reading saved configuration.'
      read_saved_protocols
      ensure_dependencies
      [ -x "$BIN_FILE" ] || die "Missing sing-box binary: $BIN_FILE"
      STAGE=$(mktemp -d)
      run_checks || die "CHECK FAIL | report=$REPORT_FILE"
      ;;
  esac
}
main "$@"
