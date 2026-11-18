#!/usr/bin/env bash
set -uo pipefail

VEIL_SCRIPTS_VERSION=__SCRIPTS_VERSION__
PROFILE_ID="__PROFILE_ID__"
RELAY_PORT=__RELAY_PORT__
HY_PORT_DEFAULT=2095
ETC=/etc/veil
LIB=/usr/local/lib/veil
SELF=/usr/local/sbin/veil-server
FW_COMMENT="veil"

HY_PASSWORD='__HY_PASSWORD__'
OBFS_PASSWORD='__OBFS_PASSWORD__'
CERT_B64='__CERT_PEM_B64__'
KEY_B64='__KEY_PEM_B64__'
RELAY_B64='__RELAY_PY_B64__'

TOTAL=7
step() { printf '\n[%s/%s] %s\n' "$1" "$TOTAL" "$2"; }
info() { printf '      %s\n' "$*"; }
fail() {
  printf '\nVEIL-ERROR: %s\n' "$1"
  [ -n "${2:-}" ] && printf 'FIX: %s\n' "$2"
  exit 1
}
CHANGES=()
changed() { CHANGES+=("$*"); }

need_root() {
  [ "$(id -u)" -eq 0 ] || fail "This script must run as root." "Run it again with sudo in front."
}

detect_os() {
  OS_ID=unknown; OS_LIKE=""; OS_NAME=unknown
  if [ -r /etc/os-release ]; then
    . /etc/os-release
    OS_ID="${ID:-unknown}"; OS_LIKE="${ID_LIKE:-}"; OS_NAME="${PRETTY_NAME:-$OS_ID}"
  fi
  ARCH="$(uname -m)"
  case "$ARCH" in
    x86_64|amd64) ARCH=amd64 ;;
    aarch64|arm64) ARCH=arm64 ;;
    *) fail "This CPU type ($ARCH) is not supported." "Use a server with an amd64 or arm64 CPU." ;;
  esac
  if command -v apt-get >/dev/null 2>&1; then PKG=apt
  elif command -v dnf >/dev/null 2>&1; then PKG=dnf
  elif command -v yum >/dev/null 2>&1; then PKG=yum
  else PKG=none; fi
  command -v systemctl >/dev/null 2>&1 || fail "This server has no systemd." "Use Ubuntu 20.04+ or Debian 11+."
}

wait_apt_lock() {
  local i=0
  while fuser /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock >/dev/null 2>&1; do
    [ $i -eq 0 ] && info "Waiting for another package install to finish (automatic updates)..."
    i=$((i + 1))
    [ $i -gt 120 ] && fail "The package manager is busy (apt lock held for over 10 minutes)." \
      "Wait a few minutes or reboot the server, then run the command again."
    sleep 5
  done
}

pkg_install() {
  case "$PKG" in
    apt)
      wait_apt_lock
      DEBIAN_FRONTEND=noninteractive apt-get update -qq </dev/null >/dev/null 2>&1
      DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" </dev/null >/dev/null 2>&1 ;;
    dnf) dnf install -y -q "$@" </dev/null >/dev/null 2>&1 ;;
    yum) yum install -y -q "$@" </dev/null >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

udp_holder() {
  ss -H -ulpn "sport = :$1" 2>/dev/null | sed -n 's/.*users:(("\([^"]*\)".*/\1/p' | head -1
}

firewall_kind() {
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then echo ufw
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then echo firewalld
  elif command -v iptables >/dev/null 2>&1; then echo iptables
  else echo none; fi
}

firewall_open() {
  case "$(firewall_kind)" in
    ufw)
      ufw status | grep -qE "^${RELAY_PORT}/udp +ALLOW" || { ufw allow "${RELAY_PORT}/udp" comment "$FW_COMMENT" >/dev/null; changed "ufw: allowed ${RELAY_PORT}/udp"; }
      FW=ufw ;;
    firewalld)
      firewall-cmd --query-port="${RELAY_PORT}/udp" >/dev/null 2>&1 || {
        firewall-cmd --permanent --add-port="${RELAY_PORT}/udp" >/dev/null && firewall-cmd --reload >/dev/null
        changed "firewalld: allowed ${RELAY_PORT}/udp"; }
      FW=firewalld ;;
    iptables)
      if ! iptables -C INPUT -p udp --dport "$RELAY_PORT" -m comment --comment "$FW_COMMENT" -j ACCEPT 2>/dev/null; then
        iptables -I INPUT 1 -p udp --dport "$RELAY_PORT" -m comment --comment "$FW_COMMENT" -j ACCEPT
        changed "iptables: inserted ACCEPT udp/${RELAY_PORT} at the top of INPUT"
      else
        first="$(iptables -S INPUT 2>/dev/null | sed -n 2p)"
        case "$first" in
          *"$FW_COMMENT"*) ;;
          *) iptables -D INPUT -p udp --dport "$RELAY_PORT" -m comment --comment "$FW_COMMENT" -j ACCEPT
             iptables -I INPUT 1 -p udp --dport "$RELAY_PORT" -m comment --comment "$FW_COMMENT" -j ACCEPT
             changed "iptables: moved the Veil rule back to the top of INPUT" ;;
        esac
      fi
      persist_iptables
      FW=iptables ;;
    *)
      info "No firewall tool found; assuming nothing on the server blocks UDP ${RELAY_PORT}."
      FW=none ;;
  esac
}

persist_iptables() {
  if command -v netfilter-persistent >/dev/null 2>&1; then
    netfilter-persistent save >/dev/null 2>&1 && return
  fi
  if [ "$PKG" = apt ]; then
    echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections 2>/dev/null
    echo iptables-persistent iptables-persistent/autosave_v6 boolean true | debconf-set-selections 2>/dev/null
    pkg_install iptables-persistent && changed "installed iptables-persistent (keeps firewall rules after reboot)"
    command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save >/dev/null 2>&1 && return
  fi
  if command -v service >/dev/null 2>&1 && service iptables save >/dev/null 2>&1; then return; fi
  info "Note: could not save the firewall rule permanently; it is active until the next reboot (run this command again after a reboot)."
}

firewall_close() {
  case "$(firewall_kind)" in
    ufw) ufw delete allow "${RELAY_PORT}/udp" >/dev/null 2>&1 && echo "removed ufw rule ${RELAY_PORT}/udp" ;;
    firewalld) firewall-cmd --permanent --remove-port="${RELAY_PORT}/udp" >/dev/null 2>&1 && firewall-cmd --reload >/dev/null && echo "removed firewalld port ${RELAY_PORT}/udp" ;;
    iptables)
      while iptables -D INPUT -p udp --dport "$RELAY_PORT" -m comment --comment "$FW_COMMENT" -j ACCEPT 2>/dev/null; do :; done
      command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save >/dev/null 2>&1
      echo "removed iptables rule for udp/${RELAY_PORT}" ;;
  esac
}

self_probe() {
  python3 -I - "$RELAY_PORT" <<'PY' 2>/dev/null
import socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(2)
for _ in range(3):
    s.sendto(b"\xffVEILPROBE\x01" + b"\x00" * 8, ("127.0.0.1", int(sys.argv[1])))
    try:
        d, _ = s.recvfrom(2048)
        if d.startswith(b"\xffVEILPONG\x01"):
            print(d[18:].decode()); break
    except socket.timeout:
        pass
PY
}

status_table() {
  local hy_port ok_all=1 hy=FAIL relay=FAIL fw=FAIL st=FAIL relay_ver="" probe hyflag=0
  hy_port="$(cat "$ETC/hy_port" 2>/dev/null || echo "$HY_PORT_DEFAULT")"
  systemctl is-active --quiet veil-core && [ -n "$(udp_holder "$hy_port")" ] && hy=OK
  systemctl is-active --quiet veil-gate && [ -n "$(udp_holder "$RELAY_PORT")" ] && relay=OK
  relay_ver="$(python3 -I "$LIB/gate.py" --version 2>/dev/null)"
  case "$(firewall_kind)" in
    ufw) ufw status | grep -qE "^${RELAY_PORT}/udp +ALLOW" && fw=OK ;;
    firewalld) firewall-cmd --query-port="${RELAY_PORT}/udp" >/dev/null 2>&1 && fw=OK ;;
    iptables) iptables -C INPUT -p udp --dport "$RELAY_PORT" -m comment --comment "$FW_COMMENT" -j ACCEPT 2>/dev/null && fw=OK ;;
    none) fw=OK ;;
  esac
  probe="$(self_probe)"
  case "$probe" in *"hy=1"*) st=OK; hyflag=1 ;; esac
  echo
  echo "==== Veil server status ===="
  printf '%-5s %-10s %s\n' "$hy"    core      "Veil core running (local only)"
  printf '%-5s %-10s %s\n' "$relay" gate      "Veil gate on port ${RELAY_PORT}, version ${relay_ver:-?}"
  printf '%-5s %-10s %s\n' "$fw"    firewall  "port ${RELAY_PORT} allowed ($(firewall_kind))"
  printf '%-5s %-10s %s\n' "$st"    self-test "gate answers and reaches the core"
  for x in "$hy" "$relay" "$fw" "$st"; do [ "$x" = OK ] || ok_all=0; done
  local result=fail; [ $ok_all = 1 ] && result=ok
  echo "VEIL-STATUS: result=$result profile=$(cat "$ETC/profile" 2>/dev/null) scripts=$(cat "$ETC/version" 2>/dev/null) gate=${relay_ver:-0} core=$hyflag fw=$(firewall_kind) port=$RELAY_PORT"
  if [ $ok_all = 1 ]; then
    echo "All good. The server side is ready. Go back to the Veil app."
  else
    echo "Something is not right. Run the install command again; it is safe to repeat."
  fi
  [ $ok_all = 1 ]
}

uninstall() {
  need_root
  echo "Removing Veil from this server..."
  for s in veil-gate veil-core; do
    systemctl disable --now "$s" >/dev/null 2>&1 && echo "stopped and disabled $s"
    rm -f "/etc/systemd/system/$s.service"
  done
  systemctl daemon-reload
  [ -f "$ETC/relay_port" ] && RELAY_PORT="$(cat "$ETC/relay_port")"
  firewall_close
  rm -rf "$ETC" "$LIB" && echo "removed $ETC and $LIB"
  id veil >/dev/null 2>&1 && userdel veil >/dev/null 2>&1 && echo "removed system user veil"
  echo "Left in place: /usr/local/bin/hysteria (may be used by other setups)."
  echo "To remove it too: bash <(curl -fsSL https://get.hy2.sh/) --remove"
  rm -f "$SELF"
  echo "Done. Veil is removed from this server."
}

install() {
  need_root
  echo "Veil server setup (scripts v${VEIL_SCRIPTS_VERSION})"

  step 1 "Checking this server"
  detect_os
  info "System: $OS_NAME ($ARCH)"
  case "$OS_ID $OS_LIKE" in
    *ubuntu*|*debian*) ;;
    *) info "Note: tested on Ubuntu and Debian. Continuing on $OS_ID (best effort)." ;;
  esac
  if [ -f "$ETC/profile" ] && [ "$(cat "$ETC/profile")" != "$PROFILE_ID" ]; then
    info "Replacing a previous Veil setup on this server with this profile."
  fi
  if systemctl list-unit-files 2>/dev/null | grep -q '^x-ui'; then info "x-ui found: it is left untouched."; fi

  step 2 "Installing python3 and curl (if missing)"
  missing=()
  command -v python3 >/dev/null 2>&1 || missing+=(python3)
  command -v curl >/dev/null 2>&1 || missing+=(curl)
  command -v ss >/dev/null 2>&1 || missing+=(iproute2)
  if [ ${#missing[@]} -gt 0 ]; then
    [ "$PKG" = apt ] || [ "$PKG" = dnf ] || [ "$PKG" = yum ] || fail "No package manager found to install ${missing[*]}." "Install ${missing[*]} by hand, then run the command again."
    [ "$PKG" != apt ] && missing=("${missing[@]/iproute2/iproute}")
    pkg_install "${missing[@]}" || fail "Could not install ${missing[*]}." "Run: sudo apt-get update && sudo apt-get install -y ${missing[*]} , then run the command again."
    changed "installed packages: ${missing[*]}"
  fi
  info "python3 $(python3 -c 'import sys;print("%d.%d"%sys.version_info[:2])')"

  step 3 "Installing the core"
  if [ -x /usr/local/bin/hysteria ]; then
    info "Already installed: $(/usr/local/bin/hysteria version 2>/dev/null | sed -n 's/^Version:[[:space:]]*//p' | head -1)"
  else
    bash <(curl -fsSL https://get.hy2.sh/) </dev/null >/tmp/veil-hy2-install.log 2>&1 \
      || fail "The core installer failed (see /tmp/veil-hy2-install.log)." "Check that the server can reach github.com, then run the command again."
    [ -x /usr/local/bin/hysteria ] || fail "The core was not installed." "See /tmp/veil-hy2-install.log."
    changed "installed the core"
  fi

  step 4 "Configuring the core (local only)"
  id veil >/dev/null 2>&1 || { useradd --system --no-create-home --shell /usr/sbin/nologin veil 2>/dev/null || useradd -r -M -s /sbin/nologin veil; changed "created system user veil"; }
  mkdir -p "$ETC" "$LIB"
  chmod 750 "$ETC"; chown root:veil "$ETC"
  HY_PORT="$(cat "$ETC/hy_port" 2>/dev/null || echo "$HY_PORT_DEFAULT")"
  holder="$(udp_holder "$HY_PORT")"
  if [ -n "$holder" ] && ! systemctl is-active --quiet veil-core; then
    for p in $(seq 2096 2199); do [ "$p" = "$RELAY_PORT" ] && continue; [ -z "$(udp_holder "$p")" ] && { HY_PORT=$p; break; }; done
    info "Local port $HY_PORT_DEFAULT is used by $holder; using $HY_PORT instead."
  fi
  echo "$HY_PORT" > "$ETC/hy_port"
  echo "$CERT_B64" | base64 -d > "$ETC/cert.pem"
  echo "$KEY_B64" | base64 -d > "$ETC/key.pem"
  cat > "$ETC/core.yaml" <<EOF
listen: 127.0.0.1:$HY_PORT
tls:
  cert: $ETC/cert.pem
  key: $ETC/key.pem
auth:
  type: password
  password: "$HY_PASSWORD"
obfs:
  type: salamander
  salamander:
    password: "$OBFS_PASSWORD"
EOF
  chown root:veil "$ETC/cert.pem" "$ETC/key.pem" "$ETC/core.yaml"
  chmod 640 "$ETC/cert.pem" "$ETC/key.pem" "$ETC/core.yaml"
  cat > /etc/systemd/system/veil-core.service <<EOF
[Unit]
Description=Veil core (local only)
After=network-online.target
Wants=network-online.target

[Service]
User=veil
ExecStart=/usr/local/bin/hysteria server --config $ETC/core.yaml
Restart=always
RestartSec=3
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
  changed "configured veil-core.service"

  step 5 "Installing the Veil gate on port $RELAY_PORT"
  holder="$(udp_holder "$RELAY_PORT")"
  if [ -n "$holder" ] && [ "$holder" != python3 ]; then
    fail "UDP port $RELAY_PORT is already used by '$holder'." "In Veil, open the server, change the relay port, and copy the new command."
  fi
  echo "$RELAY_B64" | base64 -d > "$LIB/gate.py"
  chmod 755 "$LIB/gate.py"
  cat > /etc/systemd/system/veil-gate.service <<EOF
[Unit]
Description=Veil gate (port $RELAY_PORT)
After=network-online.target veil-core.service
Wants=network-online.target

[Service]
User=veil
ExecStart=/usr/bin/env python3 -I $LIB/gate.py $RELAY_PORT $HY_PORT
Restart=always
RestartSec=2
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF
  echo "$RELAY_PORT" > "$ETC/relay_port"
  echo "$PROFILE_ID" > "$ETC/profile"
  echo "$VEIL_SCRIPTS_VERSION" > "$ETC/version"
  systemctl daemon-reload
  systemctl enable veil-core veil-gate >/dev/null 2>&1
  systemctl restart veil-core
  systemctl restart veil-gate
  changed "installed veil-gate.service (enabled at boot)"

  step 6 "Opening port $RELAY_PORT in the server firewall"
  firewall_open
  info "Firewall: $FW"

  step 7 "Self-test"
  cp -f "$0" "$SELF" 2>/dev/null && chmod 700 "$SELF"
  sleep 2
  systemctl is-active --quiet veil-core || { journalctl -u veil-core -n 15 --no-pager 2>/dev/null; fail "The core did not start." "Run the install command again."; }

  echo
  echo "Changes made:"
  if [ ${#CHANGES[@]} -eq 0 ]; then echo "  none (already set up, services restarted)"; else for c in "${CHANGES[@]}"; do echo "  - $c"; done; fi
  echo "Undo everything: sudo veil-server --uninstall"
  status_table
}

case "${1:-}" in
  --status) need_root; detect_os; [ -f "$ETC/relay_port" ] && RELAY_PORT="$(cat "$ETC/relay_port")"; status_table ;;
  --uninstall) detect_os; uninstall ;;
  --version) echo "$VEIL_SCRIPTS_VERSION" ;;
  ""|--install) install ;;
  *) echo "usage: $0 [--status|--uninstall|--version]"; exit 2 ;;
esac
