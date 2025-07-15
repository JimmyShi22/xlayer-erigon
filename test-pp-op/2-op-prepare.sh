set -e
set -x

sed_inplace() {
  if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i '' "$@"
  else
    sed -i "$@"
  fi
}


docker-compose stop xlayer-seq
docker-compose stop xlayer-rpc

docker-compose stop xlayer-bridge-service
docker-compose stop xlayer-bridge-ui
docker-compose stop xlayer-agg-sender

docker-compose stop xlayer-agglayer
docker-compose stop xlayer-agglayer-prover

LOG_OUTPUT=$(docker compose logs xlayer-seq 2>&1 | tail -100)
echo "LOG_OUTPUT: $LOG_OUTPUT"

FORK_BLOCK=$(echo "$LOG_OUTPUT" | grep "Finish block" | tail -1 | sed -n 's/.*Finish block \([0-9]*\) with.*/\1/p')
echo "FORK_BLOCK=$FORK_BLOCK"
sed_inplace "s/FORK_BLOCK=.*/FORK_BLOCK=$FORK_BLOCK/" .env

PWD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$PWD_DIR")"
TMP_DIR="$PWD_DIR/tmp"

cd $TMP_DIR

if [ ! -d "optimism" ]; then
    echo "Cloning Optimism repository..."
    git clone -b googgoog/fix-add-game-type-cli https://github.com/googgoog/optimism.git
    cp $PWD_DIR/op-docker/Dockerfile-opstack optimism/Dockerfile
    cd optimism
    docker build -t op-stack:v1.13.4 .
    cd ..
fi

if [ ! -d "op-geth" ]; then
    echo "Cloning op-geth repository..."
    git clone -b v1.101511.0 https://github.com/ethereum-optimism/op-geth.git
    cp $PWD_DIR/op-docker/Dockerfile-opgeth op-geth/Dockerfile
    cd op-geth
    docker build -t op-geth:v1.101511.0 .
    cd ..
fi

cd $PWD_DIR

source .env

# Ensure prestate files exist and devnetL1.json is consistent before deploying contracts
EXPORT_DIR="$PWD_DIR/data/cannon-data"
mkdir -p $EXPORT_DIR

echo "Checking prestate consistency before contract deployment..."
if [ ! -f "$EXPORT_DIR/prestate-proof-mt64.json.gz" ] || [ ! -f "$EXPORT_DIR/op-program" ]; then
    echo "Extracting prestate files from Docker image..."
    TEMP_CONTAINER="temp-prestate-extract"
    docker create --name "$TEMP_CONTAINER" "$OP_STACK_IMAGE_TAG"
    
    docker cp "$TEMP_CONTAINER":/app/op-program/bin/op-program "$EXPORT_DIR/op-program" || echo "Warning: Could not copy op-program"
    docker cp "$TEMP_CONTAINER":/app/op-program/bin/prestate-proof-mt64.json "$EXPORT_DIR/prestate-proof-mt64.json" || echo "Warning: Could not copy prestate-proof-mt64.json"
    
    docker rm -f "$TEMP_CONTAINER"
    
    if [ -f "$EXPORT_DIR/prestate-proof-mt64.json" ]; then
        gzip -c "$EXPORT_DIR/prestate-proof-mt64.json" > "$EXPORT_DIR/prestate-proof-mt64.json.gz"
        echo "✅ Created prestate-proof-mt64.json.gz"
    fi
fi

# Verify and update prestate hash in devnetL1.json
if [ -f "$EXPORT_DIR/prestate-proof-mt64.json.gz" ]; then
    ACTUAL_HASH=$(sha256sum "$EXPORT_DIR/prestate-proof-mt64.json.gz" | awk '{print $1}')
    DEVNET_L1_JSON="$PWD_DIR/config-op/devnetL1.json"
    
    if [ -f "$DEVNET_L1_JSON" ]; then
        CONFIGURED_HASH=$(jq -r '.faultGameAbsolutePrestate' "$DEVNET_L1_JSON" | sed 's/0x//')
        if [ "$ACTUAL_HASH" != "$CONFIGURED_HASH" ]; then
            echo "⚠️  Updating prestate hash in devnetL1.json for contract deployment"
            echo "   Old: 0x$CONFIGURED_HASH"
            echo "   New: 0x$ACTUAL_HASH"
            
            jq --arg hash "0x$ACTUAL_HASH" '.faultGameAbsolutePrestate = $hash' "$DEVNET_L1_JSON" > "${DEVNET_L1_JSON}.tmp" && mv "${DEVNET_L1_JSON}.tmp" "$DEVNET_L1_JSON"
            echo "✅ Updated faultGameAbsolutePrestate for contract deployment"
        else
            echo "✅ Prestate hash is consistent in devnetL1.json"
        fi
    fi
fi

echo "🔧 Bootstrapping superchain with op-deployer..."

docker run \
  --network "$DOCKER_NETWORK" \
  -v "$(pwd)/$CONFIG_DIR:/deployments" \
  -w /app \
  "${OP_STACK_IMAGE_TAG}" \
  bash -c "
    set -e
    /app/op-deployer/bin/op-deployer bootstrap superchain \
      --l1-rpc-url $L1_RPC_URL_IN_DOCKER \
      --private-key $DEPLOYER_PRIVATE_KEY \
      --artifacts-locator file:///app/packages/contracts-bedrock/forge-artifacts \
      --superchain-proxy-admin-owner $ADMIN_OWNER_ADDRESS \
      --protocol-versions-owner $ADMIN_OWNER_ADDRESS \
      --guardian $ADMIN_OWNER_ADDRESS \
      --outfile /deployments/superchain.json
  "

echo "🔧 Bootstrapping implementations with op-deployer..."

SUPERCHAIN_JSON="$CONFIG_DIR/superchain.json"
PROTOCOL_VERSIONS_PROXY=$(jq -r '.protocolVersionsProxyAddress' "$SUPERCHAIN_JSON")
SUPERCHAIN_CONFIG_PROXY=$(jq -r '.superchainConfigProxyAddress' "$SUPERCHAIN_JSON")
PROXY_ADMIN=$(jq -r '.proxyAdminAddress' "$SUPERCHAIN_JSON")

docker run \
  --network "$DOCKER_NETWORK" \
  -v "$(pwd)/$CONFIG_DIR:/deployments" \
  -w /app \
  "${OP_STACK_IMAGE_TAG}" \
  bash -c "
    set -e
    /app/op-deployer/bin/op-deployer bootstrap implementations \
      --artifacts-locator file:///app/packages/contracts-bedrock/forge-artifacts \
      --l1-rpc-url $L1_RPC_URL_IN_DOCKER \
      --outfile /deployments/implementations.json \
      --mips-version "7" \
      --private-key $DEPLOYER_PRIVATE_KEY \
      --protocol-versions-proxy $PROTOCOL_VERSIONS_PROXY \
      --superchain-config-proxy $SUPERCHAIN_CONFIG_PROXY \
      --superchain-proxy-admin $PROXY_ADMIN \
      --upgrade-controller $ADMIN_OWNER_ADDRESS
  "

cp ./config-op/intent.toml.bak ./config-op/intent.toml
cp ./config-op/state.json.bak ./config-op/state.json

# Read opcmAddress from implementations.json and write it into intent.toml
OPCM_ADDRESS=$(jq -r '.opcmAddress' ./config-op/implementations.json)
if [ -z "$OPCM_ADDRESS" ] || [ "$OPCM_ADDRESS" = "null" ]; then
  echo "❌ Failed to read opcmAddress from implementations.json"
  exit 1
fi

# Replace the opcmAddress field in intent.toml with the new value
sed_inplace "s/^opcmAddress = \".*\"/opcmAddress = \"$OPCM_ADDRESS\"/" ./config-op/intent.toml
echo "✅ Updated opcmAddress ($OPCM_ADDRESS) in intent.toml"

# deploy contracts, TODO, should we need to modify source code to deploy contracts?
docker run \
  --network "$DOCKER_NETWORK" \
  -v "$(pwd)/$CONFIG_DIR:/deployments" \
  -w /app \
  "${OP_STACK_IMAGE_TAG}" \
  bash -c "
    set -e
    echo '🔧 Starting contract deployment with op-deployer...'

    # Deploy using op-deployer, wait for completion before proceeding
    /app/op-deployer/bin/op-deployer apply \
      --workdir /deployments \
      --private-key $DEPLOYER_PRIVATE_KEY \
      --l1-rpc-url $L1_RPC_URL_IN_DOCKER

    echo '📄 Generating L2 genesis and rollup config...'

    # Generate L2 genesis using op-deployer
    /app/op-deployer/bin/op-deployer inspect genesis \
      --workdir /deployments \
      195 > /deployments/genesis.json

    # Generate L2 rollup using op-node
    /app/op-deployer/bin/op-deployer inspect rollup \
      --workdir /deployments \
      195 > /deployments/rollup.json

    echo '✅ Contract deployment completed successfully'
  "

echo "genesis.json and rollup.json are generated in deployments folder"

# regenerate genesis.json for op-geth
cd $ROOT_DIR
go install ./cmd/hack/
cd $PWD_DIR
cp ./config-op/genesis.json ./config-op/genesis-op-raw.json
hack -action migrateGenesis -chaindata ./data/seq/chaindata/ -input ./config-op/genesis-op-raw.json   -output ./config-op/genesis.json

# FORK_BLOCK_HEX=$(printf "0x%x" "$FORK_BLOCK")
# cp ./config-op/genesis.json ./config-op/genesis-op-before-number.json
# sed_inplace 's/"number": "0x0"/"number": "'"$FORK_BLOCK_HEX"'"/' ./config-op/genesis.json
# sed_inplace 's/"number": 0/"number": '"$FORK_BLOCK"'/' ./config-op/rollup.json

# Extract contract addresses from state.json and update .env file
echo "🔧 Extracting contract addresses from state.json..."
STATE_JSON="$PWD_DIR/config-op/state.json"

if [ -f "$STATE_JSON" ]; then
    # Extract contract addresses from state.json
    DEPLOYMENTS_TYPE=$(jq -r 'type' "$STATE_JSON")
    if [ "$DEPLOYMENTS_TYPE" = "object" ]; then
        OPCD_TYPE=$(jq -r '.opChainDeployments | type' "$STATE_JSON" 2>/dev/null)
        if [ "$OPCD_TYPE" = "object" ]; then
            DISPUTE_GAME_FACTORY_ADDRESS=$(jq -r '.opChainDeployments.DisputeGameFactoryProxy // empty' "$STATE_JSON")
            L2OO_ADDRESS=$(jq -r '.opChainDeployments.L2OutputOracleProxy // empty' "$STATE_JSON")
            OPCM_IMPL_ADDRESS=$(jq -r '.appliedIntent.opcmAddress // empty' "$STATE_JSON")
            SYSTEM_CONFIG_PROXY_ADDRESS=$(jq -r '.opChainDeployments.SystemConfigProxy // empty' "$STATE_JSON")
            PROXY_ADMIN=$(jq -r '.superchainContracts.SuperchainProxyAdminImpl // empty' "$STATE_JSON")
        elif [ "$OPCD_TYPE" = "array" ]; then
            DISPUTE_GAME_FACTORY_ADDRESS=$(jq -r '.opChainDeployments[0].DisputeGameFactoryProxy // empty' "$STATE_JSON")
            L2OO_ADDRESS=$(jq -r '.opChainDeployments[0].L2OutputOracleProxy // empty' "$STATE_JSON")
            OPCM_IMPL_ADDRESS=$(jq -r '.appliedIntent.opcmAddress // empty' "$STATE_JSON")
            SYSTEM_CONFIG_PROXY_ADDRESS=$(jq -r '.opChainDeployments[0].SystemConfigProxy // empty' "$STATE_JSON")
            PROXY_ADMIN=$(jq -r '.superchainContracts.SuperchainProxyAdminImpl // empty' "$STATE_JSON")
        else
            DISPUTE_GAME_FACTORY_ADDRESS=""
            L2OO_ADDRESS=""
            OPCM_IMPL_ADDRESS=""
            SYSTEM_CONFIG_PROXY_ADDRESS=""
            PROXY_ADMIN=""
        fi

        # Update .env if found
        if [ -n "$DISPUTE_GAME_FACTORY_ADDRESS" ]; then
            echo "✅ Found DisputeGameFactoryProxy address: $DISPUTE_GAME_FACTORY_ADDRESS"
            sed_inplace "s/DISPUTE_GAME_FACTORY_ADDRESS=.*/DISPUTE_GAME_FACTORY_ADDRESS=$DISPUTE_GAME_FACTORY_ADDRESS/" .env
        else
            echo "⚠️  DisputeGameFactoryProxy address not found in opChainDeployments"
        fi

        if [ -n "$L2OO_ADDRESS" ]; then
            echo "✅ Found L2OutputOracleProxy address: $L2OO_ADDRESS"
            sed_inplace "s/L2OO_ADDRESS=.*/L2OO_ADDRESS=$L2OO_ADDRESS/" .env
        else
            echo "⚠️  L2OutputOracleProxy address not found in opChainDeployments"
        fi

        if [ -n "$OPCM_IMPL_ADDRESS" ]; then
            echo "✅ Found opcmAddress address: $OPCM_IMPL_ADDRESS"
            sed_inplace "s/OPCM_IMPL_ADDRESS=.*/OPCM_IMPL_ADDRESS=$OPCM_IMPL_ADDRESS/" .env
        else
            echo "⚠️  opcmAddress address not found in opChainDeployments"
        fi

        if [ -n "$SYSTEM_CONFIG_PROXY_ADDRESS" ]; then
            echo "✅ Found SystemConfigProxy address: $SYSTEM_CONFIG_PROXY_ADDRESS"
            sed_inplace "s/SYSTEM_CONFIG_PROXY_ADDRESS=.*/SYSTEM_CONFIG_PROXY_ADDRESS=$SYSTEM_CONFIG_PROXY_ADDRESS/" .env
        else
            echo "⚠️  SystemConfigProxy address not found in opChainDeployments"
        fi

        if [ -n "$PROXY_ADMIN" ]; then
            echo "✅ Found ProxyAdmin address: $PROXY_ADMIN"
            sed_inplace "s/PROXY_ADMIN=.*/PROXY_ADMIN=$PROXY_ADMIN/" .env
        else
            echo "⚠️  ProxyAdmin address not found in opChainDeployments"
        fi

        # Show summary
        echo "📄 Contract addresses updated in .env:"
        echo "   DISPUTE_GAME_FACTORY_ADDRESS=$DISPUTE_GAME_FACTORY_ADDRESS"
        echo "   L2OO_ADDRESS=$L2OO_ADDRESS"
        echo "   OPCM_IMPL_ADDRESS=$OPCM_IMPL_ADDRESS"
        echo "   SYSTEM_CONFIG_PROXY_ADDRESS=$SYSTEM_CONFIG_PROXY_ADDRESS"
        echo "   PROXY_ADMIN=$PROXY_ADMIN"
    else
        echo "❌ $STATE_JSON is not a valid JSON object"
    fi
else
    echo "❌ state.json not found at $STATE_JSON"
fi

echo "🎉 OP Stack deployment preparation completed!"

# init op-geth
OP_GETH_DATADIR="$(pwd)/data/op-geth"
rm -rf "$OP_GETH_DATADIR"
mkdir -p "$OP_GETH_DATADIR"
docker compose run --no-deps \
  -v "$(pwd)/$CONFIG_DIR/genesis.json:/genesis.json" \
  op-geth \
  --datadir "/datadir" \
  --gcmode=archive \
  init \
  --state.scheme=hash \
  /genesis.json

echo "finished init op-geth"