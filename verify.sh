#!/usr/bin/env bash
set -euo pipefail

# ── Config ──────────────────────────────────────────────────────────
API="${VISIHUB_API_BASE}"
TOKEN="${VISIHUB_API_KEY}"
REPO="${VISIHUB_REPO}"
FILE="${VISIHUB_FILE_PATH}"
DATASET_PATH="${VISIHUB_DATASET_PATH:-$(basename "$FILE")}"
MESSAGE="${VISIHUB_MESSAGE:-}"
SOURCE_TYPE="${VISIHUB_SOURCE_TYPE:-}"
SOURCE_IDENTITY="${VISIHUB_SOURCE_IDENTITY:-}"
FAIL_ON_CHECK="${VISIHUB_FAIL_ON_CHECK:-true}"

AUTH="Authorization: Bearer ${TOKEN}"

# ── Helpers ─────────────────────────────────────────────────────────
api_get() {
  curl -sfS -H "${AUTH}" -H "Content-Type: application/json" "${API}$1"
}

api_post() {
  curl -sfS -H "${AUTH}" -H "Content-Type: application/json" -X POST -d "$2" "${API}$1"
}

die() { echo "::error::$1"; exit 1; }

# ── Validate inputs ────────────────────────────────────────────────
[[ -z "${TOKEN}" ]] && die "api_key is required"
[[ -z "${REPO}" ]] && die "repo is required"
[[ -f "${FILE}" ]] || die "File not found: ${FILE}"

OWNER="${REPO%%/*}"
SLUG="${REPO##*/}"
BYTE_SIZE=$(stat -c%s "${FILE}" 2>/dev/null || stat -f%z "${FILE}")

echo "::group::VisiHub Verify"
echo "  Repo:    ${OWNER}/${SLUG}"
echo "  File:    ${FILE} (${BYTE_SIZE} bytes)"
echo "  Dataset: ${DATASET_PATH}"

# ── Compute content hash (BLAKE3 if available, else SHA256) ────────
if command -v b3sum &>/dev/null; then
  HASH="blake3:$(b3sum --no-names "${FILE}")"
  echo "  Hash:    ${HASH}"
elif command -v sha256sum &>/dev/null; then
  HASH="sha256:$(sha256sum "${FILE}" | cut -d' ' -f1)"
  echo "  Hash:    ${HASH} (sha256 fallback)"
else
  HASH=""
  echo "  Hash:    (none — install b3sum for BLAKE3)"
fi

# ── Step 1: Verify token ──────────────────────────────────────────
echo ""
echo "Verifying API token..."
ME=$(api_get "/api/desktop/me") || die "Invalid API token"
USER_SLUG=$(echo "${ME}" | jq -r '.user_slug')
echo "  Authenticated as: ${USER_SLUG}"

# ── Step 2: Find or create dataset ────────────────────────────────
echo ""
echo "Looking up dataset '${DATASET_PATH}'..."
DATASETS=$(api_get "/api/desktop/repos/${OWNER}/${SLUG}/datasets") || die "Failed to list datasets for ${OWNER}/${SLUG}"

DATASET_ID=$(echo "${DATASETS}" | jq -r --arg path "${DATASET_PATH}" '.[] | select(.name == $path) | .id' | head -1)

if [[ -z "${DATASET_ID}" || "${DATASET_ID}" == "null" ]]; then
  echo "  Dataset not found, creating..."
  CREATE_RESP=$(api_post "/api/desktop/repos/${OWNER}/${SLUG}/datasets" "{\"name\":\"${DATASET_PATH}\"}") || die "Failed to create dataset"
  DATASET_ID=$(echo "${CREATE_RESP}" | jq -r '.dataset_id')
  echo "  Created dataset #${DATASET_ID}"
else
  echo "  Found dataset #${DATASET_ID}"
fi

# ── Step 3: Create revision (get upload URL) ──────────────────────
echo ""
echo "Creating revision..."
REV_BODY="{\"byte_size\":${BYTE_SIZE}"
if [[ -n "${HASH}" && "${HASH}" == blake3:* ]]; then
  REV_BODY="${REV_BODY},\"content_hash\":\"${HASH}\""
fi
if [[ -n "${SOURCE_TYPE}" || -n "${SOURCE_IDENTITY}" ]]; then
  REV_BODY="${REV_BODY},\"source_metadata\":{"
  SM_PARTS=""
  [[ -n "${SOURCE_TYPE}" ]] && SM_PARTS="\"type\":\"${SOURCE_TYPE}\""
  [[ -n "${SOURCE_IDENTITY}" ]] && {
    [[ -n "${SM_PARTS}" ]] && SM_PARTS="${SM_PARTS},"
    SM_PARTS="${SM_PARTS}\"identity\":\"${SOURCE_IDENTITY}\""
  }
  SM_PARTS="${SM_PARTS},\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\""
  REV_BODY="${REV_BODY}${SM_PARTS}}"
fi
REV_BODY="${REV_BODY}}"

REV_RESP=$(api_post "/api/desktop/datasets/${DATASET_ID}/revisions" "${REV_BODY}") || die "Failed to create revision"
REVISION_ID=$(echo "${REV_RESP}" | jq -r '.revision_id')
UPLOAD_URL=$(echo "${REV_RESP}" | jq -r '.upload_url')
echo "  Revision #${REVISION_ID}"

# Extract upload headers
UPLOAD_HEADERS_JSON=$(echo "${REV_RESP}" | jq -r '.upload_headers // {}')

# ── Step 4: Upload file ──────────────────────────────────────────
echo ""
echo "Uploading ${BYTE_SIZE} bytes..."
CURL_HEADERS=()
while IFS= read -r key; do
  val=$(echo "${UPLOAD_HEADERS_JSON}" | jq -r --arg k "$key" '.[$k]')
  CURL_HEADERS+=(-H "${key}: ${val}")
done < <(echo "${UPLOAD_HEADERS_JSON}" | jq -r 'keys[]')

HTTP_CODE=$(curl -sS -o /dev/null -w "%{http_code}" -X PUT "${CURL_HEADERS[@]}" --data-binary "@${FILE}" "${UPLOAD_URL}")

if [[ "${HTTP_CODE}" -lt 200 || "${HTTP_CODE}" -ge 300 ]]; then
  die "Upload failed with HTTP ${HTTP_CODE}"
fi
echo "  Upload complete (HTTP ${HTTP_CODE})"

# ── Step 5: Complete revision ─────────────────────────────────────
echo ""
echo "Finalizing revision..."
COMPLETE_BODY="{}"
if [[ -n "${HASH}" && "${HASH}" == blake3:* ]]; then
  COMPLETE_BODY="{\"content_hash\":\"${HASH}\"}"
fi
COMPLETE_RESP=$(api_post "/api/desktop/revisions/${REVISION_ID}/complete" "${COMPLETE_BODY}") || die "Failed to complete revision"
echo "  Status: $(echo "${COMPLETE_RESP}" | jq -r '.status')"

# ── Step 6: Wait for processing ──────────────────────────────────
echo ""
echo "Waiting for import to complete..."
MAX_WAIT=120
WAITED=0

while [[ ${WAITED} -lt ${MAX_WAIT} ]]; do
  RUNS=$(api_get "/api/repos/${OWNER}/${SLUG}/runs?limit=5") || die "Failed to fetch runs"
  RUN=$(echo "${RUNS}" | jq --argjson id "${REVISION_ID}" '.runs[] | select(.id == $id)')

  if [[ -z "${RUN}" ]]; then
    sleep 3
    WAITED=$((WAITED + 3))
    continue
  fi

  STATUS=$(echo "${RUN}" | jq -r '.status')
  case "${STATUS}" in
    verified|completed)
      echo "  Run status: ${STATUS}"
      break
      ;;
    failed)
      die "Import failed"
      ;;
    *)
      sleep 3
      WAITED=$((WAITED + 3))
      ;;
  esac
done

if [[ ${WAITED} -ge ${MAX_WAIT} ]]; then
  die "Timed out waiting for import (${MAX_WAIT}s)"
fi

# ── Step 7: Extract results ──────────────────────────────────────
CHECK_STATUS=$(echo "${RUN}" | jq -r '.check_status // "none"')
DIFF_SUMMARY=$(echo "${RUN}" | jq -c '.diff_summary // null')
VERSION=$(echo "${RUN}" | jq -r '.version')
ROW_COUNT=$(echo "${RUN}" | jq -r '.row_count // "—"')
COL_COUNT=$(echo "${RUN}" | jq -r '.col_count // "—"')
PROOF_URL="${API}/api/repos/${OWNER}/${SLUG}/runs/${REVISION_ID}/proof"

if [[ "${CHECK_STATUS}" == "pass" ]]; then
  VERIFICATION="PASS"
elif [[ "${CHECK_STATUS}" == "fail" ]]; then
  VERIFICATION="FAIL"
else
  VERIFICATION="PASS"
fi

# Parse diff details
ROW_CHANGE="0"
COL_CHANGE="0"
COLS_ADDED="0"
COLS_REMOVED="0"
COLS_TYPE_CHANGED="0"
if [[ "${DIFF_SUMMARY}" != "null" ]]; then
  ROW_CHANGE=$(echo "${DIFF_SUMMARY}" | jq -r '.row_count_change // 0')
  COL_CHANGE=$(echo "${DIFF_SUMMARY}" | jq -r '.col_count_change // 0')
  COLS_ADDED=$(echo "${DIFF_SUMMARY}" | jq -r '.cols_added // 0')
  COLS_REMOVED=$(echo "${DIFF_SUMMARY}" | jq -r '.cols_removed // 0')
  COLS_TYPE_CHANGED=$(echo "${DIFF_SUMMARY}" | jq -r '.cols_type_changed // 0')
fi

echo ""
echo "  Verification: ${VERIFICATION}"
echo "  Check status: ${CHECK_STATUS}"
echo "  Version:      v${VERSION}"
if [[ "${DIFF_SUMMARY}" != "null" ]]; then
  echo "  Diff:         rows ${ROW_CHANGE} cols ${COL_CHANGE}"
fi
echo "  Proof URL:    ${PROOF_URL}"
echo "::endgroup::"

# ── Step 8: Set outputs ──────────────────────────────────────────
echo "verification_status=${VERIFICATION}" >> "${GITHUB_OUTPUT}"
echo "check_status=${CHECK_STATUS}" >> "${GITHUB_OUTPUT}"
echo "diff_summary=${DIFF_SUMMARY}" >> "${GITHUB_OUTPUT}"
echo "run_id=${REVISION_ID}" >> "${GITHUB_OUTPUT}"
echo "proof_url=${PROOF_URL}" >> "${GITHUB_OUTPUT}"
echo "version=${VERSION}" >> "${GITHUB_OUTPUT}"

# ── Step 9: GitHub Job Summary ───────────────────────────────────
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  if [[ "${VERIFICATION}" == "PASS" ]]; then
    BADGE="✅ PASS"
  else
    BADGE="❌ FAIL"
  fi

  {
    echo "### VisiHub Verify: ${BADGE}"
    echo ""
    echo "| | |"
    echo "|---|---|"
    echo "| **Dataset** | \`${DATASET_PATH}\` |"
    echo "| **Version** | v${VERSION} |"
    echo "| **Rows** | ${ROW_COUNT} |"
    echo "| **Columns** | ${COL_COUNT} |"
    echo "| **Size** | ${BYTE_SIZE} bytes |"
    echo "| **Content hash** | \`${HASH:-none}\` |"

    if [[ "${DIFF_SUMMARY}" != "null" ]]; then
      echo ""
      echo "#### Changes from previous version"
      echo ""
      if [[ "${ROW_CHANGE}" != "0" ]]; then
        if [[ "${ROW_CHANGE}" -gt 0 ]]; then
          echo "- **+${ROW_CHANGE}** rows added"
        else
          echo "- **${ROW_CHANGE}** rows removed"
        fi
      fi
      if [[ "${COLS_ADDED}" != "0" ]]; then
        echo "- **+${COLS_ADDED}** columns added"
      fi
      if [[ "${COLS_REMOVED}" != "0" ]]; then
        echo "- **${COLS_REMOVED}** columns removed"
      fi
      if [[ "${COLS_TYPE_CHANGED}" != "0" ]]; then
        echo "- **${COLS_TYPE_CHANGED}** column types changed"
      fi
      if [[ "${ROW_CHANGE}" == "0" && "${COLS_ADDED}" == "0" && "${COLS_REMOVED}" == "0" && "${COLS_TYPE_CHANGED}" == "0" ]]; then
        echo "- No structural changes"
      fi
    fi

    echo ""
    echo "[Download proof](${PROOF_URL})"
  } >> "${GITHUB_STEP_SUMMARY}"
fi

# ── Step 10: Annotations ─────────────────────────────────────────
if [[ "${VERIFICATION}" == "FAIL" ]]; then
  # Build a concise failure message for the annotation
  FAIL_MSG="Snapshot integrity check failed for ${DATASET_PATH} v${VERSION}."
  if [[ "${DIFF_SUMMARY}" != "null" ]]; then
    CHANGES=""
    [[ "${ROW_CHANGE}" != "0" ]] && CHANGES="${CHANGES} rows: ${ROW_CHANGE},"
    [[ "${COLS_REMOVED}" != "0" ]] && CHANGES="${CHANGES} cols removed: ${COLS_REMOVED},"
    [[ "${COLS_TYPE_CHANGED}" != "0" ]] && CHANGES="${CHANGES} type changes: ${COLS_TYPE_CHANGED},"
    if [[ -n "${CHANGES}" ]]; then
      CHANGES="${CHANGES%,}"  # trim trailing comma
      FAIL_MSG="${FAIL_MSG} Changes:${CHANGES}"
    fi
  fi
  echo "::error title=VisiHub Verify Failed::${FAIL_MSG}"
else
  echo "::notice title=VisiHub Verify Passed::${DATASET_PATH} v${VERSION} — integrity check passed"
fi

# ── Step 11: Fail if checks failed ───────────────────────────────
if [[ "${FAIL_ON_CHECK}" == "true" && "${VERIFICATION}" == "FAIL" ]]; then
  exit 1
fi

echo ""
echo "VisiHub verification complete: ${DATASET_PATH} v${VERSION} = ${VERIFICATION}"
