#!/bin/bash
set -e

# Directories (Relative to repo root)
BASE_DIR="infrastructure/01-platform"
TEMPLATE_DIR="$BASE_DIR/templates"
GEN_DIR="$BASE_DIR/_generated"

mkdir -p $GEN_DIR

# Configuration Targets
LOKI_NS="openshift-logging"
LOKI_OBC="loki-demo-bucket"

TEMPO_NS="openshift-tracing"
TEMPO_OBC="tempostack-demo-bucket"

# Function to process a single stack
process_secret() {
    local TYPE=$1      # "loki", "tempo" or "netobserv"
    local NS=$2        # Namespace
    local OBC_NAME=$3  # OBC Name
    local TEMPLATE_FILE="$TEMPLATE_DIR/$TYPE-secret.yaml"
    local OUTPUT_FILE="$GEN_DIR/$TYPE-secret-final.yaml"

    echo "🔄 [Storage] Processing $TYPE in namespace $NS..."

    if [[ ! -f "$TEMPLATE_FILE" ]]; then
        echo "   ❌ Template not found: $TEMPLATE_FILE"
        exit 1
    fi

    # Wait for OBC to be Bound
    echo "   ⏳ Waiting for OBC '$OBC_NAME' to be Bound..."
    while true; do
        PHASE=$(oc get obc $OBC_NAME -n $NS -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
        if [[ "$PHASE" == "Bound" ]]; then
            echo "      ✅ OBC is Bound."
            break
        fi
        sleep 5
    done

    # Extract encoded Credentials
    B64_ACCESS_KEY=$(oc get secret $OBC_NAME -n $NS -o jsonpath='{.data.AWS_ACCESS_KEY_ID}')
    B64_SECRET_KEY=$(oc get secret $OBC_NAME -n $NS -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}')
    
    # Extract Endpoint Configuration
    BUCKET_NAME=$(oc get configmap $OBC_NAME -n $NS -o jsonpath='{.data.BUCKET_NAME}')
    BUCKET_HOST=$(oc get configmap $OBC_NAME -n $NS -o jsonpath='{.data.BUCKET_HOST}')
    BUCKET_PORT=$(oc get configmap $OBC_NAME -n $NS -o jsonpath='{.data.BUCKET_PORT}')

    # Construct Endpoint URL
    if [[ "$BUCKET_PORT" == "443" ]]; then
        ENDPOINT="https://${BUCKET_HOST}"
    else
        ENDPOINT="https://${BUCKET_HOST}:${BUCKET_PORT}"
    fi
    
    echo "      - Discovered Endpoint: $ENDPOINT"
    echo "      - Discovered Bucket: $BUCKET_NAME"

    # Encode for Kubernetes Secret
    B64_BUCKET=$(echo -n "$BUCKET_NAME" | base64 -w0)
    B64_ENDPOINT=$(echo -n "$ENDPOINT" | base64 -w0)

    # Fill Template using yq
    echo "   📝 Generating secret manifest..."
    
    if [[ "$TYPE" == "loki" ]] || [ "$TYPE" == "netobserv" ]; then
        yq eval "del(.stringData) | \
                 .data.bucketnames = \"$B64_BUCKET\" | \
                 .data.endpoint = \"$B64_ENDPOINT\" | \
                 .data.access_key_id = \"$B64_ACCESS_KEY\" | \
                 .data.access_key_secret = \"$B64_SECRET_KEY\"" \
                 $TEMPLATE_FILE > $OUTPUT_FILE
                 
    elif [[ "$TYPE" == "tempo" ]]; then
        yq eval "del(.stringData) | \
                 .data.bucket = \"$B64_BUCKET\" | \
                 .data.endpoint = \"$B64_ENDPOINT\" | \
                 .data.access_key_id = \"$B64_ACCESS_KEY\" | \
                 .data.access_key_secret = \"$B64_SECRET_KEY\"" \
                 $TEMPLATE_FILE > $OUTPUT_FILE
    fi

    # Apply
    oc apply -f $OUTPUT_FILE
    echo "   ✅ Secret applied to $NS."
}

# Execute
process_secret "loki" $LOKI_NS $LOKI_OBC
process_secret "tempo" $TEMPO_NS $TEMPO_OBC

echo "🎉 Storage setup complete."