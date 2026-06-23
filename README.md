# Observability Demo - Developer Days

End-to-end observability demo on OpenShift using the **MyReadings** microservices application.

## Architecture

```
Layer 0 - Operators        OTel, Loki, Tempo, COO, OLS, Crunchy, RHBK, RabbitMQ
Layer 1 - Platform         UWM, LokiStack, TempoStack, Korrel8r, Perses, OLS
Layer 2a - Infrastructure  PostgreSQL, Keycloak, RabbitMQ (namespace-scoped)
Layer 2b - Application     4 Quarkus microservices + UI via Helm chart
```

**Observability pipeline:** Apps → OTLP → OTel Collector → Tempo (traces), Loki (logs), Prometheus (metrics via pull)

## Prerequisites

- OpenShift 4.22+ cluster with `admin` access
- **ODF** (OpenShift Data Foundation) installed -- required for object storage (Loki/Tempo buckets use `openshift-storage.noobaa.io`)
- **Container images** pre-built and pushed to `quay.io/rh-ee-drossi` (or override `global.imageRegistry` in the Helm chart)
- CLI tools: `oc`, `helm`, `yq`
- (Optional) `LLM_URL` and `LLM_API_TOKEN` for OpenShift Lightspeed

## Quick Start

```bash
# Full install (operators → platform → infra → app)
make deploy-all LLM_URL=https://... LLM_API_TOKEN=...

# Or step by step
make deploy-operators
make deploy-platform LLM_URL=https://... LLM_API_TOKEN=...
make deploy-infra
make deploy-app
```

## Demo Scenarios

```bash
# Inject N+1 query regression on catalog search
make break-app

# Restore normal behavior
make fix-app

# Run load test (opens http://localhost:8089)
make stress
```

## Teardown

```bash
make destroy-app          # remove app only (keeps Postgres, Keycloak, RabbitMQ)
make destroy-all          # remove app + infrastructure (keeps operators & platform)
make delete-operators     # remove operator subscriptions
```

## Repository Layout

```
infrastructure/
  00-operators/           Operator subscriptions (o11y + app backing services)
  01-platform/            Cluster-wide observability stack (UWM, Loki, Tempo, Korrel8r, Perses, OLS)
   02-app-infra/           Namespace-scoped backing services (Postgres, Keycloak, RabbitMQ)
scripts/                  Setup and wait helper scripts
stress/                   Locust load test
```

The Helm chart for the application layer lives at [MyReadings/myreadings_helm](https://github.com/MyReadings/myreadings_helm) and is cloned automatically on first `make deploy-app`.
