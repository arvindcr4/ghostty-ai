#!/usr/bin/env python3
"""
Generate unit tests for Ghostty AI module files using Cerebras SDK.
Uses Cerebras's fast inference to analyze Zig source files and generate comprehensive tests.
"""

import os
import sys
from pathlib import Path
from cerebras.cloud.sdk import Cerebras

# Cerebras API configuration - multiple keys for rate limit handling
CEREBRAS_API_KEYS = [
    "csk-5j8mmycv5m9fptjpwvwfnj86hptfy48vy92mcxxtfe993vf2",
    "csk-vc38d5m3tkdneecmvpnch5krntfy8hxkwvx8ttrmtydktdw3",
# Cerebras API configuration - load from environment
CEREBRAS_API_KEYS = [
    os.environ.get("CEREBRAS_API_KEY_1"),
    os.environ.get("CEREBRAS_API_KEY_2"),
]

# Filter out None values in case only one key is provided
CEREBRAS_API_KEYS = [key for key in CEREBRAS_API_KEYS if key]

if not CEREBRAS_API_KEYS:
    print("ERROR: No Cerebras API keys found. Set CEREBRAS_API_KEY_1 and/or CEREBRAS_API_KEY_2 environment variables.")
    sys.exit(1)

# Initialize Cerebras clients for both keys
clients = [Cerebras(api_key=key) for key in CEREBRAS_API_KEYS]
current_client_idx = 0

def get_client():
    """Get current client, rotating on rate limit."""
    global current_client_idx
    return clients[current_client_idx]

def rotate_client():
    """Switch to next API key."""
    global current_client_idx
    current_client_idx = (current_client_idx + 1) % len(clients)
    print(f"  Switched to API key {current_client_idx + 1}")

# AI module directory
AI_MODULE_DIR = Path(__file__).parent.parent / "src" / "ai"

# Files to generate tests for - ALL AI module files for 100% coverage
TARGET_FILES = [
    # Already have tests (keeping for completeness if re-run)
    "validation.zig",
    "mcp.zig",
    "history.zig",
    "shell.zig",
    "redactor.zig",
    "suggestions.zig",
    "prompt_suggestions.zig",
    "completions.zig",
    "active.zig",
    "ssh.zig",
    "theme.zig",
    "explanation.zig",
    "client.zig",
    "workflow.zig",
    "workflows.zig",
    # Missing tests - adding for 100% coverage
    "analytics.zig",
    "blocks.zig",
    "collaboration.zig",
    "command_corrections.zig",
    "command_history.zig",
    "corrections.zig",
    "custom_prompts.zig",
    "documentation.zig",
    "embeddings.zig",
    "error_recovery.zig",
    "export_import.zig",
    "ide_editing.zig",
    "keyboard_shortcuts.zig",
    "knowledge_rules.zig",
    "main.zig",
    "multi_turn.zig",
    "next_command.zig",
    "notebooks.zig",
    "notifications.zig",
    "performance.zig",
    "plugins.zig",
    "progress.zig",
    "rich_history.zig",
    "rollback.zig",
    "secrets.zig",
    "security.zig",
    "session_sharing.zig",
    "sharing.zig",
    "theme_suggestions.zig",
    "voice.zig",
]


def read_file(filepath: Path) -> str:
    """Read file contents."""
    try:
        with open(filepath, "r") as f:
            return f.read()
    except Exception as e:
        print(f"Error reading {filepath}: {e}")
        return ""


def analyze_zig_file(content: str, filename: str) -> dict:
    """Use Cerebras to analyze a Zig file and extract testable components."""

    prompt = f"""Analyze this Zig source file and identify all testable components.

File: {filename}

```zig
{content[:8000]}
```

Return a JSON object with:
1. "structs": List of struct names with their public methods
2. "functions": List of public functions
3. "enums": List of enum types
4. "test_suggestions": List of specific test cases to write

Focus on:
- Initialization and deinitialization
- Error handling paths
- Edge cases (empty input, null values)
- State transitions
- Memory management

Be concise and specific."""

    # Try with current client, rotate on rate limit
    for attempt in range(len(clients)):
        try:
            response = get_client().chat.completions.create(
                model="zai-glm-4.6",
                messages=[
                    {"role": "system", "content": "You are a Zig programming expert specializing in test-driven development. Analyze code and suggest comprehensive test cases."},
                    {"role": "user", "content": prompt}
                ],
                max_tokens=2000,
                temperature=0.3,
            )
            return {"analysis": response.choices[0].message.content, "filename": filename}
        except Exception as e:
            if "429" in str(e) or "rate" in str(e).lower() or "quota" in str(e).lower():
                rotate_client()
                continue
            print(f"Error analyzing {filename}: {e}")
            return {"analysis": "", "filename": filename}

    print(f"All API keys exhausted for {filename}")
    return {"analysis": "", "filename": filename}


def generate_tests(content: str, filename: str, analysis: str) -> str:
    """Use Cerebras to generate Zig unit tests."""

    prompt = f"""Generate comprehensive Zig unit tests for this file.

File: {filename}
Analysis: {analysis}

Source code (first 6000 chars):
```zig
{content[:6000]}
```

Requirements:
1. Use std.testing.allocator for memory management
2. Use ArrayListUnmanaged with .empty initialization (Zig 0.15 API)
3. Test initialization, normal operations, edge cases, and cleanup
4. Use defer for cleanup
5. Follow this test pattern:

```zig
test "descriptive test name" {{
    const alloc = std.testing.allocator;
    // setup
    // action
    // assertions using try std.testing.expect() or try std.testing.expectEqual()
}}
```

Generate 5-10 focused, well-documented tests. Output ONLY the test code, no explanations."""

    # Try with current client, rotate on rate limit
    for attempt in range(len(clients)):
        try:
            response = get_client().chat.completions.create(
                model="zai-glm-4.6",
                messages=[
                    {"role": "system", "content": "You are a Zig testing expert. Generate clean, comprehensive unit tests that follow Zig 0.15 conventions. Output only valid Zig test code."},
                    {"role": "user", "content": prompt}
                ],
                max_tokens=4000,
                temperature=0.2,
            )
            return response.choices[0].message.content
        except Exception as e:
            if "429" in str(e) or "rate" in str(e).lower() or "quota" in str(e).lower():
                rotate_client()
                continue
            print(f"Error generating tests for {filename}: {e}")
            return ""

    print(f"All API keys exhausted for {filename}")
    return ""


def extract_zig_tests(response: str) -> str:
    """Extract Zig test code from LLM response."""
    # Try to find code blocks
    if "```zig" in response:
        parts = response.split("```zig")
        if len(parts) > 1:
            code = parts[1].split("```")[0]
            code = code.strip()
    elif "```" in response:
        parts = response.split("```")
        if len(parts) > 1:
            code = parts[1]
            if code.startswith("zig\n"):
                code = code[4:]
            code = code.strip()
    else:
        code = response.strip()

    # Remove duplicate imports that conflict with header
    lines = code.split('\n')
    filtered_lines = []
    for line in lines:
        # Skip imports that are already in the header
        stripped = line.strip()
        if stripped.startswith('const std = @import("std")'):
            continue
        if stripped.startswith('const testing = std.testing'):
            continue
        if stripped.startswith('const module = @import('):
            continue
        # Skip lines that import the module we're testing (header handles this)
        if '@import("' in stripped and '.zig")' in stripped and stripped.startswith('const '):
            # Extract the filename and check if it matches our module pattern
            if '= @import("' in stripped:
                continue
        filtered_lines.append(line)

    return '\n'.join(filtered_lines).strip()


def save_tests(filename: str, tests: str, output_dir: Path):
    """Save generated tests to a file."""
    output_file = output_dir / f"test_{filename}"

    # Create header with imports
    header = f"""//! Auto-generated unit tests for {filename}
//! Generated using Cerebras SDK

const std = @import("std");
const testing = std.testing;

// Import the module under test
const module = @import("{filename}");

"""

    full_content = header + tests

    try:
        with open(output_file, "w") as f:
            f.write(full_content)
        print(f"  Saved tests to {output_file}")
    except Exception as e:
        print(f"  Error saving {output_file}: {e}")


def generate_test_report(results: list) -> str:
    """Generate a summary report of test generation."""
    report = """
# AI Module Test Generation Report
Generated using Cerebras SDK

## Files Processed
"""
    for result in results:
        status = "✓" if result.get("success") else "✗"
        report += f"- {status} {result['filename']}\n"

    report += f"""
## Summary
- Total files: {len(results)}
- Successful: {sum(1 for r in results if r.get('success'))}
- Failed: {sum(1 for r in results if not r.get('success'))}

## Next Steps
1. Review generated tests in src/ai/tests/
2. Fix any compilation errors
3. Run: zig build test
"""
    return report


def main():
    print("=" * 60)
    print("Ghostty AI Module Test Generator")
    print("Using Cerebras SDK for fast LLM inference")
    print("=" * 60)

    # Create output directory
    output_dir = AI_MODULE_DIR / "tests"
    output_dir.mkdir(exist_ok=True)
    print(f"\nOutput directory: {output_dir}")

    results = []

    for filename in TARGET_FILES:
        filepath = AI_MODULE_DIR / filename

        if not filepath.exists():
            print(f"\n[SKIP] {filename} - file not found")
            results.append({"filename": filename, "success": False, "error": "not found"})
            continue

        # Skip if test already exists (unless REGENERATE env var is set)
        test_file = output_dir / f"test_{filename}"
        if test_file.exists() and not os.environ.get("REGENERATE"):
            print(f"\n[SKIP] {filename} - test already exists")
            results.append({"filename": filename, "success": True, "skipped": True})
            continue

        print(f"\n[PROCESSING] {filename}")

        # Read source file
        content = read_file(filepath)
        if not content:
            results.append({"filename": filename, "success": False, "error": "read error"})
            continue

        print(f"  Read {len(content)} bytes")

        # Analyze file
        print("  Analyzing with Cerebras...")
        analysis = analyze_zig_file(content, filename)

        if not analysis.get("analysis"):
            print("  Warning: Empty analysis, using basic approach")
            analysis["analysis"] = "Basic struct and function testing"

        # Generate tests
        print("  Generating tests...")
        tests = generate_tests(content, filename, analysis["analysis"])

        if tests:
            # Extract actual test code
            test_code = extract_zig_tests(tests)

            if test_code:
                save_tests(filename, test_code, output_dir)
                results.append({"filename": filename, "success": True})
            else:
                print("  Warning: Could not extract test code")
                results.append({"filename": filename, "success": False, "error": "extraction failed"})
        else:
            print("  Error: No tests generated")
            results.append({"filename": filename, "success": False, "error": "generation failed"})

    # Generate and save report
    report = generate_test_report(results)
    report_path = output_dir / "REPORT.md"
    with open(report_path, "w") as f:
        f.write(report)
    print(f"\nReport saved to {report_path}")

    print("\n" + "=" * 60)
    print("Test generation complete!")
    print(f"Successful: {sum(1 for r in results if r.get('success'))}/{len(results)}")
    print("=" * 60)

    return 0 if all(r.get("success") for r in results) else 1


if __name__ == "__main__":
    sys.exit(main())
