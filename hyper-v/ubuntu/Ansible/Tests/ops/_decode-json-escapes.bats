#!/usr/bin/env bats
#
# Tests for ops/_decode-json-escapes.sh - turns the JSON string escapes in
# Ansible's default-callback output back into the characters they stand for,
# so ops/runner-status.sh prints its report as written.
# Run with: bats Tests/ops/_decode-json-escapes.bats

# shellcheck source=hyper-v/ubuntu/Ansible/Tests/_bats-helpers.sh
source "${BATS_TEST_DIRNAME}/../_bats-helpers.sh"

DECODER="$(cd "${BATS_TEST_DIRNAME}/../../ops" && pwd)/_decode-json-escapes.sh"

setup() {
    _bats_resolve_bash
}

# Pipes the first argument through decode_json_escapes.
_decode() {
    printf '%s\n' "$1" | "${BASH_BIN}" -c 'source "$1"; decode_json_escapes' _ "${DECODER}"
}

@test "decodes an escaped ESC into the ESC byte" {

    # ARRANGE
    input='"msg": "\u001b[32mUP\u001b[0m"'
    expected="\"msg\": \"$(printf '\033')[32mUP$(printf '\033')[0m\""

    # ACT
    run _decode "${input}"

    # ASSERT
    [ "${status}" -eq 0 ]
    [ "${output}" = "${expected}" ]
}

@test "decodes an escaped backslash into one backslash" {

    # ARRANGE
    input='"msg": "run .\\scripts\\Test-HostNetworkPreflight.ps1"'
    expected='"msg": "run .\scripts\Test-HostNetworkPreflight.ps1"'

    # ACT
    run _decode "${input}"

    # ASSERT
    [ "${status}" -eq 0 ]
    [ "${output}" = "${expected}" ]
}

@test "decodes an escaped double quote" {

    # ARRANGE
    input='"msg": "the \"ok\" line"'
    expected='"msg": "the "ok" line"'

    # ACT
    run _decode "${input}"

    # ASSERT
    [ "${status}" -eq 0 ]
    [ "${output}" = "${expected}" ]
}

# An escaped backslash ahead of u001b is a literal backslash, not an ESC.
@test "keeps an escaped backslash followed by u001b as text" {

    # ARRANGE
    input='"msg": "\\u001b"'
    expected='"msg": "\u001b"'

    # ACT
    run _decode "${input}"

    # ASSERT
    [ "${status}" -eq 0 ]
    [ "${output}" = "${expected}" ]
}

@test "passes a line without escapes through unchanged" {

    # ARRANGE
    input='TASK [Report each runner status] ***'
    expected='TASK [Report each runner status] ***'

    # ACT
    run _decode "${input}"

    # ASSERT
    [ "${status}" -eq 0 ]
    [ "${output}" = "${expected}" ]
}
