#!/bin/bash

set -e
# Enable debug output only if DEBUG=1 is set
if [ "${DEBUG:-0}" = "1" ]; then
    set -x
fi

# Load environment variables
source .env

echo "🎯 Starting Challenge Test..."

# Function to capitalize first letter (compatible across bash versions)
capitalize_first() {
    local word="$1"
    echo "$(echo "${word:0:1}" | tr 'a-z' 'A-Z')${word:1}"
}

# Function to get the depth of the latest claim using list-claims
get_latest_claim_depth() {
    local claims_output=$(docker run --rm \
        --network "$DOCKER_NETWORK" \
        -v "$(pwd)/data/cannon-data:/data" \
        -v "$(pwd)/config-op/rollup.json:/rollup.json" \
        -v "$(pwd)/config-op/genesis.json:/l2-genesis.json" \
        "${OP_STACK_IMAGE_TAG}" \
        /app/op-challenger/bin/op-challenger list-claims \
            --l1-eth-rpc=${L1_RPC_URL_IN_DOCKER} \
            --game-address=$LATEST_GAME_ADDRESS 2>/dev/null)
    
    # Extract the depth from the last claim line (skip header lines)
    local latest_depth=$(echo "$claims_output" | grep -E "^\s*[0-9]+" | tail -1 | awk '{print $4}')
    
    # Default to 0 if parsing failed
    if [ -z "$latest_depth" ] || ! [[ "$latest_depth" =~ ^[0-9]+$ ]]; then
        latest_depth=0
    fi
    
    echo "$latest_depth"
}

# Get the latest game address using op-challenger list-game
echo "1. Getting latest game address..."
GAME_LIST=$(docker run --rm \
  --network "$DOCKER_NETWORK" \
  -v "$(pwd)/data/cannon-data:/data" \
  -v "$(pwd)/config-op/rollup.json:/rollup.json" \
  -v "$(pwd)/config-op/genesis.json:/l2-genesis.json" \
  "${OP_STACK_IMAGE_TAG}" \
  /app/op-challenger/bin/op-challenger list-games \
    --l1-eth-rpc=${L1_RPC_URL_IN_DOCKER} \
    --game-factory-address=${DISPUTE_GAME_FACTORY_ADDRESS})

# Debug: Show the game list
echo "📋 Game list:"
echo "$GAME_LIST"
echo ""

# First try to find a game "In Progress"
IN_PROGRESS_GAME=$(echo "$GAME_LIST" | grep -E "^\s*[0-9]+" | grep "In Progress" | tail -1)
if [ -n "$IN_PROGRESS_GAME" ]; then
    echo "🔄 Found game in progress, using it for challenge"
    LATEST_GAME_LINE="$IN_PROGRESS_GAME"
    LATEST_GAME_ADDRESS=$(echo "$LATEST_GAME_LINE" | awk '{print $2}')
else
    echo "📝 No game in progress, using latest game"
    # Extract the latest game address from the second column of the last game entry
    LATEST_GAME_LINE=$(echo "$GAME_LIST" | grep -E "^\s*[0-9]+" | tail -1)
    LATEST_GAME_ADDRESS=$(echo "$LATEST_GAME_LINE" | awk '{print $2}')
fi

echo "🔍 Selected game line: $LATEST_GAME_LINE"
echo "🎮 Extracted address: $LATEST_GAME_ADDRESS"

if [ -z "$LATEST_GAME_ADDRESS" ] || [[ ! "$LATEST_GAME_ADDRESS" =~ ^0x[a-fA-F0-9]{40}$ ]]; then
    echo "❌ Failed to get valid game address: $LATEST_GAME_ADDRESS"
    echo "💡 Available games:"
    echo "$GAME_LIST" | grep -E "^\s*[0-9]+"
    exit 1
fi

echo "✅ Latest game address: $LATEST_GAME_ADDRESS"

# Get game information
echo "📋 Getting game information..."
GAME_INFO=$(docker run --rm \
    --network "$DOCKER_NETWORK" \
    -v "$(pwd)/data/cannon-data:/data" \
    -v "$(pwd)/config-op/rollup.json:/rollup.json" \
    -v "$(pwd)/config-op/genesis.json:/l2-genesis.json" \
    "${OP_STACK_IMAGE_TAG}" \
    /app/op-challenger/bin/op-challenger list-claims \
        --l1-eth-rpc=${L1_RPC_URL_IN_DOCKER} \
        --game-address=$LATEST_GAME_ADDRESS 2>/dev/null | head -2)

echo "$GAME_INFO"

# Get initial depth
INITIAL_DEPTH=$(get_latest_claim_depth)
echo "🌳 Initial claim depth: $INITIAL_DEPTH"
echo "🎯 Target: Reach maximum depth (73) then wait for DEFENDER_WINS (status=2)"

echo "2. Starting move sequence..."



# Function to get the depth of a specific claim
get_claim_depth() {
    local claim_index=$1
    # Use list-claims to get the depth of the specific claim
    local claims_output=$(docker run --rm \
        --network "$DOCKER_NETWORK" \
        -v "$(pwd)/data/cannon-data:/data" \
        -v "$(pwd)/config-op/rollup.json:/rollup.json" \
        -v "$(pwd)/config-op/genesis.json:/l2-genesis.json" \
        "${OP_STACK_IMAGE_TAG}" \
        /app/op-challenger/bin/op-challenger list-claims \
            --l1-eth-rpc=${L1_RPC_URL_IN_DOCKER} \
            --game-address=$LATEST_GAME_ADDRESS 2>/dev/null)
    
    # Find the line with the specific claim index and extract depth
    local claim_depth=$(echo "$claims_output" | grep -E "^\s*$claim_index\s" | awk '{print $4}')
    
    # Default to 0 if parsing failed
    if [ -z "$claim_depth" ] || ! [[ "$claim_depth" =~ ^[0-9]+$ ]]; then
        claim_depth=0
    fi
    
    echo "$claim_depth"
}

# Function to generate claim based on parent claim depth
generate_claim() {
    local parent_index=$1
    local parent_depth=$(get_claim_depth $parent_index)
    local base_claim="0x35ac85f39df227892e62fd41961f98fdf09bcac8474b3b19e60bafec5ac762a6"
    
    if [ $parent_depth -eq 30 ]; then
        # For defending against claims at depth 30 (Split Depth), set first byte to 00
        echo "0x00ac85f39df227892e62fd41961f98fdf09bcac8474b3b19e60bafec5ac762a6"
    else
        echo "$base_claim"
    fi
}

# Function to get the claimant address of a specific claim
get_claimant() {
    local claim_index=$1
    # claimData returns a struct, claimant is the 3rd field (bytes 64-84 in the hex output)
    local raw_output=$(docker run --rm \
        --network "$DOCKER_NETWORK" \
        "${OP_STACK_IMAGE_TAG}" \
        cast call \
            --rpc-url ${L1_RPC_URL_IN_DOCKER} \
            $LATEST_GAME_ADDRESS \
            "claimData(uint256)" \
            $claim_index)
    
    # Extract claimant address from position 64-84 (32-byte aligned, so starts at byte 64)
    # The address is in the 3rd 32-byte slot, padded with zeros
    local hex_data=$(echo "$raw_output" | tr -d '\n' | sed 's/0x//')
    local claimant_padded=${hex_data:128:64}  # 3rd 32-byte slot (2*64 = 128 start position)
    local claimant="0x${claimant_padded: -40}"  # Last 40 chars (20 bytes) for address
    echo "$claimant"
}

# Verify challenger address matches the private key (for reference)
CHALLENGER_ADDRESS_FROM_KEY=$(docker run --rm \
    --network "$DOCKER_NETWORK" \
    "${OP_STACK_IMAGE_TAG}" \
    cast wallet address ${OP_CHALLENGER_PRIVATE_KEY})

echo "🎯 Challenger address: $CHALLENGER_ADDRESS_FROM_KEY"

# Move loop
SUCCESSFUL_MOVES=0    # Track only successful moves
ATTEMPT_COUNT=0       # Track total attempts
LAST_CLAIM_COUNT=0    # Track last seen claim count

while true; do  # Continue until max depth reached or game ends
    ATTEMPT_COUNT=$((ATTEMPT_COUNT + 1))
    
    # Check if the latest claim has reached max depth (73)
    LATEST_DEPTH=$(get_latest_claim_depth)
    echo "🔍 Attempt #$ATTEMPT_COUNT: Latest claim depth: $LATEST_DEPTH"
    
    if [ "$LATEST_DEPTH" -ge 73 ]; then
        echo "🏁 Maximum depth (73) reached! No more claims can be made."
        echo "   Latest depth: $LATEST_DEPTH"
        break
    fi
    
    # Get current claim count
    CURRENT_CLAIMS=$(docker run --rm \
        --network "$DOCKER_NETWORK" \
        "${OP_STACK_IMAGE_TAG}" \
        cast call \
            --rpc-url ${L1_RPC_URL_IN_DOCKER} \
            $LATEST_GAME_ADDRESS \
            "claimDataLen()")
    
    CURRENT_CLAIM_COUNT=$(printf "%d" $CURRENT_CLAIMS)
    
    echo "🔍 Current claims: $CURRENT_CLAIM_COUNT, Last seen: $LAST_CLAIM_COUNT, Successful moves: $SUCCESSFUL_MOVES"
    
    # Check if claim count increased and is odd (proposer made a new claim)
    if [ $CURRENT_CLAIM_COUNT -le $LAST_CLAIM_COUNT ]; then
        echo "⏳ No new claims, waiting..."
        sleep 10
        continue
    fi
    
    # Check if current claim count is odd (proposer's turn completed)
    if [ $((CURRENT_CLAIM_COUNT % 2)) -eq 0 ]; then
        echo "⏳ Claim count is even ($CURRENT_CLAIM_COUNT), waiting for proposer..."
        LAST_CLAIM_COUNT=$CURRENT_CLAIM_COUNT
        sleep 10
        continue
    fi
    
    echo "✅ New proposer claim detected! Claims: $LAST_CLAIM_COUNT -> $CURRENT_CLAIM_COUNT (odd)"
    
    # Target the latest claim (since claim count is odd, latest claim is from proposer)
    PROPOSER_CLAIM_INDEX=$((CURRENT_CLAIM_COUNT - 1))
    echo "   🎯 Will target latest claim at index $PROPOSER_CLAIM_INDEX"
    
    # Get the depth of the claim we're targeting
    PARENT_CLAIM_DEPTH=$(get_claim_depth $PROPOSER_CLAIM_INDEX)
    
    # Determine move type and generate claim based on parent claim depth
    if [ $PARENT_CLAIM_DEPTH -eq 30 ] || [ $PARENT_CLAIM_DEPTH -eq 28 ]; then
        MOVE_TYPE="--defend"
        MOVE_NAME="defending"
        CLAIM=$(generate_claim $PROPOSER_CLAIM_INDEX)
        echo "🔥 Special defend against claim at depth 30 (Split Depth) with modified claim: $CLAIM"
    else
        MOVE_TYPE="--attack"
        MOVE_NAME="attacking"
        CLAIM=$(generate_claim $PROPOSER_CLAIM_INDEX)
    fi
    
    echo "🗡️  $(capitalize_first "$MOVE_NAME") proposer claim #$PROPOSER_CLAIM_INDEX at depth $PARENT_CLAIM_DEPTH (attempt #$ATTEMPT_COUNT, successful: $SUCCESSFUL_MOVES)"
    echo "   Claim: $CLAIM"
    
    # Execute move (attack or defend)
    if docker run --rm \
        --network "$DOCKER_NETWORK" \
        -v "$(pwd)/data/cannon-data:/data" \
        -v "$(pwd)/config-op/rollup.json:/rollup.json" \
        -v "$(pwd)/config-op/genesis.json:/l2-genesis.json" \
        "${OP_STACK_IMAGE_TAG}" \
        /app/op-challenger/bin/op-challenger move \
            --l1-eth-rpc=${L1_RPC_URL_IN_DOCKER} \
            --game-address=$LATEST_GAME_ADDRESS \
            $MOVE_TYPE \
            --parent-index=$PROPOSER_CLAIM_INDEX \
            --claim=$CLAIM \
            --private-key=${OP_CHALLENGER_PRIVATE_KEY}; then
        
        # Move succeeded - increment successful count
        SUCCESSFUL_MOVES=$((SUCCESSFUL_MOVES + 1))
        LAST_CLAIM_COUNT=$CURRENT_CLAIM_COUNT
        echo "✅ Move successful! (#$SUCCESSFUL_MOVES successful moves total)"
        echo "   $(capitalize_first "$MOVE_NAME") proposer claim at index $PROPOSER_CLAIM_INDEX (parent depth: $PARENT_CLAIM_DEPTH, game depth: $LATEST_DEPTH)"
        
        if [ $PARENT_CLAIM_DEPTH -eq 30 ]; then
            echo "🎯 Completed special defend against claim at depth 30 (Split Depth)!"
        fi
        
        # Small delay before next check
        echo "⏳ Waiting for proposer to respond..."
        sleep 5
        
    else
        echo "❌ Move attempt #$ATTEMPT_COUNT failed (target claim: $PROPOSER_CLAIM_INDEX, mode: $MOVE_NAME)"
        
        # Update last seen claim count to avoid retry
        LAST_CLAIM_COUNT=$CURRENT_CLAIM_COUNT
        
        # Check if game has ended
        GAME_STATUS=$(docker run --rm \
            --network "$DOCKER_NETWORK" \
            "${OP_STACK_IMAGE_TAG}" \
            cast call \
                --rpc-url ${L1_RPC_URL_IN_DOCKER} \
                $LATEST_GAME_ADDRESS \
                "status()")
        
        STATUS_DECIMAL=$(printf "%d" $GAME_STATUS)
        
        if [ $STATUS_DECIMAL -ne 0 ]; then
            echo "🏁 Game ended during attacks with status: $STATUS_DECIMAL"
            break
        fi
        
        # Wait before next check
        sleep 5
    fi
done

echo "🏁 Move sequence completed!"
echo "   Total attempts: $ATTEMPT_COUNT"
echo "   Successful moves: $SUCCESSFUL_MOVES"

# Wait longer for game to resolve when max depth is reached
echo "⏰ Waiting for game to resolve after reaching max depth..."
echo "   This may take several minutes..."

# Manual resolve process: resolve claims from back to front
echo "🔧 Starting manual claim resolution process..."

# Get current claim count
TOTAL_CLAIMS=$(docker run --rm \
    --network "$DOCKER_NETWORK" \
    "${OP_STACK_IMAGE_TAG}" \
    cast call \
        --rpc-url ${L1_RPC_URL_IN_DOCKER} \
        $LATEST_GAME_ADDRESS \
        "claimDataLen()")

TOTAL_CLAIM_COUNT=$(printf "%d" $TOTAL_CLAIMS)
echo "📊 Total claims to resolve: $TOTAL_CLAIM_COUNT"

# Resolve claims from back to front (highest index to 0)
if [ $TOTAL_CLAIM_COUNT -gt 0 ]; then
    echo "🔄 Resolving claims from index $((TOTAL_CLAIM_COUNT - 1)) down to 0..."
    
    for (( claim_index=$((TOTAL_CLAIM_COUNT - 1)); claim_index>=0; claim_index-- )); do
        echo "🎯 Resolving claim at index $claim_index (_numToResolve=10)..."
        
        # Call claimResolve with _numToResolve=10
        if docker run --rm \
            --network "$DOCKER_NETWORK" \
            "${OP_STACK_IMAGE_TAG}" \
            cast send \
                --rpc-url ${L1_RPC_URL_IN_DOCKER} \
                --private-key ${OP_CHALLENGER_PRIVATE_KEY} \
                $LATEST_GAME_ADDRESS \
                "claimResolve(uint256,uint256)" \
                $claim_index \
                10; then
            
            echo "✅ Claim $claim_index resolved successfully"
            
            # Wait for transaction to be processed and claim to be resolved
            echo "⏳ Waiting for claim $claim_index to be fully resolved..."
            
            # Check if claim is resolved by checking its status
            local max_wait=100
            local wait_count=0
            local claim_resolved=false
            
            while [ $wait_count -lt $max_wait ] && [ "$claim_resolved" = false ]; do
                wait_count=$((wait_count + 1))
                
                # Check if claim is resolved (implementation may vary, using a simple delay for now)
                sleep 1
                
                # Try to get claim data to verify it's still valid/resolved
                local claim_data=$(docker run --rm \
                    --network "$DOCKER_NETWORK" \
                    "${OP_STACK_IMAGE_TAG}" \
                    cast call \
                        --rpc-url ${L1_RPC_URL_IN_DOCKER} \
                        $LATEST_GAME_ADDRESS \
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
    done
    
    echo "✅ All claims processed, now calling resolve()..."
    
    # Call the main resolve() function after all claims are processed
    echo "🎯 Calling game resolve()..."
    
    if docker run --rm \
        --network "$DOCKER_NETWORK" \
        "${OP_STACK_IMAGE_TAG}" \
        cast send \
            --rpc-url ${L1_RPC_URL_IN_DOCKER} \
            --private-key ${OP_CHALLENGER_PRIVATE_KEY} \
            $LATEST_GAME_ADDRESS \
            "resolve()"; then
        
        echo "✅ Game resolve() called successfully"
        
        # Wait for resolve to complete
        echo "⏳ Waiting for game resolution to complete..."
        sleep 10
        
        # Verify the game is resolved
        local resolved_status=$(docker run --rm \
            --network "$DOCKER_NETWORK" \
            "${OP_STACK_IMAGE_TAG}" \
            cast call \
                --rpc-url ${L1_RPC_URL_IN_DOCKER} \
                $LATEST_GAME_ADDRESS \
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

echo "🏁 Manual resolution process completed, checking final status..."

# Final status check after manual resolution
echo "📊 Checking final game status after manual resolution..."

GAME_STATUS=$(docker run --rm \
    --network "$DOCKER_NETWORK" \
    "${OP_STACK_IMAGE_TAG}" \
    cast call \
        --rpc-url ${L1_RPC_URL_IN_DOCKER} \
        $LATEST_GAME_ADDRESS \
        "status()")

STATUS_DECIMAL=$(printf "%d" $GAME_STATUS)

echo "📊 Final game status: $GAME_STATUS (decimal: $STATUS_DECIMAL)"

# Check if status equals 2 (DEFENDER_WINS)
if [ $STATUS_DECIMAL -eq 2 ]; then
    echo "🏆 SUCCESS: Game status is 2 (DEFENDER_WINS) - Challenge test passed!"
    
    # Additional info
    RESOLVED=$(docker run --rm \
        --network "$DOCKER_NETWORK" \
        "${OP_STACK_IMAGE_TAG}" \
        cast call \
            --rpc-url ${L1_RPC_URL_IN_DOCKER} \
            $LATEST_GAME_ADDRESS \
            "resolved()")
    
    echo "📋 Game Claims (via list-claims):"
    docker run --rm \
        --network "$DOCKER_NETWORK" \
        -v "$(pwd)/data/cannon-data:/data" \
        -v "$(pwd)/config-op/rollup.json:/rollup.json" \
        -v "$(pwd)/config-op/genesis.json:/l2-genesis.json" \
        "${OP_STACK_IMAGE_TAG}" \
        /app/op-challenger/bin/op-challenger list-claims \
            --l1-eth-rpc=${L1_RPC_URL_IN_DOCKER} \
            --game-address=$LATEST_GAME_ADDRESS
    
    exit 0
else
    echo "❌ FAILURE: Game status is $STATUS_DECIMAL, expected 2 (DEFENDER_WINS)"
    
    # Status meanings for debugging
    case $STATUS_DECIMAL in
        0)
            echo "   Current status: IN_PROGRESS (0)"
            ;;
        1)
            echo "   Current status: CHALLENGER_WINS (1)"
            ;;
        *)
            echo "   Current status: UNKNOWN ($STATUS_DECIMAL)"
            ;;
    esac
    
    echo "📋 Debug Information:"
    echo "   - Game Address: $LATEST_GAME_ADDRESS"
    echo "   - Total Attempts: $ATTEMPT_COUNT"
    echo "   - Successful Moves: $SUCCESSFUL_MOVES"
    echo "   - Claims Processed: $TOTAL_CLAIM_COUNT"
    echo "   - Manual Resolution: Attempted"
    
    exit 1
fi

