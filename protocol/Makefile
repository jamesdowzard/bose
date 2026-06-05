# Protocol codegen targets.
#
#   make gen    — regenerate generated/ from spec/bmap.toml
#   make test   — run the pytest suite (golden bytes + emitters)
#   make check  — regenerate, fail if generated/ drifted from the commit, run tests
#
# `make check` is the CI-equivalent gate: it proves the committed generated Swift
# and Kotlin are in sync with the spec, then runs the golden byte tests.

.PHONY: gen test check

gen:
	uv run python -m codegen.generate

test:
	uv run pytest -q

check: gen
	git diff --exit-code generated/
	uv run pytest -q
