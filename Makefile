.PHONY: test integration-test build ci

test:
	@found=0; \
	for f in tests/test_*.nim; do \
		[ -e "$$f" ] || continue; \
		found=1; \
		echo "--- $$f ---"; \
		nim r "$$f" || exit 1; \
	done; \
	if [ $$found -eq 0 ]; then \
		echo "No unit tests found in tests/test_*.nim"; \
	fi

integration-test:
	@found=0; \
	for f in tests/integration_*.nim; do \
		[ -e "$$f" ] || continue; \
		found=1; \
		echo "--- $$f ---"; \
		nim r "$$f" || exit 1; \
	done; \
	if [ $$found -eq 0 ]; then \
		echo "No integration tests found in tests/integration_*.nim"; \
	fi

build:
	nim c -o:scriptorium src/scriptorium.nim

ci:
	act -W .github/workflows/build.yml
