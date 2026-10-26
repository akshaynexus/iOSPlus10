#!/bin/sh
# Public reference sources for the Goodix optical G7 ("Delmar") fingerprint stack, into out/fp/ref
# (git-ignored). Sparse, shallow clones; nothing is committed here.
#   scripts/bg.sh fp-refs scripts/fp/get-references.sh
#   out/fp/ref/oplus-secure/   techyminati/android_vendor_oplus_secure: the OPLUS fingerprint HAL source
#                              (goodix_optical/goodix_G7: gf_delmar_types.h = TA command ids and structs,
#                              DelmarSensor.cpp = capture flow, CaEntry = QSEE transport)
#   out/fp/ref/op-sm8475/      OnePlusOSS/android_kernel_oneplus_sm8475: drivers/input/oplus_fp_driver
#                              (goodix_optical_fp/gf_spi.c = the HLOS shim: ioctls, netlink, power)
#   out/fp/ref/goodix-fp-dump/ goodix-fp-linux-dev/goodix-fp-dump: the public Goodix MCU protocol
#                              (USB sensors 5110/5xxx: message pack 0xA0, command set, image readout)
set -eu
. "$(dirname "$0")/../lib/env.sh"
R=$OUT/fp/ref
mkdir -p "$R"
sparse() { # name url path...
  n=$1; u=$2; shift 2
  if [ ! -d "$R/$n/.git" ]; then
    git clone -q --depth 1 --filter=blob:none --sparse "$u" "$R/$n"
  fi
  git -C "$R/$n" sparse-checkout set "$@"
  echo "$n: $(git -C "$R/$n" rev-parse --short HEAD) $*"
}
sparse oplus-secure https://github.com/techyminati/android_vendor_oplus_secure \
  biometrics/fingerprints/bsp/vendor/fingerprint/goodix_optical/goodix_G7 \
  biometrics/fingerprints/bsp/vendor/fingerprint/goodix_optical/goodix_G6
sparse op-sm8475 https://github.com/OnePlusOSS/android_kernel_oneplus_sm8475 \
  drivers/input/oplus_fp_driver
[ -d "$R/goodix-fp-dump/.git" ] || git clone -q --depth 1 https://github.com/goodix-fp-linux-dev/goodix-fp-dump "$R/goodix-fp-dump"
echo "goodix-fp-dump: $(git -C "$R/goodix-fp-dump" rev-parse --short HEAD)"
echo done
