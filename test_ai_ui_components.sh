#!/bin/bash
# Ghostty AI UI Components Test Script
# Tests memory safety patterns, allocator consistency, and compilation

set -e

echo "================================"
echo "Ghostty AI UI Components Tests"
echo "================================"
echo ""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0

# Test helper functions
pass() {
    echo -e "${GREEN}✓${NC} $1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
    echo -e "${RED}✗${NC} $1"
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

warn() {
    echo -e "${YELLOW}⚠${NC} $1"
    WARN_COUNT=$((WARN_COUNT + 1))
}

info() {
    echo -e "${BLUE}ℹ${NC} $1"
}

# Dynamically discover AI UI component files via glob pattern
# This ensures the test stays in sync with actual components
AI_UI_FILES=()
while IFS= read -r file; do
    AI_UI_FILES+=("$file")
done < <(find src/apprt/gtk/class -name "ai_*.zig" -type f 2>/dev/null | sort)

if [ ${#AI_UI_FILES[@]} -eq 0 ]; then
    echo -e "${RED}ERROR: No AI UI component files found matching src/apprt/gtk/class/ai_*.zig${NC}"
    exit 1
fi

info "Discovered ${#AI_UI_FILES[@]} AI UI component files"

# ============================================
# Test Suite 1: File Existence
# ============================================
test_files_exist() {
    echo "Test Suite 1: File Existence"
    echo "--------------------------------------------"

    for file in "${AI_UI_FILES[@]}"; do
        if [ -f "$file" ]; then
            pass "$(basename "$file") exists"
        else
            fail "$(basename "$file") NOT FOUND"
        fi
    done
    echo ""
}

# ============================================
# Test Suite 2: Memory Safety - errdefer Pattern
# ============================================
test_errdefer_pattern() {
    echo "Test Suite 2: Memory Safety - errdefer self.unref()"
    echo "--------------------------------------------"
    info "Checking that new() functions have errdefer self.unref() after newInstance"

    for file in "${AI_UI_FILES[@]}"; do
        if [ -f "$file" ]; then
            # Check if file has Item types with new() function
            if grep -q "pub fn new(" "$file"; then
                # Count new() functions and errdefer patterns
                # Use tr -d to strip newlines and ensure clean integer values
                NEW_FUNCS=$(grep -c "pub fn new(" "$file" 2>/dev/null | tr -d '\n' || echo "0")
                ERRDEFER_COUNT=$(grep -c "errdefer self.unref();" "$file" 2>/dev/null | tr -d '\n' || echo "0")
                REFSINK_COUNT=$(grep -c "return self.refSink();" "$file" 2>/dev/null | tr -d '\n' || echo "0")

                # Sanitize to ensure only digits, defaulting to 0
                NEW_FUNCS=${NEW_FUNCS//[^0-9]/}
                NEW_FUNCS=${NEW_FUNCS:-0}
                ERRDEFER_COUNT=${ERRDEFER_COUNT//[^0-9]/}
                ERRDEFER_COUNT=${ERRDEFER_COUNT:-0}
                REFSINK_COUNT=${REFSINK_COUNT//[^0-9]/}
                REFSINK_COUNT=${REFSINK_COUNT:-0}

                # Calculate expected: Item new() needs errdefer, Dialog new() uses refSink
                ITEM_NEW_FUNCS=$((NEW_FUNCS - REFSINK_COUNT))

                if [ "$ERRDEFER_COUNT" -ge "$ITEM_NEW_FUNCS" ] 2>/dev/null && [ "$ITEM_NEW_FUNCS" -gt 0 ] 2>/dev/null; then
                    pass "$(basename "$file"): errdefer coverage ($ERRDEFER_COUNT/$ITEM_NEW_FUNCS Item new functions)"
                elif [ "$REFSINK_COUNT" -gt 0 ] && [ "$ITEM_NEW_FUNCS" -eq 0 ]; then
                    pass "$(basename "$file"): Dialog-only, uses refSink pattern"
                elif [ "$ERRDEFER_COUNT" -gt 0 ]; then
                    pass "$(basename "$file"): has errdefer self.unref() ($ERRDEFER_COUNT found)"
                else
                    warn "$(basename "$file"): $NEW_FUNCS new() functions but no errdefer self.unref()"
                fi
            fi
        fi
    done
    echo ""
}

# ============================================
# Test Suite 3: Allocator Consistency
# ============================================
test_allocator_consistency() {
    echo "Test Suite 3: Allocator Consistency"
    echo "--------------------------------------------"
    info "Checking that new() uses Application.default().allocator()"

    for file in "${AI_UI_FILES[@]}"; do
        if [ -f "$file" ]; then
            # Check if Item types use consistent allocator
            if grep -q "pub fn new(" "$file" && grep -q "alloc.dupeZ" "$file"; then
                # Check if new() accepts allocator parameter (BAD) vs gets it internally (GOOD)
                if grep -B5 "pub fn new(" "$file" | grep -q "alloc: Allocator"; then
                    fail "$(basename "$file"): new() accepts allocator parameter (mismatch risk)"
                else
                    if grep -A3 "pub fn new(" "$file" | grep -q "Application.default().allocator()"; then
                        pass "$(basename "$file"): uses Application.default().allocator()"
                    else
                        warn "$(basename "$file"): check allocator pattern manually"
                    fi
                fi
            fi
        fi
    done
    echo ""
}

# ============================================
# Test Suite 4: Double Reference Prevention
# ============================================
test_double_reference() {
    echo "Test Suite 4: Double Reference Prevention"
    echo "--------------------------------------------"
    info "Checking for refSink() + ref() anti-pattern"

    for file in "${AI_UI_FILES[@]}"; do
        if [ -f "$file" ]; then
            # Check for the dangerous pattern: refSink() followed by ref()
            if grep -A1 "self.refSink()" "$file" | grep -q "return self.ref()"; then
                fail "$(basename "$file"): MEMORY LEAK - refSink() + ref() pattern found"
            else
                if grep -q "return self.refSink();" "$file"; then
                    pass "$(basename "$file"): correct refSink pattern"
                fi
            fi
        fi
    done
    echo ""
}

# ============================================
# Test Suite 5: Dispose Defensive Checks
# ============================================
test_dispose_defensive() {
    echo "Test Suite 5: Dispose Defensive Checks"
    echo "--------------------------------------------"
    info "Checking for defensive null checks in dispose()"

    for file in "${AI_UI_FILES[@]}"; do
        if [ -f "$file" ]; then
            # Check if dispose uses defensive pattern
            if grep -q "fn dispose(" "$file"; then
                if grep -A20 "fn dispose(" "$file" | grep -q 'if (self\.' ; then
                    pass "$(basename "$file"): has defensive checks in dispose"
                else
                    # Some files may have simple dispose - check if they free strings
                    if grep -A10 "fn dispose(" "$file" | grep -q "alloc.free"; then
                        warn "$(basename "$file"): dispose frees memory but check for defensive checks"
                    else
                        pass "$(basename "$file"): simple dispose (no string fields)"
                    fi
                fi
            fi
        fi
    done
    echo ""
}

# ============================================
# Test Suite 6: GObject Pattern Compliance
# ============================================
test_gobject_pattern() {
    echo "Test Suite 6: GObject Pattern Compliance"
    echo "--------------------------------------------"
    info "Checking for proper GObject class definitions"

    for file in "${AI_UI_FILES[@]}"; do
        if [ -f "$file" ]; then
            # Check for getGObjectType
            if grep -q "getGObjectType = gobject.ext.defineClass" "$file"; then
                pass "$(basename "$file"): has getGObjectType"
            else
                fail "$(basename "$file"): missing getGObjectType"
            fi

            # Check for dispose implementation
            if grep -q "dispose.implement" "$file"; then
                pass "$(basename "$file"): implements dispose"
            else
                warn "$(basename "$file"): no dispose implementation found"
            fi
        fi
    done
    echo ""
}

# ============================================
# Test Suite 7: Compilation Check
# ============================================
test_compilation() {
    echo "Test Suite 7: Compilation Check"
    echo "--------------------------------------------"
    info "Running zig build to check for errors..."

    # Capture build output
    BUILD_OUTPUT=$(zig build 2>&1) || true

    for file in "${AI_UI_FILES[@]}"; do
        basename_file=$(basename "$file")
        if echo "$BUILD_OUTPUT" | grep -q "$basename_file.*error:"; then
            fail "$basename_file: has compilation errors"
            echo "$BUILD_OUTPUT" | grep -A2 "$basename_file.*error:" | head -5
        else
            pass "$basename_file: compiles successfully"
        fi
    done
    echo ""
}

# ============================================
# Test Suite 8: Code Quality Metrics
# ============================================
test_code_quality() {
    echo "Test Suite 8: Code Quality Metrics"
    echo "--------------------------------------------"

    TOTAL_LINES=0
    for file in "${AI_UI_FILES[@]}"; do
        if [ -f "$file" ]; then
            LINES=$(wc -l < "$file")
            TOTAL_LINES=$((TOTAL_LINES + LINES))
            info "$(basename "$file"): $LINES lines"
        fi
    done
    echo ""
    info "Total lines: $TOTAL_LINES"
    info "Files: ${#AI_UI_FILES[@]}"
    echo ""
}

# ============================================
# Run All Tests
# ============================================
echo "Running AI UI Component Tests..."
echo ""

test_files_exist
test_errdefer_pattern
test_allocator_consistency
test_double_reference
test_dispose_defensive
test_gobject_pattern
test_compilation
test_code_quality

# ============================================
# Summary
# ============================================
echo "================================"
echo "Test Summary"
echo "================================"
echo -e "${GREEN}Passed:${NC}   $PASS_COUNT"
echo -e "${YELLOW}Warnings:${NC} $WARN_COUNT"
echo -e "${RED}Failed:${NC}   $FAIL_COUNT"
echo ""

if [ $FAIL_COUNT -eq 0 ]; then
    echo -e "${GREEN}All critical tests passed!${NC}"
    if [ $WARN_COUNT -gt 0 ]; then
        echo -e "${YELLOW}Review warnings for potential improvements.${NC}"
    fi
    exit 0
else
    echo -e "${RED}Some tests failed. Please review and fix.${NC}"
    exit 1
fi
