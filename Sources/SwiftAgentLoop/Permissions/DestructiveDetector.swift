import Foundation

/// Detects potentially destructive bash commands that should require explicit user approval.
/// Patterns ported from Claude Code's destructive command detection.
public struct DestructiveDetector: Sendable {

    /// Check if a bash command contains potentially destructive operations.
    /// Returns a warning message if destructive, nil if safe.
    public static func check(command: String) -> String? {
        for pattern in patterns {
            if pattern.regex.firstMatch(
                in: command,
                range: NSRange(command.startIndex..., in: command)
            ) != nil {
                return pattern.warning
            }
        }
        return nil
    }

    // MARK: - Internal

    private struct Pattern: Sendable {
        let regex: NSRegularExpression
        let warning: String
    }

    private typealias Spec = (pattern: String, warning: String, caseInsensitive: Bool)

    // swiftlint:disable:next function_body_length
    private static let patterns: [Pattern] = {
        let specs: [Spec] = [
            // ── Git — data loss / hard to reverse ──────────────────────

            (#"\bgit\s+reset\s+--hard\b"#,
             "Note: may discard uncommitted changes", false),

            (#"\bgit\s+push\b[^;&|\n]*[ \t](--force|--force-with-lease|-f)\b"#,
             "Note: may overwrite remote history", false),

            (#"\bgit\s+clean\b(?![^;&|\n]*(?:-[a-zA-Z]*n|--dry-run))[^;&|\n]*-[a-zA-Z]*f"#,
             "Note: may permanently delete untracked files", false),

            (#"\bgit\s+checkout\s+(--\s+)?\.[ \t]*($|[;&|\n])"#,
             "Note: may discard all working tree changes", false),

            (#"\bgit\s+restore\s+(--\s+)?\.[ \t]*($|[;&|\n])"#,
             "Note: may discard all working tree changes", false),

            (#"\bgit\s+stash[ \t]+(drop|clear)\b"#,
             "Note: may permanently remove stashed changes", false),

            (#"\bgit\s+branch\s+(-D[ \t]|--delete\s+--force|--force\s+--delete)\b"#,
             "Note: may force-delete a branch", false),

            // ── Git — safety bypass ────────────────────────────────────

            (#"\bgit\s+(commit|push|merge)\b[^;&|\n]*--no-verify\b"#,
             "Note: may skip safety hooks", false),

            (#"\bgit\s+commit\b[^;&|\n]*--amend\b"#,
             "Note: may rewrite the last commit", false),

            // ── File deletion ──────────────────────────────────────────

            (#"(^|[;&|\n]\s*)rm\s+-[a-zA-Z]*[rR][a-zA-Z]*f|(^|[;&|\n]\s*)rm\s+-[a-zA-Z]*f[a-zA-Z]*[rR]"#,
             "Note: may recursively force-remove files", false),

            (#"(^|[;&|\n]\s*)rm\s+-[a-zA-Z]*[rR]"#,
             "Note: may recursively remove files", false),

            (#"(^|[;&|\n]\s*)rm\s+-[a-zA-Z]*f"#,
             "Note: may force-remove files", false),

            // ── Database ───────────────────────────────────────────────

            (#"\b(DROP|TRUNCATE)\s+(TABLE|DATABASE|SCHEMA)\b"#,
             "Note: may drop or truncate database objects", true),

            (#"\bDELETE\s+FROM\s+\w+[ \t]*(;|"|'|\n|$)"#,
             "Note: may delete all rows from a database table", true),

            // ── Infrastructure ─────────────────────────────────────────

            (#"\bkubectl\s+delete\b"#,
             "Note: may delete Kubernetes resources", false),

            (#"\bterraform\s+destroy\b"#,
             "Note: may destroy Terraform infrastructure", false),

            // ── Disk destruction ──────────────────────────────────────

            (#"\bdd\s+[^;&|\n]*of="#,
             "Note: may overwrite disk or partition data", false),

            // ── Permission / ownership changes ────────────────────────

            (#"\bchmod\s+(000|777)\b"#,
             "Note: may remove all permissions or make world-writable", false),

            (#"\bchown\b"#,
             "Note: may change file ownership", false),

            // ── Remote code execution ─────────────────────────────────

            (#"\b(curl|wget)\b[^;&|\n]*\|\s*(ba)?sh\b"#,
             "Note: may execute remote code", false),

            // ── Git rebase safety bypass ──────────────────────────────

            (#"\bgit\s+rebase\b[^;&|\n]*--no-verify\b"#,
             "Note: may skip safety hooks during rebase", false),
        ]

        var result: [Pattern] = []
        for spec in specs {
            let options: NSRegularExpression.Options = spec.caseInsensitive
                ? [.caseInsensitive] : []
            if let regex = try? NSRegularExpression(
                pattern: spec.pattern,
                options: options
            ) {
                result.append(Pattern(regex: regex, warning: spec.warning))
            }
        }
        return result
    }()
}