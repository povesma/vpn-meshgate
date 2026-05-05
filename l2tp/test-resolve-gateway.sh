#!/bin/sh
# Ad-hoc unit test for resolve_gateway() in l2tp/entrypoint.sh.
# Stubs nslookup and /etc/hosts; asserts behavior across success, fallback,
# atomic rewrite, and exhaustion paths. Run from repo root: sh l2tp/test-resolve-gateway.sh

set -u

PASS=0
FAIL=0
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

assert() {
    desc="$1"; cond="$2"
    if [ "${cond}" = "true" ]; then
        PASS=$((PASS + 1))
        printf "  PASS  %s\n" "${desc}"
    else
        FAIL=$((FAIL + 1))
        printf "  FAIL  %s\n" "${desc}"
    fi
}

# Extract function definitions from entrypoint.sh into a sourceable file.
# Strip the trailing `# === Main ===` and below so sourcing doesn't run the loop.
SRC="$(dirname "$0")/entrypoint.sh"
LIB="${WORK}/lib.sh"
awk '/^# === Main ===/{exit} {print}' "${SRC}" > "${LIB}"

run_case() {
    case_name="$1"
    primary_behavior="$2"   # "ok" or "fail"
    secondary_behavior="$3" # "ok" or "fail"
    expected_rc="$4"
    expected_ip="$5"

    sandbox="${WORK}/${case_name}"
    mkdir -p "${sandbox}/bin" "${sandbox}/etc"
    : > "${sandbox}/etc/hosts"
    echo "10.0.0.5	other.example.com" >> "${sandbox}/etc/hosts"
    echo "1.2.3.4	gw.test.local" >> "${sandbox}/etc/hosts"

    cat > "${sandbox}/bin/nslookup" <<NSL
#!/bin/sh
host="\$1"; resolver="\$2"
case "\${resolver}" in
    1.1.1.1)
        if [ "${primary_behavior}" = "ok" ]; then
            cat <<EOF
Server:		\${resolver}
Address:	\${resolver}#53

Non-authoritative answer:
Name:	\${host}
Address: 192.0.2.10
EOF
            exit 0
        else
            echo ";; communications error" >&2
            exit 1
        fi
        ;;
    8.8.8.8)
        if [ "${secondary_behavior}" = "ok" ]; then
            cat <<EOF
Server:		\${resolver}
Address:	\${resolver}#53

Non-authoritative answer:
Name:	\${host}
Address: 198.51.100.20
EOF
            exit 0
        else
            echo ";; communications error" >&2
            exit 1
        fi
        ;;
esac
exit 1
NSL
    chmod +x "${sandbox}/bin/nslookup"

    # Run the function in a subshell with stubbed PATH and redirected /etc/hosts.
    # Use a wrapper to redirect /etc/hosts writes into the sandbox.
    out=$(
        PATH="${sandbox}/bin:${PATH}" \
        L2TP_SERVER="gw.test.local" \
        BOOTSTRAP_DNS_PRIMARY="1.1.1.1" \
        BOOTSTRAP_DNS_SECONDARY="8.8.8.8" \
        BOOTSTRAP_DNS_RETRIES=2 \
        BOOTSTRAP_DNS_BACKOFF="0 0 0" \
        VPN_INSTANCE_NAME="testinst" \
        sh -c "
            set +e
            . '${LIB}'
            set +e
            # Override write_hosts_entry to operate on sandbox /etc/hosts copy
            HOSTS_FILE='${sandbox}/etc/hosts'
            write_hosts_entry() {
                _ip=\"\$1\"; _host=\"\$2\"
                _filtered=\$(grep -v \"[[:space:]]\${_host}\\\$\" \"\${HOSTS_FILE}\" || true)
                {
                    printf '%s\n' \"\${_filtered}\"
                    printf '%s\t%s\n' \"\${_ip}\" \"\${_host}\"
                } > \"\${HOSTS_FILE}\"
            }
            resolve_gateway
            rc=\$?
            echo \"GATEWAY_IP=\${GATEWAY_IP}\"
            echo \"RC=\${rc}\"
        " 2>&1
    )

    actual_rc=$(echo "${out}" | grep '^RC=' | tail -1 | cut -d= -f2)
    actual_ip=$(echo "${out}" | grep '^GATEWAY_IP=' | tail -1 | cut -d= -f2)

    [ "${actual_rc}" = "${expected_rc}" ] && rc_ok=true || rc_ok=false
    assert "[${case_name}] return code = ${expected_rc}" "${rc_ok}"

    if [ -n "${expected_ip}" ]; then
        [ "${actual_ip}" = "${expected_ip}" ] && ip_ok=true || ip_ok=false
        assert "[${case_name}] GATEWAY_IP = ${expected_ip}" "${ip_ok}"

        # /etc/hosts assertions
        if grep -q "^${expected_ip}	gw.test.local\$" "${sandbox}/etc/hosts"; then
            entry_ok=true
        else
            entry_ok=false
        fi
        assert "[${case_name}] /etc/hosts contains fresh entry" "${entry_ok}"

        # Stale prior entry (1.2.3.4) must be gone
        if grep -q "^1.2.3.4	gw.test.local\$" "${sandbox}/etc/hosts"; then
            stale_gone=false
        else
            stale_gone=true
        fi
        assert "[${case_name}] stale prior entry removed" "${stale_gone}"

        # Unrelated entries preserved
        if grep -q "^10.0.0.5	other.example.com\$" "${sandbox}/etc/hosts"; then
            other_ok=true
        else
            other_ok=false
        fi
        assert "[${case_name}] unrelated /etc/hosts entries preserved" "${other_ok}"

        # Exactly one line for gw.test.local (no accumulation)
        count=$(grep -c "[[:space:]]gw.test.local\$" "${sandbox}/etc/hosts")
        [ "${count}" = "1" ] && single_ok=true || single_ok=false
        assert "[${case_name}] exactly one /etc/hosts line for host" "${single_ok}"
    fi
}

echo "Test 1: primary resolver succeeds"
run_case "primary_ok" "ok" "fail" "0" "192.0.2.10"

echo "Test 2: primary fails, secondary succeeds"
run_case "fallback" "fail" "ok" "0" "198.51.100.20"

echo "Test 3: both resolvers fail every attempt -> exhaustion"
run_case "exhausted" "fail" "fail" "1" ""

printf "\nResults: %d passed, %d failed\n" "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ]
