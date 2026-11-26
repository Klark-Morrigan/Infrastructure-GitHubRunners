#!/usr/bin/env bash
#
# Stub nslookup for diagnose-vm-egress.bats:
# prints what BIND's nslookup prints
# for the case STUB_NSLOOKUP_MODE names, and exits as it does. An answered
# query, even a failed one, opens with the Server and Address header lines.
#
# shellcheck disable=SC2154
# STUB_* variables come from the suite

readonly SERVER_HEADER=$'Server:\t\t10.10.0.1\nAddress:\t10.10.0.1#53\n'

case "${STUB_NSLOOKUP_MODE}" in
    answer)
        printf '%s\n%s\n%s\n' "${SERVER_HEADER}" 'Name:	api.github.com' 'Address: 140.82.121.6'
        exit 0
        ;;
    refused)
        printf '%s\n' ';; communications error to 10.10.0.1#53: connection refused' \
            ';; no servers could be reached'
        exit 1
        ;;
    timeout)
        printf '%s\n' ';; communications error to 10.10.0.1#53: timed out' \
            ';; no servers could be reached'
        exit 1
        ;;
    noservers)
        printf '%s\n' ';; no servers could be reached'
        exit 1
        ;;
    nxdomain)
        printf '%s\n%s\n' "${SERVER_HEADER}" "** server can't find api.github.com: NXDOMAIN"
        exit 1
        ;;
    *)
        exit 1
        ;;
esac
