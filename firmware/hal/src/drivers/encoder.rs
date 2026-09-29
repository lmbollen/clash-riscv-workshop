// SPDX-License-Identifier: Apache-2.0

//! Ergonomic driver methods for the generated `RotaryEncoder` peripheral.
//!
//! Like `serial.rs`, this adds inherent methods straight onto the generated type,
//! which is possible because the PAC is generated in this same crate.
//!
//! The hardware does the parts that need a clock: synchronising the pins,
//! debouncing the button and switch, and decoding quadrature into a counter. What
//! it deliberately does not do is remember anything on the reader's behalf. Its
//! `position` register is a small free-running counter that wraps every
//! [`RotaryEncoder::POSITION_SIZE`] edges — useful for working out *movement*, but
//! not a position in any absolute sense, and there is no way to zero it.
//!
//! Turning that into the thing programs actually want — where the shaft is
//! relative to wherever it was when I started looking — is this module's job, and
//! [`EncoderTracker`] is where it happens.

use crate::hals::soc::RotaryEncoder;

/// How many values the hardware counter takes before wrapping, from the generated
/// PAC so that it tracks the `Index n` on the Clash side.
const MODULUS: i32 = RotaryEncoder::POSITION_SIZE as i32;

/// The largest movement between two polls that can still be told apart from the
/// same movement the other way round: past this, "forwards by a lot" and
/// "backwards by a little" are the same reading. See [`EncoderTracker::poll`].
pub const MAX_EDGES_PER_POLL: i32 = MODULUS / 2;

impl RotaryEncoder {
    /// The raw hardware counter, in `0..`[`RotaryEncoder::POSITION_SIZE`].
    ///
    /// Only meaningful compared against another reading of it, which is what
    /// [`EncoderTracker`] does. Exposed for bring-up: it is the shortest path from
    /// "I turned the knob" to "did the fabric see anything at all?".
    pub fn raw_position(&self) -> u8 {
        // `Index<N, u8>` is a `#[repr(transparent)]` wrapper; `into_inner` is the
        // documented way back to the primitive.
        self.position().into_inner()
    }

    /// Whether the push button in the shaft is currently held down.
    pub fn pressed(&self) -> bool {
        self.button()
    }

    /// Whether the slide switch is in the on position.
    pub fn switched_on(&self) -> bool {
        self.switch()
    }

    /// Start tracking from wherever the shaft is right now, which becomes
    /// position zero.
    pub fn tracker(&self) -> EncoderTracker {
        EncoderTracker {
            last_raw: self.raw_position(),
            position: 0,
            pressed: self.pressed(),
            switch: self.switched_on(),
        }
    }
}

/// Where the encoder is relative to where it was when tracking started.
///
/// The peripheral reports what *is* true, not what *changed* — it has no idea who
/// is reading it or how often — and its counter wraps every
/// [`RotaryEncoder::POSITION_SIZE`] edges, so it cannot be read as a position on
/// its own. This keeps the two things the hardware cannot: the previous reading,
/// and a running total wide enough to be useful.
///
/// Keeping it here rather than in the fabric is deliberate. A counter with a
/// reset line is a counter that belongs to whoever resets it, and two parts of a
/// program that both want their own origin would fight over it. In software each
/// of them just makes its own tracker.
pub struct EncoderTracker {
    /// The hardware counter as of the previous [`Self::poll`].
    last_raw: u8,
    /// Edges accumulated since the origin, unwrapped.
    position: i32,
    pressed: bool,
    switch: bool,
}

/// What changed between two [`EncoderTracker::poll`] calls.
#[derive(Clone, Copy, PartialEq, Eq)]
pub struct EncoderChange {
    /// Edges moved since the previous poll: positive clockwise, negative
    /// anticlockwise, zero if the shaft did not move.
    pub turned: i32,
    /// Where the shaft is now, relative to the tracker's origin.
    pub position: i32,
    /// The button went from released to held.
    pub pressed: bool,
    /// The button went from held to released.
    pub released: bool,
    /// The slide switch changed position; its new value is [`Self::switch`].
    pub toggled: bool,
    /// Where the slide switch is now.
    pub switch: bool,
}

impl EncoderChange {
    /// Whether anything at all happened, so a caller can skip reporting.
    pub fn is_any(&self) -> bool {
        self.turned != 0 || self.pressed || self.released || self.toggled
    }
}

impl EncoderTracker {
    /// Read the encoder and report what changed since the previous call.
    ///
    /// Movement is worked out as the shorter way round the hardware counter, so a
    /// counter that wrapped between two polls still yields a small delta rather
    /// than a jump of nearly a whole revolution. That only holds while the shaft
    /// moves less than [`MAX_EDGES_PER_POLL`] edges between polls; turn faster than
    /// that (or poll rarely enough) and the movement is indistinguishable from a
    /// smaller one the other way. A poll loop that does nothing but print has
    /// several orders of magnitude of headroom over a hand, but a program that
    /// goes away and does something slow in between should keep this in mind.
    ///
    /// A movement of exactly [`MAX_EDGES_PER_POLL`] is the tie: it is reported as
    /// clockwise.
    pub fn poll(&mut self, enc: &RotaryEncoder) -> EncoderChange {
        let raw = enc.raw_position();
        let pressed_now = enc.pressed();
        let switch_now = enc.switched_on();

        // Distance forwards from the old reading to the new one, in `0..MODULUS`;
        // more than half way round is really the short way backwards.
        let forwards = (raw as i32 + MODULUS - self.last_raw as i32) % MODULUS;
        let turned = if forwards > MAX_EDGES_PER_POLL {
            forwards - MODULUS
        } else {
            forwards
        };

        // Saturating rather than wrapping: a total that has run out of `i32` is
        // already meaningless, and pinning it at the end at least keeps the sign
        // and the ordering right.
        self.position = self.position.saturating_add(turned);

        let change = EncoderChange {
            turned,
            position: self.position,
            pressed: pressed_now && !self.pressed,
            released: !pressed_now && self.pressed,
            toggled: switch_now != self.switch,
            switch: switch_now,
        };

        self.last_raw = raw;
        self.pressed = pressed_now;
        self.switch = switch_now;

        change
    }

    /// Where the shaft is now, relative to the origin, without re-reading the
    /// hardware. Only as fresh as the last [`Self::poll`].
    pub fn position(&self) -> i32 {
        self.position
    }

    /// Whether the button was held at the last [`Self::poll`].
    pub fn pressed(&self) -> bool {
        self.pressed
    }

    /// Where the slide switch was at the last [`Self::poll`].
    pub fn switched_on(&self) -> bool {
        self.switch
    }

    /// Make wherever the shaft is now the new origin, so [`Self::position`] starts
    /// again from zero.
    ///
    /// Does not touch the hardware, and so cannot lose movement: the next
    /// [`Self::poll`] still measures from the same counter reading it would have.
    pub fn zero(&mut self) {
        self.position = 0;
    }
}
