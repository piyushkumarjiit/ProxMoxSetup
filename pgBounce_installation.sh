#!/bin/bash
# -------------------------------------------------------------------------
# FILE: deploy-pgbouncer.sh
# ROLE: Adds PgBouncer to an existing CIP stack without breaking it
# -------------------------------------------------------------------------

echo "--- 1. Navigating to Stack Directory ---"
cd /opt/cip-stack || { echo "Directory /opt/cip-stack not found!"; exit 1; }

echo "--- 2. Creating docker-compose.override.yml ---"
cat <<EOF > docker-compose.override.yml
services:
  pgbouncer:
    image: edoburu/pgbouncer:latest
    container_name: cip_pgbouncer
    environment:
      # Connects using the internal Docker DNS name of your postgres service
      DB_HOST: postgres
      DB_USER: cip_user
      DB_PASSWORD: cip_password
      DB_NAME: cip_entities
      POOL_MODE: transaction
      MAX_CLIENT_CONN: 2000
      DEFAULT_POOL_SIZE: 40
      IGNORE_STARTUP_PARAMETERS: extra_float_digits
    ports: 
      - "6432:5432"
    depends_on:
      - postgres
    security_opt:
      - apparmor:unconfined
    restart: always
EOF

echo "--- 3. Applying the Update ---"
# Docker Compose will automatically read the override file and start just the new container
# while leaving your existing postgres, redis, and qdrant containers running untouched.
docker compose up -d

echo "--- SUCCESS ---"
echo "PgBouncer is now running and proxying traffic to Postgres."
echo "Verify logs with: docker logs cip_pgbouncer"
