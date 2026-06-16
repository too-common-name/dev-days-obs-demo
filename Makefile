# ====================================================================================
#  OBSERVABILITY DEMO AUTOMATION
# ====================================================================================

# --- Tools ---
OC := oc
YQ := yq

# --- Directories ---
OPERATORS_DIR := infrastructure/00-operators
PLATFORM_DIR  := infrastructure/01-platform

SCRIPTS_DIR   := scripts
TEMPLATE_DIR  := templates
GENERATED_DIR := _generated

# --- Settings ---
_ := $(shell chmod +x $(SCRIPTS_DIR)/*.sh)

.PHONY: help check-tools deploy-all destroy-all
.PHONY: deploy-operators deploy-platform deploy-app

help: ## Show this help message
	@echo 'Usage: make [target]'
	@echo ''
	@echo 'Targets:'
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'

check-tools: ## Verify required tools (oc, yq) are installed
	@which $(OC) > /dev/null || (echo "❌ Error: 'oc' not found." && exit 1)
	@which $(YQ) > /dev/null || (echo "❌ Error: 'yq' not found." && exit 1)
	@echo "✅ Cluster connected: $$( $(OC) whoami --show-server )"

# ====================================================================================
#  LAYER 0: OPERATORS
# ====================================================================================

deploy-operators: check-tools ## 1. Install OTel, Loki, Tempo, and COO Operators
	@echo "🚀 [Layer 0] Installing Operators..."
	@$(OC) apply -R -f $(OPERATORS_DIR)
	@echo "⏳ Waiting for Operators to install and settle..."
	@./$(SCRIPTS_DIR)/wait-for-operators.sh

delete-operators: check-tools ## ⚠️  Uninstall Operators (Subscriptions & OperatorGroups)
	@echo "🔥 Uninstalling Operators..."
	@$(OC) delete -R -f $(OPERATORS_DIR) --ignore-not-found
	@echo "ℹ️  Note: This removes Subscriptions. Installed CSVs may remain in the cluster."

# ====================================================================================
#  LAYER 1: PLATFORM STACK (Cluster-Wide)
# ====================================================================================

deploy-platform: check-tools ## 2. Deploy UWM, Loki, Tempo, UI Plugins, MCP, and OLS Config
	@echo "🚀 [Layer 1] Starting Platform Deployment..."

	@echo "   [1/6] Configuring User Workload Monitoring..."
	@$(OC) apply -f $(PLATFORM_DIR)/00-monitoring-config.yaml

	@echo "   [2/6] Creating object storage buckets..."
	@$(OC) apply -f $(PLATFORM_DIR)/01-storage-claims.yaml

	@echo "   [3/6] Linking Storage to Platform..."
	@./$(SCRIPTS_DIR)/setup-storage.sh
	
	@echo "   [4/6] Deploying Loki, Tempo and Netobserv Stacks..."
	@$(OC) apply -f $(PLATFORM_DIR)/02-logging-stack.yaml
	@$(OC) apply -f $(PLATFORM_DIR)/03-tracing-stack.yaml
	
	@echo "   [5/6] Enabling Console Plugins (Troubleshooting/Incidents)..."
	@$(OC) apply -f $(PLATFORM_DIR)/04-ui-plugins.yaml
		
	@echo "   [6/6] Checking OLS Configuration..."
	@if [ -z "$(LLM_URL)" ] || [ -z "$(LLM_API_TOKEN)" ]; then \
		echo "     ⚠️  LLM_URL or LLM_API_TOKEN missing. Skipping OLS enablement."; \
	else \
		echo "     Generating OLS Configuration..."; \
		model_name=$$(curl -s -k -X GET "$(LLM_URL)/models" \
			-H "Authorization: Bearer $(LLM_API_TOKEN)" | yq '.data[0].id'); \
		if [ -z "$$model_name" ] || [ "$$model_name" = "null" ]; then \
			echo "❌ Error: Could not fetch model name. Check URL and Token."; \
			exit 1; \
		fi; \
		echo "     URL:   $(LLM_URL)"; \
		echo "     Model: $$model_name"; \
		export LLM_URL="$(LLM_URL)" \
			   LLM_API_TOKEN="$$(echo -n '$(LLM_API_TOKEN)' | base64 -w0)" \
			   LLM_MODEL="$$model_name"; \
		envsubst < $(PLATFORM_DIR)/$(TEMPLATE_DIR)/ols-config.yaml > $(PLATFORM_DIR)/$(GENERATED_DIR)/ols-config.yaml; \
		$(OC) apply -f $(PLATFORM_DIR)/$(GENERATED_DIR)/ols-config.yaml; \
	fi

	@echo "✅ Platform Stack Deployed."


deploy-all: deploy-operators deploy-platform ## 🌟 Install EVERYTHING from scratch
	@echo ""
	@echo "🎉 Full Stack Installation Complete!"
	@echo "   - Metrics: User Workload Monitoring (Thanos)"
	@echo "   - Logs:    OpenShift Logging (Loki)"
	@echo "   - Traces:  Distributed Tracing (Tempo)"
	@echo "   - Visuals: Perses Dashboard & OCP Console"

destroy-all: ## ⚠️  Delete App and Platform resources (Keeps Operators)
	@echo "🔥 Destroying Workload & Platform Resources..."
	@$(OC) delete -f $(PLATFORM_DIR) --ignore-not-found
	@echo "⚠️  Note: Operators were NOT deleted to protect the cluster state. Run 'oc delete subscription ...' manually if needed."