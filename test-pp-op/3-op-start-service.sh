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

docker compose up -d op-batcher

sleep 10
# TODO, we need to reseach and fix it,  0 block hash mismatch
LOG_OUTPUT=$(docker compose logs op-node 2>&1 | tail -20)
if echo "$LOG_OUTPUT" | grep -q "expected L2 genesis hash to match L2 block at genesis block number"; then
    CORRECT_HASH=$(echo "$LOG_OUTPUT" | grep "expected L2 genesis hash to match L2 block at genesis block number" | sed -n 's/.*genesis block number [0-9]*: \([0-9a-fx]*\) <>.*/\1/p' | head -1)
    if [ -n "$CORRECT_HASH" ]; then
        echo "Fixing genesis hash: $CORRECT_HASH"
        sed_inplace '/\"l2\":/,/}/ s/\"hash\": \"0x[a-fA-F0-9]*\"/\"hash\": \"'$CORRECT_HASH'\"/' ./config-op/rollup.json
        docker compose restart op-node
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

echo "Adding game type to DisputeGameFactory via op-deployer..."

RPC_URL=http://127.0.0.1:8545

# Retrieve existing values from chain for reference
# Get permissioned game implementation
PERMISSIONED_GAME_RAW=$(cast call --rpc-url $RPC_URL $DISPUTE_GAME_FACTORY_ADDRESS "gameImpls(uint32)" 1)
# Convert 32-byte hex to 20-byte address (last 40 hex chars, with 0x prefix)
PERMISSIONED_GAME="0x${PERMISSIONED_GAME_RAW: -40}"

# Retrieve parameters from existing permissioned game
ABSOLUTE_PRESTATE=$(cast call --rpc-url $RPC_URL $PERMISSIONED_GAME "absolutePrestate()")
MAX_GAME_DEPTH=$(cast call --rpc-url $RPC_URL $PERMISSIONED_GAME "maxGameDepth()")
SPLIT_DEPTH=$(cast call --rpc-url $RPC_URL $PERMISSIONED_GAME "splitDepth()")
CLOCK_EXTENSION=$(cast call --rpc-url $RPC_URL $PERMISSIONED_GAME "clockExtension()")
MAX_CLOCK_DURATION=$(cast call --rpc-url $RPC_URL $PERMISSIONED_GAME "maxClockDuration()")
VM_RAW=$(cast call --rpc-url $RPC_URL $PERMISSIONED_GAME "vm()")
VM="0x${VM_RAW: -40}"
ANCHOR_STATE_REGISTRY=$(cast call --rpc-url $RPC_URL $PERMISSIONED_GAME "anchorStateRegistry()")
L2_CHAIN_ID=$(cast call --rpc-url $RPC_URL $PERMISSIONED_GAME "l2ChainId()")


docker run --rm \
  --network "$DOCKER_NETWORK" \
  -v "$(pwd)/$CONFIG_DIR:/deployments" \
  -w /app/packages/contracts-bedrock/scripts/deploy \
  "${OP_STACK_IMAGE_TAG}" \
  bash -c "
    set -e
    
    echo '🚀 Executing AddGameType script...'
    forge script AddGameType.s.sol:AddGameType \
      --sig 'run((address,address,address,address,address,uint32,bytes32,uint256,uint256,uint64,uint64,uint256,address,bool,string))' \
      '($ADMIN_OWNER_ADDRESS,$OPCM_IMPL_ADDRESS,$SYSTEM_CONFIG_PROXY_ADDRESS,$PROXY_ADMIN,0x0000000000000000000000000000000000000000,0,$ABSOLUTE_PRESTATE,$MAX_GAME_DEPTH,$SPLIT_DEPTH,$CLOCK_EXTENSION,$MAX_CLOCK_DURATION,1000000000000000000,$VM,false,\"123\")' \
      --broadcast \
      --private-key $DEPLOYER_PRIVATE_KEY \
      --rpc-url $L1_RPC_URL_IN_DOCKER -vvvv
    
    echo '📋 Gathering contract addresses and generating calldata...'
    DISPUTE_GAME_FACTORY_ADDR=\$(cast call --rpc-url $L1_RPC_URL_IN_DOCKER $SYSTEM_CONFIG_PROXY_ADDRESS 'disputeGameFactory()(address)')
    OPTIMISM_PORTAL_ADDR=\$(cast call --rpc-url $L1_RPC_URL_IN_DOCKER $SYSTEM_CONFIG_PROXY_ADDRESS 'optimismPortal()(address)')
    echo 'disputeGameFactory: '\$DISPUTE_GAME_FACTORY_ADDR
    echo 'optimismPortal: '\$OPTIMISM_PORTAL_ADDR
    
    # Get anchorStateRegistry address with proper return type specification
    ANCHOR_STATE_REGISTRY_ADDR=\$(cast call --rpc-url $L1_RPC_URL_IN_DOCKER \$OPTIMISM_PORTAL_ADDR 'anchorStateRegistry()(address)')
    echo 'anchorStateRegistry: '\$ANCHOR_STATE_REGISTRY_ADDR
    
    GAME_ADDR=\$(cast call --rpc-url $L1_RPC_URL_IN_DOCKER \$DISPUTE_GAME_FACTORY_ADDR 'gameImpls(uint32)(address)' 0)
    echo 'gameImpls(0): '\$GAME_ADDR
    
    cast send \$ANCHOR_STATE_REGISTRY_ADDR 'setRespectedGameType(uint32)' 0 --rpc-url $L1_RPC_URL_IN_DOCKER --private-key $DEPLOYER_PRIVATE_KEY

    echo '✅ AddGameType operations completed successfully'
  "

# docker run \
#     --network "$DOCKER_NETWORK" \
#     -v "$(pwd)/$CONFIG_DIR:/deployments" \
#     -w /app \
#     "${OP_STACK_IMAGE_TAG}" \
#     bash -c "
#     set -e
#     /app/op-deployer/bin/op-deployer manage add-game-type \
#         --l1-rpc-url $L1_RPC_URL_IN_DOCKER \
#         --dispute-max-game-depth $MAX_GAME_DEPTH \
#         --dispute-split-depth $SPLIT_DEPTH \
#         --dispute-clock-extension $CLOCK_EXTENSION \
#         --dispute-max-clock-duration $MAX_CLOCK_DURATION \
#         --artifacts-locator file:///app/packages/contracts-bedrock/forge-artifacts \
#         --vm-address $VM \
#         --l1-proxy-admin-owner-address $ADMIN_OWNER_ADDRESS \
#         --opcm-impl-address $OPCM_IMPL_ADDRESS \
#         --system-config-proxy-address $SYSTEM_CONFIG_PROXY_ADDRESS \
#         --op-chain-proxy-admin-address $PROXY_ADMIN \
#         --dispute-game-type 0 \
#         --dispute-absolute-prestate $ABSOLUTE_PRESTATE \
#         --salt-mixer “123” \
#         --log.level debug \
#         --log.color true \
#         --permissionless \
#     " 2>&1 | tee add-game-type.log
# echo "add-game-type completed"

docker compose up -d op-proposer

docker compose up -d op-challenger
