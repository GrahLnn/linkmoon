测速

```bash
curl -L https://gitlab.com/spiritysdx/za/-/raw/main/ecs.sh -o ecs.sh && chmod +x ecs.sh && bash ecs.sh
```

```bash
bash <(curl -sL https://run.NodeQuality.com)
```

8in1

```bash
wget -P /root -N --no-check-certificate "https://raw.githubusercontent.com/mack-a/v2ray-agent/master/install.sh" && chmod 700 /root/install.sh && /root/install.sh
```

warp

```bash
bash <(wget -qO- https://gitlab.com/rwkgyg/CFwarp/raw/main/CFwarp.sh 2> /dev/null)
```

update

```bash
apt update -y && apt upgrade -y && apt full-upgrade -y && apt autoremove -y && apt install neovim curl unzip cron net-tools jq -y && timedatectl set-timezone Asia/Shanghai && bash <(curl -Ls https://raw.githubusercontent.com/alireza0/s-ui/master/install.sh)
```

set cf token

```bash
wget -N --no-check-certificate https://raw.githubusercontent.com/GrahLnn/linkmoon/refs/heads/main/injcftoken.sh && bash injcftoken.sh
```

hy2_acme

```bash
wget -N --no-check-certificate https://raw.githubusercontent.com/GrahLnn/linkmoon/refs/heads/main/install_hy2.sh && bash install_hy2.sh
```

mihomo

```bash
wget -N --no-check-certificate https://raw.githubusercontent.com/GrahLnn/linkmoon/refs/heads/main/install_mihomo.sh && bash install_mihomo.sh
```

hy2_tls

```bash
wget -N --no-check-certificate https://raw.githubusercontent.com/flame1ce/hysteria2-install/main/hysteria2-install-main/hy2/hysteria.sh && bash hysteria.sh
```

ssr
```bash
wget -N --no-check-certificate https://raw.githubusercontent.com/ToyoDAdoubiBackup/doubi/master/ss-go.sh && bash ss-go.sh
```

port jump

```bash
wget -N --no-check-certificate https://raw.githubusercontent.com/GrahLnn/linkmoon/refs/heads/main/jumport.sh && bash jumport.sh
```

install squid

```bash
wget -N --no-check-certificate https://raw.githubusercontent.com/GrahLnn/linkmoon/refs/heads/main/install_squid.sh && bash install_squid.sh
```

disable ipv6

```bash
wget -N --no-check-certificate https://raw.githubusercontent.com/GrahLnn/linkmoon/refs/heads/main/disable_ipv6.sh && bash disable_ipv6.sh
```

bbr v3
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/GrahLnn/linkmoon/main/bbr-v3-bootstrap.sh)
```

install 3proxy

```bash
wget -N --no-check-certificate https://raw.githubusercontent.com/GrahLnn/linkmoon/refs/heads/main/install-3proxy.sh && bash install-3proxy.sh
```

deploy REALITY + Hysteria2 for sing-box (always installs both)

```bash
curl -fsSL https://raw.githubusercontent.com/GrahLnn/linkmoon/main/sing-box-reality-hy2.sh -o sing-box-reality-hy2.sh && sh sing-box-reality-hy2.sh
```

HY2 uses a dedicated Cloudflare domain, Let's Encrypt ACME with Cloudflare DNS-01,
Gecko obfuscation, and UDP port hopping across **20000–50000** (30-second interval).
The script asks for the domain and a hidden API token. It no longer issues HY2
certificates for IP addresses or offers self-signed certificates.

For unattended installation, supply `HY2_DOMAIN` and `CF_API_TOKEN` in the environment
(the existing `CF_Token` variable is also supported), then run:

```sh
sh sing-box-reality-hy2.sh --yes --hy2-domain hy2.example.com --acme-email you@example.com
```

Use a token with **Zone:DNS:Edit** and **Zone:Read** scoped to the relevant zone;
an optional `CF_ZONE_TOKEN` can supply Zone:Read separately. The domain's A record
must point to the VPS IPv4 address with **DNS-only / grey cloud** enabled. DNS-01
does not require TCP port 80. Allow UDP **20000–50000** in the host firewall and
provider security group, plus the configured REALITY TCP port.

The sing-box service loads its own nftables redirect table on start and removes
it on stop; it leaves other nftables tables intact. Failed deployments restore
the previous service, configuration and managed hopping rules. Client JSON and
HY2 URIs include the hopping range and Gecko settings; use a client supporting Gecko.
Cloudflare tokens remain in the root-only server configuration and never appear
in exported client profiles.

The default IPv4 route determines the hopping ingress interface. Set `HY2_INTERFACE`
when public traffic arrives through a different interface.
