#!/bin/bash

set -e

source .env

echo "=== Create Dispute Game ==="

DISPUTE_GAME_FACTORY=$(jq -r .DisputeGameFactoryProxy config-op/artifact.json)
L2OO_ADDRESS=$(jq -r .L2OutputOracleProxy config-op/artifact.json)

echo "DisputeGameFactory: $DISPUTE_GAME_FACTORY"
echo "L2OutputOracle: $L2OO_ADDRESS"
echo "Docker Network: $DOCKER_NETWORK"

# Create a dispute game (using incorrect root claim to trigger challenge)
GAME_TYPE=254  # CANNON game type
ROOT_CLAIM="0x0000000000000000000000000000000000000000000000000000000000000001"  # Incorrect root claim to trigger challenge
EXTRA_DATA="0x0000000000000000000000000000000000000000000000000000000000000001"  # L2 block number 1

echo "Dispute Game Parameters:"
echo "  Game Type: $GAME_TYPE" 
echo "  Root Claim: $ROOT_CLAIM (Incorrect root claim to trigger challenge)"
echo "  Extra Data: $EXTRA_DATA"

# Use op-stack image to create dispute game
echo "Creating Dispute Game..."

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

echo "✅ Dispute Game Created!"
echo ""
echo "Monitor op-challenger logs:"
echo "docker logs -f op-challenger"
echo ""
echo "If successful, you should see op-challenger start processing the dispute game!" 