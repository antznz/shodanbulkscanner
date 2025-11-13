#!/usr/bin/env bash
set -euo pipefail

# shodan_bulk_get.sh
# Usage:
#   export SHODAN_API_KEY="your_key_here"
#   ./shodan_bulk_get.sh ips.txt
#
# Outputs:
#   - shodan_json/<ip>.json   (raw Shodan host JSON for each found IP)
#   - shodan_results.csv      (summary CSV)

if [ "$#" -ne 1 ]; then
  echo "Usage: $0 ips.txt"
  exit 1
fi

IPS_FILE="$1"
OUT_DIR="shodan_json"
CSV_FILE="shodan_results.csv"
TMP_LOG="shodan_bulk.log"
RETRIES=2
SLEEP_BETWEEN=0.25   # seconds; increase if you hit rate limits

# Ensure API key present
if [ -z "${SHODAN_API_KEY:-}" ]; then
  echo "ERROR: set SHODAN_API_KEY environment variable first."
  exit 2
fi

mkdir -p "$OUT_DIR"
echo "ip,found,org,hostnames,ports,os,asn,raw_json_path,error" > "$CSV_FILE"
: > "$TMP_LOG"

while IFS= read -r ip || [ -n "$ip" ]; do
  ip="${ip%%#*}"       # strip inline comments after '#'
  ip="${ip//[[:space:]]/}"  # trim whitespace
  [ -z "$ip" ] && continue

  echo "=== Querying $ip ===" | tee -a "$TMP_LOG"
  attempt=0
  success=false
  last_err=""

  while [ $attempt -le $RETRIES ]; do
    attempt=$((attempt+1))
    # Query Shodan host endpoint (uses existing indexed data ONLY)
    http_status=$(curl -s -o "$OUT_DIR/$ip.json.tmp" -w "%{http_code}" \
      "https://api.shodan.io/shodan/host/${ip}?key=${SHODAN_API_KEY}" || echo "000")

    if [ "$http_status" = "200" ]; then
      mv "$OUT_DIR/$ip.json.tmp" "$OUT_DIR/$ip.json"
      # parse some fields using jq (jq required)
      if command -v jq >/dev/null 2>&1; then
        org=$(jq -r '.org // ""' "$OUT_DIR/$ip.json" | sed 's/"/""/g')
        hostnames=$(jq -r '.hostnames | join(";") // ""' "$OUT_DIR/$ip.json" | sed 's/"/""/g')
        ports=$(jq -r '.ports | join(" ") // ""' "$OUT_DIR/$ip.json")
        os=$(jq -r '.os // ""' "$OUT_DIR/$ip.json" | sed 's/"/""/g')
        asn=$(jq -r '.asn // ""' "$OUT_DIR/$ip.json")
      else
        org=""
        hostnames=""
        ports=""
        os=""
        asn=""
      fi
      echo "\"$ip\",yes,\"$org\",\"$hostnames\",\"$ports\",\"$os\",\"$asn\",\"$OUT_DIR/$ip.json\",\"\"" >> "$CSV_FILE"
      success=true
      break
    elif [ "$http_status" = "404" ]; then
      rm -f "$OUT_DIR/$ip.json.tmp"
      echo "\"$ip\",no,,,,,,," >> "$CSV_FILE"
      success=true
      break
    else
      # record error and retry
      last_err="HTTP $http_status"
      echo "Attempt $attempt for $ip failed: $last_err" | tee -a "$TMP_LOG"
      rm -f "$OUT_DIR/$ip.json.tmp"
      # exponential backoff-ish
      sleep $(awk "BEGIN {print $SLEEP_BETWEEN * (1.5 ^ $attempt)}")
    fi
  done

  if ! $success; then
    echo "\"$ip\",error,,,,,,,\"$last_err\" >> \"$CSV_FILE\"" | bash
    echo "FINAL ERROR for $ip: $last_err" | tee -a "$TMP_LOG"
  fi

  # polite pause
  sleep "$SLEEP_BETWEEN"
done < "$IPS_FILE"

echo "Done. JSON files in ${OUT_DIR}/, summary CSV: ${CSV_FILE}"
echo "If you want a zip of all JSONs: zip -r shodan_json.zip ${OUT_DIR}/"
