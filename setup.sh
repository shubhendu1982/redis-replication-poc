#!/bin/bash

# Cleanup previous containers
docker rm -f redis1 redis2 shake1to2 shake2to1 2>/dev/null || true

echo "Starting Redis 6 instances..."

# Start redis1 (in-memory)
docker run -d --name redis1 -p 6379:6379 redis:6-alpine redis-server --appendonly no --save "" --dir /tmp

# Start redis2 (persistent)
docker run -d --name redis2 -p 6380:6379 redis:6-alpine redis-server --appendonly yes --dir /data

sleep 5

# Add initial keys
echo "Adding initial keys..."
docker exec redis1 redis-cli SET key1 value1_from_redis1
docker exec redis1 redis-cli SET key2 value2_from_redis1
docker exec redis2 redis-cli SET key3 value3_from_redis2
docker exec redis2 redis-cli SET key4 value4_from_redis2

# Start bidirectional Redis-Shake in rump mode (continuous)
echo "Starting Redis-Shake bidirectional sync..."
docker run -d --name shake1to2 --network host \
  -e SYNC=true \
  -e SHAKE_SRC_ADDRESS=127.0.0.1:6379 \
  -e SHAKE_DST_ADDRESS=127.0.0.1:6380 \
  -e SHAKE_TYPE=rump \
  ghcr.io/tair-opensource/redisshake:latest

docker run -d --name shake2to1 --network host \
  -e SYNC=true \
  -e SHAKE_SRC_ADDRESS=127.0.0.1:6380 \
  -e SHAKE_DST_ADDRESS=127.0.0.1:6379 \
  -e SHAKE_TYPE=rump \
  ghcr.io/tair-opensource/redisshake:latest

echo "Waiting 15 seconds for initial sync..."
sleep 15

# Show keys after initial sync
echo "Keys on redis1 after initial sync:"
docker exec redis1 redis-cli KEYS "*"
echo "Keys on redis2 after initial sync:"
docker exec redis2 redis-cli KEYS "*"

# Restart redis1 (in-memory)
echo "Restarting redis1..."
docker restart redis1
sleep 5

# Run a one-time fullsync to restore all keys from redis2 → redis1
echo "Running fullsync to restore redis1..."
docker run --rm --network host \
  -e SYNC=true \
  -e SHAKE_SRC_ADDRESS=127.0.0.1:6380 \
  -e SHAKE_DST_ADDRESS=127.0.0.1:6379 \
  -e SHAKE_TYPE=fullsync \
  ghcr.io/tair-opensource/redisshake:latest

# Wait a few seconds
sleep 5

# Final verification
echo "Final keys on redis1:"
docker exec redis1 redis-cli KEYS "*"
echo "Final keys on redis2:"
docker exec redis2 redis-cli KEYS "*"

echo "Verify values on redis1:"
docker exec redis1 redis-cli MGET key1 key2 key3 key4
echo "Verify values on redis2:"
docker exec redis2 redis-cli MGET key1 key2 key3 key4

echo "Bidirectional in-memory POC with Redis 6 complete!"
