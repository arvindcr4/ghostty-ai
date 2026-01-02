#!/usr/bin/env python3
"""
Add inline tests directly to Zig source files for 100% coverage.
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

# Files that need inline tests (0 or few tests)
TARGET_FILES = [
    "active.zig",
    "analytics.zig",
    "blocks.zig",
    "client.zig",
    "command_corrections.zig",
    "command_history.zig",
    "completions.zig",
    "corrections.zig",
    "custom_prompts.zig",
    "documentation.zig",
    "error_recovery.zig",
    "explanation.zig",
    "export_import.zig",
    "history.zig",
    "ide_editing.zig",
    "keyboard_shortcuts.zig",
    "knowledge_rules.zig",
    "multi_turn.zig",
    "next_command.zig",
    "performance.zig",
    "plugins.zig",
    "progress.zig",
    "prompt_suggestions.zig",
    "rich_history.zig",
    "rollback.zig",
    "secrets.zig",
    "session_sharing.zig",
    "sharing.zig",
    "shell.zig",
    "suggestions.zig",
    "theme.zig",
    "workflow.zig",
    "workflows.zig",
]


def has_tests(content: str) -> bool:
    return bool(re.search(r'^test\s+"', content, re.MULTILINE))


def generate_inline_tests(filename: str, content: str) -> str:
    """Generate inline tests for a Zig source file."""

    prompt = f"""Generate inline unit tests for this Zig file to achieve 100% code coverage.

File: {filename}

```zig
{content[:15000]}
```

REQUIREMENTS:
1. Generate tests that go at the END of this file (after all existing code)
2. Test ALL public functions (pub fn)
3. Test ALL public structs - init, deinit, and each method
4. Test error paths and edge cases
5. Use std.testing.allocator for memory
6. Use Zig 0.15 API: ArrayListUnmanaged.empty, .deinit(alloc)

OUTPUT FORMAT - Generate tests in this exact format:
```zig
// ============================================================================
// Unit Tests
// ============================================================================

test "StructName.init - basic initialization" {{
    const alloc = std.testing.allocator;
    var obj = StructName.init(alloc);
    defer obj.deinit();
    try std.testing.expect(obj.field != null);
}}

test "StructName.method - normal case" {{
    // test code
}}

test "StructName.method - error case" {{
    // test error returns
}}
```

Generate 5-15 focused tests covering all code paths. Output ONLY the test code block."""

    for _ in range(len(clients)):
        try:
            response = get_client().chat.completions.create(
                model="zai-glm-4.6",
                messages=[
                    {"role": "system", "content": "You are a Zig testing expert. Generate inline tests that go at the end of Zig source files. Use Zig 0.15 conventions."},
                    {"role": "user", "content": prompt}
                ],
                max_tokens=4000,
                temperature=0.2,
            )
            return response.choices[0].message.content
        except Exception as e:
            if "429" in str(e) or "rate" in str(e).lower():
                rotate_client()
                continue
            print(f"Error: {e}")
            return ""
    return ""


def extract_tests(response: str) -> str:
    """Extract test code from response."""
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
    return ""


def append_tests_to_file(filepath: Path, tests: str):
    """Append tests to the end of a Zig source file."""
    with open(filepath, "a") as f:
        f.write("\n\n")
        f.write(tests)
    print(f"  Added inline tests to {filepath.name}")


def main():
    print("=" * 60)
    print("Adding Inline Tests for 100% Coverage")
    print("=" * 60)

    stats = {"processed": 0, "added": 0, "skipped": 0}

    for filename in TARGET_FILES:
        filepath = AI_MODULE_DIR / filename

        if not filepath.exists():
            print(f"\n[SKIP] {filename} - not found")
            stats["skipped"] += 1
            continue

        print(f"\n[PROCESSING] {filename}")

        with open(filepath, "r") as f:
            content = f.read()

        # Check if already has tests
        if has_tests(content):
            print(f"  Already has tests, skipping")
            stats["skipped"] += 1
            continue

        # Generate tests
        print("  Generating inline tests...")
        response = generate_inline_tests(filename, content)

        if response:
            tests = extract_tests(response)
            if tests and len(tests) > 100:
                append_tests_to_file(filepath, tests)
                stats["added"] += 1
            else:
                print("  No valid tests generated")
                stats["skipped"] += 1
        else:
            stats["skipped"] += 1

        stats["processed"] += 1

    print("\n" + "=" * 60)
    print(f"Processed: {stats['processed']}")
    print(f"Tests added: {stats['added']}")
    print(f"Skipped: {stats['skipped']}")
    print("=" * 60)


if __name__ == "__main__":
    main()
