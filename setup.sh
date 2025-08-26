#!/bin/bash

# -------------------------
# Common username and password for both Redis instances
# -------------------------
REDIS_USER="myuser"
REDIS_PASS="MyRedisPass123"

# -------------------------
# Cleanup previous containers
# -------------------------
echo "Cleaning up previous containers..."
docker rm -f redis1 redis2 2>/dev/null || true
docker volume rm redis1-data redis2-data 2>/dev/null || true

echo "Starting fresh Redis 6 instances (memory-only) with username and password..."

# Start Redis instances with no persistence and requirepass
docker run -d --name redis1 -p 6379:6379 redis:6-alpine \
    redis-server --appendonly no --save "" --requirepass "$REDIS_PASS"

docker run -d --name redis2 -p 6380:6379 redis:6-alpine \
    redis-server --appendonly no --save "" --requirepass "$REDIS_PASS"

# Wait for Redis to be ready
echo "Waiting for Redis instances to start..."
sleep 3

# Create a user with full permissions (for Redis 6+ ACLs)
echo "Setting up ACL users..."
docker exec redis1 redis-cli -a "$REDIS_PASS" ACL SETUSER "$REDIS_USER" on ">$REDIS_PASS" allkeys allcommands
docker exec redis2 redis-cli -a "$REDIS_PASS" ACL SETUSER "$REDIS_USER" on ">$REDIS_PASS" allkeys allcommands

# Verify ACL setup
echo "Verifying ACL setup on redis1:"
docker exec redis1 redis-cli -a "$REDIS_PASS" ACL LIST | grep "$REDIS_USER"
echo "Verifying ACL setup on redis2:"
docker exec redis2 redis-cli -a "$REDIS_PASS" ACL LIST | grep "$REDIS_USER"

# Add initial keys ONLY to redis1 using the user credentials
echo "Adding initial keys to redis1..."
docker exec redis1 redis-cli -u "redis://$REDIS_USER:$REDIS_PASS@localhost:6379" SET key1 value1_from_redis1
docker exec redis1 redis-cli -u "redis://$REDIS_USER:$REDIS_PASS@localhost:6379" SET key2 value2_from_redis1
docker exec redis1 redis-cli -u "redis://$REDIS_USER:$REDIS_PASS@localhost:6379" SET key3 value3_from_redis1
docker exec redis1 redis-cli -u "redis://$REDIS_USER:$REDIS_PASS@localhost:6379" SET key4 value4_from_redis1

# Verify keys
echo "Initial keys in redis1:"
docker exec redis1 redis-cli -u "redis://$REDIS_USER:$REDIS_PASS@localhost:6379" KEYS "*"

echo "Initial keys in redis2 (should be empty):"
docker exec redis2 redis-cli -u "redis://$REDIS_USER:$REDIS_PASS@localhost:6379" KEYS "*"

# Verify connectivity with user credentials
echo "Testing connectivity with user credentials..."
docker exec redis1 redis-cli -u "redis://$REDIS_USER:$REDIS_PASS@localhost:6379" PING
docker exec redis2 redis-cli -u "redis://$REDIS_USER:$REDIS_PASS@localhost:6379" PING

echo "Redis setup complete!"
echo "redis1: localhost:6379"
echo "redis2: localhost:6380"
echo "Username: $REDIS_USER"
echo "Password: $REDIS_PASS"

# -------------------------
# To restart redis1 manually, use the command below:
#REDIS_USER="myuser" REDIS_PASS="MyRedisPass123"; docker rm -f redis1 2>/dev/null || true; docker run -d --name redis1 -p 6379:6379 redis:6-alpine redis-server --appendonly no --save "" --requirepass "$REDIS_PASS" && sleep 3 && docker exec redis1 redis-cli -a "$REDIS_PASS" ACL SETUSER "$REDIS_USER" on ">$REDIS_PASS" allkeys allcommands
