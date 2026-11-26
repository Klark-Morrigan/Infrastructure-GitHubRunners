#!/usr/bin/env bash
#
# Names the first hop on this VM's path out to GitHub that fails, and its
# remedy, as one line: `<hop>: <remedy>`.
#
# Run on a runner VM by playbooks/tasks/_runner-status-egress.yml when its
# egress probe fails, so a walk that finds every hop answering reports the
# failure as transient. A bare "unreachable" left the operator to walk the
# path by hand, across this VM, the router VM and the Windows host; this walks
# it for them.
#
# The router VM is not in the playbook's inventory (workloads reach SSH
# through it), so its side is inferred from here. In this fleet a workload's
# default gateway is the router, which is also its DNS resolver and forwards
# DNS to the host's Internet Connection Sharing proxy. So:
#   - the router refusing DNS means dnsmasq is down on it;
#   - DNS timing out with a raw IP also unreachable means the router has no
#     uplink at all;
#   - DNS timing out while a raw IP answers means the router forwards packets
#     but its upstream DNS, the host's ICS proxy, is silent.
# A name that still resolves proves little on its own: the VM's resolver can
# answer from its cache after the router lost its uplink, so a failed HTTPS
# probe is checked against the raw IP too.
#
# Always exits 0: the verdict is the output, and a read-only status report
# must not fail because the network it reports on is down.
#
# The verdict is the only line on stdout. Each probe's exit code and last line
# of output go to stderr, one line per probe, so the evidence behind a verdict
# can be shown without cluttering it.
#
# Usage: diagnose-vm-egress.sh [host] [raw-ip]
#   host    name to resolve and reach over HTTPS (default: api.github.com)
#   raw-ip  public address probed without DNS (default: 1.1.1.1)

set -uo pipefail

readonly PROBE_HOST="${1:-api.github.com}"
readonly RAW_IP="${2:-1.1.1.1}"

# Short timeouts keep the status report quick when every hop is dead. DNS gets
# longer: the host's ICS proxy can be slow without being dead.
readonly PING_TIMEOUT_SECONDS=2
readonly TCP_TIMEOUT_SECONDS=2
readonly DNS_TIMEOUT_SECONDS=5
readonly HTTPS_TIMEOUT_SECONDS=5

# The port the router's dnsmasq listens on, probed when the router drops ping.
readonly ROUTER_DNS_PORT=53

# curl's exit code when it rejects the server's certificate.
readonly CURL_EXIT_CERT_REJECTED=60

readonly PREFLIGHT_REMEDY='run .\scripts\Test-HostNetworkPreflight.ps1 -AutoRepair from Infrastructure-Vm-Provisioner on the host'
readonly PROBE_TOOLS=(ip ping timeout getent nslookup curl)

# The combined output of the last probe run_logged_probe ran.
PROBE_OUTPUT=''

report() {

    printf '%s\n' "$1"
    exit 0
}

report_uplink_down() {

    local gateway="$1"
    report "router-uplink-down: router ${gateway} has no way out; ${PREFLIGHT_REMEDY}"
}

log_probe_result() {

    printf '%s\n' "$1" >&2
}

# Runs one probe command and logs its exit code and the last line it printed.
# The last line, not the first, because nslookup opens an answer with a Server
# header and puts the error last. Returns the probe's exit code and leaves its
# output in PROBE_OUTPUT.
run_logged_probe() {

    local label="$1"
    shift

    local exit_code=0
    local last_line

    PROBE_OUTPUT="$("$@" 2>&1)" || exit_code=$?
    last_line="${PROBE_OUTPUT##*$'\n'}"

    log_probe_result "${label}: exit ${exit_code}${last_line:+: ${last_line}}"
    return "${exit_code}"
}

find_missing_tool() {

    local tool
    for tool in "${PROBE_TOOLS[@]}"; do
        if ! command -v "${tool}" >/dev/null 2>&1; then
            printf '%s' "${tool}"
            return
        fi
    done
}

# The address after `via` on the default route, or nothing.
read_default_gateway() {

    local route
    route="$(ip route show default 2>/dev/null)"
    if [[ "${route}" =~ via[[:space:]]+([^[:space:]]+) ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
    fi
}

# Checks the certificate as the runner does, so a wrong clock or TLS
# interception shows up here instead of passing as a working path.
probe_https() {

    local url="$1"
    run_logged_probe "curl ${url}" curl -sS -o /dev/null -I --max-time "${HTTPS_TIMEOUT_SECONDS}" "${url}"
}

# A rejected certificate still proves the path: the handshake reached a server.
is_tls_reached() {

    local curl_exit_code="$1"

    [[ ${curl_exit_code} -eq 0 \
        || ${curl_exit_code} -eq ${CURL_EXIT_CERT_REJECTED} ]]
}

# Ping alone is not proof: a router may drop ICMP. The fallback connects to its
# DNS port. A connection that opens or is refused shows the router is up, since
# only a live host answers; silence or no route means it is not.
is_gateway_present() {

    local gateway="$1"
    if run_logged_probe "ping ${gateway}" ping -q -c 1 -W "${PING_TIMEOUT_SECONDS}" "${gateway}"; then
        return 0
    fi

    # shellcheck disable=SC2016 # $1 and $2 expand in the inner bash
    if run_logged_probe "tcp ${gateway}:${ROUTER_DNS_PORT}" \
        timeout "${TCP_TIMEOUT_SECONDS}" "${BASH}" -c ': </dev/tcp/$1/$2' _ "${gateway}" "${ROUTER_DNS_PORT}"; then
        return 0
    fi

    [[ "${PROBE_OUTPUT}" == *refused* ]]
}

# The VM resolves the name, so the fault lies past DNS.
diagnose_past_dns() {

    local gateway="$1"
    local host_exit_code=0
    local raw_exit_code=0

    probe_https "https://${PROBE_HOST}" \
        || host_exit_code=$?

    if [[ ${host_exit_code} -eq 0 ]]; then
        report 'transient: every hop answers now; the failed probe did not repeat'
    fi

    if [[ ${host_exit_code} -eq ${CURL_EXIT_CERT_REJECTED} ]]; then
        report "https-cert-rejected: ${PROBE_HOST} answers but its certificate is rejected; check this VM's clock and any TLS interception past the router"
    fi

    probe_https "https://${RAW_IP}" \
        || raw_exit_code=$?

    if ! is_tls_reached "${raw_exit_code}"; then
        report_uplink_down "${gateway}"
    fi

    report "https-failed: ${PROBE_HOST} resolves but HTTPS fails; check filtering past the router"
}

# The VM's resolver failed, so ask the router directly to tell its failure
# modes apart.
diagnose_router_dns() {

    local gateway="$1"
    local router_exit_code=0
    local router_answer
    local raw_exit_code=0

    # -retry=1, not 0: nslookup versions differ on whether it counts retries or
    # tries, and 0 could send no query at all.
    run_logged_probe "nslookup ${PROBE_HOST} via ${gateway}" \
            nslookup -timeout="${DNS_TIMEOUT_SECONDS}" -retry=1 "${PROBE_HOST}" "${gateway}" \
        || router_exit_code=$?

    router_answer="${PROBE_OUTPUT}"

    if [[ ${router_exit_code} -eq 0 ]]; then
        report "vm-resolver-misconfigured: router ${gateway} answers DNS but this VM's resolver does not; check systemd-resolved and this VM's netplan nameservers"
    fi

    if [[ "${router_answer}" == *refused* ]]; then
        report "router-dns-refused: router ${gateway} refuses DNS; restart dnsmasq on the router VM"
    fi

    if [[ "${router_answer}" == *'timed out'* \
            || "${router_answer}" == *'no servers could be reached'* ]]; then

        probe_https "https://${RAW_IP}" || \
            raw_exit_code=$?

        if is_tls_reached "${raw_exit_code}"; then
            report "router-upstream-dns-silent: router ${gateway} forwards traffic but its upstream DNS is silent; ${PREFLIGHT_REMEDY}"
        fi

        report_uplink_down "${gateway}"
    fi

    report "router-dns-error: router ${gateway} answered DNS with an error: ${router_answer##*$'\n'}"
}

main() {
    local missing_tool
    local gateway

    missing_tool="$(find_missing_tool)"
    if [[ -n "${missing_tool}" ]]; then
        report "probe-tool-missing: ${missing_tool} is not installed on this VM"
    fi

    gateway="$(read_default_gateway)"
    log_probe_result "gateway: ${gateway:-none}"

    if [[ -z "${gateway}" ]]; then
        report 'no-default-gateway: this VM has no default route through a gateway; check its netplan gateway'
    fi

    if ! is_gateway_present "${gateway}"; then
        report "gateway-unreachable: router ${gateway} does not answer; start the router VM or check this VM's switch"
    fi

    # getent has no timeout of its own, and a resolver with a dead upstream can
    # stall it far longer than every other probe here.
    if run_logged_probe "getent ${PROBE_HOST}" timeout "${DNS_TIMEOUT_SECONDS}" getent hosts "${PROBE_HOST}"; then
        diagnose_past_dns "${gateway}"
    fi
    diagnose_router_dns "${gateway}"
}

main
