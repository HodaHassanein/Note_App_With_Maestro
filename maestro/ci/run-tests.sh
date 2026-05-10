#!/bin/bash
set -e

adb wait-for-device
adb shell input keyevent 82

adb install -r "$GITHUB_WORKSPACE/maestro/app/notepad-free.apk"

OUTPUT_XML="$GITHUB_WORKSPACE/maestro-results.xml"
FLOWS_DIR="$GITHUB_WORKSPACE/maestro/flows"

set +e
$HOME/.maestro/bin/maestro test \
  -e F01_NOTE_TITLE="Note Alpha" \
  -e F01_NOTE_BODY="body alpha" \
  -e F02_NOTE_TITLE="Note Beta" \
  -e F02_UNDO_FULL="Hello World" \
  -e F03_NEW_TITLE="Note Gamma" \
  -e F03_NEW_BODY="body gamma" \
  -e F06_COLOR_SWATCH="48%,52%" \
  -e F07_EXPORT_MARKER="export body" \
  --format junit \
  --output "$OUTPUT_XML" \
  "$FLOWS_DIR/01_new_note.yaml" \
  "$FLOWS_DIR/02_undo_in_editor.yaml" \
  "$FLOWS_DIR/03_edit_note.yaml" \
  "$FLOWS_DIR/05_delete_note.yaml" \
  "$FLOWS_DIR/06_select_all_colorize.yaml" \
  "$FLOWS_DIR/07_export_file.yaml"
MAESTRO_EXIT=$?
set -e

if [ $MAESTRO_EXIT -eq 0 ]; then
  echo "MAESTRO_STATUS=passed" >> $GITHUB_ENV
  STATUS="passed"
else
  echo "MAESTRO_STATUS=failed" >> $GITHUB_ENV
  STATUS="failed"
fi

if [ -f "$OUTPUT_XML" ]; then
  TOTAL=$(grep -c '<testcase' "$OUTPUT_XML" 2>/dev/null || echo 0)
  FAILED=$(grep -c '<failure' "$OUTPUT_XML" 2>/dev/null || echo 0)
  PASSED=$((TOTAL - FAILED))
else
  TOTAL=0; FAILED=0; PASSED=0
fi

mkdir -p "$GITHUB_WORKSPACE/reports/latest"
cat > "$GITHUB_WORKSPACE/reports/latest/report.txt" << REPORT
Last Maestro run (CI)
=====================
Time    : $(date '+%Y-%m-%d %H:%M:%S UTC')
Branch  : $GITHUB_REF_NAME
Trigger : $GITHUB_EVENT_NAME
Commit  : $GITHUB_SHA
Status  : $STATUS
Passed  : $PASSED
Failed  : $FAILED
Total   : $TOTAL
Run     : $GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID
REPORT

if [ -d "$HOME/.maestro/tests" ]; then
  cp -r "$HOME/.maestro/tests" "$GITHUB_WORKSPACE/reports/latest/maestro-artifacts" || true
fi

# Write summary directly to GitHub Actions job summary page
cat >> $GITHUB_STEP_SUMMARY << SUMMARY
## Maestro Test Results

| | |
|---|---|
| **Status** | $STATUS |
| **Passed** | $PASSED |
| **Failed** | $FAILED |
| **Total**  | $TOTAL |
| **Branch** | $GITHUB_REF_NAME |
| **Trigger**| $GITHUB_EVENT_NAME |
SUMMARY

if [ -f "$OUTPUT_XML" ] && [ "$FAILED" -gt 0 ]; then
  echo "" >> $GITHUB_STEP_SUMMARY
  echo "### Failed Flows" >> $GITHUB_STEP_SUMMARY
  grep -o 'name="[^"]*".*<failure[^>]*>[^<]*' "$OUTPUT_XML" 2>/dev/null | \
    sed 's/name="\([^"]*\)".*<failure[^>]*>\(.*\)/- ❌ \1: \2/' >> $GITHUB_STEP_SUMMARY || true
fi

exit $MAESTRO_EXIT
