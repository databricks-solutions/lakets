# LakeTS Makefile
# Build targets for packaging. Install is done via psql, not make.

VERSION := $(shell cat VERSION 2>/dev/null || echo "0.0.0-dev")

.PHONY: build clean checksum version help

build: dist/lakets.sql  ## Build the single-file distribution

dist/lakets.sql: VERSION build.sh $(wildcard sql/*.sql)
	@./build.sh

checksum: dist/lakets.sql  ## Generate SHA256 checksum
	@cd dist && shasum -a 256 lakets.sql > lakets.sql.sha256
	@cat dist/lakets.sql.sha256

clean:  ## Remove build artifacts
	rm -rf dist/

version:  ## Show current version
	@echo $(VERSION)

help:  ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-15s\033[0m %s\n", $$1, $$2}'
