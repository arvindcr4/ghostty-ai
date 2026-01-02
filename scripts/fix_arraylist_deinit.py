#!/usr/bin/env python3
"""Fix ArrayListUnmanaged deinit calls to include alloc parameter."""

import re
from pathlib import Path

TESTS_DIR = Path(__file__).parent.parent / "src" / "ai" / "tests"


def detect_allocator_name(content: str) -> str:
    """Detect the allocator variable name used in the file.

    Common patterns in Zig test files:
    - const alloc = std.testing.allocator;
    - const allocator = std.testing.allocator;
    - const gpa = std.heap.GeneralPurposeAllocator(.{}){};
    - const ally = ...

    Returns the detected name or 'std.testing.allocator' as fallback.
    """
    # Check for common allocator variable assignments
    patterns = [
        r'const\s+(alloc)\s*=\s*std\.testing\.allocator',
        r'const\s+(allocator)\s*=\s*std\.testing\.allocator',
        r'const\s+(gpa)\s*=',
        r'const\s+(ally)\s*=',
        r'var\s+(alloc)\s*=\s*std\.testing\.allocator',
        r'var\s+(allocator)\s*=\s*std\.testing\.allocator',
    ]

    for pattern in patterns:
        if match := re.search(pattern, content):
            return match[1]

    # If no variable found, check if std.testing.allocator is used directly
    if 'std.testing.allocator' in content:
        return 'std.testing.allocator'

    # Default fallback
    return 'alloc'


def fix_test_file(filepath: Path):
    """Fix ArrayListUnmanaged deinit calls in a single file."""
    with open(filepath, 'r', encoding='utf-8') as f:
        content = f.read()

    original = content

    # Detect the allocator variable name used in this file
    alloc_name = detect_allocator_name(content)

    pattern = r'var\s+(\w+)\s*=\s*std\.ArrayListUnmanaged\([^)]*\)\{\}'
    arraylist_vars = {match.group(1) for match in re.finditer(pattern, content)}
    # Also look for: var <name>: std.ArrayListUnmanaged(...) = ...
    pattern2 = r'var\s+(\w+)\s*:\s*std\.ArrayListUnmanaged\([^)]*\)'
    for match in re.finditer(pattern2, content):
        arraylist_vars.add(match.group(1))

    # For each ArrayList variable, fix its deinit call
    for var_name in arraylist_vars:
        # Fix: defer <var>.deinit() -> defer <var>.deinit(alloc_name)
        pattern = rf'defer\s+{var_name}\.deinit\(\)'
        replacement = f'defer {var_name}.deinit({alloc_name})'
        content = re.sub(pattern, replacement, content)

        # Also fix: <var>.deinit() at end of scope (not in defer)
        pattern = rf'{var_name}\.deinit\(\);'
        replacement = f'{var_name}.deinit({alloc_name});'
        content = re.sub(pattern, replacement, content)

    if content != original:
        with open(filepath, 'w', encoding='utf-8') as f:
            f.write(content)
        return True, arraylist_vars, alloc_name
    return False, arraylist_vars, alloc_name


def main():
    print("Fixing ArrayListUnmanaged deinit calls...")

    fixed = 0
    for test_file in TESTS_DIR.glob("test_*.zig"):
        was_fixed, vars_found, alloc_name = fix_test_file(test_file)
        if was_fixed:
            print(f"  Fixed: {test_file.name} ({len(vars_found)} ArrayList vars, allocator='{alloc_name}')")
            fixed += 1

    print(f"\nFixed {fixed} files")

if __name__ == "__main__":
    main()
