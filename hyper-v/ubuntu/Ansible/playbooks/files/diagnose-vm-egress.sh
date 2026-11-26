#!/usr/bin/env bash
#
# Names the first hop on this VM's path out to GitHub that fails, and its
# remedy, as one line: `<hop>: <remedy>`, or `ok` when the path works.
#
# Run on a runner VM by playbooks/runner-status.yml when its egress probe
# fails. A bare "unreachable" left the operator to walk the path by hand,
# across this VM, the router VM and the Windows host; this walks it for them.
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
# Each probe's raw result goes to stderr, one line per probe, so the evidence
# behind a verdict can be shown without cluttering the verdict line.
#
# Usage: diagnose-vm-egress.sh [host] [raw-ip]
#   host    name to resolve and reach over HTTPS (default: api.github.com)
#   raw-ip  public address probed without DNS (default: 1.1.1.1)

set -uo pipefail

readonly PROBE_HOST="${1:-api.github.com}"
readonly RAW_IP="${2:-1.1.1.1}"

# Short timeouts keep the status report quick when every hop is dead.
readonly PING_TIMEOUT_SECONDS=2
readonly DNS_TIMEOUT_SECONDS=2
readonly HTTPS_TIMEOUT_SECONDS=5

# Forward slashes, which PowerShell accepts: Ansible's default callback
# JSON-encodes the report, which would print a backslash doubled.
readonly PREFLIGHT_REMEDY='run ./scripts/Test-HostNetworkPreflight.ps1 -AutoRepair from Infrastructure-Vm-Provisioner on the host'
readonly PROBE_TOOLS=(ip ping timeout getent nslookup curl)

report() {
    printf '%s\n' "$1"
    exit 0
}

log_probe_result() {
    printf '%s\n' "$1" >&2
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

is_reachable_over_https() {
    local url="$1"
    local exit_code=0

    curl -sS -o /dev/null -I -k --max-time "${HTTPS_TIMEOUT_SECONDS}" "${url}" >/dev/null 2>&1 || exit_code=$?
    log_probe_result "curl ${url}: exit ${exit_code}"
    [[ ${exit_code} -eq 0 ]]
}

# Ping alone is not proof: a router may drop ICMP. The ping still makes the
# kernel resolve the router's MAC address, so an ARP entry that holds one, and
# has not been marked FAILED or INCOMPLETE, shows the router is there.
is_gateway_present() {

    local gateway="$1"
    local ping_exit_code=0
    local neighbour

    ping -c 1 -W "${PING_TIMEOUT_SECONDS}" "${gateway}" >/dev/null 2>&1 || ping_exit_code=$?
    log_probe_result "ping ${gateway}: exit ${ping_exit_code}"
    if [[ ${ping_exit_code} -eq 0 ]]; then
        return 0
    fi

    neighbour="$(ip neigh show "${gateway}" 2>/dev/null)"
    log_probe_result "arp ${gateway}: ${neighbour:-none}"
    [[ "${neighbour}" == *lladdr* && "${neighbour}" != *FAILED* && "${neighbour}" != *INCOMPLETE* ]]
}

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

readonly UPLINK_DOWN_VERDICT="router-uplink-down: router ${gateway} has no way out; ${PREFLIGHT_REMEDY}"

# getent has no timeout of its own, and a resolver with a dead upstream can
# stall it far longer than every other probe here.
resolver_exit_code=0
timeout "${DNS_TIMEOUT_SECONDS}" getent hosts "${PROBE_HOST}" >/dev/null 2>&1 || resolver_exit_code=$?
log_probe_result "getent ${PROBE_HOST}: exit ${resolver_exit_code}"

if [[ ${resolver_exit_code} -eq 0 ]]; then
    if is_reachable_over_https "https://${PROBE_HOST}"; then
        report 'ok'
    fi
    if ! is_reachable_over_https "https://${RAW_IP}"; then
        report "${UPLINK_DOWN_VERDICT}"
    fi
    report "https-failed: ${PROBE_HOST} resolves but HTTPS fails; check filtering past the router"
fi

# The VM's resolver failed, so ask the router directly to tell its failure
# modes apart.
router_answer="$(nslookup -timeout="${DNS_TIMEOUT_SECONDS}" -retry=0 "${PROBE_HOST}" "${gateway}" 2>&1)"
router_exit_code=$?
first_line="${router_answer%%$'\n'*}"
log_probe_result "nslookup ${PROBE_HOST} via ${gateway}: exit ${router_exit_code}: ${first_line}"

if [[ ${router_exit_code} -eq 0 ]]; then
    report "vm-resolver-misconfigured: router ${gateway} answers DNS but this VM's resolver does not; check its netplan nameservers"
fi

if [[ "${router_answer}" == *refused* ]]; then
    report "router-dns-refused: router ${gateway} refuses DNS; restart dnsmasq on the router VM"
fi

if [[ "${router_answer}" == *'timed out'* || "${router_answer}" == *'no servers could be reached'* ]]; then
    if is_reachable_over_https "https://${RAW_IP}"; then
        report "router-upstream-dns-silent: router ${gateway} forwards traffic but its upstream DNS is silent; ${PREFLIGHT_REMEDY}"
    fi
    report "${UPLINK_DOWN_VERDICT}"
fi

report "router-dns-error: router ${gateway} answered DNS with an error: ${first_line}"
