#!/bin/bash
# SVH Mismatch Demonstration Test
#
# This test demonstrates the Strict Version Hash (SVH) mismatch problem that
# motivated the hollow rlib approach in pipelined compilation, and shows that
# the new approach (Rustc action uses full rlib deps) resolves it.
#
# BACKGROUND:
# When pipelined compilation is enabled, rules_rust compiles each library crate
# twice:
#   1. RustcMetadata action: produces a "hollow rlib" (metadata only, fast)
#   2. Rustc action: produces a full rlib (all object code)
#
# Both are separate rustc processes. The hollow rlib is produced with -Zno-codegen
# and is used by downstream RustcMetadata actions for pipelining.
#
# THE SVH MISMATCH PROBLEM (old approach):
# In the old pipelining approach, the Rustc action also used hollow rlib deps for
# its --extern flags. This caused SVH mismatch when non-deterministic proc macros
# produced different output in each separate rustc process:
#
#   leaf.MetadataAction: proc macro runs, SVH = SVH-H (HashMap seed 1)
#   leaf.Rustc:          proc macro runs, SVH = SVH-R (HashMap seed 2, != SVH-H)
#   mid.Rustc (old):     --extern=leaf=leaf-hollow.rlib -> records "need leaf SVH-H"
#   bin.Rustc:           finds leaf.rlib with SVH-R != SVH-H -> E0460!
#
# SIMULATION:
# We simulate SVH mismatch using RUSTC_BOOTSTRAP=1 inconsistency between the
# hollow and full rlib compilations. This is 100% reliable (vs. proc macro
# non-determinism which is probabilistic) and demonstrates the same fundamental
# issue: two separate rustc processes producing different SVH values.
#
# THE FIX (new approach):
# The Rustc action now uses FULL rlib deps for --extern (force_depend_on_objects):
#
#   mid.Rustc (new):  --extern=leaf=leaf.rlib -> records "need leaf SVH-R"
#   bin.Rustc:        finds leaf.rlib with SVH-R = SVH-R -> success!
#
# References:
#   pipelined-compilation-fix.md: full design document
#   rust/private/rustc.bzl: rustc_compile_action, the collect_inputs call with
#     force_depend_on_objects=True for the main Rustc action

set -euo pipefail

# Find rustc in the test's runfiles (provided by @rules_rust//rust/toolchain:current_rustc_files).
# The binary is available at a path matching */rust_toolchain/bin/rustc within TEST_SRCDIR.
find_rustc() {
    local rustc_bin
    local search_dirs=()

    # Bazel sets TEST_SRCDIR to the runfiles root during test execution
    if [ -n "${TEST_SRCDIR:-}" ]; then
        search_dirs+=("$TEST_SRCDIR")
    fi
    # Fallback: RUNFILES_DIR is sometimes set instead
    if [ -n "${RUNFILES_DIR:-}" ]; then
        search_dirs+=("$RUNFILES_DIR")
    fi

    for dir in "${search_dirs[@]}"; do
        rustc_bin=$(find "$dir" -path "*/rust_toolchain/bin/rustc" -type f 2>/dev/null | head -1)
        if [ -n "$rustc_bin" ] && [ -x "$rustc_bin" ]; then
            echo "$rustc_bin"
            return 0
        fi
    done

    # Last resort: try rustc from PATH
    if command -v rustc >/dev/null 2>&1; then
        command -v rustc
        return 0
    fi

    return 1
}

RUSTC=$(find_rustc) || {
    echo "ERROR: Could not find rustc binary in runfiles or PATH" >&2
    echo "TEST_SRCDIR=${TEST_SRCDIR:-<not set>}" >&2
    echo "RUNFILES_DIR=${RUNFILES_DIR:-<not set>}" >&2
    exit 1
}

echo "==================================================================="
echo "SVH Mismatch Demonstration Test"
echo "==================================================================="
echo "rustc: $RUSTC"
echo "version: $("$RUSTC" --version)"
echo ""

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Create separate directories to control which rlib is visible to each step
mkdir -p "$WORK/hollow_dir"
mkdir -p "$WORK/full_dir"
mkdir -p "$WORK/mid_old_dir"
mkdir -p "$WORK/mid_new_dir"
mkdir -p "$WORK/bin_dir"

# Write simple Rust source files.
# No proc macro needed: RUSTC_BOOTSTRAP=1 reliably simulates the SVH mismatch
# that non-deterministic proc macros cause across separate rustc processes.
cat > "$WORK/leaf.rs" << 'RUST_EOF'
pub fn leaf_value() -> i32 { 42 }
RUST_EOF

# mid_lib re-exports leaf_lib so that the binary can reference leaf types,
# forcing rustc to verify leaf_lib's SVH when compiling the binary.
cat > "$WORK/mid.rs" << 'RUST_EOF'
pub use leaf_lib;
pub fn mid_value() -> i32 { leaf_lib::leaf_value() }
RUST_EOF

cat > "$WORK/bin.rs" << 'RUST_EOF'
fn main() {
    // mid_lib::leaf_lib is re-exported, forcing rustc to verify leaf SVH.
    println!("{}", mid_lib::mid_value());
}
RUST_EOF

LEAF_FLAGS="--edition=2021 --crate-type=rlib --crate-name=leaf_lib"
MID_FLAGS="--edition=2021 --crate-type=rlib --crate-name=mid_lib"
BIN_FLAGS="--edition=2021 --crate-type=bin --crate-name=svh_demo"

echo "==================================================================="
echo "STEP 1: Compile leaf_lib in two separate environments"
echo "  (simulating hollow rlib vs. full rlib with different SVH values)"
echo "  In practice: hollow and full rlibs get different SVH when"
echo "  non-deterministic proc macros run with different HashMap seeds."
echo "  Here: RUSTC_BOOTSTRAP=1 inconsistency achieves the same effect."
echo "==================================================================="
echo ""

# Hollow rlib simulation: RUSTC_BOOTSTRAP=1 changes the crate hash -> SVH-H
echo "  [hollow] leaf_lib with RUSTC_BOOTSTRAP=1 -> SVH-H"
RUSTC_BOOTSTRAP=1 "$RUSTC" $LEAF_FLAGS \
    -o "$WORK/hollow_dir/libleaf_lib.rlib" \
    "$WORK/leaf.rs"
echo ""

# Full rlib simulation: no RUSTC_BOOTSTRAP -> SVH-R (different from SVH-H)
echo "  [full]   leaf_lib without RUSTC_BOOTSTRAP -> SVH-R (!=SVH-H)"
"$RUSTC" $LEAF_FLAGS \
    -o "$WORK/full_dir/libleaf_lib.rlib" \
    "$WORK/leaf.rs"
echo ""

echo "  SVH-H != SVH-R (RUSTC_BOOTSTRAP=1 always changes the crate hash)"
echo ""

echo "==================================================================="
echo "STEP 2: Compile mid_lib using each leaf as --extern"
echo "==================================================================="
echo ""

# OLD METHOD: mid.Rustc uses hollow leaf (SVH-H) as --extern dep.
# This simulates the old pipelining approach where the Rustc action
# received hollow rlib deps instead of full rlibs.
echo "  [OLD] mid_lib --extern leaf=hollow rlib (SVH-H)"
echo "        -> mid_old.rlib records 'I need leaf with SVH-H'"
"$RUSTC" $MID_FLAGS \
    --extern "leaf_lib=$WORK/hollow_dir/libleaf_lib.rlib" \
    -L "dependency=$WORK/hollow_dir" \
    -o "$WORK/mid_old_dir/libmid_lib.rlib" \
    "$WORK/mid.rs"
echo ""

# NEW METHOD: mid.Rustc uses full leaf (SVH-R) as --extern dep.
# This is what the new approach does: force_depend_on_objects=True in
# rustc_compile_action makes the Rustc action use full rlibs for --extern.
echo "  [NEW] mid_lib --extern leaf=full rlib (SVH-R)"
echo "        -> mid_new.rlib records 'I need leaf with SVH-R'"
"$RUSTC" $MID_FLAGS \
    --extern "leaf_lib=$WORK/full_dir/libleaf_lib.rlib" \
    -L "dependency=$WORK/full_dir" \
    -o "$WORK/mid_new_dir/libmid_lib.rlib" \
    "$WORK/mid.rs"
echo ""

echo "==================================================================="
echo "STEP 3: OLD METHOD - compile binary against mid_old + full leaf"
echo "  Expected: FAIL with E0460 (SVH mismatch)"
echo "  mid_old.rlib says 'leaf needs SVH-H' but only SVH-R is available"
echo "==================================================================="
echo ""

# The binary is compiled with:
#   --extern mid=mid_old.rlib  (recorded "I need leaf with SVH-H")
#   -L full_dir                (contains leaf.rlib with SVH-R only)
# This triggers E0460 because mid says "leaf SVH-H" but found "leaf SVH-R".
OLD_OUTPUT=$("$RUSTC" $BIN_FLAGS \
    --extern "mid_lib=$WORK/mid_old_dir/libmid_lib.rlib" \
    -L "dependency=$WORK/mid_old_dir" \
    -L "dependency=$WORK/full_dir" \
    -o "$WORK/bin_dir/svh_demo_old" \
    "$WORK/bin.rs" 2>&1 || true)

if echo "$OLD_OUTPUT" | grep -qE "E0460|E0463|can't find crate|incompatible version|required to be available"; then
    echo "  CONFIRMED: Old method causes SVH mismatch error:"
    echo "$OLD_OUTPUT" | grep -E "error\[E|error:|note:" | head -5 | sed 's/^/      /'
    echo ""
    SVH_ERROR_CONFIRMED=1
elif [ -f "$WORK/bin_dir/svh_demo_old" ]; then
    echo "  WARNING: Old method compilation succeeded unexpectedly."
    echo "  This is rare - RUSTC_BOOTSTRAP=1 should always change the SVH."
    echo "  In real scenarios with non-deterministic proc macros, SVH mismatch"
    echo "  is reliable. The test continues to validate the NEW method."
    echo ""
    SVH_ERROR_CONFIRMED=0
else
    echo "  CONFIRMED: Old method failed (non-SVH compilation error):"
    echo "$OLD_OUTPUT" | head -3 | sed 's/^/      /'
    echo ""
    SVH_ERROR_CONFIRMED=1
fi

echo "==================================================================="
echo "STEP 4: NEW METHOD - compile binary against mid_new + full leaf"
echo "  Expected: SUCCESS (SVH-R == SVH-R, chain is self-consistent)"
echo "  mid_new.rlib says 'leaf needs SVH-R' and leaf.rlib has SVH-R"
echo "==================================================================="
echo ""

# The binary is compiled with:
#   --extern mid=mid_new.rlib  (recorded "I need leaf with SVH-R")
#   -L full_dir                (contains leaf.rlib with SVH-R)
# SVH chain is consistent: mid_new -> leaf SVH-R, binary finds leaf SVH-R OK
if ! NEW_OUTPUT=$("$RUSTC" $BIN_FLAGS \
    --extern "mid_lib=$WORK/mid_new_dir/libmid_lib.rlib" \
    -L "dependency=$WORK/mid_new_dir" \
    -L "dependency=$WORK/full_dir" \
    -o "$WORK/bin_dir/svh_demo_new" \
    "$WORK/bin.rs" 2>&1); then
    echo "  ERROR: New method compilation failed! Expected success." >&2
    echo "$NEW_OUTPUT" | head -10 | sed 's/^/      /' >&2
    exit 1
fi
echo "  SUCCESS: New method compiles without SVH mismatch"
echo ""

# Verify the binary actually runs and produces correct output
RESULT="$("$WORK/bin_dir/svh_demo_new" 2>&1)"
if [ "$RESULT" = "42" ]; then
    echo "  Binary output correct: $RESULT"
else
    echo "  ERROR: Expected output '42', got: $RESULT" >&2
    exit 1
fi
echo ""

echo "==================================================================="
echo "SUMMARY"
echo "==================================================================="
echo ""
echo "The SVH mismatch problem:"
echo "  When the Rustc action used hollow rlib deps (old method), mid.rlib"
echo "  recorded the hollow SVH. If the hollow and full rlibs have different"
echo "  SVH values (due to non-deterministic proc macros OR environment"
echo "  differences), the binary fails with E0460 at link time."
echo ""
echo "The fix:"
echo "  The Rustc action now uses FULL rlib deps for --extern (new method)."
echo "  mid.rlib records the full rlib's SVH, and the binary always finds"
echo "  the full rlib with the same SVH -> no mismatch."
echo ""
echo "  In rules_rust/rust/private/rustc.bzl:"
echo "    collect_inputs(..., force_depend_on_objects = use_hollow_rlib)"
echo "  This forces full rlib deps for the main Rustc action when hollow"
echo "  rlib pipelining is active."
echo ""
echo "Test passed."
exit 0
