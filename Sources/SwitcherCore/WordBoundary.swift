import Foundation

// Boundary classification adapted from Bzz (MIT), Copyright (c) 2026 Roman Kovalev.
// https://github.com/zlopixatel/bzz/blob/b36c1c87d2fcafd82617686df74f0e74092d7ff4/buffer.go
// Uses live Apple tables instead of Bzz's fixed mapping; see THIRD_PARTY.md.

/// A printable boundary can be handled before its key reaches the editor.
/// Comma/period/quotes that are letters on the other layout stay in the token:
/// e.g. hf,jnftn must remain one word. Space/Enter/Tab resolve those tails later.
public enum WordBoundary {
    private static let endings = Set(".,!?;:)]}'\"»”’…—–")
    public static func isImmediate(_ text: String, mapped: String, token: String, mappedToken: String) -> Bool {
        guard text.count == 1, mapped.count == 1,
              !text.contains(where: \.isLetter), !mapped.contains(where: \.isLetter),
              let literal = text.first, let converted = mapped.first,
              endings.contains(literal) || endings.contains(converted) else { return false }
        // The right single quote is also an apostrophe. Its following letters
        // belong to the same word (he’d, John’s); treating it as a boundary
        // would turn that suffix into an unrelated short-word correction.
        // Closing single quotes can safely wait for Space/Enter/Tab instead.
        if "'’".contains(literal) || "'’".contains(converted) { return false }
        // Do not cut off domains, URL queries, email, paths or identifiers.
        // Their punctuation remains available to the whole-token address parser.
        for value in [token + text, mappedToken + mapped] {
            if value.dropLast().contains(where: { ".:".contains($0) }) { return false }
            if value.contains("@") || value.contains("/") || value.contains("\\") || value.contains("_") || value.contains("=") { return false }
        }
        return true
    }
}
