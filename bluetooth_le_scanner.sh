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
	nicknames=""
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
			nicknames="${nicknames:+$nicknames }${var#*=}"
		fi
	done
}

reset_bluetooth_htitool()
{

		hciconfig hci0 down
		sleep 10
		hciconfig hci0 up
}

scan_hcitool()
{
	_tries=${1-0}

	# HCITool appears to return 124 after SIGINT, so anything
	# other than that is an error
	_hcitool_output=$(timeout -k 10 -s SIGINT $bluetooth_scan_duration hcitool lescan)

	if [ "$?" -ne "124" ]; then
		if [ "$_tries" -gt 3 ]; then
			err "hcitool keeps failing, this is no good"
		fi
		echo "hcitool failed, let's try downup" 1>&2
		reset_bluetooth_hcitool
		scan_hcitool $(expr $_tries + 1)
	else
		printf %s "$_hcitool_output" | sed -nE 's,^([0-9A-F][0-9A-F]:\S+)\s.*,\1,p'
	fi
}

reset_bluetooth_bluetoothctl()
{

	bluetoothctl power off
	sleep 10
	bluetoothctl power on
}

scan_bluetoothctl()
{

	_hcitool_output=$(timeout -k 10 -s INT $bluetooth_scan_duration bluetoothctl scan on)
	if [ "$?" -ne 124 ]; then
		err "Bluetoothctl failed"
	fi
	printf %s "$_hcitool_output" | sed -nE '\,Device,s,[^:]+([0-9A-F][0-9A-F]:\S+)\s.*,\1,p'
}

pick_tool()
{
	# All we need is to output a list of BT MAC addresses, line separated
	# 00:00:00:00:00:00
	if type bluetoothctl >/dev/null; then
		printf %s bluetoothctl
	elif type hcitool >/dev/null; then
		printf %s hcitool
	else
		# Should never be reached
		err "This is a problem-- dependency code clearly faulty"
	fi
}

scan()
{

	scan_$(pick_tool)
}

reset_bluetooth()
{

	reset_bluetooth_$(pick_tool)
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
elif [ -r "${config_file:=/etc/bluetooth_le_scanner.conf}" ]; then
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
: ${bluetooth_reset_interval:=1800}

# We need to definitely report on nicknamed ones, so
# pretend they were available before
for nick in $nicknames; do
	mac=${nick%=*}
	maclist="${maclist:+$maclist }$mac:0"
done

# Every half hour, we'll reset the Bluetooth adaptor.
# Nasty cheap ones often stop working properly every
# now and again, and a simple up/down usually fixes them.
# Reset it on startup, so set last reset time to 1970.
bt_last_adaptor_reset=0

while :; do
	[ -n "$dns_conf" ] && get_conf_from_dns
	timestamp_now=$(date +%s)
	if [ "$bluetooth_reset_interval" -gt 0 -a \
		"$(($timestamp_now - 1800))" -gt "$bt_last_adaptor_reset" ]; then
		bt_last_adaptor_reset=$timestamp_now
		reset_bluetooth
	fi
	tmpmaclist=$(scan | sort -u | while read mac _junk; do
		printf %s "$mac:$(date +%s) "
	done)
	newmaclist="$tmpmaclist"
	# Check for those that have dropped off
	for m in $maclist; do
		_mac=${m%:*}
		_ts=${m##*:}
		if [ "${tmpmaclist%${_mac}*}" = "${tmpmaclist}" ]; then
			# No longer visible, check expired
			hr_date=$(date -d @$_ts 2>/dev/null || date -r $_ts)
			if [ "$(expr $timestamp_now - $_ts)" -lt "$bluetooth_expiry_time" ]; then
				dbg "$_mac disappeared: last seen $hr_date"
				newmaclist="${newmaclist:+$newmaclist }$m"
			else
				dbg "$_mac expired"
				publish 0 $_mac $_ts "$hr_date"
			fi
		fi
	done
	# Now we've added on the old ones that haven't expired, publish them all
	for m in $newmaclist; do
		_mac=${m%:*}
		_ts=${m##*:}
		hr_date=$(date -d @$_ts 2>/dev/null || date -r $_ts)
		dbg "$_mac visible:     last seen $hr_date"
		publish 1 $_mac $_ts "$hr_date"
	done
	maclist="$newmaclist"
done
