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
install -o root -g 0 -m 755 bluetooth_le_scanner.sh /usr/bin/
install -o root -g 0 -m 600 bluetooth_le_scanner.conf.sample /etc/bluetooth_le_scanner.conf
# edit /etc/bluetooth_le_scanner.conf
install -o root -g 0 -m 644 systemd/bluetooth_le_scanner.service /etc/systemd/system/
mkdir -p /var/db/bluetooth_le_scanner
systemctl enable bluetooth_le_scanner
service bluetooth_le_scanner start
```
