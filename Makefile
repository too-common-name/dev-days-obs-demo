# ====================================================================================
#  OBSERVABILITY DEMO AUTOMATION
# ====================================================================================

OC     := oc
YQ     := yq
HELM   := helm
PODMAN := podman

# --- Directories ---
OPERATORS_DIR := infrastructure/00-operators
PLATFORM_DIR  := infrastructure/01-platform
APP_INFRA_DIR := infrastructure/02-app-infra
SCRIPTS_DIR   := scripts

# --- OLS ---
OLS_NS              := openshift-lightspeed
OLS_OPERATOR_DEPLOY := lightspeed-operator-controller-manager
OLS_APP_LABEL       := app.kubernetes.io/component=application-server

INCIDENT_MCP_BASE_URL := https://raw.githubusercontent.com/openshift/cluster-health-analyzer/refs/heads/main/manifests/mcp

# --- Helm Chart (cloned from GitHub into .cache/) ---
HELM_REPO      := https://github.com/MyReadings/myreadings_helm
HELM_REF       := main
HELM_CHART_DIR := .cache/myreadings_helm
HELM_RELEASE   := myreadings

# --- Namespace & Keycloak ---
APP_NS    := myreadings-dev
KC_REALM  := my-readings
KC_CLIENT := myreadings-client

# --- Dynamic cluster lookups ---
KC_HOST  = $(shell $(OC) get route myreadings-keycloak -n $(APP_NS) -o jsonpath='https://{.spec.host}' 2>/dev/null)
APP_HOST = $(shell $(OC) get route myreadings-ui -n $(APP_NS) -o jsonpath='https://{.spec.host}' 2>/dev/null)

# --- Storage (override for clusters with different SC names) ---
STORAGE_CLASS_BLOCK ?= ocs-external-storagecluster-ceph-rbd
STORAGE_CLASS_OBC   ?= openshift-storage.noobaa.io
USE_OBC             ?= true

# --- Stress test (override via env or CLI) ---
KC_USERNAME    ?= testuser
KC_PASSWORD    ?= testuser

_ := $(shell chmod +x $(SCRIPTS_DIR)/*.sh 2>/dev/null)

# --- RabbitMQ (installed from upstream manifest, not OLM) ---
RABBITMQ_OPERATOR_URL := https://github.com/rabbitmq/cluster-operator/releases/latest/download/cluster-operator.yml

.PHONY: help check-tools \
	deploy-operators deploy-platform-operators deploy-app-operators delete-operators \
	deploy-platform deploy-infra deploy-app deploy-all \
	stress break fix fix-all prep-demo \
	fix-postgres \
	destroy-app destroy-infra destroy-platform destroy-all

help: ## Show this help message
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-25s\033[0m %s\n", $$1, $$2}'

check-tools: ## Verify required CLI tools are installed
	@which $(OC) > /dev/null   || (echo "Error: oc not found"   && exit 1)
	@which $(YQ) > /dev/null   || (echo "Error: yq not found"   && exit 1)
	@which $(HELM) > /dev/null || (echo "Error: helm not found" && exit 1)
	@which git > /dev/null     || (echo "Error: git not found"  && exit 1)
	@which $(PODMAN) > /dev/null || (echo "Error: podman not found" && exit 1)
	@which python3 > /dev/null || (echo "Error: python3 not found" && exit 1)
	@which curl > /dev/null    || (echo "Error: curl not found" && exit 1)
	@which envsubst > /dev/null || (echo "Error: envsubst not found (install gettext)" && exit 1)
	@echo "Cluster: $$($(OC) whoami --show-server)"

# ====================================================================================
#  LAYER 0 -- OPERATORS
# ====================================================================================

deploy-platform-operators: check-tools ## Install o11y operators only
	@echo "[Layer 0a] Installing platform operators..."
	@$(OC) apply -R -f $(OPERATORS_DIR)/platform
	@./$(SCRIPTS_DIR)/wait-for-operators.sh platform

deploy-app-operators: check-tools ## Install app operators (Crunchy + RHBK + RabbitMQ)
	@echo "[Layer 0b] Installing app operators..."
	@$(OC) apply -f $(APP_INFRA_DIR)/namespace.yaml
	@$(OC) apply -R -f $(OPERATORS_DIR)/app
	@$(OC) apply -f $(RABBITMQ_OPERATOR_URL)
	@./$(SCRIPTS_DIR)/wait-for-operators.sh app

deploy-operators: deploy-platform-operators deploy-app-operators ## Install all operators

delete-operators: check-tools ## Uninstall operator subscriptions
	@$(OC) delete -R -f $(OPERATORS_DIR)/platform --ignore-not-found
	@$(OC) delete -R -f $(OPERATORS_DIR)/app --ignore-not-found
	@$(OC) delete -f $(RABBITMQ_OPERATOR_URL) --ignore-not-found
	@echo "Cleaning orphaned CSVs..."
	@$(OC) delete csv -n openshift-operators -l operators.coreos.com/crunchy-postgres-operator.openshift-operators= --ignore-not-found 2>/dev/null || \
		($(OC) get csv -n openshift-operators -o name 2>/dev/null | grep postgres | xargs -r $(OC) delete -n openshift-operators --ignore-not-found 2>/dev/null || true)
	@$(OC) get csv -n rhbk-operator -o name 2>/dev/null | grep rhbk | xargs -r $(OC) delete -n rhbk-operator --ignore-not-found 2>/dev/null || true

# ====================================================================================
#  LAYER 1 -- PLATFORM (cluster-wide observability + OLS)
# ====================================================================================

deploy-platform: check-tools ## Deploy UWM, Loki, Tempo, Korrel8r, Perses, MCP, OLS
	@echo "[Layer 1] Deploying platform..."
	@$(OC) apply -f $(INCIDENT_MCP_BASE_URL)/01_service_account.yaml
	@$(OC) apply -f $(INCIDENT_MCP_BASE_URL)/02_deployment.yaml
	@$(OC) apply -f $(INCIDENT_MCP_BASE_URL)/03_mcp_service.yaml
	@$(OC) apply -f $(PLATFORM_DIR)/00-monitoring-config.yaml
	@if [ "$(USE_OBC)" = "true" ]; then \
		sed 's|openshift-storage.noobaa.io|$(STORAGE_CLASS_OBC)|g' $(PLATFORM_DIR)/01-storage-claims.yaml | $(OC) apply -f -; \
		./$(SCRIPTS_DIR)/setup-storage.sh; \
	else \
		echo "Skipping OBC (USE_OBC=false). Ensure Loki/Tempo secrets exist."; \
	fi
	@if [ "$(USE_OBC)" = "true" ]; then \
		sed 's|ocs-external-storagecluster-ceph-rbd|$(STORAGE_CLASS_BLOCK)|g' $(PLATFORM_DIR)/02-logging-stack.yaml | $(OC) apply -f -; \
	else \
		sed 's|ocs-external-storagecluster-ceph-rbd|$(STORAGE_CLASS_BLOCK)|g' $(PLATFORM_DIR)/02-logging-stack.yaml | \
			$(YQ) 'del(.spec.storage.tls)' | $(OC) apply -f -; \
	fi
	@if [ "$(USE_OBC)" = "true" ]; then \
		$(OC) apply -f $(PLATFORM_DIR)/03-tracing-stack.yaml; \
	else \
		$(YQ) 'del(.spec.storage.tls)' $(PLATFORM_DIR)/03-tracing-stack.yaml | $(OC) apply -f -; \
	fi
	@$(OC) apply -f $(PLATFORM_DIR)/04-ui-plugins.yaml
	@$(OC) apply -f $(PLATFORM_DIR)/05-korrel8r-otel-rules.yaml
	@echo "Waiting for Korrel8r deployment..."
	@for i in $$(seq 1 30); do \
		$(OC) get deployment korrel8r -n openshift-cluster-observability-operator >/dev/null 2>&1 && break; \
		sleep 10; \
	done
	@$(OC) apply --server-side --field-manager=korrel8r-otel-customization --force-conflicts \
		-f $(PLATFORM_DIR)/06-korrel8r-deployment-patch.yaml 2>/dev/null || \
		echo "Korrel8r deployment not found (apply patch manually later)."
	@$(OC) apply -f $(PLATFORM_DIR)/07-perses-datasource.yaml
	@# --- OLS ---
	@CSV=$$($(OC) get csv -n openshift-lightspeed -o jsonpath='{.items[?(@.spec.displayName=="OpenShift Lightspeed Operator")].metadata.name}' 2>/dev/null); \
	if [ -n "$$CSV" ]; then \
		$(OC) get csv $$CSV -n openshift-lightspeed -o yaml | \
			$(YQ) '(.spec.install.spec.deployments[].spec.template.spec.containers[].args[] | select(. == "--openshift-mcp-server-image=*")) = "--openshift-mcp-server-image=quay.io/tremes/ocp-mcp"' | \
			$(OC) replace -f -; \
	fi
	@if [ -n "$(LLM_URL)" ] && [ -n "$(LLM_API_TOKEN)" ]; then \
		model_info=$$(curl -sk "$(LLM_URL)/models" -H "Authorization: Bearer $(LLM_API_TOKEN)"); \
		model_name=$$(echo "$$model_info" | yq '.data[0].id'); \
		ctx_window=$$(echo "$$model_info" | yq -r '.data[0].max_model_len // 131072'); \
		export LLM_URL="$(LLM_URL)" \
			   LLM_API_TOKEN="$$(echo -n '$(LLM_API_TOKEN)' | base64 -w0)" \
			   LLM_MODEL="$$model_name" \
			   LLM_CONTEXT_WINDOW="$$ctx_window"; \
		envsubst < $(PLATFORM_DIR)/templates/ols-config.yaml > $(PLATFORM_DIR)/_generated/ols-config.yaml; \
		$(OC) apply -f $(PLATFORM_DIR)/_generated/ols-config.yaml; \
		echo "OLS configured (model: $$model_name, context: $$ctx_window)."; \
	else \
		echo "OLS skipped (set LLM_URL and LLM_API_TOKEN to enable)."; \
	fi
	@echo "Platform deployed."

# ====================================================================================
#  LAYER 2a -- APP INFRASTRUCTURE (Postgres, RabbitMQ, Keycloak)
# ====================================================================================

deploy-infra: check-tools ## Deploy backing services, wait, configure, enable grants
	@echo "[Layer 2a] Deploying infrastructure..."
	@$(OC) apply -f $(APP_INFRA_DIR)/namespace.yaml
	@$(OC) apply -f $(APP_INFRA_DIR)/perses-dashboards.yaml
	@$(OC) apply -f $(APP_INFRA_DIR)/postgres/scc-privileged.yaml
	@$(OC) apply -f $(APP_INFRA_DIR)/rabbitmq/scc-privileged.yaml
	@$(OC) apply -f $(APP_INFRA_DIR)/postgres/init-sql.yaml          -n $(APP_NS)
	@$(OC) apply -f $(APP_INFRA_DIR)/postgres/postgrescluster.yaml   -n $(APP_NS)
	@$(OC) apply -f $(APP_INFRA_DIR)/rabbitmq/rabbitmqcluster.yaml   -n $(APP_NS)
	@echo "Waiting for RabbitMQ secret..."
	@for i in $$(seq 1 60); do \
		$(OC) get secret myreadings-rabbitmq-default-user -n $(APP_NS) >/dev/null 2>&1 && break; \
		sleep 5; \
	done
	@$(OC) get secret myreadings-rabbitmq-default-user -n $(APP_NS) >/dev/null 2>&1 || \
		(echo "Error: RabbitMQ secret not ready after 5 min" && exit 1)
	@$(OC) apply -f $(APP_INFRA_DIR)/keycloak/keycloak.yaml -n $(APP_NS)
	@$(OC) apply -f $(APP_INFRA_DIR)/keycloak/route.yaml    -n $(APP_NS)
	@echo "Waiting for infrastructure pods..."
	@$(OC) wait --for=condition=Ready pod -l postgres-operator.crunchydata.com/instance-set=instance1 -n $(APP_NS) --timeout=300s
	@$(OC) wait --for=condition=Ready pod -l app.kubernetes.io/name=myreadings-rabbitmq -n $(APP_NS) --timeout=300s
	@$(OC) wait --for=condition=Ready pod -l app=keycloak -n $(APP_NS) --timeout=300s
	@echo "Running configuration jobs..."
	@APPS_DOMAIN=$$($(OC) get ingresses.config/cluster -o jsonpath='{.spec.domain}'); \
	$(OC) create configmap myreadings-app-config \
		--from-literal=FRONTEND_URL="https://myreadings-ui-$(APP_NS).$$APPS_DOMAIN" \
		--from-literal=KC_TEST_USER="$(KC_USERNAME)" \
		--from-literal=KC_TEST_PASSWORD="$(KC_PASSWORD)" \
		-n $(APP_NS) --dry-run=client -o yaml | $(OC) apply -f -
	@$(OC) apply -f $(APP_INFRA_DIR)/config-jobs/ -n $(APP_NS)
	@echo "Infrastructure deployed."

# ====================================================================================
#  LAYER 2b -- APP DEPLOYMENT (Helm from GitHub)
# ====================================================================================

$(HELM_CHART_DIR):
	@git clone --depth 1 -b $(HELM_REF) $(HELM_REPO) $(HELM_CHART_DIR)

deploy-app: check-tools $(HELM_CHART_DIR) ## Deploy microservices via Helm (chart from GitHub)
	@KC_ISSUER="$$($(OC) get route myreadings-keycloak -n $(APP_NS) -o jsonpath='https://{.spec.host}/realms/$(KC_REALM)')"; \
	$(HELM) upgrade --install $(HELM_RELEASE) $(HELM_CHART_DIR) -n $(APP_NS) --wait --timeout 5m \
		--set keycloak.tokenIssuer="$$KC_ISSUER"
	@echo "App deployed: $(APP_HOST)"

deploy-all: deploy-operators deploy-platform deploy-infra deploy-app ## Full install from scratch

# ====================================================================================
#  DEMO SCENARIOS
# ====================================================================================

break: check-tools $(HELM_CHART_DIR) ## Inject N+1 + constrain resources
	@$(HELM) upgrade $(HELM_RELEASE) $(HELM_CHART_DIR) -n $(APP_NS) --reuse-values \
		--set catalog.searchStrategy=broken \
		--set catalog.searchDelayMs=50 \
		--set readinglist.resources.requests.cpu=50m \
		--set readinglist.resources.limits.cpu=75m \
		--set readinglist.resources.requests.memory=48Mi \
		--set readinglist.resources.limits.memory=96Mi
	@$(OC) rollout status deployment/catalog-service -n $(APP_NS) --timeout=120s
	@$(OC) rollout status deployment/readinglist-service -n $(APP_NS) --timeout=120s

fix: check-tools $(HELM_CHART_DIR) ## Restore everything (single helm upgrade)
	@$(HELM) upgrade $(HELM_RELEASE) $(HELM_CHART_DIR) -n $(APP_NS) --reuse-values \
		--set catalog.searchStrategy=normal \
		--set catalog.searchDelayMs=0 \
		--set catalog.resources.requests.cpu=300m \
		--set catalog.resources.limits.cpu=1 \
		--set catalog.resources.requests.memory=128Mi \
		--set catalog.resources.limits.memory=256Mi \
		--set readinglist.resources.requests.cpu=150m \
		--set readinglist.resources.limits.cpu=500m \
		--set readinglist.resources.requests.memory=128Mi \
		--set readinglist.resources.limits.memory=256Mi
	@$(OC) rollout status deployment/catalog-service -n $(APP_NS) --timeout=120s
	@$(OC) rollout status deployment/readinglist-service -n $(APP_NS) --timeout=120s
	@echo "All restored."

DEMO_PROMPT := $(PLATFORM_DIR)/templates/ols-demo-prompt.txt

prep-demo: check-tools ## Pause OLS operator, enable traces toolset, apply demo prompt
	@echo "Pausing OLS operator..."
	@$(OC) scale deployment $(OLS_OPERATOR_DEPLOY) -n $(OLS_NS) --replicas=0
	@echo "Enabling traces toolset in MCP server..."
	@$(OC) get configmap openshift-mcp-server-config -n $(OLS_NS) -o json | \
		python3 -c "import sys,json; cm=json.load(sys.stdin); \
			toml=cm['data']['config.toml']; \
			toml=toml.replace('toolsets = [\"core\", \"config\", \"helm\", \"metrics\"]', \
				'toolsets = [\"core\", \"config\", \"helm\", \"metrics\", \"traces\"]') \
				if '\"traces\"' not in toml else toml; \
			cm['data']['config.toml']=toml; json.dump(cm,sys.stdout)" | \
		$(OC) replace -f -
	@if [ -f "$(DEMO_PROMPT)" ]; then \
		echo "Applying demo prompt..."; \
		$(OC) get configmap olsconfig -n $(OLS_NS) -o json | \
			python3 -c "import sys,json; cm=json.load(sys.stdin); \
				cm['data']['system_prompt']=open('$(DEMO_PROMPT)').read(); \
				json.dump(cm,sys.stdout)" | \
			$(OC) replace -f -; \
	fi
	@$(OC) delete pod -n $(OLS_NS) -l $(OLS_APP_LABEL) --wait=false
	@echo "OLS restarting with traces enabled (~60s)."

fix-all: fix ## Full reset: fix app + unpause OLS operator (reconciles prompt + toolsets)
	@echo "Unpausing OLS operator."
	@$(OC) scale deployment $(OLS_OPERATOR_DEPLOY) -n $(OLS_NS) --replicas=1
	@echo "All restored."

stress: check-tools ## Run Locust load test via Podman
	@test -n "$(KC_USERNAME)" || (echo "Error: set KC_USERNAME and KC_PASSWORD" && exit 1)
	@$(PODMAN) rm -f myreadings-locust 2>/dev/null || true
	@$(PODMAN) run -d --name myreadings-locust --network host -v ./stress:/stress:Z \
		-e KC_TOKEN_URL="$(KC_HOST)/realms/$(KC_REALM)/protocol/openid-connect/token" \
		-e KC_CLIENT_ID="$(KC_CLIENT)" \
		-e KC_USERNAME="$(KC_USERNAME)" \
		-e KC_PASSWORD="$(KC_PASSWORD)" \
		docker.io/locustio/locust -f /stress/locustfile.py --host $(APP_HOST)
	@echo "Locust running → http://localhost:8089"
	@echo "Stop: podman stop myreadings-locust"

# ====================================================================================
#  MAINTENANCE
# ====================================================================================

fix-postgres: check-tools ## Fix Postgres after cluster reboot (Patroni standby.signal issue)
	@PG_POD=$$($(OC) get pod -n $(APP_NS) -l postgres-operator.crunchydata.com/instance-set=instance1 -o name); \
	$(OC) debug $$PG_POD -c database -n $(APP_NS) -- rm -f /pgdata/pg16/standby.signal; \
	$(OC) delete $$PG_POD -n $(APP_NS); \
	echo "Waiting for Postgres to recover..."; \
	$(OC) wait --for=condition=Ready pod -l postgres-operator.crunchydata.com/instance-set=instance1 -n $(APP_NS) --timeout=120s
	@echo "Postgres recovered."

# ====================================================================================
#  TEARDOWN
# ====================================================================================

destroy-app: check-tools ## Uninstall Helm release (keeps infra)
	@$(HELM) uninstall $(HELM_RELEASE) -n $(APP_NS) || true

destroy-infra: check-tools ## Delete Postgres, Keycloak, RabbitMQ, dashboards, SCC, namespace
	@$(OC) delete -f $(APP_INFRA_DIR)/config-jobs/                  -n $(APP_NS) --ignore-not-found
	@$(OC) delete -f $(APP_INFRA_DIR)/keycloak/keycloak.yaml        -n $(APP_NS) --ignore-not-found
	@$(OC) delete -f $(APP_INFRA_DIR)/keycloak/route.yaml           -n $(APP_NS) --ignore-not-found
	@$(OC) delete -f $(APP_INFRA_DIR)/rabbitmq/rabbitmqcluster.yaml -n $(APP_NS) --ignore-not-found
	@$(OC) delete -f $(APP_INFRA_DIR)/postgres/postgrescluster.yaml -n $(APP_NS) --ignore-not-found
	@$(OC) delete -f $(APP_INFRA_DIR)/postgres/init-sql.yaml        -n $(APP_NS) --ignore-not-found
	@$(OC) delete configmap myreadings-app-config                   -n $(APP_NS) --ignore-not-found
	@$(OC) delete -f $(APP_INFRA_DIR)/perses-dashboards.yaml                     --ignore-not-found
	@$(OC) delete -f $(APP_INFRA_DIR)/postgres/scc-privileged.yaml               --ignore-not-found
	@$(OC) delete -f $(APP_INFRA_DIR)/rabbitmq/scc-privileged.yaml               --ignore-not-found
	@$(OC) delete -f $(APP_INFRA_DIR)/namespace.yaml                             --ignore-not-found

destroy-platform: check-tools ## Delete platform stack (Loki, Tempo, Korrel8r, OLS, MCP, UI plugins)
	@$(OC) delete -f $(PLATFORM_DIR)/07-perses-datasource.yaml --ignore-not-found
	@$(OC) delete -f $(PLATFORM_DIR)/06-korrel8r-deployment-patch.yaml --ignore-not-found 2>/dev/null || true
	@$(OC) delete -f $(PLATFORM_DIR)/05-korrel8r-otel-rules.yaml --ignore-not-found
	@$(OC) delete -f $(PLATFORM_DIR)/04-ui-plugins.yaml --ignore-not-found
	@$(OC) delete -f $(PLATFORM_DIR)/03-tracing-stack.yaml --ignore-not-found
	@$(OC) delete -f $(PLATFORM_DIR)/02-logging-stack.yaml --ignore-not-found
	@$(OC) delete -f $(PLATFORM_DIR)/01-storage-claims.yaml --ignore-not-found
	@$(OC) delete -f $(PLATFORM_DIR)/00-monitoring-config.yaml --ignore-not-found
	@$(OC) delete -f $(PLATFORM_DIR)/_generated/ols-config.yaml --ignore-not-found --timeout=30s 2>/dev/null || \
		($(OC) patch olsconfig cluster --type=merge -p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true)
	@$(OC) delete -f $(INCIDENT_MCP_BASE_URL)/03_mcp_service.yaml --ignore-not-found 2>/dev/null || true
	@$(OC) delete -f $(INCIDENT_MCP_BASE_URL)/02_deployment.yaml --ignore-not-found 2>/dev/null || true
	@$(OC) delete -f $(INCIDENT_MCP_BASE_URL)/01_service_account.yaml --ignore-not-found 2>/dev/null || true
	@echo "Platform stack removed."

destroy-all: destroy-app destroy-infra destroy-platform delete-operators ## Full cleanup: app + infra + platform + operators
