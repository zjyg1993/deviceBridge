#!/bin/bash
# Install a restricted, one-time authorized launchd service. This never accesses a drive.
set -euo pipefail
umask 022
root='/Library/Application Support/DeviceBridge'
target="$root/USBSmart"
plist='/Library/LaunchDaemons/local.batterybridge.usb-smart.plist'
label=local.batterybridge.usb-smart
socket=/var/run/devicebridge-usb-smart.sock
bundle="${1:-}"
owner="${2:-}"
[[ $EUID == 0 && "$bundle" == /Applications/DeviceBridge.app && "$owner" =~ ^[0-9]{3,10}$ && "$owner" -ge 501 ]]
/usr/bin/codesign --verify --deep --strict "$bundle"
[[ ! -L "$root" && ! -L "$target" && ! -L "$plist" ]]
/usr/bin/install -d -o root -g wheel -m 755 "$root"
[[ "$(/usr/bin/stat -f %u "$root")" == 0 ]]
stage=$(/usr/bin/mktemp -d "$root/.usb-smart.XXXXXX")
plist_stage=$(/usr/bin/mktemp /Library/LaunchDaemons/.DeviceBridge-smart.XXXXXX)
trap '/bin/rm -rf "$stage"; /bin/rm -f "$plist_stage"' EXIT
/bin/chmod 755 "$stage"
/usr/bin/install -d -o root -g wheel -m 755 "$stage/Helpers" "$stage/Frameworks"
for helper in devicebridge-usb-smart devicebridge-usb-smart-service; do
  /usr/bin/install -o root -g wheel -m 755 "$bundle/Contents/Helpers/$helper" "$stage/Helpers/$helper"
  /usr/bin/codesign --verify --strict "$stage/Helpers/$helper"
done
/usr/bin/install -o root -g wheel -m 755 "$bundle/Contents/Frameworks/libusb-1.0.0.dylib" "$stage/Frameworks/libusb-1.0.0.dylib"
/usr/bin/codesign --verify --strict "$stage/Frameworks/libusb-1.0.0.dylib"
/bin/cat > "$plist_stage" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key>
  <array><string>$target/Helpers/devicebridge-usb-smart-service</string><string>$owner</string></array>
  <key>Sockets</key>
  <dict><key>SMART</key><dict><key>SockPathName</key><string>$socket</string><key>SockPathOwner</key><integer>$owner</integer><key>SockPathMode</key><integer>384</integer></dict></dict>
</dict>
</plist>
PLIST
/usr/bin/plutil -lint "$plist_stage"
/usr/sbin/chown root:wheel "$plist_stage"
/bin/chmod 644 "$plist_stage"
if /bin/launchctl print "system/$label" >/dev/null 2>&1; then
  /bin/launchctl bootout "system/$label"
fi
if [[ -S "$socket" && ! -L "$socket" ]]; then /bin/rm -f "$socket"; fi
if [[ -d "$target" ]]; then
  /bin/mv "$target" "$stage/previous"
fi
/usr/bin/install -d -o root -g wheel -m 755 "$target"
/bin/mv "$stage/Helpers" "$stage/Frameworks" "$target/"
if [[ -f "$plist" ]]; then /bin/cp -p "$plist" "$stage/previous.plist"; fi
/bin/mv -f "$plist_stage" "$plist"
if ! /bin/launchctl bootstrap system "$plist"; then
  /bin/rm -rf "$target"
  /bin/rm -f "$plist"
  if [[ -d "$stage/previous" && -f "$stage/previous.plist" ]]; then
    /bin/mv "$stage/previous" "$target"
    /bin/mv "$stage/previous.plist" "$plist"
    /bin/launchctl bootstrap system "$plist" || true
  fi
  exit 1
fi
