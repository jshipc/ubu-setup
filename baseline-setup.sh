#!/usr/bin/env bash
# baseline-setup.sh — Ubuntu Server 25.04 post-install baseline for Dell R340 + Bareos host
# Safe to re-run. Uses apt, enables chrony, and (best-effort) adds Dell OpenManage bits.

set -euo pipefail

### ── Tunables ──────────────────────────────────────────────────────────────────
# If you want your server to use local NTP (e.g., your UDM-Pro at 192.168.0.1),
# list it first. Public fallbacks are fine to leave in place too.
NTP_SERVERS=("192.168.0.1" "time.google.com" "pool.ntp.org")

# Try to install Dell OpenManage/idracadm? (best effort; may be unavailable for 25.04 yet)
INSTALL_DELL_OMSA=true
### ──────────────────────────────────────────────────────────────────────────────

need_cmd() { command -v "$1" &>/dev/null || { echo "Missing required command: $1"; exit 1; }; }

echo ">>> Updating package index & upgrading base system…"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get dist-upgrade -y

echo ">>> Installing core monitoring & utilities…"
apt-get install -y \
  htop iotop sysstat lsof psmisc tree unzip \
  net-tools iproute2 traceroute mtr-tiny nmap curl wget tcpdump dnsutils \
  smartmontools nvme-cli gdisk parted lvm2 xfsprogs zfsutils-linux \
  screen tmux rsync chrony logrotate debian-goodies ipmitool

# Enable performance history (sysstat)
echo ">>> Enabling sysstat (sar/iostat)…"
sed -i 's/^ENABLED="false"/ENABLED="true"/' /etc/default/sysstat || true
systemctl enable --now sysstat

# Configure chrony (NTP)
echo ">>> Configuring chrony NTP servers…"
CHRONY_CONF="/etc/chrony/chrony.conf"
if [[ -f "$CHRONY_CONF" ]]; then
  # Comment out existing 'pool' and 'server' lines, then append our list
  sed -i 's/^\s*\(pool\|server\)\s\+/# &/g' "$CHRONY_CONF"
  {
    echo ""
    echo "# Added by baseline-setup.sh"
    for s in "${NTP_SERVERS[@]}"; do
      echo "server $s iburst"
    done
  } >> "$CHRONY_CONF"
  systemctl enable --now chrony
  systemctl restart chrony
  sleep 2
  chronyc tracking || true
fi

# Best-effort: Dell OpenManage / idracadm
if [[ "$INSTALL_DELL_OMSA" == "true" ]]; then
  echo ">>> Attempting to add Dell repository for idracadm/OMSA (best effort)…"
  # Dell’s bootstrap sometimes lags for newest Ubuntu; ignore failures gracefully.
  set +e
  wget -q -O - http://linux.dell.com/repo/hardware/dsu/bootstrap.cgi | bash
  RC=$?
  set -e
  if [[ $RC -eq 0 ]]; then
    apt-get update -y || true
    apt-get install -y srvadmin-idracadm7 || echo "Note: srvadmin-idracadm7 not available for this release yet."
  else
    echo "Note: Dell repo bootstrap unavailable; skipping idracadm install."
  fi
fi

# Helpful sanity info
echo ">>> Baseline complete."
echo ">>> Quick checks:"
echo "  - Kernel:      $(uname -r)"
echo "  - IPs:         $(hostname -I || true)"
echo "  - Default route:"
ip route | sed 's/^/    /' || true
echo "  - NTP status:"
chronyc tracking 2>/dev/null | sed 's/^/    /' || echo "    (chrony status not available)"

echo ">>> Suggested next steps:"
echo "  1) smartctl -a /dev/sda        # check first disk health"
echo "  2) ipmitool mc info            # verify BMC/iDRAC visibility"
echo "  3) apt install bareos*         # begin Bareos setup when ready"
echo "  4) Consider 'zpool' or LVM setup on SAS disks for staging pools."