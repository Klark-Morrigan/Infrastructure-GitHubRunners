#!/usr/bin/env bash
#
# Stub curl for diagnose-vm-egress.bats:
# appends its arguments to CURL_LOG
# and xits with STUB_CURL_RAW_EXIT for the raw IP's URL,
# STUB_CURL_HOST_EXIT for any other.
#
# shellcheck disable=SC2154
# STUB_* variables and CURL_LOG come from the suite

printf '%s\n' "$*" >>"${CURL_LOG}"
case "$*" in
    *"https://${STUB_RAW_IP}"*) exit "${STUB_CURL_RAW_EXIT}" ;;
    *) exit "${STUB_CURL_HOST_EXIT}" ;;
esac
