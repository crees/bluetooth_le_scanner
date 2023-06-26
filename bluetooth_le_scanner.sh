#!/bin/sh

err()
{
	echo ${1+"$@"}
	exit 2
}

check_deps()
{
	_missingTools=""

	for tool in "$@"; do
		type $tool > /dev/null || _missingTools="$_missingTools $tool"
	done

	if [ -n "$_missingTools" ]; then
		err "Missing dependencies: $_missingTools"
	fi
}

scan_hcitool()
{
	timeout -s SIGINT 30s hcitool lescan || err "hcitool failed"
}

scan()
{
	# Later we can probably autodetect different tools for
	# non-BlueZ environments
	# All we need is to output a list of BT MAC addresses, line separated with
	# a label afterwards, e.g. a name like this:
	# 00:00:00:00:00:00 (Unknown)
	scan_hcitool
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
	_name="$3"
	_nick=$(get_nickname $_mac)

	mosquitto_pub \
		-h $mqtt_host \
		-p $mqtt_port \
		-u $mqtt_user \
		-P $mqtt_password \
		-t "$mqtt_topic/$_nick" \
		-s <<EOF
{
	"present": "$_present",
	"mac": "$_mac",
	"name":	"$_name",
	"timestamp": "$(date +%s)",
	"last": "$(date '+%X %x')"
}
EOF
}

check_deps mosquitto_pub hcitool

while getopts c: opt; do
	case $opt in
	c)
		config_file="$OPTARG"
		;;
	?)
		err "Usage: $0: [-c config_file]\n"
		;;
	esac
done

if [ -r "${config_file:=$(pwd)/bluetooth_le_scanner.conf}" ]; then
	. "$config_file"
else
	err "$config_file either does not exist or is unreadable"
fi

if ! [ -r "$dbdir" -a -d "$dbdir" ]; then
	err "$dbdir does not exist, is not readable or is not a directory"
fi

if [ -f "$dbdir/previous" ]; then
	cat "$dbdir/current" >> "$dbdir/previous"
	# We need to definitely report on nicknamed ones, so
	# pretend they were available before
	for nick in $nicknames; do
		echo "${nick%=*} Unknown" >> "$dbdir/previous"
	done
	sort -u "$dbdir/previous" > "$dbdir/current"
else
	touch "$dbdir/current"
fi

while :; do
	mv "$dbdir/current" "$dbdir/previous"
	scan | grep '^[0-9A-Fa-f][0-9A-Fa-f]:' | \
		sort -u > "$dbdir/current"
	# These have either just been scanned or are still here
	comm -2 "$dbdir/current" "$dbdir/previous" | \
			sort -r | while read mac name; do
		publish 1 $mac "$name"
	done
	# These have disappeared
	comm -13 "$dbdir/current" "$dbdir/previous" | \
			sort -r | while read mac name; do
		publish 0 $mac "$name"
	done
done
