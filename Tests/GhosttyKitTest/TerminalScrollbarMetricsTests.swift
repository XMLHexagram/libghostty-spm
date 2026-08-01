@testable import GhosttyTerminal
import Testing

/// The derived fractions a host draws a scrollbar from. All the interesting
/// cases are degenerate ones: a fresh terminal reports `offset == 0,
/// len == total`, and a host that divides naively there gets NaN on screen.
struct TerminalScrollbarMetricsTests {
    @Test("A viewport that shows everything is not scrollable")
    func fitsOnScreen() {
        #expect(TerminalScrollbarMetrics(total: 40, offset: 0, length: 40).fitsOnScreen)
        #expect(TerminalScrollbarMetrics(total: 10, offset: 0, length: 40).fitsOnScreen)
        #expect(!TerminalScrollbarMetrics(total: 400, offset: 0, length: 40).fitsOnScreen)
    }

    @Test("An empty terminal reports zeroes and must not divide by them")
    func emptyIsInert() {
        let empty = TerminalScrollbarMetrics(total: 0, offset: 0, length: 0)
        #expect(empty.fitsOnScreen)
        #expect(empty.scrollProgress == 0)
        #expect(empty.visibleFraction == 1)
    }

    @Test("Progress spans top to bottom of the scrollable range")
    func progressEndpoints() {
        // 400 rows total, 40 visible → 360 rows of travel.
        let top = TerminalScrollbarMetrics(total: 400, offset: 0, length: 40)
        let bottom = TerminalScrollbarMetrics(total: 400, offset: 360, length: 40)
        let middle = TerminalScrollbarMetrics(total: 400, offset: 180, length: 40)
        #expect(top.scrollProgress == 0)
        #expect(bottom.scrollProgress == 1)
        #expect(middle.scrollProgress == 0.5)
    }

    @Test("An offset past the end clamps instead of overshooting the track")
    func progressClamps() {
        let past = TerminalScrollbarMetrics(total: 400, offset: 9_999, length: 40)
        #expect(past.scrollProgress == 1)
    }

    @Test("Visible fraction is the thumb's share of the track")
    func visibleFraction() {
        #expect(TerminalScrollbarMetrics(total: 400, offset: 0, length: 40).visibleFraction == 0.1)
        // Nothing scrolled off yet — the thumb fills the track.
        #expect(TerminalScrollbarMetrics(total: 40, offset: 0, length: 40).visibleFraction == 1)
        // len > total shouldn't produce a thumb longer than the track.
        #expect(TerminalScrollbarMetrics(total: 40, offset: 0, length: 80).visibleFraction == 1)
    }
}

/// The momentum phase has to survive the trip into ghostty's packed
/// `ScrollMods` byte. It previously did not: four of the core's seven cases
/// were modelled and only two bits were read back, so `.ended` — the one a
/// settle-on-gesture-end would key off — silently arrived as `.none`.
struct TerminalScrollModifiersTests {
    @Test("Every momentum case round-trips through the packed rawValue")
    func momentumRoundTrips() {
        for momentum in [
            TerminalScrollModifiers.Momentum.none, .began, .stationary,
            .changed, .ended, .cancelled, .mayBegin,
        ] {
            let packed = TerminalScrollModifiers(precision: true, momentum: momentum)
            #expect(packed.momentum == momentum, "\(momentum) did not survive packing")
            #expect(packed.precision, "the precision bit must not be clobbered by momentum")
        }
    }

    @Test("Precision is the low bit and independent of momentum")
    func precisionIsIndependent() {
        #expect(!TerminalScrollModifiers(precision: false, momentum: .ended).precision)
        #expect(TerminalScrollModifiers(precision: true, momentum: .none).rawValue == 1)
    }
}
