#! /bin/bash

source "/sf/bin/funcs.sh"
source "/sf/bin/funcs_net.sh"

# NOTE: The iptable rules set inside this container are not visible (iptables -S) on the host
# even that 'network_mode: host' is set. Yet the rule are working on the host side (Why?).
# Furthermore, creating the correct link on the host in /var/run/netns to make the docker namespace
# show up in 'ip netns list' and entering the namespace 'ip netns exec' still wont show
# the iptable rules set inside this container. (Why?).
# See also
# - https://stackoverflow.com/questions/31265993/docker-networking-namespace-not-visible-in-ip-netns-list

# We need to use our own forwarding rules. Docker-compose otherwise spawns a separate process
# for _every_ port - which exceeds Docker's own startup timer if to many ports are forwarded
# and thus docker-compose will fail to start.
#
# Forward traffic to docker
# [UDP/TCP] [PORT-RANGE] [DSTIP]
fw2docker()
{
	local proto
	local range
	local dstip
	proto="$1"
	range="$2"
	dstip="$3"

	iptables -t nat -I PREROUTING -i "${dev}" -d "${mainip}" -p "${proto}" --dport "${range}" -j DNAT --to-destination "${dstip}"

	[[ -z $SF_DEBUG ]] && return

	# #1 - Special hack when connecting from localhost to 10.0.2.15
	iptables -t nat -I OUTPUT -o lo -d "${mainip}" -p "${proto}" --dport "${range}" -j DNAT --to-destination "${dstip}"
	# #2 - When connecting from localhost to 127.0.0.1 (#1 is also required)
	iptables -t nat -I OUTPUT -o lo -s 127.0.0.1 -d 127.0.0.1  -p "${proto}" --dport "${range}" -j DNAT --to-destination "${dstip}"
	iptables -t nat -A POSTROUTING  -s 127.0.0.1 -d "${dstip}" -p "${proto}" --dport "${range}" -j SNAT --to "${NET_DIRECT_BRIDGE_IP:?}"
}

# This is a hack.
# - Docker sets the default route to IP of the host-side of the bridge
# - Our 'sf-router' container likes to receive all the traffic instead.
# - Remove host's bridge ip address (flush) 
# - sf-router's init.sh script will take over the IP of host's bridge (and thus receiving all traffic)
# An alternative would be to assign a default gw in user's sf-shell
# and use nsenter -n to change the default route (without giving NET_ADMIN
# to the user).
dev=$(DevByIP "${NET_LG_ROUTER_IP:?}")
[[ -z $dev ]] && ERREXIT 255 "Failed to find network device on host for NET_LG_ROUTER_IP=$NET_LG_ROUTER_IP"
# Remove _any_ ip from the interface. This means LGs can never exit
# to the Internet via the host but still route packets to sf-router.
# sf-router is taking over the IP NET_LG_ROUTER_IP
ip link set "$dev" arp off
ip addr flush "$dev"

mainip=$(GetMainIP)
dev=$(DevByIP "${mainip:?}")
[[ -z $dev ]] && ERREXIT 255 "Failed to find main network device on host."

# NET_DIRECT_WG_IP=172.28.0.3
# NET_DIRECT_BRIDGE_IP=172.28.0.1
# WireGuard forwards to sf-wg
iptables -t nat -F PREROUTING
iptables -t nat -F OUTPUT
iptables -t nat -F POSTROUTING
fw2docker "udp" "32768:65535" "${NET_DIRECT_WG_IP}"
# MOSH forwards to sf-router (for traffic control)
fw2docker "udp" "25002:26023" "${NET_DIRECT_ROUTER_IP}"

[[ -n $SF_DEBUG ]] && sysctl -w "net.ipv4.conf.$(DevByIP "${NET_DIRECT_BRIDGE_IP:?}").route_localnet=1"

# Keep this running so we can inspect iptables rules (really mostly for debugging only)
exec -a '[network-fix]' sleep infinity