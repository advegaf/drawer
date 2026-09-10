import SwiftUI

/// The motion vocabulary, in one place so the whole surface moves like one thing.
enum NotchMotion {
    /// Opening and closing the notch, in both directions, as it was in the
    /// project's first commit: the fold is the same physical event as the
    /// unfold, played backward, not a separate faster motion.
    static let unfold = Animation.spring(response: 0.42, dampingFraction: 0.78)

    /// The base spring `stagger` below delays per cell. Not used directly
    /// anywhere else: see `overscroll` for the value that used to sit under
    /// this name.
    static let contents = Animation.spring(response: 0.36, dampingFraction: 0.82)

    /// A level bar catching up to a change it did not originate: a
    /// brightness key, another app, the system. Short and critically
    /// damped, so the fill slides to the new value and stops dead rather
    /// than overshooting it. A drag never uses this; it draws instantly.
    static let level = Animation.easeOut(duration: 0.18)

    /// The overscroll bounce and the pending-cell scale used to share this
    /// value under the name `contents`. Restoring `contents` above to its
    /// original spring would have silently changed both, so they get their
    /// own constant instead, holding the value `contents` used to hold.
    static let overscroll = Animation.easeOut(duration: 0.18)

    /// The settings handle's own hover animation, not part of opening or
    /// closing the notch. See Sources/Features/SettingsHandle.swift.
    static let handle = Animation.easeOut(duration: 0.18)

    /// The scroll step between cells and the scroll chevrons. In this fork
    /// these drive scrolling within an already-open notch, not the notch
    /// opening or closing, so they keep this fork's values rather than the
    /// ones from the project's first commit. Leave them alone: restoring
    /// their old numbers here would be a different, unrequested change.
    static let glide = Animation.easeOut(duration: 0.14)
    static let crossfade = Animation.easeOut(duration: 0.1)

    /// The settings orb being taken back into the notch on close, ahead of
    /// the fold itself so it is already absorbed before the shape closes
    /// around where it was.
    static let merge = Animation.easeIn(duration: 0.2)

    /// Each cell trails the one above it, so the stack unfurls rather than
    /// appearing all at once. Capped so a long list never feels sluggish.
    static func stagger(index: Int) -> Animation {
        contents.delay(min(Double(index) * 0.045, 0.18))
    }

    /// Everything above, unless the system has been asked for less movement.
    static func respectingReduceMotion(_ animation: Animation, _ reduce: Bool) -> Animation? {
        reduce ? nil : animation
    }
}
