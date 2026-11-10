# ticketing-platform

Local infrastructure for the Distributed Ticketing Platform: one command starts Postgres, Kafka and the observability stack with Docker Compose, inside the 16 GB laptop budget (ADR-027). Later phases add Helm charts, Kubernetes manifests, secrets config and k6 load tests here.

## Quick start
```bash
make up        # core + messaging; waits until every container is healthy (~20 s)
make status    # health + memory per container, with the total
make smoke     # proves it works (Postgres isolation, Kafka round trip, OTLP trace)
make down      # stop; data volumes are kept
```
`make up` copies `.env.example` to `.env` the first time. `make help` lists every command.

| Command | What it does |
|---|---|
| `make up` | Start profiles `core` + `messaging` (override: `make up PROFILES="core"`) |
| `make tools` | Same, plus Kafbat UI |
| `make down` | Stop and remove containers, keep volumes |
| `make status` | `docker compose ps` + `docker stats --no-stream` memory per container and total |
| `make logs` | Follow logs; one service: `make logs s=kafka` |
| `make smoke` | `scripts/smoke-test.sh` |
| `make reset` | **Deletes all data volumes** after you type `yes` |

## What runs
| Service | Image (pinned) | Profile | Memory limit | Host ports (127.0.0.1 only) |
|---|---|---|---|---|
| postgres | `postgres:18.6-alpine` | `core` | 512 MB | 5432 |
| otel-lgtm | `grafana/otel-lgtm:0.40.0` | `core` | 1.5 GB | 3000 Grafana, 4317 OTLP gRPC, 4318 OTLP HTTP |
| kafka | `apache/kafka:4.4.0` | `messaging` | 1 GB (heap 512 MB) | 9092 |
| kafbat-ui | `kafbat/kafka-ui:v1.5.0` | `tools` | 384 MB | 8089 → http://localhost:8089 |

Measured right after start (2026-11-10): core + messaging ≈ **0.9 GB**, with tools ≈ 1.4 GB; limits add up to 3 GB (3.4 GB with tools). Grafana: http://localhost:3000 (anonymous admin locally; `admin`/`admin` to sign in).

### Connecting
| From | Postgres | Kafka | OTLP |
|---|---|---|---|
| The Mac (IDE, Gradle, tests) | `localhost:5432` | `localhost:9092` | `http://localhost:4318` / `localhost:4317` |
| Another container on network `ticketing` | `postgres:5432` | `kafka:19092` | `http://otel-lgtm:4318` / `otel-lgtm:4317` |

Postgres databases and logins: `catalogue`, `inventory`, `booking`, `payment` (password `<SERVICE>_DB_PASSWORD` in `.env`). Each login can connect **only** to its own database (ADR-028). The `postgres` superuser is for admin work only.

```bash
docker exec -it ticketing-postgres psql -U postgres                       # admin shell
docker exec -it ticketing-postgres psql -h 127.0.0.1 -U catalogue catalogue  # as a service
```

## Local secrets
`.env.example` (committed) holds local-only development passwords; `.env` (git-ignored) is the copy Compose actually reads. Postgres applies them only when its volume is empty, so after changing one run `make reset` or `ALTER ROLE … PASSWORD …`. In Phase 4, OpenBao + External Secrets Operator replace this file (ADR-021): secrets come from a vault, not a file on disk.

## Smoke test
`make smoke` prints `OK`/`FAIL` per check and a summary:
1. Each service login connects to its own database and creates a table there; it is **refused** (`permission denied for database`) on the next service's database.
2. Creates topic `smoke-test`, produces one unique message and consumes it through the container listener (`kafka:19092`), then reads it again through the host listener (`localhost:9092`). The Kafka CLI tools run in throw-away containers with their own memory limit.
3. Sends one span over OTLP/HTTP with `curl` and polls Tempo (through Grafana) until the trace is stored. It prints the trace ID and a Grafana link: **Explore → Tempo → TraceQL → paste the trace ID**, or open the printed link.

## Concepts
**Compose networks, volumes, health checks, profiles.** A *network* is a private virtual LAN; containers on it find each other by service name (`kafka`, `postgres`) through Docker's DNS. A *named volume* is storage managed by Docker that survives `down`, so data outlives containers (`make reset` deletes it). A *health check* is a command Docker runs repeatedly; `up --wait` and `depends_on: condition: service_healthy` use it to know when a service is really ready, not just started. *Profiles* tag services so you start only the groups you need.

**Container memory limit vs JVM heap.** `mem_limit` is a hard cap from the Linux kernel (cgroups): exceed it and the process is killed (OOM, exit 137). The JVM heap (`-Xmx`) is only part of a Java process's memory; metaspace, thread stacks, direct buffers and the JIT come on top. So the heap must sit well below the limit: Kafka has 512 MB heap in a 1 GB container.

**KRaft vs ZooKeeper.** Kafka used to keep cluster metadata (topics, partitions, leaders) in a separate ZooKeeper cluster. KRaft moves it into Kafka itself: some nodes act as *controllers* and agree on metadata with the Raft protocol. Kafka 4 removed ZooKeeper. Here one process is both controller and broker (`process.roles=broker,controller`).

**Kafka listeners and advertised listeners.** A *listener* is a socket the broker opens. An *advertised listener* is the address the broker tells clients to use afterwards: a client connects to any bootstrap address, gets the cluster metadata, then reconnects to the advertised address. That address must be reachable from where the client runs, so there are two: `INTERNAL` (advertised `kafka:19092`, the Docker DNS name) for containers, and `EXTERNAL` (advertised `localhost:9092`, the published port) for the Mac. A third, `CONTROLLER` (9093), carries KRaft traffic and is not published.

**Postgres roles, databases and `CONNECT`.** A *role* is a user or group; a role with `LOGIN` can sign in. A *database* is a separate namespace in the same server; one connection reaches exactly one database. Connecting needs the `CONNECT` privilege on that database, which by default is granted to `PUBLIC` (everyone). The init script revokes it from `PUBLIC` and grants it only to the owning service login, so `catalogue` cannot even open a connection to `inventory`.

**OTLP.** The OpenTelemetry Protocol: the standard wire format for sending traces, metrics and logs from an application (or agent) to a backend. Two transports: gRPC on 4317 and HTTP (protobuf or JSON) on 4318. Services export OTLP and never need to know which backend sits behind it.

**What's in `grafana/otel-lgtm`.** One container with: an **OpenTelemetry Collector** (receives OTLP and routes each signal to its store), **Loki** (logs), **Grafana** (UI and dashboards over all stores), **Tempo** (traces), **Prometheus** (metrics; the "M" stands for Mimir, Grafana's scalable Prometheus-compatible store, which Prometheus stands in for here) and **Pyroscope** (continuous profiles). Fine for a laptop; in Kubernetes each part runs on its own (ADR-007).

## Rules for changes
- Pin every image version (no `latest`); set `mem_limit` on every service; publish ports on `127.0.0.1` only.
- New infrastructure (Redis, Apicurio, Keycloak, Elasticsearch) goes in its own profile, started only while a task needs it.
- Never run this together with minikube (ADR-027): `make down` first.
- Commits follow [Conventional Commits](https://www.conventionalcommits.org/); trunk-based on `master`.

## Requirements
Docker with Compose v2 (OrbStack, memory capped at ~8 GB), `make`, `curl`, `openssl`. No Postgres or Kafka tools on the Mac are needed; the smoke test runs them in containers.
