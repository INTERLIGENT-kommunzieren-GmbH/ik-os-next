#!/bin/bash
# Shared harness for the booted-system tests (SDD §63).
PASS=0; FAIL=0; SKIP=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
no()   { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
skip() { printf '  \033[33m-\033[0m %s (skipped: %s)\n' "$1" "$2"; SKIP=$((SKIP+1)); }
check(){ local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else no "$d"; fi; }
manual(){ printf '  \033[36m?\033[0m %s \033[2m(manual)\033[0m\n' "$1"; }
summary() {
    printf '\n%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
    [[ $FAIL -eq 0 ]]
}
