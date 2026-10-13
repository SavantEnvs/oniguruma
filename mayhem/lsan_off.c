// mayhem/lsan_off.c
//
// Fleet policy: disable LeakSanitizer at build/link time for every ASan-built target, proactively —
// not just once a leak defect is found. Leaks aren't the bug class this fleet fuzzes for; ASan's own
// memory-corruption checks and UBSan stay fully active; only leak detection is affected.
int __lsan_is_turned_off(void) {
    return 1;
}
