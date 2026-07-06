#!/bin/bash
set -e

GROUP="${1:-all}"

PLATFORM_SUBS=("cluster-observability-operator:openshift-cluster-observability-operator" "loki-operator:openshift-operators-redhat" "opentelemetry-product:openshift-opentelemetry-operator" "tempo-operator:openshift-tracing" "lightspeed-operator:openshift-lightspeed")
APP_SUBS=("crunchy-postgres-operator:openshift-operators" "rhbk-operator:rhbk-operator")

case "$GROUP" in
    platform) SUBS=("${PLATFORM_SUBS[@]}") ;;
    app)      SUBS=("${APP_SUBS[@]}") ;;
    *)        SUBS=("${PLATFORM_SUBS[@]}" "${APP_SUBS[@]}") ;;
esac

TIMEOUT_SECONDS=300

echo "⏳ Checking Operator installation status (group: $GROUP)..."

for entry in "${SUBS[@]}"; do
    sub="${entry%%:*}"
    ns="${entry##*:}"

    echo "   👉 Verifying $sub in $ns..."

    start_time=$(date +%s)
    while true; do
        current_time=$(date +%s)
        elapsed=$((current_time - start_time))

        if [[ $elapsed -gt $TIMEOUT_SECONDS ]]; then
            echo "      ❌ Timeout waiting for Subscription '$sub' in '$ns' after ${TIMEOUT_SECONDS}s"
            exit 1
        fi

        CSV_NAME=$(oc get sub "$sub" -n "$ns" -o jsonpath='{.status.currentCSV}' 2>/dev/null)

        if [[ -z "$CSV_NAME" ]]; then
            echo "      - Waiting for OLM to resolve $sub..."
            sleep 5
            continue
        fi

        PHASE=$(oc get csv "$CSV_NAME" -n "$ns" -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")

        if [[ "$PHASE" == "Succeeded" ]]; then
            echo "      ✅ $CSV_NAME is Succeeded."
            break
        else
            echo "      - $CSV_NAME status is '$PHASE'..."
            sleep 5
        fi
    done
done

if [[ "$GROUP" == "app" || "$GROUP" == "all" ]]; then
    echo "   👉 Verifying RabbitMQ operator (non-OLM)..."
    start_time=$(date +%s)
    while true; do
        current_time=$(date +%s)
        elapsed=$((current_time - start_time))
        if [[ $elapsed -gt $TIMEOUT_SECONDS ]]; then
            echo "      ❌ Timeout waiting for RabbitMQ operator"
            exit 1
        fi
        READY=$(oc get deployment rabbitmq-cluster-operator -n rabbitmq-system -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
        if [[ "$READY" -ge 1 ]]; then
            echo "      ✅ RabbitMQ operator is ready."
            break
        fi
        echo "      - Waiting for RabbitMQ operator deployment..."
        sleep 5
    done
fi

echo "🚀 All operators are ready (group: $GROUP)."
