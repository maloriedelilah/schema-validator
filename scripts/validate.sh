#!/usr/bin/env bash
#
# scripts/validate.sh -- thin client for the self-hosted author-geo SHACL
# validator. Feeds a built HTML page (extracts its JSON-LD) OR a raw
# .jsonld file to the validator's REST API, prints the report, and exits
# non-zero on any SHACL violation -- so it can be used as a CI/build gate.
#
# Usage:
#   scripts/validate.sh <file.html|file.jsonld> [base-url]
#
#   base-url defaults to http://localhost:4738 (the docker-compose mapped
#   port). Pass a different base-url if the validator is running elsewhere.
#
# Requires: curl, jq, python3 (only for HTML -> JSON-LD extraction).
# We fail LOUDLY and immediately if a required tool is missing, rather
# than falling back to a fragile regex parse that could silently produce
# a wrong verdict -- see the flock's "silent failure" lesson.
#
set -euo pipefail

BASE_URL="${2:-http://localhost:4738}"
DOMAIN="authorgeo"
VALIDATION_TYPE="author_geo_page"
API_URL="${BASE_URL}/shacl/${DOMAIN}/api/validate"

fail() { echo "ERROR: $*" >&2; exit 1; }

[ $# -ge 1 ] || fail "usage: $0 <file.html|file.jsonld> [base-url]"
INPUT_FILE="$1"
[ -f "$INPUT_FILE" ] || fail "no such file: $INPUT_FILE"

for tool in curl jq; do
    command -v "$tool" >/dev/null 2>&1 || fail "required tool '$tool' not found on PATH"
done

# --- Step 1: get the JSON-LD content to validate ------------------------
case "$INPUT_FILE" in
    *.jsonld|*.json)
        JSONLD_CONTENT="$(cat "$INPUT_FILE")"
        ;;
    *.html|*.htm)
        command -v python3 >/dev/null 2>&1 || fail "required tool 'python3' not found on PATH (needed to extract JSON-LD from HTML)"
        # Extract the FIRST <script type="application/ld+json"> block.
        # If a page carries multiple such blocks and you need to validate
        # more than one, run this script once per block/file instead of
        # silently picking-and-merging them here.
        JSONLD_CONTENT="$(python3 - "$INPUT_FILE" <<'PYEOF'
import sys, re
from html.parser import HTMLParser

path = sys.argv[1]
html = open(path, encoding="utf-8").read()

class LDExtractor(HTMLParser):
    def __init__(self):
        super().__init__()
        self.in_ldjson = False
        self.chunks = []
        self.found = None

    def handle_starttag(self, tag, attrs):
        if tag.lower() == "script":
            attrs_d = dict(attrs)
            if attrs_d.get("type", "").lower() == "application/ld+json":
                self.in_ldjson = True

    def handle_endtag(self, tag):
        if tag.lower() == "script" and self.in_ldjson:
            self.in_ldjson = False
            if self.found is None:
                self.found = "".join(self.chunks)
            self.chunks = []

    def handle_data(self, data):
        if self.in_ldjson:
            self.chunks.append(data)

p = LDExtractor()
p.feed(html)
if p.found is None:
    sys.exit("no <script type=\"application/ld+json\"> block found in " + path)
print(p.found.strip())
PYEOF
)" || fail "could not extract JSON-LD from $INPUT_FILE"
        ;;
    *)
        fail "unrecognised input extension for '$INPUT_FILE' (expected .html/.htm or .jsonld/.json)"
        ;;
esac

[ -n "$JSONLD_CONTENT" ] || fail "extracted/loaded JSON-LD content was empty"

# --- Step 2: call the validator's REST API -------------------------------
# API shape (contentToValidate / embeddingMethod / contentSyntax /
# validationType / reportSyntax) confirmed against a REAL, currently-live
# ITB SHACL validator deployment (the BRegDCAT-AP validator's documented
# curl example: https://interoperable-europe.ec.europa.eu one, retrieved
# 2026-07-21) -- not guessed.
CONTENT_B64="$(printf '%s' "$JSONLD_CONTENT" | base64 | tr -d '\n')"

REQUEST_JSON="$(jq -n \
    --arg content "$CONTENT_B64" \
    --arg vtype "$VALIDATION_TYPE" \
    '{
        contentToValidate: $content,
        embeddingMethod: "BASE64",
        contentSyntax: "application/ld+json",
        validationType: $vtype,
        reportSyntax: "application/json"
    }')"

HTTP_CODE_FILE="$(mktemp)"
BODY_FILE="$(mktemp)"
trap 'rm -f "$HTTP_CODE_FILE" "$BODY_FILE"' EXIT

set +e
curl --silent --show-error --max-time 30 --retry 3 --retry-delay 2 \
    --request POST "$API_URL" \
    --header "Content-Type: application/json" \
    --data "$REQUEST_JSON" \
    --output "$BODY_FILE" \
    --write-out "%{http_code}" > "$HTTP_CODE_FILE"
CURL_EXIT=$?
set -e

[ "$CURL_EXIT" -eq 0 ] || fail "curl failed to reach $API_URL (exit $CURL_EXIT) -- is the validator up? (docker compose up -d)"

HTTP_CODE="$(cat "$HTTP_CODE_FILE")"
[ "$HTTP_CODE" = "200" ] || {
    echo "--- validator response body ---" >&2
    cat "$BODY_FILE" >&2
    fail "validator returned HTTP $HTTP_CODE (expected 200)"
}

jq empty "$BODY_FILE" 2>/dev/null || {
    echo "--- validator response body (not valid JSON) ---" >&2
    cat "$BODY_FILE" >&2
    fail "validator response was not valid JSON -- did reportSyntax=application/json get honoured?"
}

# --- Step 3: print the report ---------------------------------------------
echo "=== SHACL validation report ($INPUT_FILE) ==="
jq '.' "$BODY_FILE"

# --- Step 4: decide pass/fail on the ACTUAL response fields ----------------
# The GITB Test Assertion Report (TAR) JSON, which the validator's REST API
# produces when reportSyntax=application/json, carries a top-level "result"
# field (one of SUCCESS / WARNING / FAILURE) and a "counters" object with
# nrOfErrors / nrOfWarnings / nrOfAssertions. We key pass/fail off BOTH:
# result != SUCCESS, OR counters.nrOfErrors > 0, is a fail. This is
# belt-and-suspenders in case one field is missing/renamed in a future
# validator version -- we'd rather over-report a failure than silently
# pass a broken page.
#
# NOTE for the operator: this could not be verified against a live response
# in the build sandbox (no Docker there -- see VERIFY.md). The very first
# time you run this for real, diff the printed report against these field
# names and adjust the jq paths below if the live validator disagrees.
RESULT="$(jq -r '.result // .report.result // "UNKNOWN"' "$BODY_FILE")"
NR_ERRORS="$(jq -r '(.counters.nrOfErrors // .report.counters.nrOfErrors // 0)' "$BODY_FILE")"

echo "--- summary: result=$RESULT nrOfErrors=$NR_ERRORS ---"

if [ "$RESULT" = "SUCCESS" ] && [ "$NR_ERRORS" -eq 0 ]; then
    echo "PASS: no SHACL violations."
    exit 0
else
    echo "FAIL: SHACL violations found (result=$RESULT, nrOfErrors=$NR_ERRORS)." >&2
    exit 1
fi
