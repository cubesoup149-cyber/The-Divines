#!/usr/bin/env bash
#
# THE DIVINES — Supabase Storage heartbeat.
#
# Deletes the ONE dedicated heartbeat image from THE DIVINES' own Supabase
# Storage bucket, then uploads it again, then checks it is publicly reachable.
#
# Safety rules built into this script (it refuses to run if any is broken):
#   * It only talks to THE DIVINES' Supabase project (host is pinned below), so a
#     different project's URL — e.g. the TSIimg one — is rejected.
#   * It only touches ONE exact object: heartbeat/divines-heartbeat.png in the
#     "image" bucket. It never lists a bucket, never deletes by prefix and never
#     touches the folders the app uses for people's uploads:
#         profiles/…   chat/…   dm/…
#   * The credential comes from a GitHub Secret and is never printed.
#
# Mirrors how the website itself talks to Supabase (same REST endpoints, same key
# type, upload with x-upsert:false) — which is why the image is deleted first.
set -euo pipefail

# ---- verified from the project's config.js / supabase-storage.js ----------------------------
EXPECTED_HOST="xjzkcexvzwpiezvhmdeo.supabase.co"   # SUPABASE_URL in config.js
EXPECTED_BUCKET="image"                             # SUPABASE_BUCKET in config.js
EXPECTED_PATH="heartbeat/divines-heartbeat.png"     # dedicated; NOT profiles/, chat/ or dm/
# ----------------------------------------------------------------------------------------------

SUPABASE_URL="${SUPABASE_URL:-}"
SUPABASE_BUCKET="${SUPABASE_BUCKET:-}"
HEARTBEAT_PATH="${HEARTBEAT_PATH:-}"
HEARTBEAT_FILE="${HEARTBEAT_FILE:-}"
SUPABASE_KEY="${SUPABASE_KEY:-}"

fail() { echo "::error::$*" >&2; exit 1; }

# ---- 1. guards --------------------------------------------------------------------------------
[ -n "$SUPABASE_KEY" ] || fail "Secret DIVINES_SUPABASE_PUBLISHABLE_KEY is not set (Settings → Secrets and variables → Actions)."

URL_HOST="${SUPABASE_URL#*://}"; URL_HOST="${URL_HOST%%/*}"
[ "$URL_HOST" = "$EXPECTED_HOST" ] || fail "Refusing to run: SUPABASE_URL host is '$URL_HOST', but THE DIVINES' project is '$EXPECTED_HOST'."
[ "$SUPABASE_BUCKET" = "$EXPECTED_BUCKET" ] || fail "Refusing to run: bucket is '$SUPABASE_BUCKET', expected '$EXPECTED_BUCKET'."
[ "$HEARTBEAT_PATH" = "$EXPECTED_PATH" ] || fail "Refusing to run: object path is '$HEARTBEAT_PATH', expected exactly '$EXPECTED_PATH'."
case "$HEARTBEAT_PATH" in
  heartbeat/*) ;;
  *) fail "Refusing to run: the heartbeat path must be inside heartbeat/." ;;
esac
case "$HEARTBEAT_PATH" in
  *..*|*//*|profiles/*|chat/*|dm/*) fail "Refusing to run: unsafe heartbeat path '$HEARTBEAT_PATH'." ;;
esac

[ -f "$HEARTBEAT_FILE" ] || fail "Heartbeat image not found at '$HEARTBEAT_FILE'."
[ "$(head -c 8 "$HEARTBEAT_FILE" | od -An -tx1 | tr -d ' \n')" = "89504e470d0a1a0a" ] || fail "'$HEARTBEAT_FILE' is not a PNG."
SIZE="$(wc -c < "$HEARTBEAT_FILE")"
[ "$SIZE" -le 1048576 ] || fail "Heartbeat image is $SIZE bytes; keep it under 1 MB."

OBJECT_URL="https://${EXPECTED_HOST}/storage/v1/object/${EXPECTED_BUCKET}/${EXPECTED_PATH}"
PUBLIC_URL="https://${EXPECTED_HOST}/storage/v1/object/public/${EXPECTED_BUCKET}/${EXPECTED_PATH}"
# Keep the key out of the process list: send headers from a private temp file.
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
HDR="$WORK/h"; ( umask 077; printf 'apikey: %s\nAuthorization: Bearer %s\n' "$SUPABASE_KEY" "$SUPABASE_KEY" > "$HDR" )
BODY="$WORK/body"

echo "Project : $EXPECTED_HOST"
echo "Bucket  : $EXPECTED_BUCKET"
echo "Object  : $EXPECTED_PATH (only this one file is touched)"

# ---- 2. delete the previous heartbeat image (that one object only) ---------------------------
code="$(curl -sS --max-time 30 -o "$BODY" -w '%{http_code}' -X DELETE "$OBJECT_URL" -H @"$HDR")" || fail "Could not reach Supabase while deleting the previous heartbeat image."
case "$code" in
  200|204) DELETE_RESULT="deleted the previous heartbeat image" ;;
  404)     DELETE_RESULT="no previous heartbeat image (first run?)" ;;
  400)     if grep -qiE 'not.?found' "$BODY"; then DELETE_RESULT="no previous heartbeat image (first run?)"
           else fail "Delete returned 400: $(head -c 300 "$BODY")"; fi ;;
  401|403) fail "Delete refused ($code): the key is wrong or the 'image' bucket policy doesn't allow this key to delete. Use THE DIVINES' publishable key. Response: $(head -c 300 "$BODY")" ;;
  *)       fail "Delete failed with HTTP $code: $(head -c 300 "$BODY")" ;;
esac
echo "Delete  : $DELETE_RESULT (HTTP $code)"

# ---- 3. upload the heartbeat image again (retry a few times; same headers the website uses) --
ok=""
for attempt in 1 2 3; do
  code="$(curl -sS --max-time 60 -o "$BODY" -w '%{http_code}' -X POST "$OBJECT_URL" -H @"$HDR" \
          -H 'Content-Type: image/png' -H 'Cache-Control: no-cache' -H 'x-upsert: false' \
          --data-binary @"$HEARTBEAT_FILE")" || code="000"
  case "$code" in
    200|201) ok=1; break ;;
    401|403) fail "Upload refused ($code): the 'image' bucket policy doesn't allow this key to upload. Response: $(head -c 300 "$BODY")" ;;
    *) echo "Upload attempt $attempt failed (HTTP $code): $(head -c 200 "$BODY")"; sleep $((attempt * 5)) ;;
  esac
done
[ -n "$ok" ] || fail "Upload failed after 3 attempts (last HTTP $code). The old heartbeat image was already removed; the next run will retry."
echo "Upload  : done (HTTP $code, $SIZE bytes)"

# ---- 4. verify it is publicly reachable -----------------------------------------------------
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
vcode="$(curl -sS --max-time 30 -o "$WORK/check" -w '%{http_code} %{content_type}' "${PUBLIC_URL}?t=${STAMP}")" || fail "Uploaded, but could not fetch the public URL to verify it."
case "$vcode" in
  "200 image/png"*) echo "Verify  : public URL returns the PNG" ;;
  *) fail "Uploaded, but the public URL check returned '$vcode'." ;;
esac

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### THE DIVINES Supabase heartbeat — $STAMP"
    echo "- Project: \`$EXPECTED_HOST\`  ·  Bucket: \`$EXPECTED_BUCKET\`"
    echo "- Object: \`$EXPECTED_PATH\` — $DELETE_RESULT, uploaded again ($SIZE bytes), public URL verified"
  } >> "$GITHUB_STEP_SUMMARY"
fi
echo "Heartbeat complete."
