#!/usr/bin/env bash
# Cat9000v network lab controller (libvirt/KVM)
set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/lab.conf"

# Re-exec under the libvirt group if this login session doesn't have it yet.
if ! id -nG | tr ' ' '\n' | grep -qx libvirt && getent group libvirt | grep -qw "$USER"; then
  exec sg libvirt -c "$(printf '%q ' "$0" "$@")"
fi

V() { virsh -q -c "$LIBVIRT_URI" "$@"; }
die() { echo "error: $*" >&2; exit 1; }
node_dir() { echo "$LAB_DIR/nodes/$1"; }
is_switch() { [[ " ${SWITCHES[*]} " == *" $1 "* ]]; }
is_host() { [[ " ${HOSTS[*]} " == *" $1 "* ]]; }
defined() { V dominfo "$1" &>/dev/null; }
running() { [[ "$(V domstate "$1" 2>/dev/null)" == "running" ]]; }

# ---- networks -------------------------------------------------------------
ensure_networks() {
  if ! V net-info "$OOB_NET" &>/dev/null; then
    V net-define "$LAB_DIR/networks/$OOB_NET.xml"
    V net-autostart "$OOB_NET" >/dev/null
  fi
  for net in "$OOB_NET" default; do
    [[ "$(V net-info "$net" | awk '/Active/{print $2}')" == "yes" ]] || V net-start "$net"
  done
}

# ---- UDP point-to-point links -------------------------------------------
# Each switch data port owns a local UDP port; a link is a pair of ports that
# send to each other. Unlinked ports send into a black hole.
port_local() { echo $(( 20000 + NODE_IDX[$1]*100 + $2 )); }
port_peer() {                      # -> "node:port" of the far end, or ""
  local me="$1:$2" l a b
  for l in "${LINKS[@]}"; do
    read -r a b <<<"$l"
    [[ "$a" == "$me" ]] && { echo "$b"; return; }
    [[ "$b" == "$me" ]] && { echo "$a"; return; }
  done
  return 0
}

# ---- XML generation -------------------------------------------------------
serial_xml() {
  cat <<X
    <serial type='tcp'>
      <source mode='bind' host='127.0.0.1' service='${CONSOLE_PORT[$1]}'/>
      <protocol type='raw'/>
      <log file='$(node_dir "$1")/console.log' append='on'/>
      <target port='0'/>
    </serial>
X
}

switch_xml() {
  local n="$1" i="${NODE_IDX[$1]}" d; d="$(node_dir "$n")"
  cat <<X
<domain type='kvm'>
  <name>$n</name>
  <title>Catalyst 9000v ($n)</title>
  <memory unit='MiB'>$CAT9KV_RAM_MIB</memory>
  <vcpu placement='static'>$CAT9KV_VCPU</vcpu>
  <cpu mode='host-passthrough' check='none'/>
  <os><type arch='x86_64' machine='pc'>hvm</type><boot dev='hd'/></os>
  <features><acpi/><apic/></features>
  <clock offset='utc'/>
  <on_poweroff>destroy</on_poweroff><on_reboot>restart</on_reboot><on_crash>restart</on_crash>
  <devices>
    <emulator>/usr/bin/qemu-system-x86_64</emulator>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2'/>
      <source file='$d/disk.qcow2'/>
      <target dev='hda' bus='ide'/>
    </disk>
    <disk type='file' device='cdrom'>
      <driver name='qemu' type='raw'/>
      <source file='$d/config.iso'/>
      <target dev='hdc' bus='ide'/>
      <readonly/>
    </disk>
    <!-- NIC 1 = GigabitEthernet0/0 (OOB management, Mgmt-vrf) -->
    <interface type='network'>
      <mac address='52:54:00:c9:0$i:00'/>
      <source network='$OOB_NET'/>
      <model type='virtio'/>
      <!-- no checksum/segmentation offload: IOS-XE's TCP stack rejects
           partially-checksummed segments coming off the host tap -->
      <driver name='qemu'>
        <host csum='off' gso='off' tso4='off' tso6='off' ecn='off' ufo='off'/>
        <guest csum='off' tso4='off' tso6='off' ecn='off' ufo='off'/>
      </driver>
      <address type='pci' domain='0x0000' bus='0x00' slot='0x03' function='0x0'/>
    </interface>
X
  local p peer ph pp remote
  for ((p=1; p<=CAT9KV_DATA_PORTS; p++)); do
    peer="$(port_peer "$n" "$p")"
    if [[ -n "$peer" ]]; then
      ph="${peer%%:*}"; pp="${peer##*:}"; remote="$(port_local "$ph" "$pp")"
      echo "    <!-- GigabitEthernet1/0/$p  <->  $ph Gi1/0/$pp -->"
    else
      remote=$(( 30000 + i*100 + p ))
      echo "    <!-- GigabitEthernet1/0/$p  (unconnected) -->"
    fi
    cat <<X
    <interface type='udp'>
      <mac address='52:54:00:c9:0$i:$(printf %02x "$p")'/>
      <source address='127.0.0.1' port='$remote'>
        <local address='127.0.0.1' port='$(port_local "$n" "$p")'/>
      </source>
      <model type='virtio'/>
      <address type='pci' domain='0x0000' bus='0x00' slot='$(printf '0x%02x' $((3+p)))' function='0x0'/>
    </interface>
X
  done
  serial_xml "$n"
  cat <<X
    <memballoon model='none'/>
  </devices>
</domain>
X
}

nms_xml() {
  local d; d="$(node_dir nms)"
  cat <<X
<domain type='kvm'>
  <name>nms</name>
  <title>NMS jumphost (Ubuntu 24.04)</title>
  <memory unit='MiB'>$NMS_RAM_MIB</memory>
  <vcpu placement='static'>$NMS_VCPU</vcpu>
  <cpu mode='host-passthrough' check='none'/>
  <os><type arch='x86_64' machine='q35'>hvm</type><boot dev='hd'/></os>
  <features><acpi/><apic/></features>
  <clock offset='utc'/>
  <on_poweroff>destroy</on_poweroff><on_reboot>restart</on_reboot><on_crash>restart</on_crash>
  <devices>
    <emulator>/usr/bin/qemu-system-x86_64</emulator>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2' discard='unmap'/>
      <source file='$d/disk.qcow2'/>
      <target dev='vda' bus='virtio'/>
    </disk>
    <disk type='file' device='cdrom'>
      <driver name='qemu' type='raw'/>
      <source file='$d/seed.iso'/>
      <target dev='sda' bus='sata'/>
      <readonly/>
    </disk>
    <!-- eth0: internet via libvirt NAT (default network) -->
    <interface type='network'>
      <mac address='52:54:00:c9:0a:01'/>
      <source network='default'/>
      <model type='virtio'/>
    </interface>
    <!-- eth1: OOB management network, 10.0.0.10 -->
    <interface type='network'>
      <mac address='52:54:00:c9:0a:02'/>
      <source network='$OOB_NET'/>
      <model type='virtio'/>
    </interface>
    <!-- eth2: OOB network of the cat8000v lab (~/cat8000v, libvirt net c8k-oob), 10.1.0.10 — shared NMS/Nautobot -->
    <interface type='network'>
      <mac address='52:54:00:c9:0a:03'/>
      <source network='c8k-oob'/>
      <model type='virtio'/>
    </interface>
$(serial_xml nms)
    <channel type='unix'><target type='virtio' name='org.qemu.guest_agent.0'/></channel>
    <rng model='virtio'><backend model='random'>/dev/urandom</backend></rng>
    <memballoon model='virtio'/>
  </devices>
</domain>
X
}

host_xml() {       # CirrOS end host: eth0 = OOB mgmt, eth1 = UDP tunnel to a switch access port
  local n="$1" i="${NODE_IDX[$1]}" d; d="$(node_dir "$n")"
  read -r sp _ <<<"${HOST_ATTACH[$n]}"
  local swn="${sp%%:*}" swp="${sp##*:}"
  cat <<X
<domain type='kvm'>
  <name>$n</name>
  <title>CirrOS host ($n) on $swn Gi1/0/$swp</title>
  <memory unit='MiB'>$CIRROS_RAM_MIB</memory>
  <vcpu placement='static'>1</vcpu>
  <cpu mode='host-passthrough' check='none'/>
  <os><type arch='x86_64' machine='pc'>hvm</type><boot dev='hd'/></os>
  <features><acpi/><apic/></features>
  <clock offset='utc'/>
  <on_poweroff>destroy</on_poweroff><on_reboot>restart</on_reboot><on_crash>restart</on_crash>
  <devices>
    <emulator>/usr/bin/qemu-system-x86_64</emulator>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2'/>
      <source file='$d/disk.qcow2'/>
      <target dev='vda' bus='virtio'/>
    </disk>
    <disk type='file' device='cdrom'>
      <driver name='qemu' type='raw'/>
      <source file='$d/seed.iso'/>
      <target dev='hda' bus='ide'/>
      <readonly/>
    </disk>
    <!-- eth0: OOB management, ${MGMT_IP[$n]} -->
    <interface type='network'>
      <mac address='52:54:00:c9:0$i:00'/>
      <source network='$OOB_NET'/>
      <model type='virtio'/>
      <address type='pci' domain='0x0000' bus='0x00' slot='0x03' function='0x0'/>
    </interface>
    <!-- eth1: $swn GigabitEthernet1/0/$swp -->
    <interface type='udp'>
      <mac address='52:54:00:c9:0$i:01'/>
      <source address='127.0.0.1' port='$(port_local "$swn" "$swp")'>
        <local address='127.0.0.1' port='$(port_local "$n" 1)'/>
      </source>
      <model type='virtio'/>
      <address type='pci' domain='0x0000' bus='0x00' slot='0x04' function='0x0'/>
    </interface>
$(serial_xml "$n")
    <memballoon model='none'/>
  </devices>
</domain>
X
}

build_host() {
  local n="$1" d; d="$(node_dir "$n")"
  [[ -f "$CIRROS_IMAGE" ]] || die "CirrOS image not found: $CIRROS_IMAGE"
  read -r sp vlan cidr gw <<<"${HOST_ATTACH[$n]}"
  mkdir -p "$d"
  if [[ ! -f "$d/disk.qcow2" ]]; then
    echo "[$n] creating overlay disk on $(basename "$CIRROS_IMAGE")"
    qemu-img create -q -f qcow2 -b "$CIRROS_IMAGE" -F qcow2 "$d/disk.qcow2"
  fi
  echo "[$n] building cloud-init (NoCloud) seed ISO"
  # CirrOS parses meta-data as JSON (YAML meta-data fails with "json2fstree failed")
  printf '{"instance-id": "%s-001", "local-hostname": "%s"}\n' "$n" "$n" > "$d/meta-data"
  # CirrOS runs a user-data script; it has no netplan/cloud-init network support
  cat > "$d/user-data" <<U
#!/bin/sh
# $n: eth0 = OOB management (${MGMT_IP[$n]}), eth1 = ${sp%%:*} Gi1/0/${sp##*:} (VLAN $vlan)
hostname $n
ip link set eth0 up
ip addr add ${MGMT_IP[$n]}/24 dev eth0
ip link set eth1 up
ip addr add $cidr dev eth1
ip route replace default via $gw dev eth1
U
  genisoimage -quiet -o "$d/seed.iso.tmp" -V cidata -J -r "$d/user-data" "$d/meta-data" && mv -f "$d/seed.iso.tmp" "$d/seed.iso"
  host_xml "$n" > "$d/domain.xml"
  V define "$d/domain.xml" >/dev/null
}

# ---- build ------------------------------------------------------------------
build_switch() {
  local n="$1" d; d="$(node_dir "$n")"
  [[ -f "$CAT9KV_IMAGE" ]] || die "base image not found: $CAT9KV_IMAGE"
  if [[ ! -f "$d/disk.qcow2" ]]; then
    echo "[$n] creating overlay disk on $(basename "$CAT9KV_IMAGE")"
    qemu-img create -q -f qcow2 -b "$CAT9KV_IMAGE" -F qcow2 "$d/disk.qcow2"
  fi
  echo "[$n] building day-0 config ISO"
  # write via a temp file: libvirt chowns the previous ISO to libvirt-qemu
  genisoimage -quiet -o "$d/config.iso.tmp" -l -J -r -V config "$d/iosxe_config.txt" && mv -f "$d/config.iso.tmp" "$d/config.iso"
  switch_xml "$n" > "$d/domain.xml"
  V define "$d/domain.xml" >/dev/null
}

build_nms() {
  local d; d="$(node_dir nms)"
  [[ -f "$NMS_IMAGE" ]] || die "cloud image not found: $NMS_IMAGE"
  if [[ ! -f "$d/disk.qcow2" ]]; then
    echo "[nms] creating ${NMS_DISK_GB}G overlay disk on $(basename "$NMS_IMAGE")"
    qemu-img create -q -f qcow2 -b "$NMS_IMAGE" -F qcow2 "$d/disk.qcow2" "${NMS_DISK_GB}G"
  fi
  echo "[nms] building cloud-init seed ISO"
  genisoimage -quiet -o "$d/seed.iso.tmp" -V cidata -J -r "$d/user-data" "$d/meta-data" "$d/network-config" && mv -f "$d/seed.iso.tmp" "$d/seed.iso"
  nms_xml > "$d/domain.xml"
  V define "$d/domain.xml" >/dev/null
}

build() { for n in "$@"; do if is_switch "$n"; then build_switch "$n"; elif is_host "$n"; then build_host "$n"; else build_nms; fi; done; }

save_switch_config() {   # write memory: RESTCONF RPC first, serial console as fallback
  local n="$1" user="${IOSXE_USERNAME:-admin}" pass="${IOSXE_PASSWORD:-admin}"
  curl -sk -u "$user:$pass" -m 30 -X POST "https://${MGMT_IP[$n]}/restconf/operations/cisco-ia:save-config" \
       -H 'Content-Type: application/yang-data+json' -H 'Accept: application/yang-data+json' 2>/dev/null | grep -qi success && return 0
  timeout 90 python3 "$LAB_DIR/tools/console.py" send 127.0.0.1 "${CONSOLE_PORT[$n]}" "write memory" >/dev/null 2>&1
}

# ---- commands ---------------------------------------------------------------
cmd_up() {
  local nodes=("${@:-${ALL_NODES[@]}}")
  ensure_networks
  for n in "${nodes[@]}"; do
    defined "$n" || build "$n"
    # pre-create the console log so virtlogd appends to our file instead of a root-only one
    [[ -f "$(node_dir "$n")/console.log" ]] || { touch "$(node_dir "$n")/console.log"; chmod 644 "$(node_dir "$n")/console.log"; }
    if running "$n"; then echo "[$n] already running"; else V start "$n"; echo "[$n] started (console: 127.0.0.1:${CONSOLE_PORT[$n]})"; fi
  done
}

cmd_down() {
  local nodes=("${@:-${ALL_NODES[@]}}")
  for n in "${nodes[@]}"; do
    running "$n" || { echo "[$n] not running"; continue; }
    if is_switch "$n"; then
      echo "[$n] saving config, then powering off"
      save_switch_config "$n" || echo "[$n] warning: could not save config"
      V destroy "$n" >/dev/null
    else
      V shutdown "$n" >/dev/null
      for _ in $(seq 30); do running "$n" || break; sleep 1; done
      running "$n" && V destroy "$n" >/dev/null
    fi
    echo "[$n] stopped"
  done
}

cmd_rebuild() {    # re-define domains from lab.conf/templates without touching disks
  for n in "${@:-${ALL_NODES[@]}}"; do
    running "$n" && die "$n is running; stop it first"
    defined "$n" && V undefine "$n" >/dev/null
    build "$n"; echo "[$n] redefined"
  done
}

cmd_clean() {      # destroy VMs and delete overlay disks (base images untouched)
  for n in "${@:-${ALL_NODES[@]}}"; do
    running "$n" && V destroy "$n" >/dev/null
    defined "$n" && V undefine "$n" >/dev/null
    rm -f "$(node_dir "$n")"/{disk.qcow2,config.iso,seed.iso,domain.xml,console.log}
    echo "[$n] removed"
  done
}

cmd_status() {
  printf '%-6s %-10s %-11s %-8s %s\n' NODE STATE MGMT-IP CONSOLE MEM/CPU
  for n in "${ALL_NODES[@]}"; do
    local st; st="$(V domstate "$n" 2>/dev/null || echo undefined)"
    local mem="-"; defined "$n" && mem="$(V dominfo "$n" | awk '/Max memory/{m=$3/1024/1024} /CPU\(s\)/{c=$2} END{printf "%.0fG/%s", m, c}')"
    printf '%-6s %-10s %-11s %-8s %s\n' "$n" "$st" "${MGMT_IP[$n]}" "${CONSOLE_PORT[$n]}" "$mem"
  done
  echo; echo "links:"
  for l in "${LINKS[@]}"; do
    read -r a b <<<"$l"
    if is_host "${b%%:*}"; then read -r _ vlan cidr _ <<<"${HOST_ATTACH[${b%%:*}]}"; echo "  ${a%%:*} Gi1/0/${a##*:}  <->  ${b%%:*} eth1  (VLAN $vlan, $cidr)"
    else echo "  ${a%%:*} Gi1/0/${a##*:}  <->  ${b%%:*} Gi1/0/${b##*:}"; fi
  done
}

cmd_console() {
  local n="${1:?node}"; running "$n" || die "$n is not running"
  echo "Connecting to $n console (exit: Ctrl-] then q, or Ctrl-\\)"; echo
  socat -,raw,echo=0,escape=0x1d "tcp:127.0.0.1:${CONSOLE_PORT[$n]}"
}

cmd_ssh() {
  local n="${1:?node}"; shift || true
  if is_switch "$n"; then
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        -o KexAlgorithms=+diffie-hellman-group14-sha1 -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa \
        "admin@${MGMT_IP[$n]}" "$@"
  elif is_host "$n"; then
    echo "(CirrOS login: cirros / gocubsgo)" >&2
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "cirros@${MGMT_IP[$n]}" "$@"
  else
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "lab@${MGMT_IP[$n]}" "$@"
  fi
}

cmd_bootstrap() {  # wait for a switch to finish booting, then generate SSH keys (+ re-apply day-0 config)
  for n in "${@:-${SWITCHES[@]}}"; do
    is_switch "$n" || continue
    local d; d="$(node_dir "$n")"
    echo "[$n] waiting for console prompt (Cat9kv takes ~5-10 min on first boot)..."
    python3 "$LAB_DIR/tools/console.py" wait 127.0.0.1 "${CONSOLE_PORT[$n]}" 1200 >/dev/null
    echo "[$n] applying config + generating SSH keys"
    python3 "$LAB_DIR/tools/console.py" push 127.0.0.1 "${CONSOLE_PORT[$n]}" "$d/iosxe_config.txt" >/dev/null
    python3 "$LAB_DIR/tools/console.py" push 127.0.0.1 "${CONSOLE_PORT[$n]}" "$d/post-boot.txt" >/dev/null
    echo "[$n] ready: ssh admin@${MGMT_IP[$n]} (password: admin)"
  done
}

cmd_log() { tail -n "${2:-50}" -f "$(node_dir "${1:?node}")/console.log"; }

nautobot_token() { ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "lab@${MGMT_IP[nms]}" 'grep ^NAUTOBOT_SUPERUSER_API_TOKEN /opt/nautobot/.env | cut -d= -f2'; }
nautobot_py() {     # run a nautobot/*.py helper with the API token from the NMS
  [[ -x "$LAB_DIR/tests/.venv/bin/python" ]] || "$LAB_DIR/tests/setup.sh"
  NAUTOBOT_URL="http://${MGMT_IP[nms]}:8080" NAUTOBOT_TOKEN="$(nautobot_token)" "$LAB_DIR/tests/.venv/bin/python" "$LAB_DIR/nautobot/$1" "${@:2}"
}

cmd_nautobot() {   # Nautobot (Docker Compose) on the NMS jumphost
  local sub="${1:-status}"; shift || true
  case "$sub" in
    install) exec "$LAB_DIR/nautobot/install.sh" ;;
    onboard) nautobot_py onboard.py "$@" ;;          # discover switches from the network
    seed)    nautobot_py seed.py "$@" ;;             # load the lab intent (one-time bootstrap)
    render)  nautobot_py render_nac.py "$@" ;;       # regenerate nac/data/devices.nac.yaml (--check to verify)
    golden)  GITEA_PASSWORD="$(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "lab@${MGMT_IP[nms]}" 'grep ^GITEA_PASSWORD /opt/nautobot/.env | cut -d= -f2')" \
             nautobot_py golden_config.py "$@" ;;   # configure Golden Config, run backup -> intended -> compliance
    token)   nautobot_token ;;
    status)  cmd_ssh nms 'cd /opt/nautobot && sg docker -c "docker compose ps --format \"table {{.Service}}\t{{.Status}}\""'
             echo; echo "UI/API: http://${MGMT_IP[nms]}:8080  (admin / admin)" ;;
    logs)    cmd_ssh nms "cd /opt/nautobot && sg docker -c 'docker compose logs --tail ${1:-100} ${2:-}'" ;;
    down)    cmd_ssh nms 'cd /opt/nautobot && sg docker -c "docker compose down"' ;;
    up)      cmd_ssh nms 'cd /opt/nautobot && sg docker -c "docker compose up -d"' ;;
    *) die "usage: lab.sh nautobot {install|status|logs [n] [service]|up|down|onboard|seed|render [--check]|golden|token}" ;;
  esac
}

cmd_test() {       # run the Robot Framework suite; results in results/<date>_<time>/
  [[ -x "$LAB_DIR/tests/.venv/bin/robot" ]] || "$LAB_DIR/tests/setup.sh"
  exec "$LAB_DIR/tests/run.sh" "$@"
}

cmd_nac() {        # run terraform in nac/ with switch credentials in the environment
  export PATH="$HOME/.local/bin:$PATH"
  command -v terraform >/dev/null || die "terraform not found in PATH"
  local user="${IOSXE_USERNAME:-admin}" pass="${IOSXE_PASSWORD:-admin}"
  cd "$LAB_DIR/nac"
  IOSXE_USERNAME="$user" IOSXE_PASSWORD="$pass" terraform "$@"
  local rc=$?
  # after a successful apply, persist running-config on every switch (RESTCONF RPC)
  if [[ $rc -eq 0 && "${1:-}" == "apply" ]]; then
    for n in "${SWITCHES[@]}"; do
      if curl -sk -u "$user:$pass" -m 30 -X POST "https://${MGMT_IP[$n]}/restconf/operations/cisco-ia:save-config" \
           -H 'Content-Type: application/yang-data+json' -H 'Accept: application/yang-data+json' | grep -q -i 'success'; then
        echo "[$n] running-config saved to startup-config"
      else
        echo "[$n] warning: save-config RPC failed" >&2
      fi
    done
  fi
  return $rc
}

usage() {
  cat <<U
usage: $(basename "$0") <command> [node...]
  up [node..]        create (if needed) and start nodes       (default: all)
  down [node..]      save switch configs and stop nodes       (default: all)
  status             show node state, mgmt IPs, console ports, links
  console <node>     attach to serial console
  ssh <node> [cmd]   ssh to a node's OOB management IP
  bootstrap [sw..]   wait for switch boot, generate SSH keys (run once after first 'up')
  log <node> [n]     follow a node's console log
  nac <tf args..>    run terraform in nac/ (e.g. nac init, nac plan, nac apply)
  test [robot args]  run the Robot Framework tests (e.g. test --exclude internet)
  nautobot <cmd>     install|status|logs|up|down|onboard|seed|render|golden|token  (Nautobot, :8080)
  rebuild [node..]   re-generate domain XML from lab.conf (keeps disks)
  clean [node..]     stop, undefine and delete overlay disks (fresh start)
nodes: ${ALL_NODES[*]}
U
}

cmd="${1:-}"; shift || true
case "$cmd" in
  up|down|status|console|ssh|bootstrap|log|nac|test|nautobot|rebuild|clean) "cmd_$cmd" "$@" ;;
  *) usage; exit 1 ;;
esac
