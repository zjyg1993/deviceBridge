#!/bin/zsh
set -eu
project_dir="${0:A:h}"
output_dir="${1:-${project_dir}/build.noindex}"
case "${output_dir}/" in
  *.noindex/*) ;;
  *) output_dir="${output_dir}.noindex" ;;
esac
mkdir -p "${output_dir}"
bundle_dir="${output_dir}/DeviceBridge.app"
# Recreate the staging bundle so removed features cannot leave stale resources.
rm -rf "${bundle_dir}"
mkdir -p "${bundle_dir}/Contents/MacOS" "${bundle_dir}/Contents/Resources"
clang -fobjc-arc -fblocks -O2 -Wall -Wextra -Wno-unused-parameter \
  -arch arm64 -arch x86_64 -mmacosx-version-min=13.0 \
  -framework Cocoa -framework IOKit -framework ServiceManagement -framework CoreAudio -framework ApplicationServices \
  "${project_dir}/Sources/NativeAudioSetup.m" "${project_dir}/Sources/NativeProxyAudio.m" "${project_dir}/Sources/main.m" "${project_dir}/Sources/Protocol.m" "${project_dir}/Sources/Policy.m" "${project_dir}/Sources/NativeBrightnessBridge.m" "${project_dir}/Sources/Display.m" "${project_dir}/Sources/DisplayDDC.m" \
  -o "${bundle_dir}/Contents/MacOS/DeviceBridge"
python3 - "${bundle_dir}/Contents/Info.plist" <<'PY'
import plistlib,sys
p={'CFBundleIdentifier':'local.batterybridge.agent','CFBundleName':'DeviceBridge','CFBundleDisplayName':'DeviceBridge','CFBundleExecutable':'DeviceBridge','CFBundlePackageType':'APPL','CFBundleShortVersionString':'0.9.9','CFBundleVersion':'49','LSMinimumSystemVersion':'13.0','LSUIElement':True,'CFBundleIconFile':'AppIcon','NSHighResolutionCapable':True,'NSHumanReadableCopyright':'DeviceBridge · local utility · preview'}
with open(sys.argv[1],'wb') as f:plistlib.dump(p,f)
PY
icon_work="${output_dir}/icon-work"
mkdir -p "${icon_work}/AppIcon.iconset"
clang -fobjc-arc -framework Cocoa "${project_dir}/Sources/Icon.m" -o "${icon_work}/draw-icon"
"${icon_work}/draw-icon" "${icon_work}"
for icon_size in 16 32 128 256 512; do
  cp "${icon_work}/size${icon_size}.png" "${icon_work}/AppIcon.iconset/icon_${icon_size}x${icon_size}.png"
  retina_size=$((icon_size*2))
  cp "${icon_work}/size${retina_size}.png" "${icon_work}/AppIcon.iconset/icon_${icon_size}x${icon_size}@2x.png"
done
python3 - "${icon_work}" "${bundle_dir}/Contents/Resources/AppIcon.icns" <<'PYICON'
import struct,sys,pathlib
src=pathlib.Path(sys.argv[1]); chunks=[]
for typ,size in [('ic07',128),('ic08',256),('ic09',512),('ic10',1024)]:
 data=(src/f'size{size}.png').read_bytes();chunks.append(typ.encode()+struct.pack('>I',len(data)+8)+data)
body=b''.join(chunks);pathlib.Path(sys.argv[2]).write_bytes(b'icns'+struct.pack('>I',len(body)+8)+body)
PYICON
# Build the upstream proxy driver; installation is a separate user action.
/bin/zsh "${project_dir}/experiments/native-bridge/build-proxy-driver.sh" "${output_dir}/proxy-payload/ProxyAudioDevice.driver"
clang -fobjc-arc -framework Foundation -framework CoreAudio "${project_dir}/tests/ProxyDriverLoadTests.m" -o "${output_dir}/proxy-driver-load-tests"
"${output_dir}/proxy-driver-load-tests" "${output_dir}/proxy-payload/ProxyAudioDevice.driver/Contents/MacOS/ProxyAudioDevice"
# A sealed archive prevents Finder from adding metadata inside the signed driver.
/usr/bin/ditto -c -k --norsrc --noextattr --keepParent "${output_dir}/proxy-payload/ProxyAudioDevice.driver" "${bundle_dir}/Contents/Resources/ProxyAudioDevice.zip"
cp "${project_dir}/experiments/native-bridge/install-proxy-driver.sh" "${bundle_dir}/Contents/Resources/"
cp "${project_dir}/experiments/native-bridge/prepare-proxy-driver.sh" "${bundle_dir}/Contents/Resources/"
clang -fobjc-arc -fblocks -framework Cocoa -framework CoreAudio -I "${project_dir}/Sources" "${project_dir}/Sources/NativeAudioSetup.m" "${project_dir}/Sources/NativeProxyAudio.m" "${project_dir}/tests/NativeAudioSetupTests.m" -o "${output_dir}/native-audio-setup-tests"
"${output_dir}/native-audio-setup-tests"
/bin/zsh "${project_dir}/tests/ProxyDriverPreparationTests.sh" "${output_dir}/proxy-payload/ProxyAudioDevice.driver" "${project_dir}/experiments/native-bridge/prepare-proxy-driver.sh"
# Build and validate the native-control experiments before bundling the helper.
/bin/zsh "${project_dir}/experiments/native-bridge/build.sh"
mkdir -p "${bundle_dir}/Contents/Helpers"
cp "${project_dir}/experiments/native-bridge/build.noindex/native-bridge" "${bundle_dir}/Contents/Helpers/native-bridge"
cp "${project_dir}/experiments/native-bridge/README.md" "${bundle_dir}/Contents/Resources/NativeBridge-README.md"
# Restricted HID entitlement needs an Apple-authorized provisioning profile.
# Never add it to an ad-hoc signature: macOS can terminate that executable.
signing_identity="${DEVICEBRIDGE_SIGN_IDENTITY:--}"
if [[ "${signing_identity}" == - ]]; then
  codesign --force --sign - --identifier local.batterybridge.agent "${bundle_dir}"
elif [[ -z "${DEVICEBRIDGE_PROVISIONING_PROFILE:-}" ]]; then
  codesign --force --sign "${signing_identity}" --identifier local.batterybridge.agent "${bundle_dir}"
else
  profile="${DEVICEBRIDGE_PROVISIONING_PROFILE}"
  security cms -D -i "${profile}" > "${output_dir}/signing-profile.plist"
  python3 "${project_dir}/experiments/native-bridge/prepare-signing.py" "${output_dir}/signing-profile.plist" "${output_dir}/native-brightness.entitlements"
  cp "${profile}" "${bundle_dir}/Contents/embedded.provisionprofile"
  codesign --force --sign "${signing_identity}" --entitlements "${output_dir}/native-brightness.entitlements" --identifier local.batterybridge.agent "${bundle_dir}"
fi
codesign --verify --strict --verbose=2 "${bundle_dir}"
clang -fobjc-arc -fblocks -O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer -I "${project_dir}/Sources" -framework Cocoa -framework CoreGraphics -framework IOKit "${project_dir}/Sources/NativeBrightnessBridge.m" "${project_dir}/Sources/DisplayDDC.m" "${project_dir}/tests/NativeBrightnessTests.m" -o "${output_dir}/native-brightness-tests"
"${output_dir}/native-brightness-tests"
clang -fobjc-arc -framework Foundation -I "${project_dir}/Sources" \
 "${project_dir}/Sources/Protocol.m" "${project_dir}/tests/ProtocolTests.m" -o "${output_dir}/protocol-tests"
"${output_dir}/protocol-tests"
printf '%s\n' "Built: ${bundle_dir}"

clang -fobjc-arc -framework Foundation -I "${project_dir}/Sources" "${project_dir}/Sources/Policy.m" "${project_dir}/tests/PolicyTests.m" -o "${output_dir}/policy-tests"
"${output_dir}/policy-tests"
clang -fobjc-arc -fblocks -Wno-unused-parameter -mmacosx-version-min=13.0 \
  -framework Cocoa -framework IOKit -framework ServiceManagement -framework CoreAudio -framework ApplicationServices \
  "${project_dir}/Sources/NativeAudioSetup.m" "${project_dir}/Sources/NativeProxyAudio.m" "${project_dir}/tests/InterfaceTests.m" "${project_dir}/Sources/Protocol.m" "${project_dir}/Sources/Policy.m" "${project_dir}/Sources/NativeBrightnessBridge.m" "${project_dir}/Sources/Display.m" "${project_dir}/Sources/DisplayDDC.m" \
  -o "${output_dir}/interface-tests"
"${output_dir}/interface-tests"

clang -fobjc-arc -framework Foundation -I "${project_dir}/Sources" \
  "${project_dir}/Sources/DisplayDDC.m" "${project_dir}/tests/DisplayTests.m" -o "${output_dir}/display-tests"
"${output_dir}/display-tests"
clang -fobjc-arc -fblocks -mmacosx-version-min=13.0 -framework Cocoa -framework IOKit -framework CoreAudio -framework ApplicationServices -I "${project_dir}/Sources" \
  "${project_dir}/Sources/NativeProxyAudio.m" "${project_dir}/Sources/NativeBrightnessBridge.m" "${project_dir}/Sources/Display.m" "${project_dir}/Sources/DisplayDDC.m" "${project_dir}/tests/DisplayControllerTests.m" -o "${output_dir}/display-controller-tests"
"${output_dir}/display-controller-tests"
