#!/usr/bin/env bash
# Non-interactive VPS bootstrap for the byJoey BBR v3 kernel.
set -Eeuo pipefail

readonly NAME="bbr-v3-bootstrap"
readonly VERSION="1.0.0"
readonly ROOT_DIR="/usr/local/lib/${NAME}"
readonly SCRIPT_PATH="${ROOT_DIR}/${NAME}.sh"
readonly STATE_DIR="/var/lib/${NAME}"
readonly STATE_FILE="${STATE_DIR}/original-sysctl"
readonly RPS_STATE_FILE="${STATE_DIR}/original-rps"
readonly SYSCTL_FILE="/etc/sysctl.d/99-${NAME}.conf"
readonly LIMITS_FILE="/etc/security/limits.d/99-${NAME}.conf"
readonly GAI_FILE="/etc/gai.conf"
readonly GAI_BACKUP="${STATE_DIR}/gai.conf.original"
readonly GAI_ABSENT="${STATE_DIR}/gai.conf.was-absent"
readonly RESUME_SERVICE="${NAME}-resume.service"
readonly RPS_SERVICE="${NAME}-rps.service"
readonly RELEASES_API="https://api.github.com/repos/byJoey/Actions-bbr-v3/releases"

MODE="apply"
[[ "${1:-}" == "--resume" ]] && MODE="resume"
[[ "${1:-}" == "--rollback" ]] && MODE="rollback"
[[ "${1:-}" == "--apply-rps" ]] && MODE="apply-rps"

log() { printf '[%s] %s\n' "$NAME" "$*"; }
die() { printf '[%s] ERROR: %s\n' "$NAME" "$*" >&2; exit 1; }
require_root() { [[ "${EUID}" -eq 0 ]] || die "run as root"; }

require_supported_os() {
    [[ -r /etc/os-release ]] || die "cannot identify the operating system"
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-}" in
        debian) [[ "${VERSION_ID:-0}" =~ ^([1-9][0-9]*) ]] && (( VERSION_ID >= 12 )) ;;
        ubuntu) [[ "${VERSION_ID:-0}" == "24.04" || "${VERSION_ID:-0}" > "24.04" ]] ;;
        *) return 1 ;;
    esac || die "BBR v3 kernel installation supports Debian 12+ and Ubuntu 24.04+ only"
    case "$(uname -m)" in x86_64|aarch64) ;; *) die "unsupported architecture: $(uname -m)" ;; esac
}

install_dependencies() {
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y --no-install-recommends ca-certificates curl wget jq iproute2 kmod
}

copy_self() {
    mkdir -p "$ROOT_DIR" "$STATE_DIR"
    if [[ "${0}" != "$SCRIPT_PATH" ]]; then
        install -m 0755 "$0" "$SCRIPT_PATH"
    fi
}

has_bbr_v3() {
    [[ "$(modinfo -F version tcp_bbr 2>/dev/null || true)" == "3" ]]
}

arch_filter() {
    case "$(uname -m)" in x86_64) printf 'x86_64';; aarch64) printf 'arm64';; esac
}

install_bbr_v3_kernel() {
    local release_json latest_tag asset_urls tmpdir
    release_json="$(curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 "$RELEASES_API")" \
        || die "cannot retrieve BBR v3 release metadata"
    latest_tag="$(jq -r --arg arch "$(arch_filter)" '
        map(select(.tag_name | test("^" + $arch + "-[0-9]"; "i"))
            | select(.tag_name | endswith("-max") | not))
        | sort_by(.published_at) | .[-1].tag_name // empty
    ' <<<"$release_json")"
    [[ -n "$latest_tag" ]] || die "no standard BBR v3 release for $(uname -m)"
    asset_urls="$(jq -r --arg tag "$latest_tag" '
        .[] | select(.tag_name == $tag) | .assets[].browser_download_url
        | select(endswith(".deb"))
        | select(test("(-dbg_|-dbgsym_)"; "i") | not)
    ' <<<"$release_json")"
    [[ -n "$asset_urls" ]] || die "release $latest_tag has no installable Debian packages"

    tmpdir="$(mktemp -d /tmp/${NAME}.XXXXXX)"
    log "installing BBR v3 kernel release: $latest_tag"
    while IFS= read -r url; do
        [[ -n "$url" ]] || continue
        wget --https-only --secure-protocol=TLSv1_2 --progress=dot:giga -P "$tmpdir" "$url"
    done <<<"$asset_urls"
    compgen -G "$tmpdir/*.deb" >/dev/null || die "kernel package download failed"
    dpkg -i "$tmpdir"/*.deb || apt-get -f install -y
    command -v update-grub >/dev/null && update-grub
    rm -rf "$tmpdir"
}

install_resume_service() {
    cat >"/etc/systemd/system/${RESUME_SERVICE}" <<EOF
[Unit]
Description=Complete ${NAME} after BBR v3 kernel reboot
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=${SCRIPT_PATH} --resume

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "$RESUME_SERVICE"
}

disable_resume_service() {
    # This function is called by the resume service itself; stopping it here
    # could terminate the final verification before it is reported.
    systemctl disable "$RESUME_SERVICE" 2>/dev/null || true
    rm -f "/etc/systemd/system/${RESUME_SERVICE}"
    systemctl daemon-reload
}

save_sysctl_once() {
    [[ -f "$STATE_FILE" ]] && return 0
    local keys=(
        net.core.default_qdisc net.ipv4.tcp_congestion_control net.core.somaxconn
        net.core.netdev_max_backlog net.ipv4.tcp_max_syn_backlog net.ipv4.ip_local_port_range
        net.core.rmem_max net.core.wmem_max net.ipv4.tcp_rmem net.ipv4.tcp_wmem
        net.ipv4.tcp_slow_start_after_idle net.ipv4.tcp_mtu_probing net.ipv4.tcp_fastopen
        net.ipv4.tcp_notsent_lowat net.ipv4.udp_rmem_min net.ipv4.udp_wmem_min net.ipv4.tcp_ecn
        net.core.rps_sock_flow_entries
    ) key value
    : >"$STATE_FILE"
    for key in "${keys[@]}"; do
        value="$(sysctl -n "$key" 2>/dev/null || true)"
        [[ -n "$value" ]] && printf '%s=%s\n' "$key" "$value" >>"$STATE_FILE"
    done
}

save_gai_once() {
    [[ -f "$GAI_BACKUP" || -f "$GAI_ABSENT" ]] && return 0
    if [[ -e "$GAI_FILE" ]]; then cp -a "$GAI_FILE" "$GAI_BACKUP"; else : >"$GAI_ABSENT"; fi
}

buffer_cap_bytes() {
    local mem_kb
    mem_kb="$(awk '/MemTotal:/ {print $2}' /proc/meminfo)"
    if (( mem_kb < 524288 )); then printf '%s' $((16 * 1024 * 1024))
    elif (( mem_kb < 1048576 )); then printf '%s' $((32 * 1024 * 1024))
    else printf '%s' $((64 * 1024 * 1024)); fi
}

write_production_sysctl() {
    local cap
    cap="$(buffer_cap_bytes)"
    modprobe tcp_bbr 2>/dev/null || true
    modprobe sch_fq 2>/dev/null || true
    cat >"$SYSCTL_FILE" <<EOF
# Managed by ${NAME}; remove via ${SCRIPT_PATH} --rollback.
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 16384
net.ipv4.tcp_max_syn_backlog = 16384
net.ipv4.ip_local_port_range = 10240 65535
net.core.rmem_max = ${cap}
net.core.wmem_max = ${cap}
net.ipv4.tcp_rmem = 4096 131072 ${cap}
net.ipv4.tcp_wmem = 4096 16384 ${cap}
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
net.ipv4.tcp_ecn = 1
EOF
    sysctl -p "$SYSCTL_FILE"
    local iface
    while IFS= read -r iface; do
        [[ -n "$iface" ]] && tc qdisc replace dev "$iface" root fq 2>/dev/null || true
    done < <(ip -o route show default 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "dev") print $(i + 1)}' | sort -u)
    cat >"$LIMITS_FILE" <<EOF
# Managed by ${NAME}.
* soft nofile 1048576
* hard nofile 1048576
EOF
}

prefer_ipv4() {
    save_gai_once
    touch "$GAI_FILE"
    grep -Eq '^\s*precedence\s+::ffff:0:0/96\s+100\s*$' "$GAI_FILE" || \
        printf '\n# Managed by %s\nprecedence ::ffff:0:0/96  100\n' "$NAME" >>"$GAI_FILE"
}

enable_mss_clamp() {
    command -v iptables >/dev/null || { log "iptables unavailable; MSS clamp skipped"; return 0; }
    iptables -t mangle -C POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \
        iptables -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
}

cpu_mask() {
    local cpus="$1" groups rem i=0 part parts=()
    groups=$((cpus / 32)); rem=$((cpus % 32))
    if (( rem > 0 )); then part=$(printf '%x' $(( (1 << rem) - 1 ))); parts+=("$part"); fi
    while (( i < groups )); do parts+=("ffffffff"); ((i += 1)); done
    local IFS=,
    printf '%s' "${parts[*]}"
}

save_rps_once() {
    [[ -f "$RPS_STATE_FILE" ]] && return 0
    : >"$RPS_STATE_FILE"
    local node
    while IFS= read -r node; do printf '%s|%s\n' "$node" "$(<"$node")" >>"$RPS_STATE_FILE"; done \
        < <(find /sys/class/net -type f -writable \( -path '*/queues/rx-*/rps_cpus' -o -path '*/queues/rx-*/rps_flow_cnt' \) 2>/dev/null)
}

apply_rps() {
    local cpus mask node applied=0
    cpus="$(nproc)"
    (( cpus > 1 )) || { log "single CPU; RPS skipped"; return 0; }
    save_rps_once
    mask="$(cpu_mask "$cpus")"
    while IFS= read -r node; do
        printf '%s' "$mask" >"$node" && applied=1 || true
        [[ -w "${node%rps_cpus}rps_flow_cnt" ]] && printf '4096' >"${node%rps_cpus}rps_flow_cnt" || true
    done < <(find /sys/class/net -path '*/queues/rx-*/rps_cpus' -type f -writable 2>/dev/null)
    (( applied == 1 )) && sysctl -w net.core.rps_sock_flow_entries=32768 >/dev/null || log "no writable RPS queues; NIC tuning skipped"
    enable_mss_clamp
}

install_rps_service() {
    cat >"/etc/systemd/system/${RPS_SERVICE}" <<EOF
[Unit]
Description=Apply ${NAME} RPS settings
After=network.target

[Service]
Type=oneshot
ExecStart=${SCRIPT_PATH} --apply-rps

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "$RPS_SERVICE"
}

verify() {
    [[ "$(sysctl -n net.ipv4.tcp_congestion_control)" == "bbr" ]] || die "BBR did not activate"
    [[ "$(sysctl -n net.core.default_qdisc)" == "fq" ]] || die "FQ did not activate"
    log "complete: kernel=$(uname -r), bbr_version=$(modinfo -F version tcp_bbr 2>/dev/null || echo unknown), buffer_cap=$(buffer_cap_bytes)"
}

restore_sysctl() {
    [[ -f "$STATE_FILE" ]] || return 0
    local key value
    while IFS='=' read -r key value; do sysctl -w "$key=$value" >/dev/null 2>&1 || true; done <"$STATE_FILE"
}

rollback() {
    disable_resume_service
    systemctl disable --now "$RPS_SERVICE" 2>/dev/null || true
    rm -f "/etc/systemd/system/${RPS_SERVICE}" "$SYSCTL_FILE" "$LIMITS_FILE"
    systemctl daemon-reload
    command -v iptables >/dev/null && iptables -t mangle -D POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
    if [[ -f "$RPS_STATE_FILE" ]]; then
        local node value
        while IFS='|' read -r node value; do [[ -w "$node" ]] && printf '%s' "$value" >"$node" || true; done <"$RPS_STATE_FILE"
    fi
    [[ -f "$GAI_BACKUP" ]] && cp -a "$GAI_BACKUP" "$GAI_FILE"
    [[ -f "$GAI_ABSENT" ]] && rm -f "$GAI_FILE"
    restore_sysctl
    log "managed tuning reverted; the installed BBR v3 kernel was deliberately retained as a boot fallback"
}

apply() {
    require_supported_os
    install_dependencies
    copy_self
    if ! has_bbr_v3; then
        [[ "$MODE" != "resume" ]] || die "the BBR v3 kernel did not boot; inspect bootloader settings before retrying"
        install_bbr_v3_kernel
        install_resume_service
        log "kernel installed. Rebooting now; the script will continue automatically after boot."
        systemctl reboot
        exit 0
    fi
    save_sysctl_once
    write_production_sysctl
    prefer_ipv4
    enable_mss_clamp
    apply_rps
    install_rps_service
    verify
    disable_resume_service
}

require_root
case "$MODE" in
    apply|resume) apply ;;
    apply-rps) apply_rps ;;
    rollback) rollback ;;
    *) die "unsupported mode" ;;
esac
