#!/bin/sh
set -e
# Join whatever groups own the mounted GPU nodes so /dev/kfd and /dev/dri work
# on any host (no RENDER_GID/VIDEO_GID needed), then drop to the app user.
for dev in /dev/kfd /dev/dri/render*; do
    [ -e "$dev" ] || continue
    gid=$(stat -c %g "$dev")
    grp=$(getent group "$gid" | cut -d: -f1)
    [ -n "$grp" ] || {
        grp="gpu$gid"
        groupadd -g "$gid" "$grp"
    }
    usermod -aG "$grp" voicebox
done

# Freshly-created volumes land root-owned, which the non-root app user cannot
# write — model downloads and the SQLite DB then fail. Claim them here, while we
# still have root. Only fixes the mount roots, so it stays cheap on restarts
# with a warm model cache.
for dir in /app/data /app/data/generations /home/voicebox/.cache/huggingface; do
    [ -d "$dir" ] || mkdir -p "$dir"
    [ "$(stat -c %u "$dir")" = "$(id -u voicebox)" ] || chown voicebox:voicebox "$dir"
done

exec gosu voicebox "$@"
