#!/bin/bash
set -e

# -------------------------
# Config
# -------------------------
REDIS_USER=""
REDIS_PASS="MyRedisPass123"
CERTS_DIR="/Users/shubhenduganguly/repo/redis-replication-poc/redis-certs"
MAX_DB=15  # Maximum Redis DB index to check

# -------------------------
# Restart Redis1 (data will be gone)
# -------------------------
echo "Stopping and removing redis1..."
docker rm -f redis1 2>/dev/null || true

echo "Starting redis1 with TLS..."
docker run -d --name redis1 -p 6379:6379 \
  -v "$CERTS_DIR:/certs" \
  redis:7 \
  redis-server \
    --tls-port 6379 \
    --port 0 \
    --requirepass "$REDIS_PASS" \
    --tls-cert-file /certs/redis1.crt \
    --tls-key-file /certs/redis1.key \
    --tls-ca-cert-file /certs/ca.crt \
    --tls-auth-clients optional

echo "Waiting for redis1 to start..."
sleep 5

# -------------------------
# Reapply ACL user
# -------------------------
echo "Setting up ACL user on redis1..."
docker exec redis1 redis-cli \
  --tls \
  --cacert /certs/ca.crt \
  --no-auth-warning \
  -a "$REDIS_PASS" \
  ACL SETUSER "$REDIS_USER" on ">$REDIS_PASS" allkeys allcommands

# -------------------------
# Print keys from all databases
# -------------------------
echo "Listing keys from all databases..."
for db in $(seq 0 $MAX_DB); do
  keys=$(docker exec redis1 redis-cli \
    --tls \
    --cacert /certs/ca.crt \
    --no-auth-warning \
    -a "$REDIS_PASS" \
    -n "$db" KEYS "*")
  
  if [ -n "$keys" ]; then
    echo "DB $db keys:"
    echo "$keys"
  else
    echo "DB $db is empty."
  fi
done

echo "Redis1 restart complete and keys printed."
