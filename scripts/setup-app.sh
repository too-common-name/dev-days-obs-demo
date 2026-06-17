#!/bin/bash
set -e

GITHUB_TOKEN=${1:?"Usage: $0 <github-token>"}
GITOPS_BRANCH="demo-single-cluster"
GITOPS_RAW="https://raw.githubusercontent.com/too-common-name/myreadings-gitops/refs/heads/${GITOPS_BRANCH}"
NAMESPACE="myreadings-dev"
TIMEOUT=600
INTERVAL=15

echo "   [1/3] Creating GitOps bootstrap..."
oc apply -f "${GITOPS_RAW}/bootstrap.yaml"

echo "   [2/3] Waiting for ArgoCD applications..."
elapsed=0

# Phase 1: wait for at least one application to appear
count=0
while [ $elapsed -lt $TIMEOUT ]; do
  count=$(oc get applications -n openshift-gitops \
    -l app.kubernetes.io/part-of=myreadings -o json \
    | jq '.items | length')

  [ "$count" -gt 0 ] && break
  echo "     ⏳ No applications yet (${elapsed}s/${TIMEOUT}s)"
  sleep $INTERVAL
  elapsed=$((elapsed + INTERVAL))
done

if [ "$count" -eq 0 ]; then
  echo "   ❌ Timeout: no applications appeared after ${TIMEOUT}s"
  exit 1
fi
echo "     Found ${count} application(s), waiting for health..."

# Phase 2: wait for all to be Synced + Healthy
while [ $elapsed -lt $TIMEOUT ]; do
  not_ready=$(oc get applications -n openshift-gitops \
    -l app.kubernetes.io/part-of=myreadings -o json \
    | jq '[.items[] | select(.status.sync.status != "Synced" or .status.health.status != "Healthy")] | length')

  [ "$not_ready" -eq 0 ] && break
  echo "     ⏳ ${not_ready} app(s) not ready (${elapsed}s/${TIMEOUT}s)"
  sleep $INTERVAL
  elapsed=$((elapsed + INTERVAL))
done

if [ $elapsed -ge $TIMEOUT ]; then
  echo "   ❌ Timeout: applications not ready after ${TIMEOUT}s"
  oc get applications -n openshift-gitops -l app.kubernetes.io/part-of=myreadings
  exit 1
fi
echo "   ✅ All applications Synced and Healthy"

echo "   [3/3] Triggering CI pipelines..."
oc create secret generic github-token \
  --from-literal=".git-credentials=https://too-common-name:${GITHUB_TOKEN}@github.com" \
  --from-literal=".gitconfig=[credential \"https://github.com\"]
  helper = store" \
  -n "${NAMESPACE}" --dry-run=client -o yaml | oc apply -f -

oc create secret generic maven-settings \
  --from-file=settings.xml=/dev/stdin \
  -n "${NAMESPACE}" --dry-run=client -o yaml << 'EOF' | oc apply -f -
<settings>
  <servers>
    <server>
      <id>github</id>
      <username>too-common-name</username>
      <password>${GITHUB_TOKEN}</password>
    </server>
  </servers>
</settings>
EOF
