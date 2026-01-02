#!/usr/bin/env python3
"""Comprehensive fix for LLM-generated test files."""

import re
from pathlib import Path

TESTS_DIR = Path(__file__).parent.parent / "src" / "ai" / "tests"

def fix_test_file(filepath: Path):
    """Fix common issues in a test file."""
    with open(filepath, 'r', encoding='utf-8') as f:
        content = f.read()

    original = content

    # 1. Remove invalid "const module.X = module.X" lines
    content = re.sub(r'^const module\.\w+ = module\.\w+;\s*\n', '', content, flags=re.MULTILINE)

    # 2. Remove invalid "pub const module.X = ..." lines
    content = re.sub(r'^pub const module\.\w+.*?;\s*\n', '', content, flags=re.MULTILINE)

    # 3. Remove duplicate std imports (keep first one)
    lines = content.split('\n')
    seen_std_import = False
    new_lines = []
    for line in lines:
        if line.strip() == 'const std = @import("std");':
            if not seen_std_import:
                seen_std_import = True
                new_lines.append(line)
            # else skip duplicate
        else:
            new_lines.append(line)
    content = '\n'.join(new_lines)

    # 4. Remove lines that are just "bash" or other shell artifacts
    content = re.sub(r'^bash\s*$', '', content, flags=re.MULTILINE)
    content = re.sub(r'^zig\s*$', '', content, flags=re.MULTILINE)

    # 5. Fix "var x = const" pattern (LLM mistake)
    content = re.sub(r'var\s+(\w+)\s*=\s*const\s+', r'const \1 = ', content)

    # 6. Clean up multiple blank lines
    content = re.sub(r'\n{3,}', '\n\n', content)

    if content != original:
        with open(filepath, 'w', encoding='utf-8') as f:
            f.write(content)
        return True
    return False

def check_truncated(filepath: Path) -> bool:
    """Check if file appears truncated."""
    with open(filepath, 'r', encoding='utf-8') as f:
        content = f.read()

    # Count braces
    open_braces = content.count('{')
    close_braces = content.count('}')

    return open_braces != close_braces

def main():
    print("Fixing test files...")

    fixed = 0
    truncated = []

    for test_file in sorted(TESTS_DIR.glob("test_*.zig")):
        if fix_test_file(test_file):
            print(f"  Fixed: {test_file.name}")
            fixed += 1

        if check_truncated(test_file):
            truncated.append(test_file.name)

    print(f"\nFixed {fixed} files")

    if truncated:
        print(f"\nPotentially truncated files ({len(truncated)}):")
        for f in truncated:
            print(f"  - {f}")

if __name__ == "__main__":
    main()
