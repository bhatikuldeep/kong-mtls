# Run these from the repository root.
.PHONY: up test test-edge down clean
up:     ## create the certificates, the Konnect control plane and its config, and start the data plane
	@bash scripts/up.sh
test:   ## send requests with each certificate and check what Kong does
	@bash scripts/test.sh
test-edge: ## bonus: an edge ends TLS and passes the client certificate to Kong in a header
	@bash scripts/test-edge.sh
down:   ## remove the containers (Konnect and the certificates stay, so `make up` is quick)
	@docker compose --env-file .env down
clean:  ## remove everything: containers, the Konnect control plane, the certificates
	@bash scripts/clean.sh
