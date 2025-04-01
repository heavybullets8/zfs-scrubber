#!/bin/bash

: "${PUSHOVER_NOTIFICATION:=false}"
: "${ACTION:=scrub}"

exit_bool=false

if [ -z "$TALOS_VERSION" ]; then
    echo "Error: TALOS_VERSION environment variable not set."
    exit_bool=true
elif ! ZFS_IMAGE=$(crane export "ghcr.io/siderolabs/extensions:${TALOS_VERSION}" | tar x -O image-digests | grep zfs | awk '{print $1}'); then
    echo "Error: Could not find a compatible ZFS extension for Talos $TALOS_VERSION."
    exit_bool=true
fi

if [ "$exit_bool" = false ]; then
    echo "Verifying ZFS image signature..."
    if ! cosign verify \
        --certificate-identity-regexp '@siderolabs\.com$' \
        --certificate-oidc-issuer https://accounts.google.com \
        "$ZFS_IMAGE" >/dev/null 2>&1; then
        echo "Error: Image signature verification failed for $ZFS_IMAGE."
        exit_bool=true
    fi
fi

if [ "$PUSHOVER_NOTIFICATION" = true ]; then
    if [ -z "$PUSHOVER_USER_KEY" ]; then
        echo "Error: \"PUSHOVER_USER_KEY\" is missing while \"PUSHOVER_NOTIFICATION\" is \"true\"."
        exit_bool=true
    fi

    if [ -z "$PUSHOVER_API_TOKEN" ]; then
        echo "Error: \"PUSHOVER_API_TOKEN\" is missing while \"PUSHOVER_NOTIFICATION\" is \"true\"."
        exit_bool=true
    fi
fi

if [ -z "$ZFS_POOL" ]; then
    echo "Error: No ZFS_POOL specified."
    exit_bool=true
fi

if [ "$exit_bool" = true ]; then
    echo "Exiting due to previous errors..."
    exit 1
fi

echo "Installing ZFS from $ZFS_IMAGE..."
if ! crane export "$ZFS_IMAGE" | tar --strip-components=1 -x -C /; then
    echo "Error: Failed to extract ZFS extension."
    exit 1
fi
echo

send_pushover_notification() {
    if [ "$PUSHOVER_NOTIFICATION" = true ]; then
        local message="$1"
        local title="$2"
        local priority="${3:-}"

        curl_cmd=(curl -s -w "%{http_code}" --form-string "token=${PUSHOVER_API_TOKEN}"
            --form-string "user=${PUSHOVER_USER_KEY}"
            --form-string "message=${message}"
            --form-string "title=${title}"
            --form-string "html=1")

        if [ -n "$priority" ]; then
            curl_cmd+=(--form-string "priority=${priority}")
        fi

        response=$("${curl_cmd[@]}" https://api.pushover.net/1/messages.json)
        http_code="${response: -3}"
        if [ "$http_code" -ne 200 ]; then
            echo "Warning: Failed to send Pushover notification. HTTP status code: $http_code"
        fi
    fi
}

scrub_pool() {
    echo "===================================================="
    echo "Starting scrub on pool: $ZFS_POOL"
    echo "===================================================="

    if output=$(zpool scrub "$ZFS_POOL" 2>&1); then
        send_pushover_notification "<b>🛠️ Starting scrub on pool:</b> ${ZFS_POOL}" "ZFS Scrub Started"
    else
        send_pushover_notification $'❌ <b>Failed to start scrub on pool:</b> '"${ZFS_POOL}"$'\n<pre>'"${output}"'</pre>' "ZFS Scrub Failed" 1
        return 1
    fi

    echo "Scrub started on pool: $ZFS_POOL"
    echo "Monitoring scrub progress..."

    while true; do
        sleep 30
        echo "--------"
        status=$(zpool status "$ZFS_POOL")
        scrub_line=$(printf "%s\n" "$status" | grep -A 2 "scan:")
        echo "$scrub_line"
        if echo "$scrub_line" | grep -q "scrub repaired"; then
            echo "===================================================="
            echo "Scrub completed on pool: $ZFS_POOL"
            echo "===================================================="
            scan_line=$(printf "%s\n" "$status" | grep "scan:")
            send_pushover_notification "<b>✅ Scrub completed on pool:</b> ${ZFS_POOL}"$'\n<pre>'"${scan_line}"'</pre>' "ZFS Scrub Completed"
            break
        elif echo "$scrub_line" | grep -q "scrub in progress"; then
            continue
        elif echo "$scrub_line" | grep -q "resilver in progress"; then
            echo "Resilver in progress on pool: $ZFS_POOL"
            continue
        else
            echo "Unexpected scrub status on pool: ${ZFS_POOL}, status: ${scrub_line}"
            send_pushover_notification "❌ Unexpected scrub status on pool: ${ZFS_POOL}"$'\n<pre>'"${scrub_line}"'</pre>' "ZFS Scrub Error" 1
            return 1
        fi
    done
}

cleanup_snapshots() {
    echo "===================================================="
    echo "Starting cleanup on pool: $ZFS_POOL"
    echo "===================================================="
    mapfile -t snapshot_clone_pairs < <(zfs get -H -o name,value -t snapshot clones | grep "^${ZFS_POOL}/pvc-" | grep -v "[[:space:]]-$")
    if [ -z "${snapshot_clone_pairs[*]:-}" ]; then
        echo "Nothing to cleanup."
        return
    fi

    local success_count=0
    local failure_count=0

    for line in "${snapshot_clone_pairs[@]}"; do
        temp_source=$(echo "$line" | awk -F '\t' '{print $1}' | cut -d'@' -f1)
        snapshot_name=$(echo "$line" | awk -F '\t' '{print $1}' | cut -d'@' -f2)
        active_pvc=$(echo "$line" | awk -F '\t' '{print $2}')

        if [ -z "$temp_source" ] || [ -z "$snapshot_name" ] || [ -z "$active_pvc" ]; then
            echo "Error: Invalid data found"
            echo "  Temporary source: ${temp_source:-<empty>}"
            echo "  Snapshot: ${snapshot_name:-<empty>}"
            echo "  Active PVC: ${active_pvc:-<empty>}"
            echo "Skipping this pair..."
            echo
            ((failure_count++))
            continue
        fi

        echo
        echo "Processing Snapshot Pair"
        echo "----------------------"
        echo "  Temporary source: $temp_source"
        echo "  Snapshot: $snapshot_name"
        echo "  Active PVC: $active_pvc"
        echo

        echo "  → Promoting active PVC"
        if ! zfs promote "$active_pvc"; then
            echo "    Error: Failed to promote: $active_pvc"
            ((failure_count++))
            continue
        fi

        echo "  → Destroying temporary source"
        if ! zfs destroy "$temp_source"; then
            echo "    Error: Failed to destroy dataset: $temp_source"
            ((failure_count++))
            continue
        fi

        echo "  → Destroying snapshot"
        if ! zfs destroy "$active_pvc@$snapshot_name"; then
            echo "    Error: Failed to destroy snapshot: $active_pvc@$snapshot_name"
            ((failure_count++))
            continue
        fi

        echo
        echo "  ✓ Cleanup complete for this pair"
        echo
        ((success_count++))
    done

    echo "===================================================="
    echo "Cleanup completed on pool: $ZFS_POOL"
    echo "===================================================="

    if [ "$success_count" -gt 0 ] && [ "$failure_count" -eq 0 ]; then
        send_pushover_notification "<b>✅ Cleanup completed successfully on pool:</b> ${ZFS_POOL}"$'\n'"All $success_count snapshot pairs cleaned up." "ZFS Cleanup Completed"
    elif [ "$failure_count" -gt 0 ]; then
        send_pushover_notification "<b>⚠️ Cleanup completed with errors on pool:</b> ${ZFS_POOL}"$'\n'"Successful cleanups: $success_count"$'\n'"Failed cleanups: $failure_count" "ZFS Cleanup Completed with Errors"
    fi
}

case "$ACTION" in
scrub)
    scrub_pool
    ;;
cleanup)
    cleanup_snapshots
    ;;
all)
    scrub_pool
    echo
    echo
    cleanup_snapshots
    ;;
*)
    echo "Error: Invalid ACTION specified. Use 'scrub', 'cleanup', or 'all'."
    exit 1
    ;;
esac
