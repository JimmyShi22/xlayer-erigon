set -e
set -x

sed_inplace() {
  if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i '' "$@"
  else
    sed -i "$@"
  fi
}

docker compose up -d op-proposer

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

source .env
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
    fi
else
    echo "✅ Prestate files already exist"
fi

docker compose up -d op-challenger