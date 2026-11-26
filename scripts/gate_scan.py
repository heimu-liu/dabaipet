"""Static checks for the Swift package. Run from the repository root."""
import re
import sys
from pathlib import Path

CORE_IMPORT = r"(?m)^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:\w+\s+)?import\s+(?:\w+\s+)?(?:AppKit|Cocoa|SwiftUI|Carbon|AVFoundation|Speech|Vision|CoreMediaIO)\b"
TEST_SHORTCUT = r"(?:\bimport\s+XCTest\b|\.disabled\b|\bwithKnownIssue\b|#expect\s*\(\s*true\s*\))"
HOME_CONFIG = r"(?:[/~]|\x22)\.(?:codex|claude)\b"
KEY = r"\bsk-(?:ant-)?[A-Za-z0-9_-]{20,}"
CLI = r"""(?:^|[/\s\"'])(?:codex|claude)(?=[\s\"']|$)"""
LAUNCH = r"\b(?:Process\s*\(|executableURL|launchPath|system\s*\(|posix_spawn\w*\s*\()|/bin/(?:ba|z)?sh\b"
ESCAPE = r"@unchecked\s+Sendable|nonisolated\s*\(\s*unsafe\s*\)|@preconcurrency|\.swiftLanguageMode\s*\(\s*\.v5\s*\)"


def violations(path, source):
    rules = [(r"\bimport\s+XCTest\b", "XCTest import"), (HOME_CONFIG, "private agent config"),
             (ESCAPE, "concurrency exception needs ORCH review")]
    if path.startswith("Tests/"):
        rules.append((TEST_SHORTCUT, "disabled or ineffective test"))
    if path.startswith("Sources/DabaiPetCore/"):
        rules.append((CORE_IMPORT, "Core framework import"))
    if Path(path).stem == "TypingCompanionMonitor":
        rules.append((r"\bNSEvent\b|\bCGEventTap\b|\bCGEvent\.tapCreate", "keyboard event access"))
    if re.search(LAUNCH, source):
        rules.append((CLI, "agent CLI invocation"))
    for pattern, label in rules:
        for match in re.finditer(pattern, source):
            yield source.count("\n", 0, match.start()) + 1, label
    for match in re.finditer(KEY, source):
        if path.startswith("Tests/") and match.group().startswith("sk-TEST-FIXTURE-"):
            continue
        yield source.count("\n", 0, match.start()) + 1, "possible embedded secret"


def self_test():
    core = "Sources/DabaiPetCore/Example.swift"
    monitor = "Sources/DabaiPetApp/TypingCompanionMonitor.swift"
    checks = [
        (core, "@testable import class AppKit.NSView", True),
        (core, "public import SwiftUI", True), (core, "import Foundation", False),
        (core, "import XCTest", True), ("Tests/Test.swift", "@Test(.disabled())", True),
        ("Tests/Test.swift", "withKnownIssue {}", True),
        ("Tests/Test.swift", "#expect( true )", True),
        ("Sources/DabaiPetUI/Settings.swift", "Button().disabled(loading)", False),
        (core, 'let path = "~/.codex/auth.json"', True),
        (core, 'let path = "/Users/me/.claude"', True),
        (core, 'let p = Process(); p.arguments = ["codex", "exec"]', True),
        (core, 'launchPath = "/usr/local/bin/claude"', True),
        (core, 'let m = "claude-haiku-4-5"', False),
        (core, 'let p = Process(); let m = "claude-haiku-4-5"', False),
        (core, 'let name = "task-1 disk-012345678901234567890"', False),
        (core, "sk-ant-" + "x" * 24, True),
        (core, "sk-" + "x" * 24, True),
        ("Tests/Fixtures/f.swift", "sk-TEST-FIXTURE-" + "x" * 24, False),
        (monitor, "NSEvent.addGlobalMonitorForEvents", True),
        (monitor, "CGEventSource.counterForEventType", False),
    ]
    for value in ["@unchecked Sendable", "nonisolated(unsafe)", "@preconcurrency", ".swiftLanguageMode(.v5)"]:
        checks.append((core, value, True))
    for path, content, forbidden in checks:
        if bool(list(violations(path, content))) != forbidden:
            sys.exit(f"static gate self-test failed: {path}, rule example {checks.index((path, content, forbidden))}")
    print(f"static fixtures: {len(checks)} passed")


if __name__ == "__main__":
    self_test()
    if sys.argv[1:] == ["--self-test"]:
        sys.exit()
    files = [Path("Package.swift")]
    for root in ("Sources", "Tests"):
        files.extend(sorted(Path(root).rglob("*.swift")))
    failed = False
    for file in files:
        for line, message in violations(file.as_posix(), file.read_text()):
            print(f"{file}:{line}: {message}", file=sys.stderr)
            failed = True
    sys.exit(int(failed))
