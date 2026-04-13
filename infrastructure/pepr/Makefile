# Pepr Policy Engine — Build & Deploy
# Usage:
#   make build       — Compile module + copy manifest for Flux
#   make dev         — Run in dev mode against current cluster
#   make deploy      — Direct deploy to current cluster (bypasses Flux)
#   make test        — Run unit tests
#   make audit-log   — Tail Pepr audit logs

.PHONY: build dev deploy test audit-log clean install

PEPR_MODULE := open-platform-policy
REGISTRY    := ghcr.io/vespo92/open-platform-pepr
MANIFEST    := dist/pepr-module-$(PEPR_MODULE).yaml

install:
	npm install

build: install
	npx pepr build
	cp $(MANIFEST) deploy/pepr-module.yaml
	@echo "✓ Manifest copied to deploy/pepr-module.yaml — ready for git commit"

build-image: install
	npx pepr build --registry $(REGISTRY)
	cp $(MANIFEST) deploy/pepr-module.yaml

dev: install
	npx pepr dev

deploy: build
	npx pepr deploy

test: install
	npm test

audit-log:
	kubectl logs -n pepr-system -l app=pepr-$(PEPR_MODULE) -f --tail=100

audit-log-watcher:
	kubectl logs -n pepr-system -l app=pepr-$(PEPR_MODULE)-watcher -f --tail=100

status:
	@echo "=== Pepr Deployments ==="
	kubectl get deploy -n pepr-system
	@echo ""
	@echo "=== Webhook Configurations ==="
	kubectl get mutatingwebhookconfiguration,validatingwebhookconfiguration | grep pepr
	@echo ""
	@echo "=== Recent Events ==="
	kubectl get events -n pepr-system --sort-by='.lastTimestamp' | tail -10

rollback:
	@echo "Scaling Pepr to 0 replicas (emergency rollback)..."
	kubectl scale deployment -n pepr-system pepr-$(PEPR_MODULE) --replicas=0
	kubectl scale deployment -n pepr-system pepr-$(PEPR_MODULE)-watcher --replicas=0
	@echo "✓ Pepr scaled to 0. Webhooks still exist but will fail-open (timeoutSeconds=10)."
	@echo "  To fully remove: kubectl delete mutatingwebhookconfiguration,validatingwebhookconfiguration -l pepr.dev/uuid=$(PEPR_MODULE)"

clean:
	rm -rf dist node_modules
