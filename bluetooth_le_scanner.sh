#!/bin/sh

err()
{
	echo ${1+"$@"} 1>&2
	kill -USR1 0
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
	_tries=${1-0}

	# HCITool appears to return 124 after SIGINT, so anything
	# other than that is an error
	timeout -s SIGINT 30s hcitool lescan

	if [ "$?" -ne "124" ]; then
		if [ "$_tries" -gt 3 ]; then
			err "hcitool keeps failing, this is no good"
		fi
		echo "hcitool failed, let's try downup" 1>&2
		hciconfig hci0 down
		sleep 10
		hciconfig hci0 up
		scan_hcitool $(expr $_tries + 1)
	fi
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

trap 'exit 2' USR1

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
		mac=${nick%=*}
		if ! grep -q "^$mac" "$dbdir/previous"; then
			echo "$mac Unknown" >> "$dbdir/previous"
		fi
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
