`bluetooth-le-scanner`
======

Very simple passive detection of Bluetooth Low Energy beacons using MQTT

This is currently for GNU/Linux using Bluez, and requires a Mosquitto
server as well.  It is very easy to adapt for other OSes- pull requests
are always welcome as portability is good.  Please stick to POSIX sh.

I'm really grateful to @andrewjfreyer for his Monitor project, which is
far too sophisticated for my needs, but it gave me several clues.

# Installation and setup (on a Raspberry Pi)

```bash
git clone https://github.com/crees/bluetooth_le_scanner/
cd bluetooth_le_scanner
install -o root -g 0 -m 755 bluetooth_le_scanner.sh /usr/sbin/
install -o root -g 0 -m 600 bluetooth_le_scanner.conf.sample /etc/bluetooth_le_scanner.conf
# edit /etc/bluetooth_le_scanner.conf
install -o root -g 0 -m 644 systemd/bluetooth_le_scanner.service /etc/systemd/system/
systemctl enable bluetooth_le_scanner
service bluetooth_le_scanner start
```

# Adding to Home Asssistant

Once you have MQTT configured, it's very straightforward to subscribe
to presence detection.  Add to your configuration.yaml:

```yaml
mqtt:
  sensor:
    - name: 'Airtag 1'
      unique_id: mqtt_myraspberry_sensor_airtag_one
      state_topic: 'btlescan/myraspberry/airtag_one'
      value_template: '{{ value_json.present }}'
    - name: 'Airtag 2'
      unique_id: mqtt_myraspberry_sensor_airtag_two
      state_topic: 'btlescan/myraspberry/airtag_two'
      value_template: '{{ value_json.present }}'
```

# Using DNS for parameters

When you have a few beacon sensors around, having a consistent configuration
is helpful.  If you control the DNS server for your domain, then you can add
a record in this form:

```
_btle_scanner           TXT     "bluetooth_scan_duration=15 bluetooth_expiry_time=60 mqtt_host=my_mqtt_host.example.com nickname=AA:AA:AA:AA:AA:AA=airtag_one nickname=BB:BB:BB:BB:BB:BB=airtag_two"
```

Run `bluetooth_le_scanner` with the `-n` option (and the `-d` debug option might be helpful
when setting up) and put the MQTT password into `/etc/bluetooth_le_scanner.mqttpasswd`.

It will rescan the DNS just before each beacon scan.  Obviously the TTL will affect how
quickly it updates!
