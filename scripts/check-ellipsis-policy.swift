// Compile only with Sources/SwitcherCore/EllipsisBoundary.swift. This executable
// uses fixed strings and metadata: no AppKit, AX, keyboard sources or events.
import Foundation

@main
private enum EllipsisPolicyChecks {
    static func main() {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ name: String) {
            precondition(condition(), "Ellipsis policy: " + name)
            checks += 1
        }
        check(EllipsisBoundary.isCandidate(original: "ghbdtn..", incoming: "."), "third literal dot is eligible")
        for (original, incoming) in [("ghbdtn", "."), ("ghbdtn.", "."), ("ghbdtn...", "."),
                                     ("ghbdtn....", "."), ("ghbdtn…", "."), ("..", "."),
                                     ("ghbdtn..", "ю"), ("ghbdtn..", ".."), ("ghbdtn..", " ")] {
            check(!EllipsisBoundary.isCandidate(original: original, incoming: incoming), "only the third literal single dot triggers")
        }
        check(!EllipsisBoundary.isCandidate(original: String(repeating: "a", count: 126) + "..", incoming: "."), "new token remains within bounded size")
        check(EllipsisBoundary.permits(original: "fdnjgthtrk.xtybt..", correctionText: "автопереключение...", correctedStem: "автопереключение"), "internal encoded ю remains part of the independently recognized complete word")
        check(EllipsisBoundary.permits(original: "rjytxyj..", correctionText: "конечно...", correctedStem: "конечно"), "all dots are preserved")
        check(EllipsisBoundary.permits(original: "rudщ..", correctionText: "hello...", correctedStem: "hello"), "policy permits either detector-verified destination")
        check(EllipsisBoundary.permits(original: "сфтэе..", correctionText: "can't...", correctedStem: "can't"), "whole recognized contractions are allowed")
        check(EllipsisBoundary.permits(original: "rnj-nj..", correctionText: "кто-то...", correctedStem: "кто-то"), "whole recognized compounds are allowed")
        for (whole, stem) in [("конечною..", "конечно"), ("конечно…", "конечно"),
                              ("конечно....", "конечно"), ("конечную...", "конечно"),
                              ("ию...", "и"), ("привет...", "hello")] {
            check(!EllipsisBoundary.permits(original: "rjytxyj..", correctionText: whole, correctedStem: stem), "full detector answer cannot consume a dot or disagree with the bare stem")
        }
        check(!EllipsisBoundary.permits(original: "unknown..", correctionText: "угадай...", correctedStem: nil), "full answer alone cannot license an unknown stem")
        for stem in ["https://site", "user@site", "foo_bar", "x=hello", "foo123", "foo\\bar", "x/y", "foo bar"] {
            check(!EllipsisBoundary.permits(original: stem + "..", correctionText: "привет...", correctedStem: "привет"), "explicit address/code syntax never commits early")
        }
        for stem in ["example.com", "https://site", "a@b", "foo_bar", "123", "-", "-word", "word-"] {
            check(!EllipsisBoundary.permits(original: "ghbdtn..", correctionText: stem + "...", correctedStem: stem), "corrected address/code/nonword is not an early word boundary")
        }
        func armed() -> EllipsisContinuation {
            EllipsisContinuation(code: 47, modifierBits: 0, sourceID: "ru", destinationPID: 123)
        }
        var continued = armed()
        check(continued.isActive, "verified commit arms constant metadata")
        var rendered = "привет..."
        for _ in 0..<2 {
            if continued.consume(code: 47, modifierBits: 0, sourceID: "ru", destinationPID: 123) { rendered += "." }
        }
        check(rendered == "привет....." && continued.isActive, "fourth and fifth old physical dot remain dots after a source switch")
        // A long pause invokes no mutation, exactly as a quiet physical keyboard.
        check(continued.consume(code: 47, modifierBits: 0, sourceID: "ru", destinationPID: 123), "pausing alone does not turn the next identical dot into ю")
        check(!continued.consume(code: 4, modifierBits: 0, sourceID: "ru", destinationPID: 123), "the first following letter ends the punctuation sequence")
        check(!continued.consume(code: 47, modifierBits: 0, sourceID: "ru", destinationPID: 123), "a later dot cannot revive ended punctuation")
        var modified = armed()
        check(!modified.consume(code: 47, modifierBits: 1, sourceID: "ru", destinationPID: 123) && !modified.isActive, "Shift/Caps/other changed modifier ends continuation")
        var sourceChanged = armed()
        check(!sourceChanged.consume(code: 47, modifierBits: 0, sourceID: "en", destinationPID: 123), "external source change ends continuation")
        check(!sourceChanged.consume(code: 47, modifierBits: 0, sourceID: "ru", destinationPID: 123), "returning to the previous source cannot rearm it")
        var destinationChanged = armed()
        check(!destinationChanged.consume(code: 47, modifierBits: 0, sourceID: "ru", destinationPID: 456), "different application cannot inherit continuation")
        var reset = armed()
        reset.reset()
        check(!reset.isActive && !reset.consume(code: 47, modifierBits: 0, sourceID: "ru", destinationPID: 123), "explicit field/focus/cancel/disable reset clears continuation even within one PID")
        check(!EllipsisContinuation(code: 47, modifierBits: 0, sourceID: "", destinationPID: 123).isActive, "unknown source cannot arm continuation")
        check(!EllipsisContinuation(code: 47, modifierBits: 0, sourceID: "ru", destinationPID: 0).isActive, "unknown destination cannot arm continuation")
        print("Passed \(checks) ellipsis policy checks; no UI/system reads or event posting")
    }
}
