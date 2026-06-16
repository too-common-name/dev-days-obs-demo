#!/bin/bash
set -e

# Namespaces where Operators might be installed (check the file 00-project foreach operator folder in 00-operators)
NAMESPACES=("openshift-cluster-observability-operator" "openshift-operators-redhat" "openshift-logging" "openshift-opentelemetry-operator" "openshift-tracing" "openshift-netobserv-operator" "openshift-lightspeed")
TIMEOUT_SECONDS=300

echo "⏳ Checking Operator installation status..."

for ns in "${NAMESPACES[@]}"; do
    # Check if namespace exists
    if ! oc get project "$ns" &> /dev/null; then
        echo "   - Namespace $ns does not exist. Skipping."
        continue
    fi

    echo "   🔍 Checking namespace: $ns"
    
    # Get all Subscription names in this namespace
    SUBS=$(oc get sub -n "$ns" -o jsonpath='{.items[*].metadata.name}')

    if [[ -z "$SUBS" ]]; then
        echo "      - No Subscriptions found in $ns."
        continue
    fi

    for sub in $SUBS; do
        echo "      👉 Verifying Subscription: $sub"
        
        start_time=$(date +%s)
        while true; do
            current_time=$(date +%s)
            elapsed=$((current_time - start_time))

            if [[ $elapsed -gt $TIMEOUT_SECONDS ]]; then
                echo "      ❌ Timeout waiting for Subscription '$sub' in '$ns' after ${TIMEOUT_SECONDS}s"
                exit 1
            fi

            # Find the CSV name linked to this Subscription
            CSV_NAME=$(oc get sub "$sub" -n "$ns" -o jsonpath='{.status.currentCSV}')

            if [[ -z "$CSV_NAME" ]]; then
                echo "        - Waiting for OLM to resolve install plan for $sub..."
                sleep 5
                continue
            fi

            # Check status of CSV
            PHASE=$(oc get csv "$CSV_NAME" -n "$ns" -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")

            if [[ "$PHASE" == "Succeeded" ]]; then
                echo "        ✅ $CSV_NAME is Succeeded."
                break
            else
                echo "        - $CSV_NAME status is '$PHASE'..."
                sleep 5
            fi
        done
    done
done

echo "🚀 All Subscribed Operators are ready."