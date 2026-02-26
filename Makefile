.PHONY: test build

test:
	@for f in tests/test_*.nim; do \
		echo "--- $$f ---"; \
		nim r $$f || exit 1; \
	done

build:
	nim c -o:sanctum src/sanctum.nim
