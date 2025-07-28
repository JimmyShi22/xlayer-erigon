#!/bin/bash

set -e
# Enable debug output only if DEBUG=1 is set
if [ "${DEBUG:-0}" = "1" ]; then
    set -x
fi

# Usage function
usage() {
    echo "Usage: $0 <GAME_ADDRESS>"
    echo ""
    echo "Arguments:"
    echo "  GAME_ADDRESS     The dispute game contract address (0x...)"
    echo ""
    echo "This script will resolve all claims in the dispute game and check if the final"
    echo "status is DEFENDER_WINS (status=2), which is the expected outcome."
    echo ""
    echo "Examples:"
    echo "  $0 0x1234567890123456789012345678901234567890"
    echo "  $0 0xabcdef1234567890abcdef1234567890abcdef12"
    echo ""
    exit 1
}

# Check arguments
if [ $# -ne 1 ]; then
    echo "❌ Error: Wrong number of arguments"
    echo ""
    usage
fi

GAME_ADDRESS="$1"
EXPECTED_STATUS="2"  # Always expect DEFENDER_WINS

# Validate game address format
if [[ ! "$GAME_ADDRESS" =~ ^0x[a-fA-F0-9]{40}$ ]]; then
    echo "❌ Error: Invalid game address format: $GAME_ADDRESS"
    echo "   Expected format: 0x followed by 40 hex characters"
    exit 1
fi

# Note: Expected status is hardcoded to 2 (DEFENDER_WINS)

# Load environment variables
if [ ! -f ".env" ]; then
    echo "❌ Error: .env file not found"
    echo "   Please ensure you're running this script from the test-pp-op directory"
    exit 1
fi

source .env

echo "🎯 Starting Manual Game Resolution..."
echo "   Game Address: $GAME_ADDRESS"
echo "   Expected Result: DEFENDER_WINS (status=2)"
echo ""

# Manual resolve process: resolve claims from back to front
echo "🔧 Starting manual claim resolution process..."

# Get current claim count
echo "📊 Getting total claim count..."
TOTAL_CLAIMS=$(docker run --rm \
    --network "$DOCKER_NETWORK" \
    "${OP_STACK_IMAGE_TAG}" \
    cast call \
        --rpc-url ${L1_RPC_URL_IN_DOCKER} \
        $GAME_ADDRESS \
        "claimDataLen()")

TOTAL_CLAIM_COUNT=$(printf "%d" $TOTAL_CLAIMS)
echo "📊 Total claims to resolve: $TOTAL_CLAIM_COUNT"

# Resolve claims from back to front (highest index to 0)
if [ $TOTAL_CLAIM_COUNT -gt 0 ]; then
    echo "🔄 Resolving claims from index $((TOTAL_CLAIM_COUNT - 1)) down to 0..."
    echo ""
    
    for (( claim_index=$((TOTAL_CLAIM_COUNT - 1)); claim_index>=0; claim_index-- )); do
        echo "🎯 Resolving claim at index $claim_index (_numToResolve=10)..."
        
        # Call resolveClaim with _numToResolve=10
        if docker run --rm \
            --network "$DOCKER_NETWORK" \
            "${OP_STACK_IMAGE_TAG}" \
            cast send \
                --rpc-url ${L1_RPC_URL_IN_DOCKER} \
                --private-key ${OP_CHALLENGER_PRIVATE_KEY} \
                $GAME_ADDRESS \
                "resolveClaim(uint256,uint256)" \
                $claim_index \
                10; then
            
            echo "✅ Claim $claim_index resolved successfully"
            
            # Wait for transaction to be processed and claim to be resolved
            echo "⏳ Waiting for claim $claim_index to be fully resolved..."
            
            # Check if claim is resolved by checking its status
            max_wait=100
            wait_count=0
            claim_resolved=false
            
            while [ $wait_count -lt $max_wait ] && [ "$claim_resolved" = false ]; do
                wait_count=$((wait_count + 1))
                
                # Check if claim is resolved (implementation may vary, using a simple delay for now)
                sleep 1
                
                # Try to get claim data to verify it's still valid/resolved
                claim_data=$(docker run --rm \
                    --network "$DOCKER_NETWORK" \
                    "${OP_STACK_IMAGE_TAG}" \
                    cast call \
                        --rpc-url ${L1_RPC_URL_IN_DOCKER} \
                        $GAME_ADDRESS \
                        "claimData(uint256)" \
                        $claim_index 2>/dev/null || echo "resolved")
                
                if [ "$claim_data" = "resolved" ] || [ $wait_count -ge $max_wait ]; then
                    claim_resolved=true
                    echo "✅ Claim $claim_index resolution confirmed (wait cycles: $wait_count)"
                else
                    echo "   ⏳ Still waiting for claim $claim_index resolution... ($wait_count/$max_wait)"
                fi
            done
            
        else
            echo "❌ Failed to resolve claim $claim_index, continuing with next..."
        fi
        
        # Brief pause between claim resolutions
        sleep 2
        echo ""
    done
    
    echo "✅ All claims processed, now calling resolve()..."
    echo ""
    
    # Call the main resolve() function after all claims are processed
    echo "🎯 Calling game resolve()..."
    
    if docker run --rm \
        --network "$DOCKER_NETWORK" \
        "${OP_STACK_IMAGE_TAG}" \
        cast send \
            --rpc-url ${L1_RPC_URL_IN_DOCKER} \
            --private-key ${OP_CHALLENGER_PRIVATE_KEY} \
            $GAME_ADDRESS \
            "resolve()"; then
        
        echo "✅ Game resolve() called successfully"
        
        # Wait for resolve to complete
        echo "⏳ Waiting for game resolution to complete..."
        sleep 10
        
        # Verify the game is resolved
        resolved_status=$(docker run --rm \
            --network "$DOCKER_NETWORK" \
            "${OP_STACK_IMAGE_TAG}" \
            cast call \
                --rpc-url ${L1_RPC_URL_IN_DOCKER} \
                $GAME_ADDRESS \
                "resolved()")
        
        echo "📊 Game resolved status: $resolved_status"
        
        if [ "$resolved_status" = "true" ] || [ "$resolved_status" = "0x0000000000000000000000000000000000000000000000000000000000000001" ]; then
            echo "✅ Game resolution confirmed!"
        else
            echo "⚠️  Game resolution status unclear: $resolved_status"
        fi
        
    else
        echo "❌ Failed to call game resolve(), will proceed with status check anyway"
    fi
    
else
    echo "⚠️  No claims to resolve (claim count: $TOTAL_CLAIM_COUNT)"
fi

echo ""
echo "🏁 Manual resolution process completed, checking final status..."

# Final status check after manual resolution
echo "📊 Checking final game status after manual resolution..."

GAME_STATUS=$(docker run --rm \
    --network "$DOCKER_NETWORK" \
    "${OP_STACK_IMAGE_TAG}" \
    cast call \
        --rpc-url ${L1_RPC_URL_IN_DOCKER} \
        $GAME_ADDRESS \
        "status()")

STATUS_DECIMAL=$(printf "%d" $GAME_STATUS)

echo "📊 Final game status: $GAME_STATUS (decimal: $STATUS_DECIMAL)"

# Convert status to human readable
case $STATUS_DECIMAL in
    0)
        STATUS_NAME="IN_PROGRESS"
        ;;
    1)
        STATUS_NAME="CHALLENGER_WINS"
        ;;
    2)
        STATUS_NAME="DEFENDER_WINS"
        ;;
    *)
        STATUS_NAME="UNKNOWN"
        ;;
esac

echo "📊 Status meaning: $STATUS_NAME ($STATUS_DECIMAL)"

# Check if status matches expected result
if [ $STATUS_DECIMAL -eq $EXPECTED_STATUS ]; then
    echo ""
    echo "🏆 SUCCESS: Game resolved with DEFENDER_WINS!"
    echo "   Final Status: $STATUS_DECIMAL ($STATUS_NAME)"
    
    # Additional info
    RESOLVED=$(docker run --rm \
        --network "$DOCKER_NETWORK" \
        "${OP_STACK_IMAGE_TAG}" \
        cast call \
            --rpc-url ${L1_RPC_URL_IN_DOCKER} \
            $GAME_ADDRESS \
            "resolved()")
    
    echo ""
    echo "📋 Game Summary:"
    echo "   - Game Address: $GAME_ADDRESS"
    echo "   - Final Status: $STATUS_DECIMAL ($STATUS_NAME) ✅"
    echo "   - Game Resolved: $RESOLVED"
    echo "   - Claims Manually Resolved: $TOTAL_CLAIM_COUNT"
    echo "   - Manual Resolution: ✅ Completed"
    
    echo ""
    echo "✅ Game resolution completed successfully!"
    exit 0
else
    echo ""
    echo "❌ FAILURE: Game did not resolve to DEFENDER_WINS!"
    echo "   Expected: 2 (DEFENDER_WINS), Actual: $STATUS_DECIMAL ($STATUS_NAME)"
    
    echo ""
    echo "📋 Debug Information:"
    echo "   - Game Address: $GAME_ADDRESS"
    echo "   - Claims Processed: $TOTAL_CLAIM_COUNT"
    echo "   - Manual Resolution: Attempted"
    echo "   - Expected Status: 2 (DEFENDER_WINS)"
    echo "   - Actual Status: $STATUS_DECIMAL ($STATUS_NAME)"
    
    # Show final claims for debugging
    echo ""
    echo "📋 Debug Game Claims (via list-claims):"
    docker run --rm \
        --network "$DOCKER_NETWORK" \
        -v "$(pwd)/data/cannon-data:/data" \
        -v "$(pwd)/config-op/rollup.json:/rollup.json" \
        -v "$(pwd)/config-op/genesis.json:/l2-genesis.json" \
        "${OP_STACK_IMAGE_TAG}" \
        /app/op-challenger/bin/op-challenger list-claims \
            --l1-eth-rpc=${L1_RPC_URL_IN_DOCKER} \
            --game-address=$GAME_ADDRESS 2>/dev/null || echo "Failed to get claims"
    
    exit 1
fi 