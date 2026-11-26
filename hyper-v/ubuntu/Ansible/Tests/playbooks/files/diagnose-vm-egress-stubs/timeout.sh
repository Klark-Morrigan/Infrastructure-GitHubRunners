#!/usr/bin/env bash
#
# Stub timeout for diagnose-vm-egress.bats. The script runs two commands under
# timeout: bash for the TCP connect to the router's DNS port, and getent.
#   bash    answers as STUB_GATEWAY_TCP says: open, refused or silent.
#   getent  outlasts its timeout when STUB_RESOLVER_TIMES_OUT is 1, and runs
#           otherwise.
# 124 is what coreutils timeout exits with when the command outlasts it.
#
# shellcheck disable=SC2154
# STUB_* variables come from the suite

readonly TIMEOUT_EXIT_CODE=124

shift
case "${1##*/}" in
    bash)
        case "${STUB_GATEWAY_TCP}" in
            open)
                exit 0
                ;;
            refused)
                printf '%s\n' 'bash: line 1: /dev/tcp/10.10.0.1/53: Connection refused' >&2
                exit 1
                ;;
            *)
                exit "${TIMEOUT_EXIT_CODE}"
                ;;
        esac
        ;;
    *)
        if [[ "${STUB_RESOLVER_TIMES_OUT}" == 1 ]]; then
            exit "${TIMEOUT_EXIT_CODE}"
        fi
        exec "$@"
        ;;
esac
