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
# The last two are both fixed on the host, by the VM provisioner's network
# preflight.
#
# Always exits 0: the verdict is the output, and a read-only status report
# must not fail because the network it reports on is down.
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

readonly PREFLIGHT_REMEDY='run Test-HostNetworkPreflight.ps1 -AutoRepair on the host'
readonly PROBE_TOOLS=(ip ping getent nslookup curl)

report() {
    printf '%s\n' "$1"
    exit 0
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
    curl -sS -o /dev/null -I -k --max-time "${HTTPS_TIMEOUT_SECONDS}" "$1" >/dev/null 2>&1
}

missingTool="$(find_missing_tool)"
if [[ -n "${missingTool}" ]]; then
    report "probe-tool-missing: ${missingTool} is not installed on this VM"
fi

gateway="$(read_default_gateway)"
if [[ -z "${gateway}" ]]; then
    report 'no-default-route: this VM has no default route; check its netplan gateway'
fi

if ! ping -c 1 -W "${PING_TIMEOUT_SECONDS}" "${gateway}" >/dev/null 2>&1; then
    report "gateway-unreachable: router ${gateway} does not answer; start the router VM or check this VM's switch"
fi

if getent hosts "${PROBE_HOST}" >/dev/null 2>&1; then
    if is_reachable_over_https "https://${PROBE_HOST}"; then
        report 'ok'
    fi
    report "https-failed: ${PROBE_HOST} resolves but HTTPS fails; check filtering past the router"
fi

# The VM's resolver failed, so ask the router directly to tell its failure
# modes apart.
routerAnswer="$(nslookup -timeout="${DNS_TIMEOUT_SECONDS}" -retry=0 "${PROBE_HOST}" "${gateway}" 2>&1)"
routerExitCode=$?

if [[ ${routerExitCode} -eq 0 ]]; then
    report "vm-resolver-misconfigured: router ${gateway} answers DNS but this VM's resolver does not; check its netplan nameservers"
fi

if [[ "${routerAnswer}" == *refused* ]]; then
    report "router-dns-refused: router ${gateway} refuses DNS; restart dnsmasq on the router VM"
fi

if [[ "${routerAnswer}" == *'timed out'* || "${routerAnswer}" == *'no servers could be reached'* ]]; then
    if is_reachable_over_https "https://${RAW_IP}"; then
        report "router-upstream-dns-silent: router ${gateway} forwards traffic but its upstream DNS is silent; ${PREFLIGHT_REMEDY}"
    fi
    report "router-uplink-down: router ${gateway} has no way out; ${PREFLIGHT_REMEDY}"
fi

firstLine="${routerAnswer%%$'\n'*}"
report "router-dns-error: router ${gateway} answered DNS with an error: ${firstLine}"
