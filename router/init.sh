#! /bin/bash

# - Take over host's 169.254.224.1 (and set host's sf-host to 169.254.255.254).
# - Force default route to VPN Gateways

source "/sf/bin/funcs.sh"

ASSERT_EMPTY "NET_VPN" "$NET_VPN"
ASSERT_EMPTY "NET_LG" "$NET_LG"
ASSERT_EMPTY "NET_LG_ROUTER_IP" "$NET_LG_ROUTER_IP"
ASSERT_EMPTY "NET_LG_ROUTER_IP_DUMMY" "$NET_LG_ROUTER_IP_DUMMY"
ASSERT_EMPTY "NET_ACCESS_ROUTER_IP" "$NET_ACCESS_ROUTER_IP"
ASSERT_EMPTY "NET_VPN_ROUTER_IP" "$NET_VPN_ROUTER_IP"
ASSERT_EMPTY "TOR_IP" "$TOR_IP"
ASSERT_EMPTY "GSNC_IP" "$GSNC_IP"
ASSERT_EMPTY "SSHD_IP" "$SSHD_IP"
ASSERT_EMPTY "NGINX_IP" "$NGINX_IP"
ASSERT_EMPTY "NET_DIRECT_ROUTER_IP" "$NET_DIRECT_ROUTER_IP"
ASSERT_EMPTY "NET_DIRECT_BRIDGE_IP" "$NET_DIRECT_BRIDGE_IP"
ASSERT_EMPTY "NET_DMZ_ROUTER_IP" "$NET_DMZ_ROUTER_IP"

VPN_IPS=("$SF_NORDVPN_IP" "$SF_CRYPTOSTORM_IP" "$SF_MULLVAD_IP")

devbyip()
{
	local dev
	dev="$(ip addr show | grep -F "inet $1" | head -n1 | awk '{print $7;}')"
	[[ -z $dev ]] && { echo -e >&2 "DEV not found for ip '$1'"; return 255; }
	echo "$dev"
}

init_revport_once()
{
	[[ -n $IS_REVPORT_INIT ]] && return
	IS_REVPORT_INIT=1
	### Create routing tables for reverse connection and when multipath routing is used:
	# We are using multipath routing _and_ reverse port forwarding from the VPN Provider.
	# See Cryptostorm's http://10.31.33.7/fwd as an example:
	# The reverse connection has the true source IP but our router's multipath route
	# might return the SYN/ACK via a different path. Thus we mark all new incoming
	# connections (from the VPN provider) and route the reply out the same GW it came in
	# from. The (cheap) alternative would be to use SNAT and MASQ but then the guest's
	# root server would not see the true source IP of the reverse connection.

	# Get the MAC address of all routers.
	fping -c3 -A -t20 -p10 -4 -q "${VPN_IPS[@]}" 2>/dev/null 

	# Mark every _NEW_ connection from VPN
	# --restore-mark 'copies' the mark from the connmark target to the current
	# packet (and then immediately checks if the packet is already part of an
	# already tracked connection (! --mark 0 -j ACCEPT)
	iptables -A PREROUTING -t mangle -i "${DEV_GW}" -j CONNMARK --restore-mark
	iptables -A PREROUTING -t mangle -i "${DEV_GW}" -m mark ! --mark 0 -j ACCEPT
	local idx
	local ips
	local ips_idx
	local i
	i=0
	while [[ i -lt ${#VPN_IPS[@]} ]]; do
		ip=${VPN_IPS[$idx]}
		idx=$i
		[[ -z $ip ]] && ERREXIT 255 "Oops, VPN_IPS[$idx] contains empty VPN IP"
		((i++))
		mac="$(ip neigh show "${ip}")"
		mac="${mac##*lladdr }"
		mac="${mac%% *}"
		[[ "${#mac}" -ne 17 ]] && continue # empty or '169.254.239.x dev eth4 FAILED'

		ips_idx+=("$idx")
		ips+=("$ip")
		# Mark any _NEW_ connection by GW's mac.
		iptables -A PREROUTING -t mangle -i "${DEV_GW}" -p tcp -m conntrack --ctstate NEW -m mac --mac-source "${mac}" -j MARK --set-mark "11${idx}"
		iptables -A PREROUTING -t mangle -i "${DEV_GW}" -p udp -m conntrack --ctstate NEW -m mac --mac-source "${mac}" -j MARK --set-mark "11${idx}"
	done
	# --save-mark adds the mark of a current packet to the connmark target
	iptables -A PREROUTING -t mangle -i "${DEV_GW}" -j CONNMARK --save-mark

	echo -e >&2 "[$(date '+%F %T' -u)] RevPort set up for ${ips[*]}"

	# Route return traffic back to VPN-GW the packet came in from.
	# Every return packet is marked (11nnn). If it is marked (e.g. it is a return packet)
	# then also mark it as 12nnn. Then use customer routing rule for all packets
	# marked 12nnn.
	# Note: We can not route on 11nnn because this would as well incoming packets (and
	# we only need to route return packets). 

	# Load the ConnTrack MARKS:
	# ..but only if not from MOSH's redirections (to 169.254.224.1)
	iptables -A PREROUTING -t mangle -i "${DEV_LG}" ! -d "${NET_LG_ROUTER_IP}" -j CONNMARK --restore-mark
	for idx in "${ips_idx[@]}"; do
		# On return path (-i DEV), add 12nnn mark for every packet that was initially tracked (11nnn).
		iptables -A PREROUTING -t mangle -i "${DEV_LG}" -m mark --mark "11${idx}" -j MARK --set-mark "12${idx}"
		# Add a routing table for return packets to force them via GW (mac) they came in from.
		ip rule add fwmark "12${idx}" table "8${idx}"
		ip route add default via "${VPN_IPS[$idx]}" dev ${DEV_GW} table "8${idx}"
	done
}

use_vpn()
{
	local gw
	local gw_ip

	unset IS_TOR

	# Configure FW rules for reverse port forwards.
	# Any earlier than this and the MAC of the routers are not known. Thus do it here.

	init_revport_once

	local _ip
	local f
	for f in /sf/run/vpn/status-*; do
		[[ ! -f "$f" ]] && break
		_ip="$(<"$f")"
		_ip="${_ip%%$'\n'*}"
		_ip="${_ip##*=}"
		_ip="${_ip//[^0-9\.]/}" # Sanitize
		[[ -z $_ip ]] && continue
		gw+=("nexthop" "via" "${_ip}" "weight" "100")
		gw_ip+=("${_ip}")
	done

	[[ -z $gw ]] && return

	echo -e >&2 "[$(date '+%F %T' -u)] Switching to VPN (gw=${gw_ip[@]})" 
	ip route del default
	ip route add default "${gw[@]}"

}

use_tor()
{
	IS_TOR=1

	echo -e >&2 "$(date) Switching to TOR" 
	ip route del default 2>/dev/null
	ip route add default via "${TOR_IP}"
}

monitor_failover()
{
	local status_sha

	# FIXME: use redis here instead of polling
	while :; do
		bash -c "exec -a '[sleep router failover]' sleep 1"
		sha="$(sha256sum /config/guest/vpn_status 2>/dev/null)"
		[[ "$status_sha" ==  "$sha" ]] && continue

		# Status has changed
		status_sha="${sha}"

		# If vpn_status no longer exists then switch to TOR
		[[ ! -f /config/guest/vpn_status ]] && { use_tor; continue; }

		use_vpn
	done
}

# Set Iptables Forwarding rules
ipt_set()
{
	# Do not use CONNTRACK unless needed to prevent conntrack-table-overflow

	iptables -P FORWARD DROP

	# 0. Path MTU Discovery is not supported by all routers on the Internet.
	# 1. Some routers fragment large TCP packets. The fragments are re-assembles at my
	#    router (sf-router) but the resulting TCP have BAD checksum.
	# 2a. NordVPN/London `whois -h 192.34.234.30  google.com` => two fragments. Bad Checksum.
	# 2b. CryptoStorm/Serbia `wget https://raw.githubusercontent.com/theaog/spirit/master/spirit.tgz`
	#     => No fragments at all. Dropped upsteream?
	#    (Oddly, this would mean the upstream re-assembles the fragments - no upstream router
	#    is supposed to re-assemble the fragments. Is there a stateful-IDS upsteam?
	#
	# Kernel trace shows (on sf-router) that it fails in checksum verification after
	# fragment re-assembly (dropwatch -l kas):
	#    https://www.cyberciti.biz/faq/linux-show-dropped-packets-per-interface-command/
	#
	# The only way around this is to advertise a smaller MSS for TCP and hope for the best
	# for all other protocols. Ultimately we need bad routers on the Internet to disappear.
	iptables -A FORWARD -i ${DEV_LG} -o ${DEV_GW} -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1380

	# -----BEGIN DIRECT SSH-----
	# Note: The IP addresses are FLIPPED because we use DNAT/SNAT/MASQ in PREROUTING
	# before the FORWARD chain is hit

	# Limit annoying SSHD brute force attacks
	iptables -A FORWARD -o ${DEV_ACCESS} -p tcp --dport 22 --syn -m hashlimit --hashlimit-mode srcip --hashlimit-name ssh_brute_limit --hashlimit-above 10/min --hashlimit-burst 16 -j DROP

	# DNAT in use: 172.28.0.1 -> 172.22.0.22
	iptables -A FORWARD -i ${DEV_DIRECT} -p tcp -d "${SSHD_IP}" --dport 22 -j ACCEPT 

	# SNAT in use: 172.22.0.22 -> 172.28.0.1
	# Inconing from 172.22.0.22 -> 172.22.0.254 (MASQ)
	iptables -A FORWARD -i ${DEV_ACCESS} -o "${DEV_DIRECT}" -p tcp --sport 22 -j ACCEPT
	# -----END DIRECT SSH-----

	# LG can access Internet via VPN
	iptables -A FORWARD -i "${DEV_LG}" -o "${DEV_GW}" -j ACCEPT
	iptables -A FORWARD -o "${DEV_LG}" -i "${DEV_GW}" -j ACCEPT

	# GSNC can access Internet via DIRECT
	iptables -A FORWARD -i "${DEV_ACCESS}" -o ${DEV_DIRECT} -p tcp -s "${GSNC_IP}" -j ACCEPT
	iptables -A FORWARD -o "${DEV_ACCESS}" -i ${DEV_DIRECT} -p tcp -d "${GSNC_IP}" -j ACCEPT

	# SSHD can forward ports to LGs (ssh -L) and LGs can access
	# SSHD reverse ports (ssh -R) but not port 22 (sshd service)
	iptables -A FORWARD -i "${DEV_LG}" -o "${DEV_ACCESS}" -p tcp --dport 22 -j REJECT  --reject-with tcp-reset
	iptables -A FORWARD -i "${DEV_ACCESS}" -o "${DEV_LG}" -s "${SSHD_IP}" -j ACCEPT
	iptables -A FORWARD -o "${DEV_ACCESS}" -i "${DEV_LG}" -d "${SSHD_IP}" -j ACCEPT

	# SSHD -D1080 forward
	iptables -A FORWARD -i "${DEV_ACCESS}" -o "${DEV_GW}" -s "${SSHD_IP}" -j ACCEPT
	iptables -A FORWARD -o "${DEV_ACCESS}" -i "${DEV_GW}" -d "${SSHD_IP}" -j ACCEPT

	# Onion to NGINX
	iptables -A FORWARD -i "${DEV_GW}" -o "${DEV_DMZ}" -s "${TOR_IP}" -d "${NGINX_IP}" -p tcp --dport 80 -j ACCEPT
	iptables -A FORWARD -o "${DEV_GW}" -i "${DEV_DMZ}" -d "${TOR_IP}" -s "${NGINX_IP}" -p tcp --sport 80 -j ACCEPT

	# TOR via VPN gateways
	iptables -A FORWARD -i "${DEV_GW}" -o "${DEV_GW}" -s "${TOR_IP}" -j ACCEPT
	iptables -A FORWARD -i "${DEV_GW}" -o "${DEV_GW}" -d "${TOR_IP}" -j ACCEPT
	
	# Onion to SSHD
	# => Already set by SSHD -D1080 setup
}

ipt_syn_limit_set()
{
	local in
	local out
	local limit
	local burst
	in="$1"
	out="$2"
	limit="$3"
	burst="$4"

	iptables --new-chain "SYN-LIMIT-${in}-${out}"
	iptables -I FORWARD 1 -i "${in}" -o "${out}" -p tcp --syn -j "SYN-LIMIT-${in}-${out}"
	# Refill bucket at a speed of 20/sec and take out max of 64k at one time.
	# 64k are taken and thereafter limit to 20syn/second (as fast as the bucket refills)
	iptables -A "SYN-LIMIT-${in}-${out}" -m limit --limit "${limit}" --limit-burst "${burst}" -j RETURN
	iptables -A "SYN-LIMIT-${in}-${out}" -j DROP
}

ipt_syn_limit()
{
	# User to VPN
	ipt_syn_limit_set "${DEV_LG}"     "${DEV_GW}" "20/sec" "10000"
	# SSH -D1080 forwards to VPN
	ipt_syn_limit_set "${DEV_ACCESS}" "${DEV_GW}" "5/sec" "5000"
}

# Delete old vpn_status
[[ -f /config/guest/vpn_status ]] && rm -f /config/guest/vpn_status

DEV_DIRECT="$(devbyip "${NET_DIRECT_ROUTER_IP}")" || exit
DEV_LG="$(devbyip "${NET_LG_ROUTER_IP_DUMMY}")" || exit
DEV_ACCESS="$(devbyip ${NET_ACCESS_ROUTER_IP})" || exit
DEV_GW="$(devbyip "${NET_VPN_ROUTER_IP}")" || exit
DEV_DMZ="$(devbyip "${NET_DMZ_ROUTER_IP}")" || exit

echo -e "\
DEV_DIRECT="${DEV_DIRECT}"\n\
DEV_LG="${DEV_LG}"\n\
DEV="${DEV_LG}"\n\
DEV_ACCESS="${DEV_ACCESS}"\n\
DEV_GW="${DEV_GW}"\n\
DEV_DMZ="${DEV_DMZ}"\n\
" >/dev/shm/net-devs.txt


[[ -n $SF_DEBUG ]] && {
	ip link show >&2
	ip addr show >&2
	ip route show >&2

	echo >&2 "DEV_LG=${DEV_LG} DEV_GW=${DEV_GW}"
}

set -e
ipt_set

ipt_syn_limit

ip route del default

# -----BEGIN SSH traffic is routed via Direct Internet-----
# All traffic must go via the router (for Traffic Control etc).
#
# A bit more tricky to forward incoming SSH traffic to our SSHD
# because we also like to see the source IP (User's Workstation's IP).
#
# Must rp_filter=2 (see docker-compose.yml)
# # iptables -t raw -A PREROUTING -p tcp -d 172.20.0.2 --dport 22 -j TRACE
# # iptables -t raw -L -v -n --line-numbers
# # modprobe nf_log_ipv4 && sysctl net.netfilter.nf_log.2=nf_log_ipv4
# - iptables -L PREROUTING -t mangle -n
# - ip rule show
# - ip route show table 207
# Forward all SSHD traffic to the router (172.28.0.2) to sf-host:22.
iptables -t mangle -A PREROUTING -i ${DEV_DIRECT} -p tcp -d "${NET_DIRECT_ROUTER_IP}" --dport 22 -j MARK --set-mark 722
ip rule add fwmark 722 table 207
ip route add default via "${SSHD_IP}" dev ${DEV_ACCESS} table 207

# Any return traffic from the SSHD shall go out (directly) to the Internet or to TOR (if arrived from TOR)
iptables -t mangle -A PREROUTING -i ${DEV_ACCESS} -p tcp -s "${SSHD_IP}" --sport 22 -d "${TOR_IP}" -j RETURN
iptables -t mangle -A PREROUTING -i ${DEV_ACCESS} -p tcp -s "${SSHD_IP}" --sport 22 -j MARK --set-mark 22
ip rule add fwmark 22 table 201
ip route add default via "${NET_DIRECT_BRIDGE_IP}" dev ${DEV_DIRECT} table 201

# Forward packets to SSHD (172.22.0.22)
iptables -t nat -A PREROUTING -p tcp -d "${NET_DIRECT_ROUTER_IP}" --dport 22 -j DNAT --to-destination "${SSHD_IP}"
# Make packets appear as if this router was listening on port 22
iptables -t nat -A POSTROUTING -p tcp -s "${SSHD_IP}" --sport 22 -j SNAT --to-source "${NET_DIRECT_ROUTER_IP}"
# When connecting from Docker's host:
# Note: Traffic from router to shell leaves with src=172.28.0.1 and dst=172.22.0.22
# However, at the SSHD they appear to be comming from src=172.22.0.254 because
# Docker's host side bridge performs NAT. On the SSHD side we can not send
# the traffic back to 172.28.0.1 (via 172.22.0.254; this router) because both share the
# same MAC.
# Instead use a hack to force traffic from 172.28.0.1 to be coming
# from 172.22.0.254 (This router's IP)
iptables -t nat -A POSTROUTING -s "${NET_DIRECT_BRIDGE_IP}" -o ${DEV_ACCESS} -j MASQUERADE
# -----END SSH traffic is routed via Internet-----

# Take over host's IP so we become the router for all LGs.
ip addr del "${NET_LG_ROUTER_IP_DUMMY}/${NET_LG##*/}" dev "${DEV_LG}" || ERREXIT 253 "Could not delete ${NET_LG_ROUTER_IP_DUMMY}"
ip addr add "${NET_LG_ROUTER_IP}/${NET_LG##*/}" dev "${DEV_LG}" || ERREXIT 252 "Could not assign '${NET_LG_ROUTER_IP}/${NET_LG##*/}' to '${DEV_LG}'"
# -----BEGIN MOSH-----
# https://upload.wikimedia.org/wikipedia/commons/3/37/Netfilter-packet-flow.svg
# Range 30,000 - 65,535 is used by CryptoStorm
# Use 25000 - 26,023 for MOSH, Max 1024 lg-hosts

# FIXME: This needs improvement to support multiple mosh sessions per LG:
# 1. Use sf_cli (nginx) to request UDP port forward
# 2. Use a userland UDP proxy (to prevent conntrack exhaustion attack)
# 3. Userland UDP proxy must run on host's network namespace as docker fails
#    to forward (expose/port) >500 ports (fails to start container)

# All LG generated UDP traffic should still go via VPN but if the traffic came in
# from DIRECT then it should leave via DIRECT. To achieve this we use a trick:
# 1. MARK on incoming interface.
# 2. DNAT to LG
# 3. MASQ towards LG _if_ marked earlier (e.g. UDP arrived from DIRECT)
# 4. Mark any traffic from LG to _router_ to leave via DIRECT (because it was masq'ed before)

# Mark incoming packets 
iptables -t nat -A PREROUTING -i ${DEV_DIRECT} -p udp -d "${NET_DIRECT_ROUTER_IP}" -j MARK --set-mark 52

# Forward different port's to separate LG's
# Each LG has a dedicated UDP port: 25002 -> 10.11.0.2, 25003 -> 19.11.0.3, ...
# Get 10.11.y.x
s=${NET_LG%/*}
y=${s%.*}
base=${y%.*}   # 10.11.y.x
y=${y##*.}
x=${s##*.}
i=3       # First free IP is 10.11.0.3 (the 3rd IP).
((x+=i))
set +e
# FIXME: Calculate max size rather then 4 Class-C
while [[ $i -lt $((256 * 4 - 3)) ]]; do
	iptables -t nat -A PREROUTING -i ${DEV_DIRECT} -p udp -d "${NET_DIRECT_ROUTER_IP}" --dport $((25000 + i)) -j DNAT --to-destination "${base}.$y.$x" || ERREXIT
	((i++))
	((x++))
	[[ $x -lt 256 ]] && continue
	x=0
	((y++))
done
set -e

# Odd, mark-52 is no match in this chain
# iptables -A FORWARD -m mark --mark 52 -j ACCEPT
iptables -A FORWARD -i ${DEV_DIRECT} -o ${DEV_LG} -p udp --dport 25002:26023 -j ACCEPT
iptables -A FORWARD -o ${DEV_DIRECT} -i ${DEV_LG} -p udp --sport 25002:26023 -j ACCEPT

# HERE: Came in via DIRECT and dport is within range => Send to LG and MASQ as sf-router (169.254.224.1)
iptables -t nat -A POSTROUTING -o ${DEV_LG} -m mark --mark 52 -j MASQUERADE

# Return traffic to _router_ should be routed via DIRECT (it's MASE'ed return traffic)
iptables -t mangle -A PREROUTING -i ${DEV_LG} -p udp -d "${NET_LG_ROUTER_IP}" --sport 25002:26023 -j MARK --set-mark 22
# -----END MOSH-----

# -----BEGIN GSNC traffic is routed via Internet----
# GSNC TCP traffic to 443 and 7350 goes to (direct) Internet
iptables -t mangle -A PREROUTING -i ${DEV_ACCESS} -p tcp -s "${GSNC_IP}" -j MARK --set-mark 22
# -----END GSNC traffic is routed via Internet----

# MASQ all traffic because the VPN/TOR instances dont know the route back
# to sf-guest (169.254.224/20).
iptables -t nat -A POSTROUTING -o "${DEV_GW}" -j MASQUERADE
# MASQ SSHD's forward to user's server
iptables -t nat -A POSTROUTING -s "${SSHD_IP}" -o "${DEV_LG}" -j MASQUERADE
# MASQ GSNC to (direct) Internet
iptables -t nat -A POSTROUTING -s "${GSNC_IP}" -o "${DEV_DIRECT}" -j MASQUERADE
# MASQ traffic from TOR to DMZ (nginx)
iptables -t nat -A POSTROUTING -o "${DEV_DMZ}" -j MASQUERADE
# TOR traffic (169.254.240.0/21) always goes to TOR (transparent proxy)
ip route add "${NET_ONION}" via "${TOR_IP}"

# blacklist_routes
# Everything else REJECT with RST or ICMP
iptables -A FORWARD -p tcp -j REJECT --reject-with tcp-reset
iptables -A FORWARD -j REJECT

echo -e >&2 "FW: SUCCESS"

# Set up Traffic Control (limit bandwidth)
/tc.sh "${DEV_LG}" "${DEV_GW}" "${DEV_DIRECT}"
echo -e >&2 "TC: SUCCESS"

set +e
# By default go via TOR until vpn_status exists
use_tor
monitor_failover

# REACHED IF ANY CMD FAILS
ip route del default
echo -e >&2 "FAILED to set routes"
exit 250

