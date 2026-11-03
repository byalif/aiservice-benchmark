#!/usr/bin/env bash
# ==============================================================================
# AI Capability Benchmark Runner (JMeter + OpenShift Metrics)
# ==============================================================================
set -e

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# Default benchmark tier settings
USERS="${1:-10}"
DURATION="${2:-180}" # in seconds (e.g. 180s for quick test, 3600s for 1-hr test)
MODEL_ID="${3:-s3dbe03f10c3a611f}"
NAMESPACE="${4:-aiservice-apmdevops-user}"
WORKLOAD_TYPE="${5:-single}" # 'single' (1 workorder) or 'batch_50' (50 workorders)
BENCHMARK_MODE="${6:-capability}" # 'capability' (direct pod) or 'e2e' (gateway route)
GATEWAY_HOST="${7:-aiservice.apps.aibrokerdev.cp.fyre.ibm.com}"
CAPABILITY="${8:-similarity}"

TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
RESULTS_DIR="${RESULTS_DIR:-$SCRIPT_DIR/../results/${MODEL_ID}_${USERS}users_${WORKLOAD_TYPE}_${TIMESTAMP}}"
mkdir -p "$RESULTS_DIR"

# Select Payload File based on Capability and Workload Type
if [ "$WORKLOAD_TYPE" == "batch_50" ]; then
    PAYLOAD_FILE="$SCRIPT_DIR/payloads/batch_50.json"
elif [ -f "$SCRIPT_DIR/payloads/${CAPABILITY}.json" ]; then
    PAYLOAD_FILE="$SCRIPT_DIR/payloads/${CAPABILITY}.json"
else
    PAYLOAD_FILE="$SCRIPT_DIR/payloads/single.json"
fi

# Async queue-based capabilities (fieldextractor, smartcleanse):
#   IS_ASYNC=true  → JMX submits job, extracts UUID, polls S3 until result
#                    appears, records end-to-end latency as a single sample.
#   Results are written to Ceph/NooBaa S3 (openshift-storage, svc/s3). The JMX
#   poll loop reaches it through a local port-forward over HTTPS, using the
#   tenant's km-s3-secret credentials. Credentials are exported as env vars
#   (inherited by JMeter and its python3 subprocess) so they never appear on a
#   command line. S3_PYTHON must be a python3 that has boto3 installed.
IS_ASYNC="false"
S3_LOCAL_PORT=""
S3_PF_PID=""

if [ "$CAPABILITY" == "fieldextractor" ] || [ "$CAPABILITY" == "smartcleanse" ]; then
    IS_ASYNC="true"
    S3_PYTHON="${S3_PYTHON:-python3}"
    if ! "$S3_PYTHON" -c "import boto3" 2>/dev/null; then
        echo "ERROR: '$S3_PYTHON' cannot import boto3 (needed to poll async results in Ceph S3)."
        echo "       Install it (pip install boto3) or set S3_PYTHON to an interpreter that has it."
        exit 1
    fi
    export S3_ACCESS_KEY S3_SECRET_KEY
    S3_ACCESS_KEY=$(oc get secret km-s3-secret -n "$NAMESPACE" -o jsonpath='{.data.S3_ACCESS_KEY}' | base64 -d)
    S3_SECRET_KEY=$(oc get secret km-s3-secret -n "$NAMESPACE" -o jsonpath='{.data.S3_SECRET_KEY}' | base64 -d)
    if [ -z "$S3_ACCESS_KEY" ] || [ -z "$S3_SECRET_KEY" ]; then
        echo "ERROR: Could not read S3 credentials from secret km-s3-secret in $NAMESPACE."
        exit 1
    fi
    S3_LOCAL_PORT=$("$S3_PYTHON" -c 'import socket; s=socket.socket(); s.bind(("",0)); print(s.getsockname()[1]); s.close()')
    oc port-forward -n openshift-storage svc/s3 "${S3_LOCAL_PORT}:443" \
        > "$RESULTS_DIR/s3_pf.log" 2>&1 &
    S3_PF_PID=$!
    for i in {1..8}; do
        nc -z localhost "$S3_LOCAL_PORT" 2>/dev/null && { echo "Ceph S3 tunnel ready on port $S3_LOCAL_PORT."; break; }
        sleep 1
    done
    DEFAULT_THINK_TIME=500
    DEFAULT_RANDOM_DELAY=200
else
    DEFAULT_THINK_TIME=1000
    DEFAULT_RANDOM_DELAY=1000
fi

echo "=========================================================="
echo " Starting AI Capability Benchmark"
echo " Model ID:      $MODEL_ID"
echo " Namespace:     $NAMESPACE"
echo " Users:         $USERS concurrent users"
echo " Duration:      $DURATION seconds"
echo " Workload:      $WORKLOAD_TYPE ($PAYLOAD_FILE)"
echo " Mode:          $BENCHMARK_MODE"
echo " Output Dir:    $RESULTS_DIR"
echo "=========================================================="

# 1. Fetch live OpenShift Token
echo "[1/4] Authenticating with OpenShift..."
TOKEN=$(oc whoami -t 2>/dev/null || true)
if [ -z "$TOKEN" ]; then
    echo "ERROR: Not logged into OpenShift. Run 'oc login' first."
    exit 1
fi

# 2. Locate the Pod for port-forwarding and metrics
POD_NAME=$(oc get pods -n "$NAMESPACE" -l km/model-id="$MODEL_ID" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [ -z "$POD_NAME" ]; then
    # Fallback search by prefix
    POD_NAME=$(oc get pods -n "$NAMESPACE" | grep "$MODEL_ID" | awk '{print $1}' | head -n 1)
fi

if [ -z "$POD_NAME" ]; then
    echo "ERROR: Could not find pod for model $MODEL_ID in namespace $NAMESPACE"
    exit 1
fi
echo "Target Pod: $POD_NAME"

# 3. Record Initial / Idle Resource Footprint
echo "[2/4] Capturing Initial Pod Resource Usage..."
oc adm top pod "$POD_NAME" -n "$NAMESPACE" > "$RESULTS_DIR/initial_resources.txt" 2>/dev/null || echo "Metrics unavailable yet" > "$RESULTS_DIR/initial_resources.txt"
cat "$RESULTS_DIR/initial_resources.txt"

# 4. Configure Endpoint Target & Dynamic Tunneling
if [ "$BENCHMARK_MODE" == "e2e" ]; then
    echo "[3/4] Targeting External AI Gateway Route ($GATEWAY_HOST)..."
    TARGET_HOST="$GATEWAY_HOST"
    TARGET_PORT="443"
    TARGET_PATH="/api/v1/predict"
    PROTOCOL="https"
    PF_PID=""
else
    # Always port-forward to port 8080 (plain HTTP KServe predictor).
    # The oauth-proxy sidecar sits on 8443 (HTTPS) but we bypass it in
    # capability mode — JMeter sends the OC bearer token directly to 8080.
    LOCAL_PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("",0)); print(s.getsockname()[1]); s.close()' 2>/dev/null || echo "8080")
    PROTOCOL="http"

    echo "[3/4] Starting tunnel: localhost:${LOCAL_PORT} -> ${POD_NAME}:8080..."
    TARGET_HOST="localhost"
    TARGET_PORT="$LOCAL_PORT"
    TARGET_PATH="/v1/models/${MODEL_ID}:predict"

    oc port-forward -n "$NAMESPACE" "pod/$POD_NAME" "${LOCAL_PORT}:8080" > "$RESULTS_DIR/port_forward.log" 2>&1 &
    PF_PID=$!
    trap "kill -9 $PF_PID 2>/dev/null || true" EXIT

    for i in {1..10}; do
        if grep -q "Forwarding from" "$RESULTS_DIR/port_forward.log" 2>/dev/null || nc -z localhost "$LOCAL_PORT" 2>/dev/null; then
            echo "Tunnel ready on port $LOCAL_PORT."
            break
        fi
        sleep 1
    done
fi

# 5. Run JMeter Headless Workload & Background Metrics Sampler
echo "[4/4] Executing JMeter Load Workload ($USERS users for ${DURATION}s, Workload: $WORKLOAD_TYPE)..."

# Start background resource logger every 5 seconds
(
  while true; do
    echo -n "$(date +%T) " >> "$RESULTS_DIR/cpu_memory_over_time.log"
    oc adm top pod "$POD_NAME" -n "$NAMESPACE" --no-headers 2>/dev/null >> "$RESULTS_DIR/cpu_memory_over_time.log" || true
    sleep 5
  done
) &
LOGGER_PID=$!
trap "kill -9 $PF_PID $LOGGER_PID $S3_PF_PID 2>/dev/null || true" EXIT

# Token counting: JMeter appends each response's "usage" list to this file
# (one JSON object per line); it is summed into token_usage.json after the run.
USAGE_FILE="$RESULTS_DIR/token_usage.jsonl"
: > "$USAGE_FILE"

# Run JMeter with absolute path to .jmx
jmeter -n \
  -JUSAGE_FILE="$USAGE_FILE" \
  -t "$SCRIPT_DIR/jmeter_similarity_test.jmx" \
  -JHOST="$TARGET_HOST" \
  -JPORT="$TARGET_PORT" \
  -JPROTOCOL="$PROTOCOL" \
  -JPATH="$TARGET_PATH" \
  -JTOKEN="$TOKEN" \
  -JUSERS="$USERS" \
  -JDURATION="$DURATION" \
  -JRAMP_UP="${RAMP_UP:-5}" \
  -JTHINK_TIME="${THINK_TIME:-$DEFAULT_THINK_TIME}" \
  -JRANDOM_DELAY="${RANDOM_DELAY:-$DEFAULT_RANDOM_DELAY}" \
  -JMODEL_ID="$MODEL_ID" \
  -JPAYLOAD_FILE="$PAYLOAD_FILE" \
  -JIS_ASYNC="$IS_ASYNC" \
  -JS3_HOST="localhost" \
  -JS3_PORT="${S3_LOCAL_PORT:-443}" \
  -JS3_PYTHON="${S3_PYTHON:-python3}" \
  -JASYNC_POLL_INTERVAL_MS="${ASYNC_POLL_INTERVAL_MS:-5000}" \
  -JASYNC_TIMEOUT_MS="${ASYNC_TIMEOUT_MS:-300000}" \
  -l "$RESULTS_DIR/run.jtl" \
  -e -o "$RESULTS_DIR/html_report"

# Sum token usage per model_type / model_name (input, output, total)
python3 - "$USAGE_FILE" "$RESULTS_DIR/token_usage.json" <<'PYEOF'
import json, sys
src, dst = sys.argv[1], sys.argv[2]
responses = with_usage = 0
models = {}
for line in open(src):
    line = line.strip()
    if not line:
        continue
    try:
        usage = json.loads(line).get("usage", [])
    except ValueError:
        continue
    responses += 1
    if not usage:
        continue
    with_usage += 1
    for u in usage:
        key = (u.get("model_type", "unknown"), u.get("model_name") or "not reported")
        m = models.setdefault(key, {"input_tokens": 0, "output_tokens": 0})
        m["input_tokens"] += int(u.get("input_token_count", u.get("input_tokens", 0)) or 0)
        m["output_tokens"] += int(u.get("output_token_count", u.get("output_tokens", 0)) or 0)
rows = [{"model_type": k[0], "model_name": k[1], **v, "total_tokens": v["input_tokens"] + v["output_tokens"]}
        for k, v in sorted(models.items())]
out = {
    "responses_counted": responses,
    "responses_with_usage": with_usage,
    "models": rows,
    "input_tokens": sum(r["input_tokens"] for r in rows),
    "output_tokens": sum(r["output_tokens"] for r in rows),
    "total_tokens": sum(r["total_tokens"] for r in rows),
}
json.dump(out, open(dst, "w"), indent=2)
print("Token usage: %d in, %d out, %d total (%d of %d responses reported usage)" % (
    out["input_tokens"], out["output_tokens"], out["total_tokens"], with_usage, responses))
PYEOF

kill -9 $LOGGER_PID 2>/dev/null || true
if [ -n "$PF_PID" ]; then
    kill -9 $PF_PID 2>/dev/null || true
fi

echo "=========================================================="
echo " Benchmark Run Complete!"
echo " HTML Dashboard:  $RESULTS_DIR/html_report/index.html"
echo " Resource Log:    $RESULTS_DIR/cpu_memory_over_time.log"
echo " Open report via: open $RESULTS_DIR/html_report/index.html"
echo "=========================================================="
