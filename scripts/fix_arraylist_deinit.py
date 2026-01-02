#!/usr/bin/env python3
"""Fix ArrayListUnmanaged deinit calls to include alloc parameter."""

import re
from pathlib import Path

TESTS_DIR = Path(__file__).parent.parent / "src" / "ai" / "tests"

def fix_test_file(filepath: Path):
    """Fix ArrayListUnmanaged deinit calls in a single file."""
    with open(filepath, 'r') as f:
        content = f.read()

    original = content

    # Find all variable names that are initialized as ArrayListUnmanaged
    # Pattern: var <name> = std.ArrayListUnmanaged(...){}
    arraylist_vars = set()
    pattern = r'var\s+(\w+)\s*=\s*std\.ArrayListUnmanaged\([^)]*\)\{\}'
    for match in re.finditer(pattern, content):
        arraylist_vars.add(match.group(1))

    # Also look for: var <name>: std.ArrayListUnmanaged(...) = ...
    pattern2 = r'var\s+(\w+)\s*:\s*std\.ArrayListUnmanaged\([^)]*\)'
    for match in re.finditer(pattern2, content):
        arraylist_vars.add(match.group(1))

    # For each ArrayList variable, fix its deinit call
    for var_name in arraylist_vars:
        # Fix: defer <var>.deinit() -> defer <var>.deinit(alloc)
        pattern = rf'defer\s+{var_name}\.deinit\(\)'
        replacement = f'defer {var_name}.deinit(alloc)'
        content = re.sub(pattern, replacement, content)

        # Also fix: <var>.deinit() at end of scope (not in defer)
        pattern = rf'{var_name}\.deinit\(\);'
        replacement = f'{var_name}.deinit(alloc);'
        content = re.sub(pattern, replacement, content)

    if content != original:
        with open(filepath, 'w') as f:
            f.write(content)
        return True, arraylist_vars
    return False, arraylist_vars

def main():
    print("Fixing ArrayListUnmanaged deinit calls...")

    fixed = 0
    for test_file in TESTS_DIR.glob("test_*.zig"):
        was_fixed, vars_found = fix_test_file(test_file)
        if was_fixed:
            print(f"  Fixed: {test_file.name} ({len(vars_found)} ArrayList vars)")
            fixed += 1

    print(f"\nFixed {fixed} files")

if __name__ == "__main__":
    main()
