#!/bin/zsh
# Packages an already tested bundle without rebuilding or changing its signature.
set -eu
project_dir="${0:A:h}"
bundle_dir="${1:?Pass the tested DeviceBridge.app path}"
output_dir="${2:-${project_dir}/release}"
bundle_dir="${bundle_dir:A}"
mkdir -p "${output_dir}" "${project_dir}/release.noindex"
output_dir="${output_dir:A}"
codesign --verify --strict --verbose=2 "${bundle_dir}"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${bundle_dir}/Contents/Info.plist")
runtime_version=$("${bundle_dir}/Contents/MacOS/DeviceBridge" --version)
case "${runtime_version}" in
    "${version}") volume_name="DeviceBridge ${version}" ;;
    "${version}-preview") volume_name="DeviceBridge ${version} Preview" ;;
    *) print -u2 'Bundle and executable versions differ'; exit 1 ;;
esac
image_path="${output_dir}/DeviceBridge-${runtime_version}.dmg"
[[ ! -e "${image_path}" ]] || { print -u2 'Release already exists'; exit 1; }
release_dir=$(mktemp -d "${project_dir}/release.noindex/package.XXXXXX")
trap 'rm -rf "${release_dir}"' EXIT
volume_dir="${release_dir}/volume"
mkdir -p "${volume_dir}"
ditto "${bundle_dir}" "${volume_dir}/DeviceBridge.app"
codesign --verify --strict "${volume_dir}/DeviceBridge.app"
cmp "${bundle_dir}/Contents/MacOS/DeviceBridge" "${volume_dir}/DeviceBridge.app/Contents/MacOS/DeviceBridge"
ln -s /Applications "${volume_dir}/Applications"
# Keep the disk image to three entries; resolve documentation assets online.
python3 - "${project_dir}" "${volume_dir}" <<'PYREADME'
from pathlib import Path
import re, sys
root, volume = map(Path, sys.argv[1:])
readme = (root / 'README.md').read_text()
base = 'https://github.com/zjyg1993/devicebridge/blob/main/'
raw = 'https://raw.githubusercontent.com/zjyg1993/devicebridge/main/'
readme = re.sub(r'(src=[\x27\x22])\./([^\x27\x22]+)',
                lambda m: m[1] + raw + m[2], readme)
readme = re.sub(r'\]\((docs/[^)]+)\)', lambda m: '](' + base + m[1] + ')', readme)
(volume / 'README.md').write_text(readme)
expected = {'DeviceBridge.app', 'Applications', 'README.md'}
if {p.name for p in volume.iterdir()} != expected:
    raise SystemExit('Unexpected disk image contents')
PYREADME
hdiutil create -srcfolder "${volume_dir}" -fs HFS+ -volname "${volume_name}" -format UDZO "${release_dir}/DeviceBridge.dmg"
hdiutil verify "${release_dir}/DeviceBridge.dmg"
mv "${release_dir}/DeviceBridge.dmg" "${image_path}"
if [[ "${bundle_dir}" == "${project_dir}/build.noindex/DeviceBridge.app" ]]; then rm -rf "${bundle_dir}"; fi
printf '%s\n' "Verified release: ${image_path}"
