#!/usr/bin/env bash
# Fresh sing-box VLESS + REALITY + Vision installer for Debian/Ubuntu + systemd.
# Re-running the script asks [Y/n] (Enter = yes) and creates NEW credentials.
# No legacy state migration or configuration compatibility is attempted.
set -Eeuo pipefail
umask 077

readonly CONFIG_DIR=/etc/sing-box
readonly CONFIG_PATH=/etc/sing-box/config.json
readonly CLIENT_PATH=/etc/sing-box/reality-client.json
readonly UNIT_PATH=/etc/systemd/system/sing-box.service
readonly BIN_PATH=/usr/local/bin/sing-box
readonly VERSION=1.14.4

COMMAND=deploy
SERVER=""
PORT=443
SNI=www.microsoft.com
TAG=DMIT-Reality
YES=0
SKIP_TARGET_CHECK=0
SKIP_TEST=0
NO_DOWNLOAD=0
PORT_SET=0
SNI_SET=0
SERVER_SET=0
TAG_SET=0
WORK_DIR=""
BACKUP_DIR=""
ROLLBACK_ARMED=0
BINARY_ROLLBACK=0
PREV_ACTIVE=0
PREV_ENABLED=0

say()  { printf '[INFO] %s\n' "$*" >&2; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
fail() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

usage() {
cat <<'EOF'
Fresh sing-box VLESS + REALITY + Vision deployment (Debian/Ubuntu + systemd)

Usage:
  sudo bash vlessreality.sh [deploy] [--port 443] [--sni www.microsoft.com] [--server IP]
  sudo bash vlessreality.sh reconfigure
  sudo bash vlessreality.sh show
  sudo bash vlessreality.sh test
  sudo bash vlessreality.sh status

Commands:
  deploy   Fresh install / fresh reconfiguration. Existing config prompts [Y/n]; Enter = yes.
  reconfigure  Same as deploy; no previous credentials/configuration are imported.
  show     Show the saved sing-box outbound JSON and VLESS URI (never generates new keys).
  test     Run a local SOCKS -> VLESS/REALITY -> HTTPS end-to-end probe.
  status   Show sing-box status and listening ports.

Options:
  --port PORT            VLESS TCP listener; default 443.
  --sni DOMAIN           REALITY SNI and upstream handshake target; default www.microsoft.com.
  --server HOST          Public VPS IP/domain for clients; auto-detected by default.
  --tag NAME             Client node name; default DMIT-Reality.
  --yes                  Auto-confirm and accept defaults (non-interactive).
  --skip-target-check    Bypass upstream TLS 1.3/certificate preflight.
  --skip-test            Bypass the local end-to-end probe during deployment.
  --no-download          Require an existing /usr/local/bin/sing-box binary.
  -h, --help             Show help.

IMPORTANT:
  * All existing server config and clients are replaced with NEW UUID/key/Short ID.
  * No legacy configuration or .env file is imported.
  * Backups are made before overwriting, with rollback if startup/test fails.
  * This script doesn't change SSH, TCP congestion control, or firewall rules.
  * Keep the working SSH :2222 or VNC session open until PUBLIC access is tested.
EOF
}

parse_args() {
  case "${1:-}" in
    deploy|reconfigure|show|test|status) COMMAND="$1"; shift ;;
    -h|--help) usage; exit 0 ;;
  esac
  while (($#)); do
    case "$1" in
      --port|--sni|--server|--tag)
        (($# >= 2)) || fail "Missing value for $1"
        [[ -n "$2" ]] || fail "Empty value for $1"
        case "$1" in
          --port) PORT="$2"; PORT_SET=1 ;;
          --sni) SNI="$2"; SNI_SET=1 ;;
          --server) SERVER="$2"; SERVER_SET=1 ;;
          --tag) TAG="$2"; TAG_SET=1 ;;
        esac
        shift 2 ;;
      --yes) YES=1; shift ;;
      --skip-target-check) SKIP_TARGET_CHECK=1; shift ;;
      --skip-test) SKIP_TEST=1; shift ;;
