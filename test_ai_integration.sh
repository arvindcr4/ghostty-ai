#!/bin/bash
# Ghostty AI Integration Test Script
# This script tests the AI integration without requiring actual API calls

set -e

echo "================================"
echo "Ghostty AI Integration Tests"
echo "================================"
echo ""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

PASS_COUNT=0
FAIL_COUNT=0

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
}

# Test 1: Check if AI client module compiles
test_ai_client_compiles() {
    echo "Test 1: AI Client Module Compilation"
    if zig build 2>&1 | grep -q "src/ai/client.zig.*error:"; then
        fail "AI client has compilation errors"
    else
        pass "AI client compiles successfully"
    fi
    echo ""
}

# Test 2: Check if AI main module compiles
test_ai_main_compiles() {
    echo "Test 2: AI Main Module Compilation"
    if zig build 2>&1 | grep -q "src/ai/main.zig.*error:"; then
        fail "AI main has compilation errors"
    else
        pass "AI main compiles successfully"
    fi
    echo ""
}

# Test 3: Check if AI Input Mode widget compiles
test_ai_input_mode_compiles() {
    echo "Test 3: AI Input Mode Widget Compilation"
    if zig build 2>&1 | grep -q "ai_input_mode.zig.*error:"; then
        fail "AI Input Mode has compilation errors"
    else
        pass "AI Input Mode compiles successfully"
    fi
    echo ""
}

# Test 4: Check if Surface has getTerminalHistory
test_surface_history_method() {
    echo "Test 4: Surface getTerminalHistory Method"
    if grep -q "pub fn getTerminalHistory" src/Surface.zig; then
        pass "getTerminalHistory method exists in Surface"
    else
        fail "getTerminalHistory method not found"
    fi
    echo ""
}

# Test 5: Check if Surface has getSelectedText
test_surface_selection_method() {
    echo "Test 5: Surface getSelectedText Method"
    if grep -q "pub fn getSelectedText" src/Surface.zig; then
        pass "getSelectedText method exists in Surface"
    else
        fail "getSelectedText method not found"
    fi
    echo ""
}

# Test 6: Check if Window has AI input mode handler
test_window_ai_handler() {
    echo "Test 6: Window AI Input Mode Handler"
    if grep -q "toggleAiInputMode" src/apprt/gtk/class/window.zig; then
        pass "Window has AI input mode handler"
    else
        fail "AI input mode handler not found in Window"
    fi
    echo ""
}

# Test 7: Check if AI Input Mode has templates
test_prompt_templates() {
    echo "Test 7: Prompt Templates Defined"
    if grep -q "const prompt_templates" src/apprt/gtk/class/ai_input_mode.zig; then
        pass "Prompt templates are defined"

        # Count templates
        TEMPLATE_COUNT=$(grep -A 50 "const prompt_templates" src/apprt/gtk/class/ai_input_mode.zig | grep -c "\.name =")
        echo "  Found $TEMPLATE_COUNT templates"
        if [ "$TEMPLATE_COUNT" -ge 7 ]; then
            pass "Has at least 7 templates"
        else
            warn "Only has $TEMPLATE_COUNT templates (expected 7+)"
        fi
    else
        fail "Prompt templates not found"
    fi
    echo ""
}

# Test 8: Check if AI config fields exist
test_ai_config_fields() {
    echo "Test 8: AI Configuration Fields"
    CONFIG_FILE="src/config/Config.zig"

    if [ -f "$CONFIG_FILE" ]; then
        if grep -q "ai-enabled" "$CONFIG_FILE"; then
            pass "ai-enabled config field exists"
        else
            fail "ai-enabled config field missing"
        fi

        if grep -q "ai-provider" "$CONFIG_FILE"; then
            pass "ai-provider config field exists"
        else
            fail "ai-provider config field missing"
        fi

        if grep -q "ai-api-key" "$CONFIG_FILE"; then
            pass "ai-api-key config field exists"
        else
            fail "ai-api-key config field missing"
        fi
    else
        fail "Config.zig not found"
    fi
    echo ""
}

# Test 9: Check if streaming support exists
test_streaming_support() {
    echo "Test 9: Streaming Response Support"
    if grep -q "pub fn chatStream" src/ai/client.zig; then
        pass "Streaming support exists in AI client"
    else
        warn "Streaming support not found (optional feature)"
    fi
    echo ""
}

# Test 10: Check if threading implementation exists
test_threading() {
    echo "Test 10: Threading Implementation"
    if grep -q "AiThreadContext" src/apprt/gtk/class/ai_input_mode.zig; then
        pass "Threading context structure exists"
    else
        warn "Threading context not found"
    fi

    if grep -q "aiThreadMain" src/apprt/gtk/class/ai_input_mode.zig; then
        pass "Thread main function exists"
    else
        warn "Thread main function not found"
    fi
    echo ""
}

# Test 11: Check Blueprint UI file
test_blueprint_ui() {
    echo "Test 11: Blueprint UI File"
    UI_FILE="src/apprt/gtk/ui/1.5/ai-input-mode.blp"

    if [ -f "$UI_FILE" ]; then
        pass "AI input mode Blueprint file exists"

        if grep -q "template_dropdown" "$UI_FILE"; then
            pass "Template dropdown defined in UI"
        else
            fail "Template dropdown not found in UI"
        fi

        if grep -q "send_btn" "$UI_FILE"; then
            pass "Send button defined in UI"
        else
            fail "Send button not found in UI"
        fi
    else
        fail "Blueprint UI file not found"
    fi
    echo ""
}

# Test 12: Check documentation
test_documentation() {
    echo "Test 12: Documentation Files"

    if [ -f "AI_TESTING_GUIDE.md" ]; then
        pass "AI Testing Guide exists"
    else
        warn "AI Testing Guide not found"
    fi

    if ls RALPH_LOOP_ITERATION_*.md 1> /dev/null 2>&1; then
        pass "Ralph Loop iteration summaries exist"
    else
        warn "No iteration summaries found"
    fi
    echo ""
}

# Run all tests
echo "Running integration tests..."
echo ""

test_ai_client_compiles
test_ai_main_compiles
test_ai_input_mode_compiles
test_surface_history_method
test_surface_selection_method
test_window_ai_handler
test_prompt_templates
test_ai_config_fields
test_streaming_support
test_threading
test_blueprint_ui
test_documentation

# Summary
echo "================================"
echo "Test Summary"
echo "================================"
echo -e "${GREEN}Passed:${NC} $PASS_COUNT"
echo -e "${RED}Failed:${NC} $FAIL_COUNT"
echo ""

if [ $FAIL_COUNT -eq 0 ]; then
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
else
    echo -e "${RED}Some tests failed.${NC}"
    exit 1
fi
