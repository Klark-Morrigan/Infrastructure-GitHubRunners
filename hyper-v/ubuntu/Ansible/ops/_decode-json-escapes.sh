#!/usr/bin/env bash
#
# Do not run directly. Dot-sourced by runner-status.sh.
#
# Defines decode_json_escapes; no top-level side effects.

# ---------------------------------------------------------------------------
# decode_json_escapes
#   Filters stdin to stdout, turning the JSON string escapes in Ansible's
#   default-callback output back into the characters they stand for. That
#   callback JSON-encodes every task result, so a report line's ANSI colour
#   arrives as the text \u001b, a backslash doubled and a double quote
#   escaped. Decodes those three, the only ones a report line carries.
#
#   An escaped backslash is parked on a control byte first, so the backslash
#   in an escaped "\\u001b" is not read as the start of an ESC escape.
# ---------------------------------------------------------------------------
decode_json_escapes() {

    local esc
    local parked_backslash

    esc="$(printf '\033')"
    parked_backslash="$(printf '\001')"

    sed -e "s/\\\\\\\\/${parked_backslash}/g" \
        -e "s/\\\\u001b/${esc}/g" \
        -e 's/\\"/"/g' \
        -e "s/${parked_backslash}/\\\\/g"
}
