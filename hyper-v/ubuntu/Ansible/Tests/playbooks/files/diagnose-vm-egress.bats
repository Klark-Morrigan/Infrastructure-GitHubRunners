#!/usr/bin/env bats
#
# Tests for
# playbooks/files/diagnose-vm-egress.sh -
# the on-VM probe that names
# the first hop on the VM's path out that fails, and its remedy.
#
# Every probe command (ip, ping, getent, nslookup, curl) is a stub on PATH,
# each driven by its own STUB_* variable, so a case sets up one broken hop and
# reads the verdict line. The stubs name bash by absolute path rather than via
# env, so the missing-tool case can strip PATH down to the stub folder alone.
# Run with: bats Tests/playbooks/files/diagnose-vm-egress.bats

SCRIPT="$(cd "${BATS_TEST_DIRNAME}/../../../playbooks/files" && pwd)/diagnose-vm-egress.sh"

# shellcheck source=hyper-v/ubuntu/Ansible/Tests/ops/_bats-helpers.sh
source "${BATS_TEST_DIRNAME}/../../ops/_bats-helpers.sh"

# Writes one stub command whose body is the rest of the arguments.
_write_stub() {

    local name="$1"
    shift
    printf '#!%s\n%s\n' "${BASH_BIN}" "$*" >"${STUBS}/${name}"
    chmod +x "${STUBS}/${name}"
}

setup() {

    _bats_init_temp diagnoseVmEgress

    STUBS="${TEST_TMP}/stubs"
    mkdir -p "${STUBS}"
    export CURL_LOG="${TEST_TMP}/curl.log"
    : >"${CURL_LOG}"

    # Defaults describe a healthy path; each case breaks one hop.
    export STUB_DEFAULT_ROUTE='default via 10.10.0.1 dev eth0 proto static'
    export STUB_PING_EXIT=0
    export STUB_GETENT_EXIT=0
    export STUB_NSLOOKUP_MODE=answer
    export STUB_CURL_RAW_EXIT=0
    export STUB_CURL_HOST_EXIT=0

    _write_stub ip 'printf "%s\n" "${STUB_DEFAULT_ROUTE}"'
    _write_stub ping 'exit "${STUB_PING_EXIT}"'
    _write_stub getent 'exit "${STUB_GETENT_EXIT}"'
    _write_stub nslookup '
case "${STUB_NSLOOKUP_MODE}" in
    answer)  printf "Name:\tapi.github.com\nAddress: 140.82.121.6\n"; exit 0 ;;
    refused) printf ";; communications error to 10.10.0.1#53: connection refused\n"; exit 1 ;;
    timeout) printf ";; communications error to 10.10.0.1#53: timed out\n;; no servers could be reached\n"; exit 1 ;;
    nxdomain) printf "** server can'"'"'t find api.github.com: NXDOMAIN\n"; exit 1 ;;
esac'
    _write_stub curl '
printf "%s\n" "$*" >>"${CURL_LOG}"
case "$*" in
    *https://1.1.1.1*) exit "${STUB_CURL_RAW_EXIT}" ;;
    *)                 exit "${STUB_CURL_HOST_EXIT}" ;;
esac'

    export PATH="${STUBS}:${PATH}"
}

teardown() {
    _bats_cleanup_temp
}

@test "reports ok when the name resolves and HTTPS answers" {

    # ARRANGE
    expected='ok'

    # ACT
    run "${BASH_BIN}" "${SCRIPT}"

    # ASSERT
    [ "${status}" -eq 0 ]
    [ "${output}" = "${expected}" ]
}

@test "reports no-default-route when the VM has no default route" {

    # ARRANGE
    export STUB_DEFAULT_ROUTE=''
    expected="no-default-route: this VM has no default route; check its netplan gateway"

    # ACT
    run "${BASH_BIN}" "${SCRIPT}"

    # ASSERT
    [ "${status}" -eq 0 ]
    [ "${output}" = "${expected}" ]
}

@test "reports gateway-unreachable, naming the gateway, when it does not answer" {

    # ARRANGE
    export STUB_PING_EXIT=1
    expected="gateway-unreachable: router 10.10.0.1 does not answer; start the router VM or check this VM's switch"

    # ACT
    run "${BASH_BIN}" "${SCRIPT}"

    # ASSERT
    [ "${status}" -eq 0 ]
    [ "${output}" = "${expected}" ]
}

@test "reports vm-resolver-misconfigured when the router answers DNS but the VM's resolver fails" {

    # ARRANGE
    export STUB_GETENT_EXIT=2
    expected="vm-resolver-misconfigured: router 10.10.0.1 answers DNS but this VM's resolver does not; check its netplan nameservers"

    # ACT
    run "${BASH_BIN}" "${SCRIPT}"

    # ASSERT
    [ "${status}" -eq 0 ]
    [ "${output}" = "${expected}" ]
}

@test "reports router-dns-refused when the router refuses DNS" {

    # ARRANGE
    export STUB_GETENT_EXIT=2
    export STUB_NSLOOKUP_MODE=refused
    expected="router-dns-refused: router 10.10.0.1 refuses DNS; restart dnsmasq on the router VM"

    # ACT
    run "${BASH_BIN}" "${SCRIPT}"

    # ASSERT
    [ "${status}" -eq 0 ]
    [ "${output}" = "${expected}" ]
}

@test "reports router-uplink-down when DNS times out and a raw IP is unreachable" {

    # ARRANGE
    export STUB_GETENT_EXIT=2
    export STUB_NSLOOKUP_MODE=timeout
    export STUB_CURL_RAW_EXIT=28
    expected="router-uplink-down: router 10.10.0.1 has no way out; run Test-HostNetworkPreflight.ps1 -AutoRepair on the host"

    # ACT
    run "${BASH_BIN}" "${SCRIPT}"

    # ASSERT
    [ "${status}" -eq 0 ]
    [ "${output}" = "${expected}" ]
}

@test "reports router-upstream-dns-silent when DNS times out but a raw IP answers" {

    # ARRANGE
    export STUB_GETENT_EXIT=2
    export STUB_NSLOOKUP_MODE=timeout
    expected="router-upstream-dns-silent: router 10.10.0.1 forwards traffic but its upstream DNS is silent; run Test-HostNetworkPreflight.ps1 -AutoRepair on the host"

    # ACT
    run "${BASH_BIN}" "${SCRIPT}"

    # ASSERT
    [ "${status}" -eq 0 ]
    [ "${output}" = "${expected}" ]
}

@test "reports router-dns-error when the router answers DNS with an error" {

    # ARRANGE
    export STUB_GETENT_EXIT=2
    export STUB_NSLOOKUP_MODE=nxdomain
    expected="router-dns-error: router 10.10.0.1 answered DNS with an error: ** server can't find api.github.com: NXDOMAIN"

    # ACT
    run "${BASH_BIN}" "${SCRIPT}"

    # ASSERT
    [ "${status}" -eq 0 ]
    [ "${output}" = "${expected}" ]
}

@test "reports https-failed when the name resolves but HTTPS fails" {

    # ARRANGE
    export STUB_CURL_HOST_EXIT=35
    expected="https-failed: api.github.com resolves but HTTPS fails; check filtering past the router"

    # ACT
    run "${BASH_BIN}" "${SCRIPT}"

    # ASSERT
    [ "${status}" -eq 0 ]
    [ "${output}" = "${expected}" ]
}

@test "reports probe-tool-missing when a probe command is not installed" {

    # ARRANGE
    rm "${STUBS}/nslookup"
    expected="probe-tool-missing: nslookup is not installed on this VM"

    # ACT
    # PATH holds the stubs alone for this one command, so bats' own teardown
    # still finds rm.
    run "${BASH_BIN}" -c "PATH='${STUBS}' '${BASH_BIN}' '${SCRIPT}'"

    # ASSERT
    [ "${status}" -eq 0 ]
    [ "${output}" = "${expected}" ]
}

@test "probes the host and raw IP it is given" {

    # ARRANGE
    export STUB_CURL_HOST_EXIT=0
    expectedHostProbe='https://example.test'

    # ACT
    run "${BASH_BIN}" "${SCRIPT}" example.test 1.1.1.1

    # ASSERT
    [ "${status}" -eq 0 ]
    grep -qF -- "${expectedHostProbe}" "${CURL_LOG}"
}
