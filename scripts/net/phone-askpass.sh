#!/bin/sh
# ssh's SSH_ASKPASS helper for scripts/net/ssh-phone.sh: the phone's password, only for a root without the repo key.
# The stock iOS root password (/private/etc/master.passwd of 20H392: /smx7MYTQIi2M = DES crypt of "alpine"). USB link only.
printf '%s\n' "${PHONE_PASSWORD:-alpine}"
