#!/bin/bash
set -e

# -------------------------
# Configuration
# -------------------------
REDIS1_ADDR="127.0.0.1:6379"
REDIS2_ADDR="127.0.0.1:6380"
REDIS_USER="myuser"
REDIS_PASS="MyRedisPass123"

SHAKE_CONFIG="$(pwd)/shake_sync_env.toml"

SYNC_TIMEOUT=$((60 * 60)) # max wait time for sync (1 hour)

# -------------------------
# Function to check if Redis is reachable
# -------------------------
check_redis_running() {
  local ADDR="$1"
  local NAME="$2"

  echo "🔍 Checking $NAME at $ADDR ..."
  if ! redis-cli -u "redis://$REDIS_USER:$REDIS_PASS@$ADDR" PING >/dev/null 2>&1; then
    echo "❌ $NAME ($ADDR) is not reachable!"
    exit 1
  fi
  echo "✅ $NAME is up"
}

# -------------------------
# Function to write config for RedisShake
# -------------------------
write_shake_config() {
  cat > "$SHAKE_CONFIG" <<EOF
[sync_reader]
address = "\${SHAKE_SRC_ADDRESS}"
username = "\${SHAKE_SRC_USERNAME}"
password = "\${SHAKE_SRC_PASSWORD}"
tls = false

[redis_writer]
address = "\${SHAKE_DST_ADDRESS}"
username = "\${SHAKE_DST_USERNAME}"
password = "\${SHAKE_DST_PASSWORD}"
tls = false

[filter]
block_key_prefix = ["temp:", "cache:"]

[advanced]
dir = "data"
EOF
}

# -------------------------
# Function to run RedisShake and monitor logs until diff=[0]
# -------------------------
run_sync() {
  local SRC="$1"
  local DST="$2"
  local DESC="$3"

  echo "➡️ Starting sync: $DESC"
  write_shake_config

  LOGFILE="$(mktemp)"
  timeout "$SYNC_TIMEOUT" docker run --rm --network host \
      -e SYNC=true \
      -e SHAKE_SRC_ADDRESS="$SRC" \
      -e SHAKE_SRC_USERNAME="$REDIS_USER" \
      -e SHAKE_SRC_PASSWORD="$REDIS_PASS" \
      -e SHAKE_DST_ADDRESS="$DST" \
      -e SHAKE_DST_USERNAME="$REDIS_USER" \
      -e SHAKE_DST_PASSWORD="$REDIS_PASS" \
      -v "$SHAKE_CONFIG":/app/shake_sync_env.toml \
      ghcr.io/tair-opensource/redisshake:latest \
      sync -conf /app/shake_sync_env.toml \
      2>&1 | tee "$LOGFILE" &
  PID=$!

  echo "🔍 Monitoring logs for diff=[0] (timeout $SYNC_TIMEOUT sec)..."
  SECONDS=0
  while kill -0 $PID >/dev/null 2>&1; do
    if grep -q "diff=\[0\]" "$LOGFILE"; then
      echo "✅ Sync successful (diff=[0])"
      kill $PID >/dev/null 2>&1 || true
      wait $PID 2>/dev/null || true
      rm -f "$LOGFILE"
      return 0
    fi
    if [ $SECONDS -ge $SYNC_TIMEOUT ]; then
      echo "❌ Timeout reached ($SYNC_TIMEOUT sec) — no diff=[0] detected"
      kill $PID >/dev/null 2>&1 || true
      wait $PID 2>/dev/null || true
      rm -f "$LOGFILE"
      exit 1
    fi
    sleep 2
  done

  echo "❌ Sync process ended without diff=[0]"
  cat "$LOGFILE"
  rm -f "$LOGFILE"
  exit 1
}

# -------------------------
# Step 0: Verify both Redis instances are running
# -------------------------
echo "✅ Checking if Redis instances are running..."
check_redis_running "$REDIS1_ADDR" "redis1"
check_redis_running "$REDIS2_ADDR" "redis2"

# -------------------------
# Step 1: Fullsync from redis1 -> redis2
# -------------------------
run_sync "$REDIS1_ADDR" "$REDIS2_ADDR" "redis1 → redis2 (before restart)"

# -------------------------
# Step 2: Wait for manual restart of redis1
# -------------------------
read -p "⏸️ Press Enter once you have manually restarted redis1 to continue..."

# -------------------------
# Step 3: Check number of keys on redis1
# -------------------------
echo "ℹ️ After restart, number of keys on redis1 (should be 0):"
redis-cli -u "redis://$REDIS_USER:$REDIS_PASS@$REDIS1_ADDR" DBSIZE || { echo "❌ Failed to query redis1"; exit 1; }

# -------------------------
# Step 4: Fullsync from redis2 -> redis1
# -------------------------
run_sync "$REDIS2_ADDR" "$REDIS1_ADDR" "redis2 → redis1 (restore after restart)"

# -------------------------
# Step 5: Final verification
# -------------------------
echo "✅ Final number of keys on redis1:"
redis-cli -u "redis://$REDIS_USER:$REDIS_PASS@$REDIS1_ADDR" DBSIZE

echo "✅ Final number of keys on redis2:"
redis-cli -u "redis://$REDIS_USER:$REDIS_PASS@$REDIS2_ADDR" DBSIZE

echo "🎉 Manual restart and recovery POC complete!"
