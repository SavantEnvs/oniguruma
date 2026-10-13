#!/usr/bin/env bash
#
# mayhem/build.sh — build Oniguruma's fuzz harnesses + its own upstream test suite.
#
#   /mayhem/fuzz_encode           sanitized + libFuzzer -> target `encode` (harnesses/base.c,
#                                  multi-encoding onig_new+onig_search over 40 encodings)
#   /mayhem/fuzz_syntax            sanitized + libFuzzer -> target `syntax` (harnesses/base.c
#                                  -DSYNTAX_TEST, also varies the 8 built-in OnigSyntaxType's)
#   /mayhem/fuzz_deluxe            sanitized + libFuzzer -> target `deluxe` (harnesses/deluxe.c,
#                                  onig_new_deluxe: independent pattern/subject encodings)
#   /mayhem/fuzz_regset            sanitized + libFuzzer -> target `regset` (harnesses/regset.c,
#                                  OnigRegSet: multiple compiled regexes searched together)
#   /mayhem/fuzz_*-standalone      sanitized, run-once reproducers (not Mayhemfile targets)
#   test/{test_utf8,test_syntax,test_options,testc,testcu,test_regset,test_back}
#                                  NORMAL flags -> upstream known-answer test suite, run by
#                                  mayhem/test.sh
#
# Harnesses are UPSTREAM'S OWN oss-fuzz-style harnesses, shipped in-tree at harnesses/ (base.c,
# deluxe.c, regset.c — contributed by Mark Griffin / K.Kosako; oniguruma was an OSS-Fuzz project
# — see .github/workflows/cifuzz.yml — though the project entry is not currently present in
# google/oss-fuzz/projects/). We reuse them verbatim rather than writing new harnesses.
#
# Order matters, and WHY --disable-shared matters:
#   1) Configure+build the library and the upstream test suite FIRST, with NORMAL flags and
#      --disable-shared. Oniguruma's libtool build normally produces both libonig.a AND a shared
#      libonig.so, and the test binaries dynamically link against the .so at runtime (via a
#      libtool wrapper script) — so if step 2 later overwrote src/.libs/libonig.so with a
#      SANITIZED rebuild, the already-built (unchanged) test executables would silently start
#      loading the sanitized library at runtime, corrupting the "clean oracle" invariant. Forcing
#      --disable-shared makes libonig.a the only artifact and the test binaries link it in
#      STATICALLY, so they are immune to whatever step 2 rebuilds afterward (same trick as the
#      python re-flex/scs ports use their own static libs for exactly this reason). The resulting
#      test binaries are still dynamically linked against libc (`file`/`ldd` confirm it), so the
#      sabotage LD_PRELOAD check in verify-repo still applies.
#   2) Rebuild ONLY src/ (the library) with $SANITIZER_FLAGS + $DEBUG_FLAGS. Also unconditionally
#      append -fsanitize=fuzzer-no-link — $SANITIZER_FLAGS (ASan+UBSan) carries NO coverage
#      instrumentation, so without this the fuzzed library has no SanCov counters and Mayhem
#      would record edges_covered=0 forever even though the harness itself builds and iterates.
#   3) Link each upstream harness (harnesses/base.c[+-DSYNTAX_TEST], deluxe.c, regset.c) against
#      the sanitized static libonig.a, once with $LIB_FUZZING_ENGINE (the libFuzzer target) and
#      once with $STANDALONE_FUZZ_MAIN (a run-once reproducer, no libFuzzer runtime).
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
: "${STANDALONE_FUZZ_MAIN:=/opt/mayhem/StandaloneFuzzTargetMain.c}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

SRC="${SRC:-/mayhem}"
cd "$SRC"

# ── 1) Upstream, NORMAL flags, static-only (--disable-shared — see header comment) ─────────────
bash autogen.sh
./configure CC="$CC" CFLAGS="-O2 $COVERAGE_FLAGS" --disable-shared
# IDEMPOTENCE: unconditionally clean src/ + test/ FIRST, every run. `make` decides whether to
# recompile a .o purely from mtimes, not from whether CFLAGS changed — so on a second build.sh
# invocation (offline PATCH-tier re-run, or just re-running this script by hand) the objects left
# over from step 2's SANITIZED rebuild would otherwise look "up to date" to this normal-flags
# phase and never get recompiled, and the test binaries would then link a sanitizer-instrumented
# libonig.a with no sanitizer runtime linked in (undefined __asan_*/__ubsan_*/__sanitizer_cov_*).
make -C src clean  >/dev/null 2>&1 || true
make -C test clean >/dev/null 2>&1 || true
make -j"$MAYHEM_JOBS"
# Build (not run) the upstream test programs — check_PROGRAMS in test/Makefile.am; POSIX-API
# testp is excluded (default configure: --enable-posix-api=no, so it is not even built).
make -C test -j"$MAYHEM_JOBS" \
  test_utf8 test_syntax test_options testc testcu test_regset test_back

# ── 2) Sanitized rebuild of ONLY the library (fuzzed code must be instrumented) ─────────────────
# -fsanitize=fuzzer-no-link is appended UNCONDITIONALLY (even when $SANITIZER_FLAGS is the empty
# no-sanitizer override) so the library always carries SanCov edge counters.
FUZZ_COV="-fsanitize=fuzzer-no-link"
make -C src clean
make -C src -j"$MAYHEM_JOBS" CFLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS $FUZZ_COV"
ONIG_LIB="$SRC/src/.libs/libonig.a"
[ -f "$ONIG_LIB" ] || { echo "build.sh: $ONIG_LIB missing after sanitized rebuild" >&2; exit 1; }

# ── 3) libFuzzer harnesses + standalone reproducers (pure C — no C++ mangling concerns) ─────────
$CC -c $SANITIZER_FLAGS $DEBUG_FLAGS "$STANDALONE_FUZZ_MAIN" -o /tmp/standalone_main.o

# Fleet policy: disable LeakSanitizer for every ASan-built target (see mayhem/lsan_off.c). Compile
# it once here and link the resulting object into every fuzz + -standalone binary below.
$CC -c $SANITIZER_FLAGS $DEBUG_FLAGS "$SRC/mayhem/lsan_off.c" -o /tmp/lsan_off.o

build_harness() {
  local name="$1" src_file="$2" extra_def="${3:-}"
  # shellcheck disable=SC2086
  $CC $extra_def $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE -I"$SRC/src" \
      "$SRC/harnesses/$src_file" /tmp/lsan_off.o "$ONIG_LIB" -o "$SRC/fuzz_$name"
  # shellcheck disable=SC2086
  $CC $extra_def $SANITIZER_FLAGS $DEBUG_FLAGS -I"$SRC/src" \
      "$SRC/harnesses/$src_file" /tmp/standalone_main.o /tmp/lsan_off.o "$ONIG_LIB" -o "$SRC/fuzz_$name-standalone"
}

build_harness encode base.c
build_harness syntax base.c -DSYNTAX_TEST
build_harness deluxe deluxe.c
build_harness regset regset.c

echo "build.sh: built /mayhem/fuzz_{encode,syntax,deluxe,regset}(+-standalone) and the upstream test suite in test/"
