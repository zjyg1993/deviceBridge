#!/bin/zsh
set -eu
root="${0:A:h}"
bundle="${1:?Pass the staging app}"
source_dir="${root}/Sources/ThirdParty/SSDScope"
cache="${root}/release.noindex/usb-smart-sources"
out="${bundle:h}/usb-smart"
mkdir -p "${cache}" "${out}"
verify_source() {
  local name="$1" expected="$2" url="$3"
  if [[ ! -f "${cache}/${name}" ]]; then
    local temporary
    temporary=$(mktemp "${cache}/download.XXXXXX")
    if ! curl -fLsS --retry 2 "${url}" -o "${temporary}" ||
       [[ $(shasum -a 256 "${temporary}" | cut -d ' ' -f 1) != "${expected}" ]]; then
      rm -f "${temporary}"
      return 1
    fi
    mv "${temporary}" "${cache}/${name}"
  fi
  (cd "${cache}" && printf '%s  %s\n' "${expected}" "${name}" | shasum -a 256 -c)
}
usb_archive=libusb-1.0.30.tar.bz2
smart_archive=smartmontools-7.5.tar.gz
verify_source "${usb_archive}" fea36f34f9156400209595e300840767ab1a385ede1dc7ee893015aea9c6dbaf https://github.com/libusb/libusb/releases/download/v1.0.30/libusb-1.0.30.tar.bz2
verify_source "${smart_archive}" 690b83ca331378da9ea0d9d61008c4b22dde391387b9bbad7f29387f2595f76e https://github.com/smartmontools/smartmontools/releases/download/RELEASE_7_5/smartmontools-7.5.tar.gz

work=$(mktemp -d "${out}/build.XXXXXX")
trap 'rm -rf "${work}"' EXIT
tar -xjf "${cache}/${usb_archive}" -C "${work}"
tar -xzf "${cache}/${smart_archive}" -C "${work}"
export MACOSX_DEPLOYMENT_TARGET=13.0
export CFLAGS="-O2 -arch arm64 -arch x86_64"
export CXXFLAGS="${CFLAGS}"
export CC=clang CXX=clang++
build_libusb() {
  cd "${work}/libusb-1.0.30"
  lt_cv_sys_max_cmd_len=32768 ac_cv_func_pipe2=no ./configure --enable-shared --disable-static --disable-dependency-tracking --prefix="${out}/libusb"
  make -j4
  make install
  install_name_tool -id '@rpath/libusb-1.0.0.dylib' "${out}/libusb/lib/libusb-1.0.0.dylib"
}
build_smartctl() {
  cd "${work}/smartmontools-7.5"
  ./configure --disable-dependency-tracking --without-libcap-ng --without-libsystemd --without-drivedbdir
  make -j4 smartctl
  cp smartctl "${work}/smartctl"
  strip "${work}/smartctl"
}
build_libusb > "${work}/usb.log" 2>&1 & usb_pid=$!
build_smartctl > "${work}/smart.log" 2>&1 & smart_pid=$!
wait "${usb_pid}" || { cat "${work}/usb.log"; wait "${smart_pid}" || true; exit 1; }
cat > "${work}/libusb.toml" <<CONFIG
[target.aarch64-apple-darwin."usb-1.0"]
rustc-link-search = ["${out}/libusb/lib"]
rustc-link-lib = ["dylib=usb-1.0"]
version_number = "1.0.30"
[target.x86_64-apple-darwin."usb-1.0"]
rustc-link-search = ["${out}/libusb/lib"]
rustc-link-lib = ["dylib=usb-1.0"]
version_number = "1.0.30"
CONFIG
export CARGO_TARGET_DIR="${out}/cargo"
export RUSTFLAGS='-C link-arg=-Wl,-rpath,@loader_path/../Frameworks'
wait "${smart_pid}" || { cat "${work}/smart.log"; exit 1; }
cargo --config "${work}/libusb.toml" build --manifest-path "${source_dir}/Cargo.toml" --locked --release --target aarch64-apple-darwin --target x86_64-apple-darwin

helpers="${bundle}/Contents/Helpers"
frameworks="${bundle}/Contents/Frameworks"
resources="${bundle}/Contents/Resources/USBSmartSources"
mkdir -p "${helpers}" "${frameworks}" "${resources}"
lipo -create "${CARGO_TARGET_DIR}"/{aarch64,x86_64}-apple-darwin/release/devicebridge-usb-smart -output "${helpers}/devicebridge-usb-smart"
cp "${work}/smartctl" "${helpers}/smartctl"
cp "${out}/libusb/lib/libusb-1.0.0.dylib" "${frameworks}/"
cp "${cache}/${usb_archive}" "${cache}/${smart_archive}" "${0:A}" "${resources}/"
cp "${source_dir}/"{LICENSE,UPSTREAM.md} "${resources}/"
cp "${work}/libusb-1.0.30/COPYING" "${resources}/LIBUSB-COPYING"
cp "${work}/smartmontools-7.5/COPYING" "${resources}/SMARTMONTOOLS-COPYING"
for binary in "${helpers}/devicebridge-usb-smart" "${helpers}/smartctl" "${frameworks}/libusb-1.0.0.dylib"; do
  lipo "${binary}" -verify_arch arm64
  lipo "${binary}" -verify_arch x86_64
  codesign --force --sign "${DEVICEBRIDGE_SIGN_IDENTITY:--}" "${binary}"
  codesign --verify --strict "${binary}"
done
"${helpers}/smartctl" --version > /dev/null
