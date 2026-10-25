#!/usr/bin/env bash
# Certbot deploy hook: copy live lineage into the Hearthost dest from ssl-map.
set -euo pipefail
MAP_DIR=/etc/hearthost/ssl-map
lineage="${RENEWED_LINEAGE:-}"
[[ -n "$lineage" && -d "$lineage" ]] || exit 0
domain="$(basename "$lineage")"
map="$MAP_DIR/$domain"
[[ -f "$map" ]] || exit 0
dest="$(tr -d '[:space:]' <"$map")"
[[ -n "$dest" ]] || exit 0
mkdir -p "$dest"
install -m 644 "$lineage/fullchain.pem" "$dest/fullchain.pem"
install -m 600 "$lineage/privkey.pem" "$dest/privkey.pem"
owner="$(stat -c '%U' "$dest" 2>/dev/null || true)"
if [[ -n "$owner" && "$owner" != "root" ]]; then
  chown "$owner:$owner" "$dest/fullchain.pem" "$dest/privkey.pem"
fi
if command -v nginx >/dev/null 2>&1; then
  nginx -t >/dev/null 2>&1 && systemctl reload nginx || true
fi
