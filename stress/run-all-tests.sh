#!/bin/bash
set -euo pipefail

RESULTS=/home/drossi/Documents/experiments/developer_days_o11y/stress/test-results.txt
HELM_CHART=/home/drossi/Documents/experiments/refactoring_studies/myreadings-helm
NS=myreadings-dev
KC_HOST=$(oc get route myreadings-keycloak -n $NS -o jsonpath='https://{.spec.host}')
APP_HOST=$(oc get route myreadings-ui -n $NS -o jsonpath='https://{.spec.host}')
KC_TOKEN_URL="${KC_HOST}/realms/my-readings/protocol/openid-connect/token"
KC_ISSUER="${KC_HOST}/realms/my-readings"

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$RESULTS"; }

capture_metrics() {
  {
    echo "--- Pod Status ---"
    oc get pods -n $NS -l app.kubernetes.io/part-of=myreadings --no-headers | grep -v Completed
    echo ""
    echo "--- Pod Resources ---"
    oc adm top pods -n $NS --no-headers 2>/dev/null | grep -E 'catalog|readinglist|review|user-service'
    echo ""
    echo "--- HPAs ---"
    oc get hpa -n $NS --no-headers 2>/dev/null
    echo ""
    echo "--- Alerts ---"
    curl -sk "https://$(oc get route thanos-querier -n openshift-monitoring -o jsonpath='{.spec.host}')/api/v1/alerts" \
      -H "Authorization: Bearer $(oc whoami -t)" 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
alerts = d.get('data',{}).get('alerts',[])
for a in alerts:
    ns = a.get('labels',{}).get('namespace','')
    name = a.get('labels',{}).get('alertname','')
    if 'myreadings' in ns or name.startswith('App') or name.startswith('Search') or name.startswith('Container'):
        print(f'  {name:30s} state={a[\"state\"]:10s} severity={a[\"labels\"].get(\"severity\",\"?\")}')
" 2>/dev/null || echo "  (could not query alerts)"
  } | tee -a "$RESULTS"
}

run_locust() {
  local users=$1 duration=$2 label=$3
  podman rm -f myreadings-locust 2>/dev/null || true
  podman run -d --name myreadings-locust --network host \
    -v /home/drossi/Documents/experiments/developer_days_o11y/stress:/stress:Z \
    -e KC_TOKEN_URL="$KC_TOKEN_URL" \
    -e KC_CLIENT_ID="myreadings-client" \
    -e KC_USERNAME="drossi" \
    -e KC_PASSWORD="drossi" \
    docker.io/locustio/locust -f /stress/locustfile.py --host "$APP_HOST" \
    --headless -u "$users" -r 10 -t "$duration"
  log "Locust started: $label ($users users, $duration)"
}

wait_locust() {
  log "Waiting for Locust to finish..."
  while podman ps --filter name=myreadings-locust --format '{{.Names}}' 2>/dev/null | grep -q myreadings-locust; do
    sleep 10
  done
  log "Locust finished."
  echo "--- Locust Final Stats ---" >> "$RESULTS"
  podman logs myreadings-locust 2>&1 | tail -25 >> "$RESULTS"
  echo "" >> "$RESULTS"
}

deploy_healthy() {
  log "Deploying healthy baseline..."
  helm upgrade --install myreadings "$HELM_CHART" -n $NS --wait --timeout 5m \
    --set keycloak.tokenIssuer="$KC_ISSUER" \
    --set catalog.searchStrategy=normal
  sleep 30
}

# ============================================================
echo "" > "$RESULTS"
log "========================================="
log "AUTOMATED DEMO TUNING TESTS"
log "========================================="

# --- TEST 1: BASELINE (healthy, 100 users, 3 min) ---
log ""
log "=== TEST 1: BASELINE (healthy) ==="
deploy_healthy
log "Pods ready. Starting 100-user baseline..."
run_locust 100 3m "baseline"
sleep 90
log "Snapshot at 90s:"
capture_metrics
wait_locust
log "Baseline complete. Capturing final state..."
capture_metrics

# --- TEST 2: BREAK-APP ONLY (N+1, 100 users, 3 min) ---
log ""
log "=== TEST 2: BREAK-APP (N+1 search) ==="
log "Injecting N+1 regression..."
helm upgrade myreadings "$HELM_CHART" -n $NS --reuse-values --set catalog.searchStrategy=broken
sleep 45
log "Pods recycled. Starting 100-user test with N+1..."
run_locust 100 3m "break-app"
sleep 120
log "Snapshot at 120s:"
capture_metrics
wait_locust
log "break-app test complete. Capturing final state..."
capture_metrics

# --- Restore healthy before next test ---
log "Restoring healthy search..."
helm upgrade myreadings "$HELM_CHART" -n $NS --reuse-values --set catalog.searchStrategy=normal
sleep 45

# --- TEST 3: BREAK-INFRA ONLY (memory limit, 100 users, 3 min) ---
log ""
log "=== TEST 3: BREAK-INFRA (memory limit 450Mi on readinglist) ==="
log "Reducing readinglist memory limit..."
helm upgrade myreadings "$HELM_CHART" -n $NS --reuse-values \
  --set readinglist.resources.requests.memory=256Mi --set readinglist.resources.limits.memory=450Mi
sleep 45
log "Starting 100-user test with constrained memory..."
run_locust 100 3m "break-infra"
sleep 120
log "Snapshot at 120s:"
capture_metrics
wait_locust
log "break-infra test complete. Capturing final state..."
capture_metrics

# --- TEST 4: BOTH BREAKS (N+1 + memory, 100 users, 3 min) ---
log ""
log "=== TEST 4: BOTH BREAKS (N+1 + memory limit) ==="
log "Injecting both breaks..."
helm upgrade myreadings "$HELM_CHART" -n $NS --reuse-values \
  --set catalog.searchStrategy=broken \
  --set readinglist.resources.requests.memory=256Mi --set readinglist.resources.limits.memory=450Mi
sleep 60
log "Starting 100-user combined test..."
run_locust 100 3m "both-breaks"
sleep 120
log "Snapshot at 120s:"
capture_metrics
wait_locust
log "Combined test complete. Capturing final state..."
capture_metrics

# --- RESTORE HEALTHY ---
log ""
log "=== RESTORING HEALTHY STATE ==="
deploy_healthy
log "System restored to healthy state."

log ""
log "========================================="
log "ALL TESTS COMPLETE"
log "Results saved to: $RESULTS"
log "========================================="
