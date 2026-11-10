#!/usr/bin/env bash
# Smoke test for the local platform (`make up` first). Checks:
#  1. Postgres: every service login reaches its own database and is REFUSED on another's.
#  2. Kafka: create a topic, produce one message and consume it, through both listeners
#     (container network kafka:19092 and host localhost:9092).
#  3. Observability: send one test trace over OTLP/HTTP and find it in Tempo via Grafana.
# Prints OK/FAIL per check and a summary; exits non-zero if anything failed.
set -uo pipefail

cd "$(dirname "$0")/.."
if [ ! -f .env ]; then
  echo "No .env file. Run 'make up' first." >&2
  exit 1
fi
set -a
# shellcheck disable=SC1091
. ./.env
set +a

KAFKA_IMAGE="apache/kafka:4.4.0"
NETWORK="ticketing"
GRAFANA="http://127.0.0.1:3000"
OTLP_HTTP="http://127.0.0.1:4318"

PASS=0
FAIL=0
ok() { echo "OK    $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL  $1"; [ -n "${2:-}" ] && echo "$2" | sed 's/^/        /'; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------- 1. Postgres
echo "== Postgres: database per service (ADR-028)"

password_of() { # $1 = service -> its password from .env
  local var
  var="$(echo "$1" | tr '[:lower:]' '[:upper:]')_DB_PASSWORD"
  echo "${!var}"
}

psql_as() { # $1 = login, $2 = database, $3 = SQL. Uses TCP (-h) so the password is really checked.
  docker exec -e PGPASSWORD="$(password_of "$1")" ticketing-postgres \
    psql -h 127.0.0.1 -U "$1" -d "$2" -v ON_ERROR_STOP=1 -tAc "$3" 2>&1
}

SERVICES=(catalogue inventory booking payment)
for i in "${!SERVICES[@]}"; do
  svc="${SERVICES[$i]}"
  other="${SERVICES[$(((i + 1) % ${#SERVICES[@]}))]}"

  # Own database: connect, and create + drop a table (the login owns its database).
  if out="$(psql_as "$svc" "$svc" 'CREATE TABLE smoke_check (id int); DROP TABLE smoke_check; SELECT current_database();')" \
    && [ "$(echo "$out" | tail -1)" = "$svc" ]; then
    ok "$svc login can connect to and create tables in database '$svc'"
  else
    fail "$svc login cannot use its own database" "$out"
  fi

  # Another service's database: must be refused.
  if out="$(psql_as "$svc" "$other" 'SELECT 1')"; then
    fail "$svc login connected to database '$other' (should be refused)"
  elif echo "$out" | grep -q "permission denied for database"; then
    ok "$svc login is refused on database '$other' ($(echo "$out" | grep -o 'permission denied for database "*[a-z]*"*'))"
  else
    fail "$svc login failed on '$other', but not with 'permission denied'" "$out"
  fi
done

# ---------------------------------------------------------------- 2. Kafka
echo "== Kafka: topic, produce, consume"

TOPIC="smoke-test"
MESSAGE="smoke-$(date +%Y%m%dT%H%M%S)-$RANDOM"

kafka_cli() { # $1 = docker network ("ticketing" or "host"), rest = shell script run in a throw-away container
  local net="$1"
  shift
  # A separate short-lived container with its own small memory limit, so the CLI tools never
  # compete with the broker's heap.
  docker run --rm --network "$net" --memory 384m -e KAFKA_HEAP_OPTS=-Xmx128m \
    "$KAFKA_IMAGE" bash -c "$*" 2>&1
}

# Container network: listener INTERNAL, advertised as kafka:19092.
if out="$(kafka_cli "$NETWORK" "
  set -e
  cd /opt/kafka/bin
  ./kafka-topics.sh --bootstrap-server kafka:19092 --create --if-not-exists --topic $TOPIC --partitions 1 --replication-factor 1 >/dev/null
  echo '$MESSAGE' | ./kafka-console-producer.sh --bootstrap-server kafka:19092 --topic $TOPIC
  ./kafka-console-consumer.sh --bootstrap-server kafka:19092 --topic $TOPIC --from-beginning --timeout-ms 15000 2>/dev/null || true
")" && echo "$out" | grep -qxF "$MESSAGE"; then
  ok "topic '$TOPIC': produced and consumed '$MESSAGE' via kafka:19092 (container network)"
else
  fail "Kafka round trip via kafka:19092" "$out"
fi

# Host: listener EXTERNAL, advertised as localhost:9092. A host-networked container sees the
# Mac's localhost (OrbStack), so it behaves like a client running on the Mac.
if out="$(kafka_cli host "
  /opt/kafka/bin/kafka-console-consumer.sh --bootstrap-server localhost:9092 --topic $TOPIC --from-beginning --timeout-ms 15000 2>/dev/null || true
")" && echo "$out" | grep -qxF "$MESSAGE"; then
  ok "consumed the same message via localhost:9092 (host listener)"
else
  fail "Kafka consume via localhost:9092 (host listener)" "$out"
fi

# ---------------------------------------------------------------- 3. OTLP trace
echo "== Observability: OTLP trace into Tempo"

TRACE_ID="$(openssl rand -hex 16)"
SPAN_ID="$(openssl rand -hex 8)"
NOW_S="$(date +%s)"
START_NS="${NOW_S}000000000"
END_NS="${NOW_S}250000000" # 250 ms span

# OTLP/HTTP with a JSON body: one resource (service.name), one scope, one span.
SPAN_JSON="$(cat <<JSON
{"resourceSpans":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"smoke-test"}}]},
 "scopeSpans":[{"scope":{"name":"ticketing-platform/smoke-test"},
  "spans":[{"traceId":"$TRACE_ID","spanId":"$SPAN_ID","name":"smoke-test-span","kind":1,
   "startTimeUnixNano":"$START_NS","endTimeUnixNano":"$END_NS",
   "attributes":[{"key":"smoke.message","value":{"stringValue":"$MESSAGE"}}]}]}]}]}
JSON
)"

code="$(curl -s -o /dev/null -w '%{http_code}' -X POST "$OTLP_HTTP/v1/traces" \
  -H 'Content-Type: application/json' -d "$SPAN_JSON")"
if [ "$code" = "200" ]; then
  ok "trace $TRACE_ID accepted by the OTel Collector (POST $OTLP_HTTP/v1/traces -> 200)"
else
  fail "OTLP export returned HTTP $code"
fi

# Ask Tempo, through Grafana's data source proxy, until the trace is searchable (a few seconds).
found=false
for _ in $(seq 1 30); do
  if curl -sf "$GRAFANA/api/datasources/proxy/uid/tempo/api/v2/traces/$TRACE_ID" | grep -q "smoke-test-span"; then
    found=true
    break
  fi
  sleep 1
done
if $found; then
  ok "trace $TRACE_ID is stored in Tempo"
else
  fail "trace $TRACE_ID not found in Tempo after 30 s"
fi

# ---------------------------------------------------------------- summary
echo
echo "$PASS passed, $FAIL failed"
echo
echo "See the trace by eye: Grafana $GRAFANA -> Explore -> data source 'Tempo' -> query type"
echo "'TraceQL' -> paste the trace ID $TRACE_ID -> Run query. Or open directly:"
echo "  $GRAFANA/explore?schemaVersion=1&panes=%7B%22t%22:%7B%22datasource%22:%22tempo%22,%22queries%22:%5B%7B%22refId%22:%22A%22,%22datasource%22:%7B%22type%22:%22tempo%22,%22uid%22:%22tempo%22%7D,%22queryType%22:%22traceql%22,%22query%22:%22$TRACE_ID%22%7D%5D,%22range%22:%7B%22from%22:%22now-1h%22,%22to%22:%22now%22%7D%7D%7D&orgId=1"
[ "$FAIL" -eq 0 ]
