#!/usr/bin/env python3
"""
Generate comprehensive unit tests for 100% code coverage.
Analyzes Zig source files to identify all functions, branches, and edge cases.
"""

import os
import re
import sys
from pathlib import Path
from cerebras.cloud.sdk import Cerebras

# Cerebras API configuration - load from environment variables
CEREBRAS_API_KEYS = [
    os.environ.get("CEREBRAS_API_KEY_1"),
    os.environ.get("CEREBRAS_API_KEY_2"),
]
# Filter out None values
CEREBRAS_API_KEYS = [key for key in CEREBRAS_API_KEYS if key]

if not CEREBRAS_API_KEYS:
    print("ERROR: No Cerebras API keys found. Set CEREBRAS_API_KEY_1 and/or CEREBRAS_API_KEY_2 environment variables.")
    sys.exit(1)

clients = [Cerebras(api_key=key) for key in CEREBRAS_API_KEYS]
current_client_idx = 0

def get_client():
    global current_client_idx
    return clients[current_client_idx]

def rotate_client():
    global current_client_idx
    current_client_idx = (current_client_idx + 1) % len(clients)

AI_MODULE_DIR = Path(__file__).parent.parent / "src" / "ai"


def extract_functions(content: str) -> list:
    """Extract all function signatures from Zig code."""
    # Match pub fn and fn declarations
    pattern = r'(?:pub\s+)?fn\s+(\w+)\s*\([^)]*\)\s*(?:![^{]+)?(?:\s*[^{]*)?{'
    return [match.group(1) for match in re.finditer(pattern, content)]


def extract_structs(content: str) -> list:
    """Extract all struct definitions."""
    pattern = r'(?:pub\s+)?const\s+(\w+)\s*=\s*struct\s*{'
    return [match.group(1) for match in re.finditer(pattern, content)]


def extract_enums(content: str) -> list:
    """Extract all enum definitions."""
    pattern = r'(?:pub\s+)?const\s+(\w+)\s*=\s*enum\s*(?:\([^)]*\))?\s*{'
    return [match.group(1) for match in re.finditer(pattern, content)]


def count_branches(content: str) -> dict:
    """Count branch points in code."""
    return {
        "if_statements": len(re.findall(r'\bif\s*\(', content)),
        "else_branches": len(re.findall(r'\belse\b', content)),
        "switch_statements": len(re.findall(r'\bswitch\s*\(', content)),
        "error_handling": len(re.findall(r'\bcatch\b|\borelse\b', content)),
        "optional_unwrap": len(re.findall(r'\.\?', content)),
    }


def read_existing_tests(test_file: Path) -> str:
    """Read existing test file if it exists."""
    if test_file.exists():
        with open(test_file, "r", encoding="utf-8") as f:
            return f.read()
    return ""


def extract_tested_functions(test_content: str) -> set:
    """Extract function names that are already being tested."""
    # Look for test names and function calls in tests
    pattern = r'test\s+"[^"]*(\w+)[^"]*"'
    tested = {
        match.group(1).lower() for match in re.finditer(pattern, test_content)
    }
    # Also look for module.functionName calls
    pattern = r'module\.(\w+)\s*\('
    for match in re.finditer(pattern, test_content):
        tested.add(match.group(1).lower())
    return tested


def generate_comprehensive_tests(filename: str, content: str, existing_tests: str) -> str:
    """Generate tests for uncovered code paths."""

    functions = extract_functions(content)
    structs = extract_structs(content)
    enums = extract_enums(content)
    branches = count_branches(content)
    tested = extract_tested_functions(existing_tests)

    # Find untested functions
    untested = [f for f in functions if f.lower() not in tested and not f.startswith("test")]

    if not untested and not structs:
        return ""

    prompt = f"""Generate ADDITIONAL comprehensive Zig unit tests for 100% code coverage.

File: {filename}

ALREADY TESTED (do not duplicate):
{', '.join(tested) if tested else 'None'}

FUNCTIONS NEEDING TESTS:
{', '.join(untested) if untested else 'All functions tested, focus on edge cases'}

STRUCTS TO TEST:
{', '.join(structs)}

ENUMS TO TEST:
{', '.join(enums)}

BRANCH COVERAGE NEEDED:
- if/else branches: {branches['if_statements']} if statements, {branches['else_branches']} else branches
- switch statements: {branches['switch_statements']}
- error handling: {branches['error_handling']} catch/orelse
- optional unwraps: {branches['optional_unwrap']}

SOURCE CODE (analyze for edge cases):
```zig
{content[:12000]}
```

Generate tests that cover:
1. ALL untested public functions
2. ALL error paths (test that errors are returned correctly)
3. ALL branches in if/else and switch statements
4. Edge cases: empty input, null, zero, max values, overflow
5. Memory management: alloc/dealloc pairs
6. State transitions for stateful structs

Use this pattern:
```zig
test "function_name - specific scenario" {{
    const alloc = std.testing.allocator;
    // setup
    // action
    // assertions
}}
```

Output ONLY new test code. Do not repeat existing tests."""

    for _ in range(len(clients)):
        try:
            response = get_client().chat.completions.create(
                model="zai-glm-4.6",
                messages=[
                    {"role": "system", "content": "You are a Zig testing expert focused on achieving 100% code coverage. Generate thorough tests for all code paths, error conditions, and edge cases."},
                    {"role": "user", "content": prompt}
                ],
                max_tokens=6000,
                temperature=0.2,
            )
            return response.choices[0].message.content
        except Exception as e:
            # Catch all exceptions including SDK-specific rate limit errors
            error_str = str(e).lower()
            if "429" in str(e) or "rate" in error_str or "quota" in error_str or "limit" in error_str:
                print(f"Rate limited, rotating client...")
                rotate_client()
                continue
            # Re-raise unexpected errors after logging
            print(f"API error: {type(e).__name__}: {e}")
            return ""
    return ""


def extract_zig_code(response: str) -> str:
    """Extract Zig code from response."""
    if "```zig" in response:
        parts = response.split("```zig")
        if len(parts) > 1:
            return parts[1].split("```")[0].strip()
    elif "```" in response:
        parts = response.split("```")
        if len(parts) > 1:
            code = parts[1]
            if code.startswith("zig\n"):
                code = code[4:]
            return code.strip()
    return response.strip()


def append_tests(test_file: Path, new_tests: str):
    """Append new tests to existing test file."""
    # Add separator and new tests
    with open(test_file, "a", encoding="utf-8") as f:
        f.write("\n\n// ============================================================================\n")
        f.write("// Additional tests for 100% coverage\n")
        f.write("// ============================================================================\n\n")
        f.write(new_tests)

    print(f"  Appended tests to {test_file}")


def main():
    print("=" * 60)
    print("100% Coverage Test Generator")
    print("=" * 60)

    tests_dir = AI_MODULE_DIR / "tests"

    # Get all source files
    source_files = sorted(AI_MODULE_DIR.glob("*.zig"))

    stats = {"processed": 0, "enhanced": 0, "skipped": 0}

    for source_file in source_files:
        filename = source_file.name
        test_file = tests_dir / f"test_{filename}"

        print(f"\n[ANALYZING] {filename}")

        # Read source
        with open(source_file, "r", encoding="utf-8") as f:
            content = f.read()

        # Get existing tests
        existing_tests = read_existing_tests(test_file)

        # Analyze coverage
        functions = extract_functions(content)
        tested = extract_tested_functions(existing_tests)
        untested = [f for f in functions if f.lower() not in tested and not f.startswith("test")]

        print(f"  Functions: {len(functions)}, Tested: {len(tested)}, Untested: {len(untested)}")

        if not untested:
            print("  All functions appear tested, checking for branch coverage...")

        # Generate additional tests
        print("  Generating comprehensive tests...")
        if new_tests := generate_comprehensive_tests(
            filename, content, existing_tests
        ):
            test_code = extract_zig_code(new_tests)
            if test_code and len(test_code) > 100:
                append_tests(test_file, test_code)
                stats["enhanced"] += 1
            else:
                print("  No additional tests generated")
                stats["skipped"] += 1
        else:
            stats["skipped"] += 1

        stats["processed"] += 1

    print("\n" + "=" * 60)
    print(f"Processed: {stats['processed']}")
    print(f"Enhanced: {stats['enhanced']}")
    print(f"Skipped: {stats['skipped']}")
    print("=" * 60)


if __name__ == "__main__":
    main()
