#!/usr/bin/env bats
#
# Tests for
# playbooks/files/diagnose-vm-egress.sh -
# the on-VM probe that names
# the first hop on the VM's path out that fails, and its remedy.
#
# Every probe command (ip, ping, timeout, getent, nslookup, curl) is a stub on PATH,
# each driven by its own STUB_* variable, so a case sets up one broken hop and
# reads the verdict line. The stubs name bash by absolute path rather than via
# env, so the missing-tool case can strip PATH down to the stub folder alone.
# Every case runs with --separate-stderr: the verdict is stdout alone, and the
# probe log on stderr is asserted on its own.
# Run with: bats Tests/playbooks/files/diagnose-vm-egress.bats

# run --separate-stderr arrived in 1.5.0.
bats_require_minimum_version 1.5.0

SCRIPT="$(cd "${BATS_TEST_DIRNAME}/../../../playbooks/files" && pwd)/diagnose-vm-egress.sh"

# shellcheck source=hyper-v/ubuntu/Ansible/Tests/_bats-helpers.sh
source "${BATS_TEST_DIRNAME}/../../_bats-helpers.sh"

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
    export STUB_NEIGH='10.10.0.1 dev eth0 lladdr 00:15:5d:00:00:01 REACHABLE'
    export STUB_PING_EXIT=0
    export STUB_TIMEOUT_EXPIRES=0
    export STUB_GETENT_EXIT=0
    export STUB_NSLOOKUP_MODE=answer
    export STUB_RAW_IP=1.1.1.1
    export STUB_CURL_RAW_EXIT=0
    export STUB_CURL_HOST_EXIT=0

    _write_stub ip '
case "$1" in
    route) printf "%s\n" "${STUB_DEFAULT_ROUTE}" ;;
    neigh) printf "%s\n" "${STUB_NEIGH}" ;;
esac'
    _write_stub ping 'exit "${STUB_PING_EXIT}"'
    # 124 is what coreutils timeout exits with when the command outlasts it.
    _write_stub timeout '
if [[ "${STUB_TIMEOUT_EXPIRES}" == 1 ]]; then
    exit 124
fi
shift
exec "$@"'
    _write_stub getent 'exit "${STUB_GETENT_EXIT}"'
    _write_stub nslookup '
case "${STUB_NSLOOKUP_MODE}" in
    answer)  printf "Name:\tapi.github.com\nAddress: 140.82.121.6\n"; exit 0 ;;
    refused) printf ";; communications error to 10.10.0.1#53: connection refused\n"; exit 1 ;;
    timeout) printf ";; communications error to 10.10.0.1#53: timed out\n;; no servers could be reached\n"; exit 1 ;;
    noservers) printf ";; no servers could be reached\n"; exit 1 ;;
    nxdomain) printf "** server can'"'"'t find api.github.com: NXDOMAIN\n"; exit 1 ;;
esac'
    _write_stub curl '
printf "%s\n" "$*" >>"${CURL_LOG}"
case "$*" in
    *"https://${STUB_RAW_IP}"*) exit "${STUB_CURL_RAW_EXIT}" ;;
    *)                          exit "${STUB_CURL_HOST_EXIT}" ;;
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
    run --separate-stderr "${BASH_BIN}" "${SCRIPT}"

    # ASSERT
    [ "${status}" -eq 0 ]
    [ "${output}" = "${expected}" ]
}

@test "reports no-default-gateway when the VM has no default route" {

    # ARRANGE
    export STUB_DEFAULT_ROUTE=''
    expected="no-default-gateway: this VM has no default route through a gateway; check its netplan gateway"

    # ACT
    run --separate-stderr "${BASH_BIN}" "${SCRIPT}"

    # ASSERT
    [ "${status}" -eq 0 ]
    [ "${output}" = "${expected}" ]
}

@test "reports no-default-gateway when the default route names no gateway" {

    # ARRANGE
    export STUB_DEFAULT_ROUTE='default dev ppp0 scope link'
    expected="no-default-gateway: this VM has no default route through a gateway; check its netplan gateway"

    # ACT
    run --separate-stderr "${BASH_BIN}" "${SCRIPT}"

    # ASSERT
    [ "${status}" -eq 0 ]
    [ "${output}" = "${expected}" ]
}

@test "reports gateway-unreachable, naming the gateway, when it answers neither ping nor ARP" {

    # ARRANGE
    export STUB_PING_EXIT=1
    export STUB_NEIGH='10.10.0.1 dev eth0 FAILED'
    expected="gateway-unreachable: router 10.10.0.1 does not answer; start the router VM or check this VM's switch"

    # ACT
    run --separate-stderr "${BASH_BIN}" "${SCRIPT}"

    # ASSERT
    [ "${status}" -eq 0 ]
    [ "${output}" = "${expected}" ]
}

# A router that drops ICMP is still there: ARP proves it.
@test "carries on past a gateway that drops ping but answers ARP" {

    # ARRANGE
    export STUB_PING_EXIT=1
    expected='ok'

    # ACT
    run --separate-stderr "${BASH_BIN}" "${SCRIPT}"

    # ASSERT
    [ "${status}" -eq 0 ]
    [ "${output}" = "${expected}" ]
}

# A lookup on a stalled resolver must not hold the report up.
@test "treats a resolver lookup that outlasts its timeout as failed" {

    # ARRANGE
    export STUB_TIMEOUT_EXPIRES=1
    expected="vm-resolver-misconfigured: router 10.10.0.1 answers DNS but this VM's resolver does not; check its netplan nameservers"

    # ACT
    run --separate-stderr "${BASH_BIN}" "${SCRIPT}"

    # ASSERT
    [ "${status}" -eq 0 ]
    [ "${output}" = "${expected}" ]
}

@test "reports vm-resolver-misconfigured when the router answers DNS but the VM's resolver fails" {

    # ARRANGE
    export STUB_GETENT_EXIT=2
    expected="vm-resolver-misconfigured: router 10.10.0.1 answers DNS but this VM's resolver does not; check its netplan nameservers"

    # ACT
    run --separate-stderr "${BASH_BIN}" "${SCRIPT}"

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
    run --separate-stderr "${BASH_BIN}" "${SCRIPT}"

    # ASSERT
    [ "${status}" -eq 0 ]
    [ "${output}" = "${expected}" ]
}

@test "reports router-uplink-down when DNS times out and a raw IP is unreachable" {

    # ARRANGE
    export STUB_GETENT_EXIT=2
    export STUB_NSLOOKUP_MODE=timeout
    export STUB_CURL_RAW_EXIT=28
    expected="router-uplink-down: router 10.10.0.1 has no way out; run scripts\Test-HostNetworkPreflight.ps1 -AutoRepair from Infrastructure-Vm-Provisioner on the host"

    # ACT
    run --separate-stderr "${BASH_BIN}" "${SCRIPT}"

    # ASSERT
    [ "${status}" -eq 0 ]
    [ "${output}" = "${expected}" ]
}

@test "reports router-upstream-dns-silent when DNS times out but a raw IP answers" {

    # ARRANGE
    export STUB_GETENT_EXIT=2
    export STUB_NSLOOKUP_MODE=timeout
    expected="router-upstream-dns-silent: router 10.10.0.1 forwards traffic but its upstream DNS is silent; run scripts\Test-HostNetworkPreflight.ps1 -AutoRepair from Infrastructure-Vm-Provisioner on the host"

    # ACT
    run --separate-stderr "${BASH_BIN}" "${SCRIPT}"

    # ASSERT
    [ "${status}" -eq 0 ]
    [ "${output}" = "${expected}" ]
}

# nslookup can report an unanswered query this way alone, without "timed out".
@test "reads no servers could be reached as a DNS timeout" {

    # ARRANGE
    export STUB_GETENT_EXIT=2
    export STUB_NSLOOKUP_MODE=noservers
    expected="router-upstream-dns-silent: router 10.10.0.1 forwards traffic but its upstream DNS is silent; run scripts\Test-HostNetworkPreflight.ps1 -AutoRepair from Infrastructure-Vm-Provisioner on the host"

    # ACT
    run --separate-stderr "${BASH_BIN}" "${SCRIPT}"

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
    run --separate-stderr "${BASH_BIN}" "${SCRIPT}"

    # ASSERT
    [ "${status}" -eq 0 ]
    [ "${output}" = "${expected}" ]
}

@test "reports https-failed when the name resolves and a raw IP answers but HTTPS fails" {

    # ARRANGE
    export STUB_CURL_HOST_EXIT=35
    expected="https-failed: api.github.com resolves but HTTPS fails; check filtering past the router"

    # ACT
    run --separate-stderr "${BASH_BIN}" "${SCRIPT}"

    # ASSERT
    [ "${status}" -eq 0 ]
    [ "${output}" = "${expected}" ]
}

# The VM's resolver can answer from its cache after the router lost its uplink.
@test "reports router-uplink-down when the name resolves but HTTPS and a raw IP both fail" {

    # ARRANGE
    export STUB_CURL_HOST_EXIT=28
    export STUB_CURL_RAW_EXIT=28
    expected="router-uplink-down: router 10.10.0.1 has no way out; run scripts\Test-HostNetworkPreflight.ps1 -AutoRepair from Infrastructure-Vm-Provisioner on the host"

    # ACT
    run --separate-stderr "${BASH_BIN}" "${SCRIPT}"

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
    run --separate-stderr "${BASH_BIN}" -c "PATH='${STUBS}' '${BASH_BIN}' '${SCRIPT}'"

    # ASSERT
    [ "${status}" -eq 0 ]
    [ "${output}" = "${expected}" ]
}

@test "probes the host it is given over HTTPS" {

    # ARRANGE
    expectedProbe='https://example.test'

    # ACT
    run --separate-stderr "${BASH_BIN}" "${SCRIPT}" example.test 9.9.9.9

    # ASSERT
    [ "${status}" -eq 0 ]
    grep -qF -- "${expectedProbe}" "${CURL_LOG}"
}

@test "probes the raw IP it is given" {

    # ARRANGE
    export STUB_GETENT_EXIT=2
    export STUB_NSLOOKUP_MODE=timeout
    export STUB_RAW_IP=9.9.9.9
    expectedProbe='https://9.9.9.9'

    # ACT
    run --separate-stderr "${BASH_BIN}" "${SCRIPT}" example.test 9.9.9.9

    # ASSERT
    [ "${status}" -eq 0 ]
    grep -qF -- "${expectedProbe}" "${CURL_LOG}"
}

@test "logs each probe it runs to stderr on a healthy path" {

    # ARRANGE
    expectedLog='gateway: 10.10.0.1
ping 10.10.0.1: exit 0
getent api.github.com: exit 0
curl https://api.github.com: exit 0'

    # ACT
    run --separate-stderr "${BASH_BIN}" "${SCRIPT}"

    # ASSERT
    [ "${status}" -eq 0 ]
    [ "${stderr}" = "${expectedLog}" ]
}

@test "logs the ARP entry, the router's DNS answer and the raw-IP probe when DNS times out" {

    # ARRANGE
    export STUB_PING_EXIT=1
    export STUB_GETENT_EXIT=2
    export STUB_NSLOOKUP_MODE=timeout
    export STUB_CURL_RAW_EXIT=28
    expectedLog='gateway: 10.10.0.1
ping 10.10.0.1: exit 1
arp 10.10.0.1: 10.10.0.1 dev eth0 lladdr 00:15:5d:00:00:01 REACHABLE
getent api.github.com: exit 2
nslookup api.github.com via 10.10.0.1: exit 1: ;; communications error to 10.10.0.1#53: timed out
curl https://1.1.1.1: exit 28'

    # ACT
    run --separate-stderr "${BASH_BIN}" "${SCRIPT}"

    # ASSERT
    [ "${status}" -eq 0 ]
    [ "${stderr}" = "${expectedLog}" ]
}

@test "logs a gateway with no ARP entry as none" {

    # ARRANGE
    export STUB_PING_EXIT=1
    export STUB_NEIGH=''
    expectedLog='gateway: 10.10.0.1
ping 10.10.0.1: exit 1
arp 10.10.0.1: none'

    # ACT
    run --separate-stderr "${BASH_BIN}" "${SCRIPT}"

    # ASSERT
    [ "${status}" -eq 0 ]
    [ "${stderr}" = "${expectedLog}" ]
}

@test "logs no gateway as none" {

    # ARRANGE
    export STUB_DEFAULT_ROUTE=''
    expectedLog='gateway: none'

    # ACT
    run --separate-stderr "${BASH_BIN}" "${SCRIPT}"

    # ASSERT
    [ "${status}" -eq 0 ]
    [ "${stderr}" = "${expectedLog}" ]
}
