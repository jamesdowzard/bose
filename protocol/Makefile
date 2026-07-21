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

# The Android committed copies are SEPARATE build inputs (app/src/generated/), copied by
# `./gradlew copyGeneratedProtocol`. Checking only generated/ let a `make gen` without that
# follow-up leave Android building against a stale wire layer while this gate passed green —
# the exact drift the gate exists to catch. Both paths are checked now.
ANDROID_GEN = ../android/app/src/generated/java/au/com/jd/bose

check: gen
	git diff --exit-code generated/
	@cmp -s generated/BMAP.generated.kt $(ANDROID_GEN)/BMAP.generated.kt \
	  || { echo "DRIFT: $(ANDROID_GEN)/BMAP.generated.kt is stale — run 'cd android && ./gradlew copyGeneratedProtocol'"; exit 1; }
	@cmp -s generated/Devices.generated.kt $(ANDROID_GEN)/Devices.generated.kt \
	  || { echo "DRIFT: $(ANDROID_GEN)/Devices.generated.kt is stale — run 'cd android && ./gradlew copyGeneratedProtocol'"; exit 1; }
	uv run pytest -q
