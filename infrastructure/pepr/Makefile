# Pepr Policy Engine — Build & Deploy
# Usage:
#   make build       — Compile Pepr module + generate K8s manifests
#   make dev         — Run in dev mode against current cluster
#   make deploy      — Deploy to current cluster
#   make test        — Run unit tests
#   make audit-log   — Tail Pepr audit logs

.PHONY: build dev deploy test audit-log clean install

PEPR_MODULE := open-platform-policy
REGISTRY    := ghcr.io/vespo92/open-platform-pepr

install:
	npm install

build: install
	npx pepr build

build-image: install
	npx pepr build --registry $(REGISTRY)

dev: install
	npx pepr dev

deploy: build
	npx pepr deploy

test: install
	npm test

audit-log:
	kubectl logs -n pepr-system -l app=pepr-$(PEPR_MODULE) -f --tail=100

clean:
	rm -rf dist node_modules
