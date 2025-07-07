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

docker run \
  --network "$DOCKER_NETWORK" \
  -v "$PWD_DIR/config-op:/config" \
  -v "$EXPORT_DIR:/prestate-out" \
  "$OP_STACK_IMAGE_TAG" \
  /app/op-challenger/bin/op-challenger generate \
    --l2-genesis /config/genesis.json \
    --rollup-config /config/rollup.json \
    --output-dir /prestate-out \
    --cannon-bin /app/op-program/bin/op-program \
    --cannon-prestate /app/op-program/bin/prestate.json \
    --cannon-rollup-config /config/rollup.json \
    --cannon-l2-genesis /config/genesis.json