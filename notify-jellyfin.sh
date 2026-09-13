#!/usr/bin/env bash
#
# notify-jellyfin.sh — tell a Jellyfin server to rescan a path after
# subtitles change there, so it picks up the new files without waiting for
# its own periodic library scan (or without relying on its file-system
# watcher, which doesn't always catch subtitle-only changes).
#
# Usage:
#   notify-jellyfin.sh PATH...
#
# Configuration is via environment variables (not flags, since these are
# the same for every call and you don't want to retype them):
#
#   JELLYFIN_URL              base URL, e.g. http://192.168.0.2:8096 (required)
#   JELLYFIN_TOKEN            API key from Jellyfin's dashboard under
#                             Settings -> Advanced -> API Keys (required)
#   JELLYFIN_HOST_PREFIX      host-side path prefix to strip (optional)
#   JELLYFIN_CONTAINER_PREFIX replacement prefix, as Jellyfin itself sees
#                             the path (optional, used with the above)
#
# The HOST_PREFIX/CONTAINER_PREFIX pair only matters if Jellyfin runs in a
# container with different internal paths than the host filesystem - e.g.
# a host directory /mnt/storage01/media/tv mounted into the container at
# /data/tvshows needs JELLYFIN_HOST_PREFIX=/mnt/storage01/media and
# JELLYFIN_CONTAINER_PREFIX=/data so that a call with a host path gets
# rewritten to what Jellyfin's API actually expects. Leave both unset for
# a native (non-container) Jellyfin install, where paths match as-is.
#
# Jellyfin 12+ requires the full "Authorization: MediaBrowser ..." header
# with client/device fields - a bare API-key header (the older convention)
# gets silently rejected with 401 on newer servers.
#
# Example:
#   export JELLYFIN_URL=http://192.168.0.2:8096
#   export JELLYFIN_TOKEN=your-api-key-here
#   export JELLYFIN_HOST_PREFIX=/mnt/storage01/media
#   export JELLYFIN_CONTAINER_PREFIX=/data
#   notify-jellyfin.sh "/mnt/storage01/media/tv/Some Show/Season 01"

set -euo pipefail

usage() {
    grep '^#' "$0" | sed -n '2,30p' | sed 's/^# \{0,1\}//'
    exit 1
}

if [[ $# -eq 0 ]]; then
    usage
fi

: "${JELLYFIN_URL:?error: JELLYFIN_URL is not set}"
: "${JELLYFIN_TOKEN:?error: JELLYFIN_TOKEN is not set}"

command -v jq >/dev/null 2>&1 || { echo "error: jq not found in PATH" >&2; exit 1; }

remap_path() {
    local p="$1"
    if [[ -n "${JELLYFIN_HOST_PREFIX:-}" && -n "${JELLYFIN_CONTAINER_PREFIX:-}" && "$p" == "$JELLYFIN_HOST_PREFIX"* ]]; then
        echo "${JELLYFIN_CONTAINER_PREFIX}${p#$JELLYFIN_HOST_PREFIX}"
    else
        echo "$p"
    fi
}

UPDATES="[]"
for p in "$@"; do
    remapped=$(remap_path "$p")
    UPDATES=$(jq -c --arg path "$remapped" '. + [{"Path": $path}]' <<<"$UPDATES")
done

BODY=$(jq -c --argjson updates "$UPDATES" '{Updates: $updates}' <<<'{}')

HTTP_STATUS=$(curl -sS -o /tmp/notify-jellyfin-response.$$ -w "%{http_code}" \
    -X POST "${JELLYFIN_URL%/}/Library/Media/Updated" \
    -H 'Authorization: MediaBrowser Client="media-scripts", Device="notify-jellyfin.sh", DeviceId="media-scripts-notify", Version="1.0.0", Token="'"$JELLYFIN_TOKEN"'"' \
    -H "Content-Type: application/json" \
    -d "$BODY" --max-time 15)

RESPONSE_BODY=$(cat /tmp/notify-jellyfin-response.$$ 2>/dev/null)
rm -f /tmp/notify-jellyfin-response.$$

if [[ "$HTTP_STATUS" -ge 200 && "$HTTP_STATUS" -lt 300 ]]; then
    echo "ok: notified Jellyfin for $# path(s) (HTTP $HTTP_STATUS)"
else
    echo "error: Jellyfin returned HTTP $HTTP_STATUS" >&2
    [[ -n "$RESPONSE_BODY" ]] && echo "$RESPONSE_BODY" >&2
    exit 1
fi
