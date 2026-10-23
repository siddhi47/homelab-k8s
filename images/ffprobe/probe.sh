#!/bin/sh
# probe <input> <key>
#   <input>  local path or http(s) URL (e.g. an S3 presigned URL)
#   <key>    identifier echoed back in the result
# Writes {"key", "probe"} or {"key", "error"} to /airflow/xcom/return.json,
# which KubernetesPodOperator(do_xcom_push=True) returns as the task's XCom.
# Always exits 0 on a bad file, so one corrupt upload doesn't fail the batch:
# the error is recorded in the manifest instead.
set -u
in="$1"; key="$2"; out=/airflow/xcom/return.json
mkdir -p /airflow/xcom
if ffprobe -v error -print_format json -show_format -show_streams "$in" > /tmp/probe.json 2> /tmp/err; then
  jq -c --arg key "$key" '{key: $key, probe: .}' /tmp/probe.json > "$out"
else
  jq -nc --arg key "$key" --arg err "$(head -c 1000 /tmp/err)" '{key: $key, error: $err}' > "$out"
fi
cat "$out"
