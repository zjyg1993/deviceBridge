#!/bin/zsh
set -eu
project_dir="${0:A:h}"
bundle_dir="${1:?Pass the staging application bundle}"
version=7.5
archive="smartmontools-${version}.tar.gz"
checksum=690b83ca331378da9ea0d9d61008c4b22dde391387b9bbad7f29387f2595f76e
cache="${project_dir}/release.noindex/smartmontools"
mkdir -p "${cache}"
work=$(mktemp -d "${cache}/build.XXXXXX")
trap 'rm -rf "${work}"' EXIT
archive_path="${cache}/${archive}"
if [[ -f "${project_dir}/${archive}" ]]; then
  archive_path="${project_dir}/${archive}"
elif [[ ! -f "${archive_path}" ]]; then
  curl --fail --location --silent --show-error --retry 2 --connect-timeout 15 \
    "https://github.com/smartmontools/smartmontools/releases/download/RELEASE_7_5/${archive}" \
    --output "${work}/${archive}"
  (cd "${work}" && printf '%s  %s\n' "${checksum}" "${archive}" | shasum -a 256 -c)
  mv "${work}/${archive}" "${archive_path}"
fi
(cd "${archive_path:h}" && printf '%s  %s\n' "${checksum}" "${archive}" | shasum -a 256 -c)
tar -xzf "${archive_path}" -C "${work}"
source_dir="${work}/smartmontools-${version}"
(
  cd "${source_dir}"
  export MACOSX_DEPLOYMENT_TARGET=13.0
  export CC=clang CXX=clang++
  export CFLAGS="-O2 -arch arm64 -arch x86_64"
  export CXXFLAGS="${CFLAGS}"
  ./configure --disable-dependency-tracking --without-libcap-ng --without-libsystemd --without-drivedbdir > "${work}/configure.log" 2>&1 || { cat "${work}/configure.log"; exit 1; }
  jobs=$(sysctl -n hw.activecpu 2>/dev/null || printf 4)
  make -j "${jobs}" smartctl > "${work}/make.log" 2>&1 || { cat "${work}/make.log"; exit 1; }
)
helpers="${bundle_dir}/Contents/Helpers"
resources="${bundle_dir}/Contents/Resources/Smartmontools"
mkdir -p "${helpers}" "${resources}"
cp "${source_dir}/smartctl" "${helpers}/smartctl"
for architecture in arm64 x86_64; do
  lipo "${helpers}/smartctl" -verify_arch "${architecture}"
done
# Include the exact upstream source and build recipe alongside the GPL executable.
cp "${source_dir}/COPYING" "${archive_path}" "${0:A}" "${resources}/"
codesign --force --sign "${DEVICEBRIDGE_SIGN_IDENTITY:--}" "${helpers}/smartctl"
"${helpers}/smartctl" --version
