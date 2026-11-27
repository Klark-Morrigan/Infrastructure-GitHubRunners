#!/usr/bin/env bash
#
# Stub ip for diagnose-vm-egress.bats:
# `ip route show default` prints
# STUB_DEFAULT_ROUTE, which the suite's setup() exports.
#
# shellcheck disable=SC2154
# STUB_* variables come from the suite

case "$1" in
    route)
        printf '%s\n' "${STUB_DEFAULT_ROUTE}"
        ;;
    *)
        ;;
esac
