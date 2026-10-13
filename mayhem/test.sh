#!/usr/bin/env bash
#
# mayhem/test.sh — RUN Oniguruma's OWN upstream test suite (prebuilt by mayhem/build.sh; never
# compiles). exit 0 = pass.
#
# Upstream's suite is test/test.sh's list: test_utf8, test_syntax, test_options, testc, testcu,
# test_regset, test_back. Each program is a genuine known-answer/assertion suite: it exercises
# hundreds of fixed pattern/subject pairs against onig_search()/onig_new() and prints a summary
# line "RESULT   SUCC: <N>,  FAIL: <F>,  ERROR: <E>" (see e.g. test/testc.c's `xx()`/x2()/n()
# helpers), then `return (nfail == 0 && nerror == 0) ? 0 : -1`. A neutered (exit(0)) binary prints
# NOTHING and exits 0 with no RESULT line, so the marker match below fails — this is a behavioral
# oracle, not an exit-status check.
#
# The expected SUCC counts are pinned to the exact values from this integration's build (fixed,
# deterministic — the test data is compiled-in C literals, independent of environment/locale). A
# genuine upstream change to the test suite will change these counts and correctly fail this
# check at the next sync rebuild; that is the intended signal (see sync.yml's build-break issue).
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"
SRC="${SRC:-/mayhem}"
cd "$SRC"

emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

cd test

# run_one <prog> <expected exact "SUCC: N,  FAIL: 0,  ERROR: 0"> substring>
# PASS requires exit 0 AND the exact known-answer RESULT line — so a neutered exit(0) binary
# (no output at all) fails, and any regression in success count / new failures also fails.
passed=0 failed=0
run_one() {
  local prog="$1" marker="$2"
  if [ ! -x "./$prog" ]; then
    echo "test.sh: missing prebuilt test runner test/$prog — mayhem/build.sh bug" >&2
    failed=$(( failed + 1 ))
    return
  fi
  if ./"$prog" > "/tmp/$prog.log" 2>&1 && grep -qF -- "$marker" "/tmp/$prog.log"; then
    echo "PASS $prog"
    passed=$(( passed + 1 ))
  else
    echo "FAIL $prog (nonzero exit or known-answer marker missing: $marker)"
    tail -20 "/tmp/$prog.log" >&2
    failed=$(( failed + 1 ))
  fi
}

run_one test_utf8    "SUCC: 1498,  FAIL: 0,  ERROR: 0"
run_one test_syntax  "SUCC:  128,  FAIL: 0,  ERROR: 0"
run_one test_options "SUCC:   47,  FAIL: 0,  ERROR: 0"
run_one testc        "SUCC:  785,  FAIL: 0,  ERROR: 0"
run_one testcu       "SUCC:  720,  FAIL: 0,  ERROR: 0"
run_one test_regset  "SUCC:   13,  FAIL: 0,  ERROR: 0"
run_one test_back    "SUCC: 1225,  FAIL: 0,  ERROR: 0"

cd "$SRC"
emit_ctrf "oniguruma-upstream-suite" "$passed" "$failed" 0
