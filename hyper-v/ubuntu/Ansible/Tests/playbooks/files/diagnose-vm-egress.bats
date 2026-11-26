#!/usr/bin/env bats
#
# Tests for
# playbooks/files/diagnose-vm-egress.sh -
# the on-VM probe that names
# the first hop on the VM's path out that fails, and its remedy.
#
# Every probe command (ip, ping, timeout, getent, nslookup, curl) is a stub on PATH,
# each driven by its own STUB_* variable, so a case sets up one broken hop and
# reads the verdict line. The stubs live in diagnose-vm-egress-stubs/ as
# <command>.sh; setup() installs each under its command name with its shebang
# swapped for bash's absolute path, so the missing-tool case can strip PATH
# down to the stub folder alone.
# Every case runs with --separate-stderr: the verdict is stdout alone, and the
# probe log on stderr is asserted on its own.
# Run with: bats Tests/playbooks/files/diagnose-vm-egress.bats

# run --separate-stderr arrived in 1.5.0.
bats_require_minimum_version 1.5.0

SCRIPT="$(cd "${BATS_TEST_DIRNAME}/../../../playbooks/files" && pwd)/diagnose-vm-egress.sh"
STUB_SOURCES="${BATS_TEST_DIRNAME}/diagnose-vm-egress-stubs"
PROBE_COMMANDS=(ip ping timeout getent nslookup curl)

# shellcheck source=hyper-v/ubuntu/Ansible/Tests/_bats-helpers.sh
source "${BATS_TEST_DIRNAME}/../../_bats-helpers.sh"

# Installs one stub as an executable named after its command.
_install_stub() {

    local name="$1"
    {
        printf '#!%s\n' "${BASH_BIN}"
        tail -n +2 "${STUB_SOURCES}/${name}.sh"
    } >"${STUBS}/${name}"
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
    export STUB_GATEWAY_TCP=open
    export STUB_RESOLVER_TIMES_OUT=0
    export STUB_GETENT_EXIT=0
    export STUB_NSLOOKUP_MODE=answer
    export STUB_RAW_IP=1.1.1.1
    export STUB_CURL_RAW_EXIT=0
    export STUB_CURL_HOST_EXIT=0

    local command
    for command in "${PROBE_COMMANDS[@]}"; do
        _install_stub "${command}"
    done

    export PATH="${STUBS}:${PATH}"
}

teardown() {
    _bats_cleanup_temp
}

# The script only runs after a failed probe, so a clean walk means that
# failure did not repeat.
@test "reports transient when the name resolves and HTTPS answers" {

    # ARRANGE
    expected='transient: every hop answers now; the failed probe did not repeat'

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

@test "reports gateway-unreachable, naming the gateway, when it answers neither ping nor its DNS port" {

    # ARRANGE
    export STUB_PING_EXIT=1
    export STUB_GATEWAY_TCP=silent
    expected="gateway-unreachable: router 10.10.0.1 does not answer; start the router VM or check this VM's switch"

    # ACT
    run --separate-stderr "${BASH_BIN}" "${SCRIPT}"

    # ASSERT
    [ "${status}" -eq 0 ]
    [ "${output}" = "${expected}" ]
}

# A router that drops ICMP is still there: only a live host refuses a connection.
@test "carries on past a gateway that drops ping but refuses its DNS port" {

    # ARRANGE
    export STUB_PING_EXIT=1
    export STUB_GATEWAY_TCP=refused
    expected='transient: every hop answers now; the failed probe did not repeat'

    # ACT
    run --separate-stderr "${BASH_BIN}" "${SCRIPT}"

    # ASSERT
    [ "${status}" -eq 0 ]
    [ "${output}" = "${expected}" ]
}

@test "carries on past a gateway that drops ping but accepts on its DNS port" {

    # ARRANGE
    export STUB_PING_EXIT=1
    expected='transient: every hop answers now; the failed probe did not repeat'

    # ACT
    run --separate-stderr "${BASH_BIN}" "${SCRIPT}"

    # ASSERT
    [ "${status}" -eq 0 ]
    [ "${output}" = "${expected}" ]
}

# A lookup on a stalled resolver must not hold the report up.
@test "treats a resolver lookup that outlasts its timeout as failed" {

    # ARRANGE
    export STUB_RESOLVER_TIMES_OUT=1
    expected="vm-resolver-misconfigured: router 10.10.0.1 answers DNS but this VM's resolver does not; check systemd-resolved and this VM's netplan nameservers"

    # ACT
    run --separate-stderr "${BASH_BIN}" "${SCRIPT}"

    # ASSERT
    [ "${status}" -eq 0 ]
    [ "${output}" = "${expected}" ]
}

@test "reports vm-resolver-misconfigured when the router answers DNS but the VM's resolver fails" {

    # ARRANGE
    export STUB_GETENT_EXIT=2
    expected="vm-resolver-misconfigured: router 10.10.0.1 answers DNS but this VM's resolver does not; check systemd-resolved and this VM's netplan nameservers"

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
    expected="router-uplink-down: router 10.10.0.1 has no way out; run .\scripts\Test-HostNetworkPreflight.ps1 -AutoRepair from Infrastructure-Vm-Provisioner on the host"

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
    expected="router-upstream-dns-silent: router 10.10.0.1 forwards traffic but its upstream DNS is silent; run .\scripts\Test-HostNetworkPreflight.ps1 -AutoRepair from Infrastructure-Vm-Provisioner on the host"

    # ACT
    run --separate-stderr "${BASH_BIN}" "${SCRIPT}"

    # ASSERT
    [ "${status}" -eq 0 ]
    [ "${output}" = "${expected}" ]
}

# A certificate rejection still proves the path: the handshake reached a server.
@test "reports router-upstream-dns-silent when DNS times out and a raw IP rejects its certificate" {

    # ARRANGE
    export STUB_GETENT_EXIT=2
    export STUB_NSLOOKUP_MODE=timeout
    export STUB_CURL_RAW_EXIT=60
    expected="router-upstream-dns-silent: router 10.10.0.1 forwards traffic but its upstream DNS is silent; run .\scripts\Test-HostNetworkPreflight.ps1 -AutoRepair from Infrastructure-Vm-Provisioner on the host"

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
    expected="router-upstream-dns-silent: router 10.10.0.1 forwards traffic but its upstream DNS is silent; run .\scripts\Test-HostNetworkPreflight.ps1 -AutoRepair from Infrastructure-Vm-Provisioner on the host"

    # ACT
    run --separate-stderr "${BASH_BIN}" "${SCRIPT}"

    # ASSERT
    [ "${status}" -eq 0 ]
    [ "${output}" = "${expected}" ]
}

# The answer opens with nslookup's Server header, so the error is its last line.
@test "reports router-dns-error with the last line of the router's answer" {

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

@test "reports https-failed when HTTPS fails and a raw IP rejects its certificate" {

    # ARRANGE
    export STUB_CURL_HOST_EXIT=28
    export STUB_CURL_RAW_EXIT=60
    expected="https-failed: api.github.com resolves but HTTPS fails; check filtering past the router"

    # ACT
    run --separate-stderr "${BASH_BIN}" "${SCRIPT}"

    # ASSERT
    [ "${status}" -eq 0 ]
    [ "${output}" = "${expected}" ]
}

# A wrong clock or TLS interception fails the runner's own connections too.
@test "reports https-cert-rejected when the name resolves but its certificate is rejected" {

    # ARRANGE
    export STUB_CURL_HOST_EXIT=60
    expected="https-cert-rejected: api.github.com answers but its certificate is rejected; check this VM's clock and any TLS interception past the router"

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
    expected="router-uplink-down: router 10.10.0.1 has no way out; run .\scripts\Test-HostNetworkPreflight.ps1 -AutoRepair from Infrastructure-Vm-Provisioner on the host"

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

# The probe checks certificates as the runner does: no -k.
@test "probes the host it is given over HTTPS, checking its certificate" {

    # ARRANGE
    expectedCurlCalls='-sS -o /dev/null -I --max-time 5 https://example.test'

    # ACT
    run --separate-stderr "${BASH_BIN}" "${SCRIPT}" example.test 9.9.9.9

    # ASSERT
    [ "${status}" -eq 0 ]
    [ "$(cat "${CURL_LOG}")" = "${expectedCurlCalls}" ]
}

@test "probes the raw IP it is given" {

    # ARRANGE
    export STUB_GETENT_EXIT=2
    export STUB_NSLOOKUP_MODE=timeout
    export STUB_RAW_IP=9.9.9.9
    expectedCurlCalls='-sS -o /dev/null -I --max-time 5 https://9.9.9.9'

    # ACT
    run --separate-stderr "${BASH_BIN}" "${SCRIPT}" example.test 9.9.9.9

    # ASSERT
    [ "${status}" -eq 0 ]
    [ "$(cat "${CURL_LOG}")" = "${expectedCurlCalls}" ]
}

@test "logs each probe it runs to stderr on a healthy path" {

    # ARRANGE
    expectedLog='gateway: 10.10.0.1
ping 10.10.0.1: exit 0
getent api.github.com: exit 0: 140.82.121.6    api.github.com
curl https://api.github.com: exit 0'

    # ACT
    run --separate-stderr "${BASH_BIN}" "${SCRIPT}"

    # ASSERT
    [ "${status}" -eq 0 ]
    [ "${stderr}" = "${expectedLog}" ]
}

@test "logs the DNS-port connect, the router's DNS answer and the raw-IP probe when DNS times out" {

    # ARRANGE
    export STUB_PING_EXIT=1
    export STUB_GATEWAY_TCP=refused
    export STUB_GETENT_EXIT=2
    export STUB_NSLOOKUP_MODE=timeout
    export STUB_CURL_RAW_EXIT=28
    expectedLog='gateway: 10.10.0.1
ping 10.10.0.1: exit 1
tcp 10.10.0.1:53: exit 1: bash: line 1: /dev/tcp/10.10.0.1/53: Connection refused
getent api.github.com: exit 2
nslookup api.github.com via 10.10.0.1: exit 1: ;; no servers could be reached
curl https://1.1.1.1: exit 28'

    # ACT
    run --separate-stderr "${BASH_BIN}" "${SCRIPT}"

    # ASSERT
    [ "${status}" -eq 0 ]
    [ "${stderr}" = "${expectedLog}" ]
}

@test "logs a silent DNS port as a timeout" {

    # ARRANGE
    export STUB_PING_EXIT=1
    export STUB_GATEWAY_TCP=silent
    expectedLog='gateway: 10.10.0.1
ping 10.10.0.1: exit 1
tcp 10.10.0.1:53: exit 124'

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
