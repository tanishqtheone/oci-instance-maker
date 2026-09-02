#!/usr/bin/env bash
#
# attempt_launch.sh
#
# Runs ONE launch attempt for the OCI A1.Flex Minecraft restore instance.
# Meant to be called repeatedly by a GitHub Actions cron schedule (see
# .github/workflows/oci-retry-launch.yml) rather than looping itself, since
# GitHub re-invokes it fresh every 5 minutes anyway.
#
# Safety: before attempting a launch, it checks whether an instance with our
# fixed display name already exists (in any non-terminated state) and skips
# if so - this prevents creating duplicate instances after a success.

set -uo pipefail

SHAPE="VM.Standard.A1.Flex"
OCPUS=2
MEMORY_IN_GBS=12
DISPLAY_NAME="minecraft-restored"   # fixed name (no timestamp) so we can check for it
ASSIGN_PUBLIC_IP=true

notify() {
    # Free push notification via ntfy.sh - no signup needed. Install the
    # ntfy app (Android/iOS) or visit https://ntfy.sh/$NTFY_TOPIC in a
    # browser and subscribe to get alerted instantly.
    local message="$1"
    curl -s -d "$message" "https://ntfy.sh/${NTFY_TOPIC}" > /dev/null || true
}

echo "Checking whether the instance already exists..."
existing=$(oci compute instance list \
    --compartment-id "$COMPARTMENT_ID" \
    --display-name "$DISPLAY_NAME" \
    --query "data[?\"lifecycle-state\" != 'TERMINATED']" \
    --output json 2>&1)

if echo "$existing" | grep -q '"id":'; then
    echo "An instance named '$DISPLAY_NAME' already exists and is not terminated. Skipping this attempt."
    exit 0
fi

echo "No existing instance found. Attempting launch..."
output=$(oci compute instance launch \
    --compartment-id "$COMPARTMENT_ID" \
    --availability-domain "$AVAILABILITY_DOMAIN" \
    --shape "$SHAPE" \
    --shape-config "{\"ocpus\": $OCPUS, \"memoryInGBs\": $MEMORY_IN_GBS}" \
    --display-name "$DISPLAY_NAME" \
    --source-details "{\"sourceType\": \"bootVolume\", \"bootVolumeId\": \"$BOOT_VOLUME_ID\"}" \
    --subnet-id "$SUBNET_ID" \
    --assign-public-ip "$ASSIGN_PUBLIC_IP" \
    2>&1)
exit_code=$?

if [ $exit_code -eq 0 ]; then
    echo "SUCCESS: $output"
    notify "✅ Minecraft instance launched successfully! Check the OCI Console."
    exit 0
fi

if echo "$output" | grep -qiE "out of host capacity|OutOfCapacity"; then
    echo "No capacity available yet. Will try again on the next scheduled run (~5 min)."
    exit 0
elif echo "$output" | grep -qiE '"status": *429|TooManyRequests|throttl'; then
    echo "Throttled by Oracle (429). Will try again on the next scheduled run (~5 min)."
    exit 0
else
    echo "ERROR (not a capacity or throttling issue):"
    echo "$output"
    notify "⚠️ OCI launch script hit a real error (not just capacity) - check GitHub Actions logs."
    exit 1
fi
