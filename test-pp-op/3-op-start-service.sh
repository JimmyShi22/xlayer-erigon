set -e
set -x

sed_inplace() {
  if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i '' "$@"
  else
    sed -i "$@"
  fi
}

# Load environment variables early
source .env

# Start op-node first
echo "🚀 Starting op-node..."
docker compose up -d op-node

# Wait for op-node to be healthy (10 seconds + health check)
echo "⏳ Waiting for op-node to be healthy..."
sleep 12

echo "Adding game type to DisputeGameFactory via op-deployer..."

# Use curl to get outputRoot
OUTPUT_JSON=$(curl -s -X POST http://127.0.0.1:9545 \
  -H "Content-Type: application/json" \
  --data '{
    "jsonrpc": "2.0",
    "method": "optimism_outputAtBlock",
    "params": ["0x0"],
    "id": 1
  }')

# Extract outputRoot
OUTPUT_ROOT=$(echo "$OUTPUT_JSON" | jq -r '.result.outputRoot')

echo "Fetched outputRoot: $OUTPUT_ROOT"

docker run \
    --network "$DOCKER_NETWORK" \
    -v "$(pwd)/$CONFIG_DIR:/deployments" \
    -w /app \
    "${OP_STACK_IMAGE_TAG}" \
    bash -c "
    set -e
    /app/op-deployer/bin/op-deployer manage add-game-type \
        --l1-rpc-url $L1_RPC_URL_IN_DOCKER \
        --artifacts-locator file://deployments \
        --workdir /deployments \
        --l2-chain-id 195 \
        --dispute-game-type 0 \
        --dispute-absolute-prestate $OUTPUT_ROOT \
        --permissionless \
    "
echo "add-game-type completed"

# Start op-batcher and op-proposer (they will wait for op-node health check)
echo "🚀 Starting op-batcher and op-proposer..."
docker compose up -d op-batcher op-proposer

sleep 10
# TODO, we need to reseach and fix it,  0 block hash mismatch
LOG_OUTPUT=$(docker compose logs op-node 2>&1 | tail -20)
if echo "$LOG_OUTPUT" | grep -q "expected L2 genesis hash to match L2 block at genesis block number"; then
    CORRECT_HASH=$(echo "$LOG_OUTPUT" | grep "expected L2 genesis hash to match L2 block at genesis block number" | sed -n 's/.*genesis block number [0-9]*: \([0-9a-fx]*\) <>.*/\1/p' | head -1)
    if [ -n "$CORRECT_HASH" ]; then
        echo "Fixing genesis hash: $CORRECT_HASH"
        sed_inplace '/\"l2\":/,/}/ s/\"hash\": \"0x[a-fA-F0-9]*\"/\"hash\": \"'$CORRECT_HASH'\"/' ./config-op/rollup.json
        docker compose restart op-node op-proposer
    fi
fi

sleep 10

PWD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd $PWD_DIR
EXPORT_DIR="$PWD_DIR/data/cannon-data"
mkdir -p $EXPORT_DIR

# Note: The prestate files should already be generated in the Docker image during build
# If we need to regenerate them, we should use cannon directly, not op-challenger
echo "Checking for existing prestate files..."
if [ ! -f "$EXPORT_DIR/prestate.json.gz" ] || [ ! -f "$EXPORT_DIR/op-program" ]; then
    echo "Prestate files missing, copying from Docker image..."
    # Create temporary container to extract prestate files
    TEMP_CONTAINER="temp-prestate-extract"
    docker create --name "$TEMP_CONTAINER" "$OP_STACK_IMAGE_TAG"
    
    # Extract op-program and prestate files
    docker cp "$TEMP_CONTAINER":/app/op-program/bin/op-program "$EXPORT_DIR/op-program" || echo "Warning: Could not copy op-program"
    docker cp "$TEMP_CONTAINER":/app/op-program/bin/prestate.json "$EXPORT_DIR/prestate.json" || echo "Warning: Could not copy prestate.json"
    docker cp "$TEMP_CONTAINER":/app/op-program/bin/prestate-proof.json "$EXPORT_DIR/prestate-proof.json" || echo "Warning: Could not copy prestate-proof.json"
    docker cp "$TEMP_CONTAINER":/app/op-program/bin/meta.json "$EXPORT_DIR/meta.json" || echo "Warning: Could not copy meta.json"
    
    # Cleanup
    docker rm -f "$TEMP_CONTAINER"
    
    # Gzip prestate.json if it exists
    if [ -f "$EXPORT_DIR/prestate.json" ]; then
        gzip -c "$EXPORT_DIR/prestate.json" > "$EXPORT_DIR/prestate.json.gz"
        echo "✅ Created prestate.json.gz"
        
        # Calculate the actual prestate hash and update devnetL1.json if needed
        ACTUAL_HASH=$(sha256sum "$EXPORT_DIR/prestate.json.gz" | awk '{print $1}')
        DEVNET_L1_JSON="$PWD_DIR/config-op/devnetL1.json"
        if [ -f "$DEVNET_L1_JSON" ]; then
            CONFIGURED_HASH=$(jq -r '.faultGameAbsolutePrestate' "$DEVNET_L1_JSON" | sed 's/0x//')
            if [ "$ACTUAL_HASH" != "$CONFIGURED_HASH" ]; then
                echo "⚠️  Prestate hash mismatch detected!"
                echo "   Configured: 0x$CONFIGURED_HASH"
                echo "   Actual:     0x$ACTUAL_HASH"
                echo "   Updating devnetL1.json with correct hash..."
                
                # Update the hash in devnetL1.json
                jq --arg hash "0x$ACTUAL_HASH" '.faultGameAbsolutePrestate = $hash' "$DEVNET_L1_JSON" > "${DEVNET_L1_JSON}.tmp" && mv "${DEVNET_L1_JSON}.tmp" "$DEVNET_L1_JSON"
                echo "✅ Updated faultGameAbsolutePrestate in devnetL1.json"
            else
                echo "✅ Prestate hash matches configuration"
            fi
        fi
    fi
else
    echo "✅ Prestate files already exist"
fi

docker compose up -d op-challenger