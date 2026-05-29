# LakeTS Makefile
# Build targets for packaging. Install is done via psql, not make.

VERSION := $(shell cat VERSION 2>/dev/null || echo "0.0.0-dev")

.PHONY: build clean checksum version release release-dry-run release-minor release-major help lock

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

lock:  ## Regenerate requirements.lock (run after editing requirements*.txt)
	@command -v uv >/dev/null || { echo "Install uv first: pip install uv" >&2; exit 1; }
	@uv pip compile requirements.txt requirements-dev.txt --generate-hashes -o requirements.lock
	@echo "✓ requirements.lock regenerated. Commit it alongside the input files."

help:  ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-15s\033[0m %s\n", $$1, $$2}'

release:  ## Release patch version (bump VERSION, update CHANGELOG, tag, push)
	@./bin/release.sh patch

release-dry-run:  ## Preview what the next patch release would do (no changes)
	@./bin/release.sh --dry-run patch

release-minor:  ## Release minor version bump
	@./bin/release.sh minor

release-major:  ## Release major version bump
	@./bin/release.sh major
