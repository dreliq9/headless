#!/usr/bin/env bash
# Manual mutation testing driver. Uses slither-mutate's generated mutants
# but interprets forge test exit codes correctly (slither-mutate's own
# reporting is broken on this toolchain version).
#
# Usage: ./mutation_run.sh
set -u

ORIG_FILE="src/Headless.sol"
BACKUP="/tmp/Headless.sol.mutationbak"
MUTANTS_DIR="mutation_campaign/Headless"
RESULTS_DIR="mutation_results"

mkdir -p "$RESULTS_DIR"
cp "$ORIG_FILE" "$BACKUP"

caught=0
survived=0
no_compile=0
total=0

> "$RESULTS_DIR/survived.txt"
> "$RESULTS_DIR/no_compile.txt"
> "$RESULTS_DIR/caught.txt"

for mutant in "$MUTANTS_DIR"/*.sol; do
    total=$((total + 1))
    cp "$mutant" "$ORIG_FILE"

    # Run via array — no eval, no shell glob expansion of (Invariant|Halmos).
    out=$(forge test --no-match-contract 'Headless(Invariant|Halmos)' -q 2>&1)
    code=$?

    if [[ "$out" == *"Compiler run failed"* ]] || [[ "$out" == *"Error: Compiler run failed"* ]]; then
        no_compile=$((no_compile + 1))
        echo "$(basename "$mutant")" >> "$RESULTS_DIR/no_compile.txt"
    elif [[ $code -eq 0 ]]; then
        survived=$((survived + 1))
        echo "$(basename "$mutant")" >> "$RESULTS_DIR/survived.txt"
    else
        caught=$((caught + 1))
        echo "$(basename "$mutant")" >> "$RESULTS_DIR/caught.txt"
    fi

    if (( total % 25 == 0 )); then
        echo "[$total] caught=$caught survived=$survived no_compile=$no_compile"
    fi
done

cp "$BACKUP" "$ORIG_FILE"

echo
echo "=== MUTATION TEST RESULTS ==="
echo "Total mutants:    $total"
echo "Caught (killed):  $caught"
echo "Survived:         $survived"
echo "No compile:       $no_compile"

# Mutation score: caught / (caught + survived). Exclude no-compile mutants
# because they're nonsensical mutations the compiler rejects.
denom=$((caught + survived))
if (( denom > 0 )); then
    pct=$(( (caught * 1000) / denom ))
    pct_int=$((pct / 10))
    pct_dec=$((pct % 10))
    echo "Mutation score:   ${pct_int}.${pct_dec}% (excluding non-compiling mutants)"
fi
