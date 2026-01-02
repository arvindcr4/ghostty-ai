#!/usr/bin/env python3
"""Fix ArrayListUnmanaged deinit calls to include alloc parameter.

This script safely modifies test files to add allocator parameter to deinit() calls.
Uses word boundaries to prevent matching inside comments/strings or partial variable names.
"""

import argparse
import re
import shutil
from datetime import datetime
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


def create_backup(filepath: Path) -> Path:
    """Create a timestamped backup of the file."""
    backup_dir = filepath.parent / ".backups"
    backup_dir.mkdir(exist_ok=True)
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    backup_path = backup_dir / f"{filepath.stem}_{timestamp}{filepath.suffix}"
    shutil.copy2(filepath, backup_path)
    return backup_path


def is_inside_comment_or_string(content: str, match_start: int) -> bool:
    """Check if a match position is inside a comment or string literal."""
    # Check for // single-line comment
    line_start = content.rfind('\n', 0, match_start) + 1
    line_before = content[line_start:match_start]
    if '//' in line_before:
        return True

    # Simple check for string literal (count unescaped quotes before position)
    before = content[:match_start]
    # This is a heuristic - not perfect but catches common cases
    quote_count = before.count('"') - before.count('\\"')
    if quote_count % 2 == 1:
        return True

    return False


def fix_test_file(filepath: Path, dry_run: bool = False):
    """Fix ArrayListUnmanaged deinit calls in a single file.

    Uses word boundaries to prevent matching partial variable names.
    Skips matches inside comments or string literals.
    """
    with open(filepath, 'r', encoding='utf-8') as f:
        content = f.read()

    original = content

    # Detect the allocator variable name used in this file
    alloc_name = detect_allocator_name(content)

    # Find ArrayList variable declarations with word boundaries
    pattern = r'\bvar\s+(\w+)\s*=\s*std\.ArrayListUnmanaged\([^)]*\)\{\}'
    arraylist_vars = {match.group(1) for match in re.finditer(pattern, content)}
    # Also look for: var <name>: std.ArrayListUnmanaged(...) = ...
    pattern2 = r'\bvar\s+(\w+)\s*:\s*std\.ArrayListUnmanaged\([^)]*\)'
    for match in re.finditer(pattern2, content):
        arraylist_vars.add(match.group(1))

    changes_made = []

    # For each ArrayList variable, fix its deinit call
    for var_name in arraylist_vars:
        # Use word boundary \b to ensure exact variable name match
        # Pattern: defer <var>.deinit() -> defer <var>.deinit(alloc_name)
        defer_pattern = rf'\bdefer\s+{re.escape(var_name)}\.deinit\(\)'
        defer_replacement = f'defer {var_name}.deinit({alloc_name})'

        # Use a replacement function that skips matches inside comments/strings
        def make_defer_replacer(pattern_content):
            def replacer(match):
                if is_inside_comment_or_string(pattern_content, match.start()):
                    return match.group(0)  # Keep original if inside comment/string
                changes_made.append((match.group(0), defer_replacement))
                return defer_replacement
            return replacer

        content = re.sub(defer_pattern, make_defer_replacer(content), content)

        # Pattern: <var>.deinit(); at end of scope (with word boundary)
        deinit_pattern = rf'\b{re.escape(var_name)}\.deinit\(\);'
        deinit_replacement = f'{var_name}.deinit({alloc_name});'

        def make_deinit_replacer(pattern_content):
            def replacer(match):
                if is_inside_comment_or_string(pattern_content, match.start()):
                    return match.group(0)  # Keep original if inside comment/string
                if match.group(0) != deinit_replacement:
                    changes_made.append((match.group(0), deinit_replacement))
                return deinit_replacement
            return replacer

        content = re.sub(deinit_pattern, make_deinit_replacer(content), content)

    if content != original:
        if dry_run:
            print(f"  Would fix: {filepath.name}")
            for old, new in changes_made[:3]:  # Show first 3 changes
                print(f"    {old} -> {new}")
            if len(changes_made) > 3:
                print(f"    ... and {len(changes_made) - 3} more changes")
            return True, arraylist_vars, alloc_name

        # Create backup before modifying
        backup_path = create_backup(filepath)

        with open(filepath, 'w', encoding='utf-8') as f:
            f.write(content)
        return True, arraylist_vars, alloc_name
    return False, arraylist_vars, alloc_name


def main():
    parser = argparse.ArgumentParser(
        description="Fix ArrayListUnmanaged deinit calls to include alloc parameter"
    )
    parser.add_argument(
        "--dry-run", "-n",
        action="store_true",
        help="Show what would be changed without modifying files"
    )
    args = parser.parse_args()

    mode = "DRY RUN - " if args.dry_run else ""
    print(f"{mode}Fixing ArrayListUnmanaged deinit calls...")

    fixed = 0
    for test_file in TESTS_DIR.glob("test_*.zig"):
        was_fixed, vars_found, alloc_name = fix_test_file(test_file, dry_run=args.dry_run)
        if was_fixed:
            action = "Would fix" if args.dry_run else "Fixed"
            print(f"  {action}: {test_file.name} ({len(vars_found)} ArrayList vars, allocator='{alloc_name}')")
            fixed += 1

    action = "would be fixed" if args.dry_run else "files fixed"
    print(f"\n{fixed} {action}")

    if args.dry_run and fixed > 0:
        print("\nRun without --dry-run to apply changes (backups will be created)")


if __name__ == "__main__":
    main()
