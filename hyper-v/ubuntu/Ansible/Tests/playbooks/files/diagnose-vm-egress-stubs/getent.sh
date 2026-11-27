#!/usr/bin/env bash
#
# Stub getent for diagnose-vm-egress.bats:
# exits with STUB_GETENT_EXIT,
# and prints an address line as the real one does when it resolves.
#
# shellcheck disable=SC2154
# STUB_* variables come from the suite

if [[ "${STUB_GETENT_EXIT}" -eq 0 ]]; then
    printf '%s\n' '140.82.121.6    api.github.com'
fi
exit "${STUB_GETENT_EXIT}"
