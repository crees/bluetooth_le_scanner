#!/bin/sh

err()
{
	echo ${1+"$@"} 1>&2
	kill -USR1 0
}

dbg()
{

	[ -n "$debug" ] && echo "$*" 1>&2
}

cleanup()
{
	rm -f "$dbdir"/*_output
	exit ${1-0}
}

check_deps()
{

	for tool in "$@"; do
		type $tool > /dev/null && return 0
	done

	err "Missing dependencies; one of : $*"
}

get_conf_from_dns()
{

	_dns_src="_btle_scanner.$(hostname -d)"
	dbg "DNS -> Getting DNS settings from $_dns_src"
	for var in $(host -t txt $_dns_src | sed 's,^[^"]*",,;s,"[^"]*$,,'); do
		for v in mqtt_host mqtt_port mqtt_user mqtt_password mqtt_topic bluetooth_scan_duration bluetooth_expiry_time; do
			if [ "${var%=*}" = "$v" ]; then
				value=${var#*=}
				echo $value | grep -q '[^A-Za-z0-9.]' && err "Questionable value in DNS for $var"
				eval $v="$value"
				dbg "DNS -> Setting \"$v=$value\""
			fi
		done
		if [ "${var%%=*}" = "nickname" ]; then
			dbg "DNS -> Found nickname ${var#*=}"
			nicknames="${nicknames+$nicknames }${var#*=}"
		fi
	done
}

scan_hcitool()
{
	_tries=${1-0}

	# HCITool appears to return 124 after SIGINT, so anything
	# other than that is an error
	timeout -k 10 -s SIGINT $bluetooth_scan_duration hcitool lescan > "$dbdir/hcitool_output"

	if [ "$?" -ne "124" ]; then
		if [ "$_tries" -gt 3 ]; then
			err "hcitool keeps failing, this is no good"
		fi
		echo "hcitool failed, let's try downup" 1>&2
		hciconfig hci0 down
		sleep 10
		hciconfig hci0 up
		scan_hcitool $(expr $_tries + 1)
	else
		sed -nE 's,^([0-9A-F][0-9A-F]:\S+)\s.*,\1,p' "$dbdir/hcitool_output"
		rm "$dbdir/hcitool_output"
	fi
}

scan_bluetoothctl()
{
	timeout -k 10 -s INT $bluetooth_scan_duration bluetoothctl scan on > "$dbdir/btctl_output"
	if [ "$?" -ne 124 ]; then
		err "Bluetoothctl failed"
	fi
	sed -nE '\,Device,s,[^:]+([0-9A-F][0-9A-F]:\S+)\s.*,\1,p' "$dbdir/btctl_output"
	rm "$dbdir/btctl_output"
}

scan()
{
	# All we need is to output a list of BT MAC addresses, line separated
	# 00:00:00:00:00:00
	if type bluetoothctl >/dev/null; then
		scan_bluetoothctl
	elif type hcitool >/dev/null; then
		scan_hcitool
	else
		# Should never be reached
		err "This is a problem-- dependency code clearly faulty"
	fi
}

get_nickname()
{
	_mac=$1

	for nick in $nicknames; do
		if [ "$_mac" = "${nick%=*}" ]; then
			echo ${nick#*=}
			return 0
		fi
	done
	echo $_mac
}
publish()
{
	_present=$1
	_mac=$2
	_timestamp=$3
	_hr_date=$4
	_nick="$(get_nickname $_mac)"

	mosquitto_pub \
		-h "$mqtt_host" \
		-p "$mqtt_port" \
		-u "$mqtt_user" \
		-P "$mqtt_password" \
		-t "$mqtt_topic/$_nick" \
		-s <<EOF
{
	"present": "$_present",
	"mac": "$_mac",
	"timestamp": "$_timestamp",
	"last": "$_hr_date"
}
EOF
}

trap 'cleanup 2' USR1
trap 'cleanup' INT TERM

check_deps mosquitto_pub
check_deps bluetoothctl hcitool

while getopts c:dp:n opt; do
	case $opt in
	c)
		config_file="$OPTARG"
		;;
	d)
		debug=yes
		;;
	n)
		dns_conf=yes
		;;
	p)
		if [ "$OPTARG" = "-" ]; then
			read mqtt_password _junk
		else
			mqtt_password="$OPTARG"
		fi
		;;
	?)
		err "Usage: $0: [-c config_file|-n] [-p -|password]\n"
		;;
	esac
done

if [ -n "$dns_conf" ]; then
	get_conf_from_dns
elif [ -r "${config_file:=$(pwd)/bluetooth_le_scanner.conf}" ]; then
	. "$config_file"
else
	err "$config_file either does not exist or is unreadable"
fi

: ${mqtt_host=localhost}
: ${mqtt_port=1883}
: ${mqtt_user=$(hostname -s)}
: ${mqtt_password=$(cat /etc/bluetooth_le_scanner.mqttpasswd || echo defaultpasswd)}
: ${mqtt_topic=btlescan/$(hostname)}
: ${dbdir=/var/db/bluetooth_le_scanner}

if ! [ -r "$dbdir" -a -d "$dbdir" ]; then
	err "$dbdir does not exist, is not readable or is not a directory"
fi

mkdir -p "$dbdir/addrs"

# We need to definitely report on nicknamed ones, so
# pretend they were available before
for nick in $nicknames; do
	mac=${nick%=*}
	printf %s 0 > "$dbdir/addrs/$mac"
done

cd "$dbdir/addrs"

while :; do
	[ -n "$dns_conf" ] && get_conf_from_dns
	timestamp_now=$(date +%s)
	scan | sort -u | while read mac _junk; do
		printf %s "$(date +%s)" > "$mac"
	done
	for mac in *; do
		[ "$mac" = "*" ] && break
		<$mac read ts
		hr_date=$(date -d @$ts 2>/dev/null || date -r $ts)
		if [ "$(expr $timestamp_now - $ts)" -lt "$bluetooth_expiry_time" ]; then
			publish 1 $mac $ts "$hr_date"
		else
			publish 0 $mac $ts "$hr_date"
			rm $mac
		fi
	done
done
