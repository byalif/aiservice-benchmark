#!/usr/bin/env bash
# AI capability benchmark runner (JMeter + OpenShift metrics)
set -e

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

USERS="${1:-10}"
DURATION="${2:-180}" # seconds
MODEL_ID="${3:-s3dbe03f10c3a611f}"
NAMESPACE="${4:-aiservice-user}"
WORKLOAD_TYPE="${5:-single}" # 'single' or 'batch_50'
BENCHMARK_MODE="${6:-capability}" # 'capability' (direct pod) or 'e2e' (gateway route)
GATEWAY_HOST="${7:-aiservice.apps.aibrokerdev.cp.fyre.ibm.com}"
CAPABILITY="${8:-similarity}"

TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
RESULTS_DIR="${RESULTS_DIR:-$SCRIPT_DIR/../results/${MODEL_ID}_${USERS}users_${WORKLOAD_TYPE}_${TIMESTAMP}}"
mkdir -p "$RESULTS_DIR"

# Pick payload file
if [ "$WORKLOAD_TYPE" == "batch_50" ]; then
    PAYLOAD_FILE="$SCRIPT_DIR/payloads/batch_50.json"
elif [ -f "$SCRIPT_DIR/payloads/${CAPABILITY}.json" ]; then
    PAYLOAD_FILE="$SCRIPT_DIR/payloads/${CAPABILITY}.json"
else
    PAYLOAD_FILE="$SCRIPT_DIR/payloads/single.json"
fi

# Async capabilities (fieldextractor, smartcleanse) poll S3 for the result,
# so port-forward MinIO and pass its host/port to JMeter.
IS_ASYNC="false"
S3_LOCAL_PORT=""
MINIO_PF_PID=""

if [ "$CAPABILITY" == "fieldextractor" ] || [ "$CAPABILITY" == "smartcleanse" ]; then
    IS_ASYNC="true"
    S3_LOCAL_PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("",0)); print(s.getsockname()[1]); s.close()')
    oc port-forward -n minio svc/minio-service "${S3_LOCAL_PORT}:9000" \
        > "$RESULTS_DIR/minio_pf.log" 2>&1 &
    MINIO_PF_PID=$!
    for i in {1..8}; do
        nc -z localhost "$S3_LOCAL_PORT" 2>/dev/null && { echo "MinIO tunnel ready on port $S3_LOCAL_PORT."; break; }
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

# 1. Get OpenShift token
echo "[1/4] Authenticating with OpenShift..."
TOKEN=$(oc whoami -t 2>/dev/null || true)
if [ -z "$TOKEN" ]; then
    echo "ERROR: Not logged into OpenShift. Run 'oc login' first."
    exit 1
fi

# 2. Find the pod
POD_NAME=$(oc get pods -n "$NAMESPACE" -l km/model-id="$MODEL_ID" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [ -z "$POD_NAME" ]; then
    # Fallback: search by name
    POD_NAME=$(oc get pods -n "$NAMESPACE" | grep "$MODEL_ID" | awk '{print $1}' | head -n 1)
fi

if [ -z "$POD_NAME" ]; then
    echo "ERROR: Could not find pod for model $MODEL_ID in namespace $NAMESPACE"
    exit 1
fi
echo "Target Pod: $POD_NAME"

# 3. Record initial resource usage
echo "[2/4] Capturing Initial Pod Resource Usage..."
oc adm top pod "$POD_NAME" -n "$NAMESPACE" > "$RESULTS_DIR/initial_resources.txt" 2>/dev/null || echo "Metrics unavailable yet" > "$RESULTS_DIR/initial_resources.txt"
cat "$RESULTS_DIR/initial_resources.txt"

# 4. Set up target and tunnel
if [ "$BENCHMARK_MODE" == "e2e" ]; then
    echo "[3/4] Targeting External AI Gateway Route ($GATEWAY_HOST)..."
    TARGET_HOST="$GATEWAY_HOST"
    TARGET_PORT="443"
    TARGET_PATH="/api/v1/predict"
    PROTOCOL="https"
    PF_PID=""
else
    # Port-forward to the predictor on 8080, bypassing the oauth-proxy on 8443.
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

# 5. Run JMeter with a background resource sampler
echo "[4/4] Executing JMeter Load Workload ($USERS users for ${DURATION}s, Workload: $WORKLOAD_TYPE)..."

# Log pod CPU/memory every 5 seconds
(
  while true; do
    echo -n "$(date +%T) " >> "$RESULTS_DIR/cpu_memory_over_time.log"
    oc adm top pod "$POD_NAME" -n "$NAMESPACE" --no-headers 2>/dev/null >> "$RESULTS_DIR/cpu_memory_over_time.log" || true
    sleep 5
  done
) &
LOGGER_PID=$!
trap "kill -9 $PF_PID $LOGGER_PID $MINIO_PF_PID 2>/dev/null || true" EXIT

jmeter -n \
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
  -JS3_PORT="${S3_LOCAL_PORT:-9000}" \
  -JS3_USER="${S3_USER:-minio}" \
  -JS3_PASS="${S3_PASS:-minio123}" \
  -JASYNC_POLL_INTERVAL_MS="${ASYNC_POLL_INTERVAL_MS:-5000}" \
  -JASYNC_TIMEOUT_MS="${ASYNC_TIMEOUT_MS:-300000}" \
  -l "$RESULTS_DIR/run.jtl" \
  -e -o "$RESULTS_DIR/html_report"

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
