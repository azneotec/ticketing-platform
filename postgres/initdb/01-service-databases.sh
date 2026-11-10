#!/usr/bin/env bash
# Creates one database and one login per service (ADR-028).
# The official Postgres image runs this once, when the data volume is empty.
#
# Isolation is by privilege, not by container:
#  - each login owns its own database (so it can create its schema there),
#  - PUBLIC loses CONNECT on every database, so a login can connect only where it was granted.
# Passwords come from environment variables (set in .env, see .env.example).
set -euo pipefail

create_service_db() { # $1 = service name, $2 = password
  # psql variables (:"name" for identifiers, :'pw' for literals) quote values safely.
  psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres \
    -v svc="$1" -v pw="$2" <<'SQL'
CREATE ROLE :"svc" LOGIN PASSWORD :'pw';
CREATE DATABASE :"svc" OWNER :"svc";
REVOKE CONNECT, TEMPORARY ON DATABASE :"svc" FROM PUBLIC;
GRANT CONNECT, TEMPORARY ON DATABASE :"svc" TO :"svc";
SQL
  echo "created database and login: $1"
}

create_service_db catalogue "$CATALOGUE_DB_PASSWORD"
create_service_db inventory "$INVENTORY_DB_PASSWORD"
create_service_db booking "$BOOKING_DB_PASSWORD"
create_service_db payment "$PAYMENT_DB_PASSWORD"

# The admin database is for the superuser only.
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres \
  -c 'REVOKE CONNECT, TEMPORARY ON DATABASE postgres FROM PUBLIC;'
