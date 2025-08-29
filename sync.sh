#!/bin/bash
set -e

# -------------------------
# Configuration
# -------------------------
REDIS1_ADDR="127.0.0.1:6379"
REDIS2_ADDR="127.0.0.1:6380"
REDIS_USER=""           # set correct username if using ACLs
REDIS_PASS="MyRedisPass123"

# NEW: make source/target type configurable
SOURCE_TYPE="standalone"   # options: standalone, cluster
TARGET_TYPE="standalone"   # options: standalone, cluster

SHAKE_CONFIG="$(pwd)/shake_sync_env.toml"
SYNC_TIMEOUT=$((60 * 60)) # max wait time for sync (1 hour)

# -------------------------
# Helper: build Redis URI depending on auth
# -------------------------
build_uri() {
  local ADDR="$1"
  if [ -n "$REDIS_USER" ] && [ -n "$REDIS_PASS" ]; then
    echo "redis://$REDIS_USER:$REDIS_PASS@$ADDR"
  elif [ -n "$REDIS_PASS" ]; then
    echo "redis://:$REDIS_PASS@$ADDR"
  else
    echo "redis://$ADDR"
  fi
}

# -------------------------
# Function: detect TLS or plain Redis
# -------------------------
detect_tls() {
  local ADDR="$1"
  local URI
  URI=$(build_uri "$ADDR")

  if timeout 2 redis-cli --tls --insecure -u "${URI/redis:/rediss:}" PING >/dev/null 2>&1; then
    echo "tls"
    return
  fi

  if timeout 2 redis-cli -u "$URI" PING >/dev/null 2>&1; then
    echo "plain"
    return
  fi

  echo "❌ Cannot connect to Redis at $ADDR with or without TLS"
  exit 1
}

# -------------------------
# Wrapper for redis-cli with auto TLS
# -------------------------
redis_cmd() {
  local ADDR="$1"
  local DB="$2"
  shift 2

  local MODE URI
  MODE=$(detect_tls "$ADDR")
  URI=$(build_uri "$ADDR")

  if [ "$MODE" = "tls" ]; then
    redis-cli --tls --insecure -u "${URI/redis:/rediss:}" -n "$DB" "$@"
  else
    redis-cli -u "$URI" -n "$DB" "$@"
  fi
}

# -------------------------
# Function to check if Redis is reachable
# -------------------------
check_redis_running() {
  local ADDR="$1"
  local NAME="$2"

  echo "🔍 Checking $NAME at $ADDR ..."
  if ! redis_cmd "$ADDR" 0 PING >/dev/null 2>&1; then
    echo "❌ $NAME ($ADDR) is not reachable!"
    exit 1
  fi
  echo "✅ $NAME is up"
}

# -------------------------
# Function to write config for RedisShake (full sync)
# -------------------------
write_shake_config() {
  local SRC_ADDR="$1"
  local DST_ADDR="$2"
  local TMP_FILE="$3"

  local SRC_MODE DST_MODE
  SRC_MODE=$(detect_tls "$SRC_ADDR")
  DST_MODE=$(detect_tls "$DST_ADDR")

  cat > "$TMP_FILE" <<EOF
[sync_reader]
cluster = $( [ "$SOURCE_TYPE" = "cluster" ] && echo true || echo false )
address = "\${SHAKE_SRC_ADDRESS}"
username = "$( [ -n "$REDIS_USER" ] && echo "$REDIS_USER" || echo "" )"
password = "$( [ -n "$REDIS_PASS" ] && echo "\${SHAKE_SRC_PASSWORD}" || echo "" )"
tls = $( [ "$SRC_MODE" = "tls" ] && echo true || echo false )
# ✅ force full sync
sync_rdb = true
sync_aof = true
prefer_replica = false
try_diskless = false

[redis_writer]
cluster = $( [ "$TARGET_TYPE" = "cluster" ] && echo true || echo false )
address = "\${SHAKE_DST_ADDRESS}"
username = "$( [ -n "$REDIS_USER" ] && echo "$REDIS_USER" || echo "" )"
password = "$( [ -n "$REDIS_PASS" ] && echo "\${SHAKE_DST_PASSWORD}" || echo "" )"
tls = $( [ "$DST_MODE" = "tls" ] && echo true || echo false )
off_reply = false

[filter]
allow_keys = []
allow_key_prefix = []
allow_key_suffix = []
allow_key_regex = []
block_keys = []
block_key_prefix = ["temp:", "cache:"]
block_key_suffix = []
block_key_regex = []
allow_db = []
block_db = []
allow_command = []
block_command = []
allow_command_group = []
block_command_group = []
function = ""

[advanced]
dir = "data"
log_file = "shake.log"
log_level = "info"
log_interval = 5
log_rotation = true
log_max_size = 512
log_max_age = 7
log_max_backups = 3
log_compress = true
rdb_restore_command_behavior = "panic"
pipeline_count_limit = 1024
target_redis_max_qps = 300000
target_redis_client_max_querybuf_len = 1073741824
target_redis_proto_max_bulk_len = 512000000
empty_db_before_sync = false
EOF
}




# -------------------------
# Function to run RedisShake in a separate sync process
# -------------------------
run_sync_separate() {
  local SRC="$1"
  local DST="$2"
  local DESC="$3"

  echo "➡️ Starting sync: $DESC"

  # Temporary config file
  local TMP_CONFIG
  TMP_CONFIG=$(mktemp)
  write_shake_config "$SRC" "$DST" "$TMP_CONFIG"

  # Temporary log
  local LOGFILE
  LOGFILE=$(mktemp)

  # Run RedisShake in background
  docker run --rm --network host \
      -e SYNC=true \
      -e SHAKE_SRC_ADDRESS="$SRC" \
      -e SHAKE_DST_ADDRESS="$DST" \
      $( [ -n "$REDIS_PASS" ] && echo "-e SHAKE_SRC_PASSWORD=$REDIS_PASS -e SHAKE_DST_PASSWORD=$REDIS_PASS" ) \
      -v "$TMP_CONFIG":/app/shake_sync_env.toml \
      ghcr.io/tair-opensource/redisshake:latest \
      sync -conf /app/shake_sync_env.toml \
      2>&1 | tee "$LOGFILE" &
  local PID=$!

  echo "🔍 Monitoring logs for diff=[0]..."
  SECONDS=0
  while kill -0 $PID >/dev/null 2>&1; do
    if grep -q "diff=\[0\]" "$LOGFILE"; then
      echo "✅ Sync successful (diff=[0])"
      kill $PID >/dev/null 2>&1 || true
      wait $PID 2>/dev/null || true
      rm -f "$TMP_CONFIG" "$LOGFILE"
      return 0
    fi

    if [ $SECONDS -ge $SYNC_TIMEOUT ]; then
      echo "❌ Timeout reached ($SYNC_TIMEOUT sec) — no diff=[0] detected"
      kill $PID >/dev/null 2>&1 || true
      wait $PID 2>/dev/null || true
      rm -f "$TMP_CONFIG" "$LOGFILE"
      exit 1
    fi
    sleep 2
  done

  echo "❌ Sync process ended without diff=[0]"
  cat "$LOGFILE"
  rm -f "$TMP_CONFIG" "$LOGFILE"
  exit 1
}

# -------------------------
# Helper: check number of keys in all DBs for a given Redis instance
# -------------------------
check_all_dbs() {
  local ADDR="$1"
  local NAME="$2"

  echo "🔍 Checking all DBs on $NAME ($ADDR)..."
  local MAX_DB
  MAX_DB=$(redis_cmd "$ADDR" 0 CONFIG GET databases 2>/dev/null | awk 'NR==2 {print $1}')
  if [ -z "$MAX_DB" ]; then
    MAX_DB=16
  fi

  for ((db=0; db<MAX_DB; db++)); do
    COUNT=$(redis_cmd "$ADDR" $db DBSIZE 2>/dev/null || echo "AUTH_FAILED")
    if [ "$COUNT" = "AUTH_FAILED" ]; then
      echo "  DB[$db] → ❌ Authentication required"
      continue
    fi
    if [[ "$COUNT" =~ ^[0-9]+$ ]]; then
      echo "  DB[$db] → $COUNT keys"
    else
      echo "  DB[$db] → ❌ Unexpected response: $COUNT"
    fi
  done
}

# -------------------------
# Main flow
# -------------------------
echo "✅ Checking if Redis instances are running..."
check_redis_running "$REDIS1_ADDR" "redis1"
check_redis_running "$REDIS2_ADDR" "redis2"

run_sync_separate "$REDIS1_ADDR" "$REDIS2_ADDR" "redis1 → redis2 (before restart)"

read -p "⏸️ Press Enter once you have manually restarted redis1 to continue..."

SRC_MODE=$(detect_tls "$REDIS1_ADDR")
DST_MODE=$(detect_tls "$REDIS2_ADDR")
echo "🔍 TLS status after restart: redis1=$SRC_MODE, redis2=$DST_MODE"

echo "ℹ️ After restart, keys on redis1 (all DBs, should be empty):"
check_all_dbs "$REDIS1_ADDR" "redis1"

run_sync_separate "$REDIS2_ADDR" "$REDIS1_ADDR" "redis2 → redis1 (restore after restart)"

echo "✅ Final verification of redis1 (all DBs):"
check_all_dbs "$REDIS1_ADDR" "redis1"

echo "✅ Final verification of redis2 (all DBs):"
check_all_dbs "$REDIS2_ADDR" "redis2"

echo "🎉 complete!"
