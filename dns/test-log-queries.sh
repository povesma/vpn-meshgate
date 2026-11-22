#!/bin/sh
# Unit test for how dns/entrypoint.sh launches dnsmasq.
# - Query logging must be off unless DNSMASQ_LOG_QUERIES=1.
# - dnsmasq must not run in debug mode (--no-daemon): debug mode handles
#   TCP queries in the main process, so one stalled TCP client blocks all DNS.
# Run from repo root: sh dns/test-log-queries.sh

set -u

PASS=0
FAIL=0
SRC="$(dirname "$0")/entrypoint.sh"

assert_eq() {
    desc="$1"; expected="$2"; actual="$3"
    if [ "${expected}" = "${actual}" ]; then
        PASS=$((PASS + 1))
        printf "  PASS  %s\n" "${desc}"
    else
        FAIL=$((FAIL + 1))
        printf "  FAIL  %s (expected '%s', got '%s')\n" "${desc}" "${expected}" "${actual}"
    fi
}

load_function() {
    eval "$(awk '/^dnsmasq_log_flag\(\)/,/^}/' "${SRC}")"
    if command -v dnsmasq_log_flag >/dev/null 2>&1; then defined=yes; else defined=no; fi
    assert_eq "dnsmasq_log_flag is defined in entrypoint.sh" "yes" "${defined}"
}

launch_line() {
    grep -E '^[[:space:]]*dnsmasq --' "${SRC}"
}

test_launch_line_exists() {
    if [ -n "$(launch_line)" ]; then found=yes; else found=no; fi
    assert_eq "dnsmasq launch line found in entrypoint.sh" "yes" "${found}"
}

test_launch_line_not_debug_mode() {
    case "$(launch_line)" in
        *--no-daemon*|*" -d "*) debug=yes ;;
        *) debug=no ;;
    esac
    assert_eq "dnsmasq is not started in debug mode (--no-daemon)" "no" "${debug}"
}

test_launch_line_stays_in_foreground() {
    case "$(launch_line)" in
        *--keep-in-foreground*) fg=yes ;;
        *) fg=no ;;
    esac
    assert_eq "dnsmasq is started with --keep-in-foreground" "yes" "${fg}"
}

test_launch_line_logs_to_stderr() {
    case "$(launch_line)" in
        *--log-facility=-*) stderr=yes ;;
        *) stderr=no ;;
    esac
    assert_eq "dnsmasq logs to stderr (--log-facility=-)" "yes" "${stderr}"
}

test_launch_line_has_no_hardcoded_flag() {
    launch="$(launch_line)"
    case "${launch}" in
        *--log-queries*) hardcoded=yes ;;
        *) hardcoded=no ;;
    esac
    assert_eq "dnsmasq launch line does not hardcode --log-queries" "no" "${hardcoded}"
}

test_unset_is_off() {
    unset DNSMASQ_LOG_QUERIES
    assert_eq "unset -> no query logging" "" "$(dnsmasq_log_flag)"
}

test_zero_is_off() {
    DNSMASQ_LOG_QUERIES=0
    assert_eq "0 -> no query logging" "" "$(dnsmasq_log_flag)"
}

test_other_value_is_off() {
    DNSMASQ_LOG_QUERIES=yes
    assert_eq "non-1 value -> no query logging" "" "$(dnsmasq_log_flag)"
}

test_one_is_on() {
    DNSMASQ_LOG_QUERIES=1
    assert_eq "1 -> --log-queries" "--log-queries" "$(dnsmasq_log_flag)"
}

load_function
for t in test_launch_line_exists test_launch_line_not_debug_mode test_launch_line_stays_in_foreground \
    test_launch_line_logs_to_stderr test_launch_line_has_no_hardcoded_flag test_unset_is_off test_zero_is_off test_other_value_is_off test_one_is_on; do
    "${t}"
done

printf "\n%d passed, %d failed\n" "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ]
