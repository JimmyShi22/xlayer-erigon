#!/bin/bash

set -e

source .env

echo "=== Create Dispute Game ==="

DISPUTE_GAME_FACTORY=$(jq -r .DisputeGameFactoryProxy config-op/artifact.json)
L2OO_ADDRESS=$(jq -r .L2OutputOracleProxy config-op/artifact.json)

echo "DisputeGameFactory: $DISPUTE_GAME_FACTORY"
echo "L2OutputOracle: $L2OO_ADDRESS"
echo "Docker Network: $DOCKER_NETWORK"

# Target block number for challenge
TARGET_BLOCK=10
TARGET_BLOCK_HEX="0xa"

# Get the actual state root for block 10
echo "Fetching L2 block $TARGET_BLOCK information..."
BLOCK_INFO=$(docker run --rm --network "$DOCKER_NETWORK" "$OP_STACK_IMAGE_TAG" cast block $TARGET_BLOCK --rpc-url http://op-geth:8545)
CORRECT_STATE_ROOT=$(echo "$BLOCK_INFO" | grep "stateRoot" | awk '{print $2}')

echo "Block $TARGET_BLOCK stateRoot: $CORRECT_STATE_ROOT"

# Create an incorrect root claim by flipping some bits in the correct state root
# Flip the last byte to create an incorrect but plausible root claim
INCORRECT_ROOT_CLAIM="${CORRECT_STATE_ROOT%??}99"
echo "Using incorrect root claim (last byte flipped): $INCORRECT_ROOT_CLAIM"
echo "Correct state root would be: $CORRECT_STATE_ROOT"

# Create dispute game parameters
GAME_TYPE=0    # CANNON (MIPS32) game type
ROOT_CLAIM="$INCORRECT_ROOT_CLAIM"  # Incorrect root claim to trigger challenge
EXTRA_DATA="0x000000000000000000000000000000000000000000000000000000000000000a"  # L2 block number 10 (0xa)

echo "Dispute Game Parameters:"
echo "  Game Type: $GAME_TYPE (CANNON/MIPS32)"
echo "  Root Claim: $ROOT_CLAIM (Incorrect to trigger challenge)"
echo "  Extra Data: $EXTRA_DATA (L2 block number $TARGET_BLOCK)"
echo "  Target Block: $TARGET_BLOCK"

# Verify our parameters make sense
if [ "$ROOT_CLAIM" = "$CORRECT_STATE_ROOT" ]; then
    echo "⚠️  WARNING: ROOT_CLAIM matches correct state root - this may not trigger a challenge!"
    echo "Consider using a different incorrect value."
fi

# Use op-stack image to create dispute game
echo "Creating Dispute Game for block $TARGET_BLOCK..."

docker run --rm \
  --network "$DOCKER_NETWORK" \
  -e "L1_RPC_URL=$L1_RPC_URL_IN_DOCKER" \
  -e "PRIVATE_KEY=$DEPLOYER_PRIVATE_KEY" \
  "$OP_STACK_IMAGE_TAG" \
  cast send \
  --rpc-url "$L1_RPC_URL_IN_DOCKER" \
  --private-key "$DEPLOYER_PRIVATE_KEY" \
  "$DISPUTE_GAME_FACTORY" \
  "create(uint32,bytes32,bytes)" \
  "$GAME_TYPE" \
  "$ROOT_CLAIM" \
  "$EXTRA_DATA" \
  --gas-limit 1000000

echo "✅ Dispute Game Created for block $TARGET_BLOCK!"
echo ""
echo "Monitor op-challenger logs with:"
echo "docker logs -f op-challenger"
echo ""
echo "The op-challenger should detect the incorrect root claim and start challenging it."
echo "Expected behavior:"
echo "  1. op-challenger validates the root claim against L2 block $TARGET_BLOCK"
echo "  2. Detects the mismatch between claimed ($ROOT_CLAIM) and actual ($CORRECT_STATE_ROOT)"
echo "  3. Initiates challenge process" 