// Windows key classification, separate from the native hook so full physical
// key sequences can be tested without injecting keys into another application.
use super::{logic::FlowKey, KeyEvent};

const SHIFT: u8 = 1;
const WIN: u8 = 2;
const CTRL: u8 = 4;
const ALT: u8 = 8;
const F23: u32 = 0x86;

pub struct Keys {
    key: FlowKey,
    modifiers: u16,
    held: bool,
}

impl Keys {
    pub fn new(key: FlowKey) -> Self {
        Self {
            key,
            modifiers: 0,
            held: false,
        }
    }

    /// Returns the Flow event and whether Windows should consume this key.
    /// Only an explicitly selected Copilot chord is consumed; ordinary
    /// modifiers and other applications' shortcuts retain their behavior.
    pub fn event(
        &mut self,
        vk: u32,
        scan: u32,
        extended: bool,
        down: bool,
        injected: bool,
    ) -> (Option<KeyEvent>, bool) {
        if injected {
            return (None, false);
        }
        let vk = match vk {
            0x10 => {
                if scan == 0x36 {
                    0xA1
                } else {
                    0xA0
                }
            }
            0x11 => {
                if extended {
                    0xA3
                } else {
                    0xA2
                }
            }
            0x12 => {
                if extended {
                    0xA5
                } else {
                    0xA4
                }
            }
            _ => vk,
        };
        let bit = match vk {
            0xA0..=0xA5 => 1 << (vk - 0xA0),
            0x5B => 1 << 6,
            0x5C => 1 << 7,
            _ => 0,
        };
        if down {
            self.modifiers |= bit;
        } else {
            self.modifiers &= !bit;
        }
        let mods = (if self.modifiers & 3 != 0 { SHIFT } else { 0 })
            | (if self.modifiers & 12 != 0 { CTRL } else { 0 })
            | (if self.modifiers & 48 != 0 { ALT } else { 0 })
            | (if self.modifiers & 192 != 0 { WIN } else { 0 });
        let ours = match self.key {
            FlowKey::RightCtrl => vk == 0xA3,
            FlowKey::RightAlt => vk == 0xA5,
            FlowKey::RightShift => vk == 0xA1,
            FlowKey::LeftCtrlSuper => {
                if matches!(vk, 0xA2 | 0x5B) {
                    let held = self.modifiers & ((1 << 2) | (1 << 6)) == (1 << 2) | (1 << 6);
                    let event = if held && down {
                        Some(KeyEvent::Down)
                    } else if self.held && !held {
                        Some(KeyEvent::Up)
                    } else {
                        None
                    };
                    self.held = held;
                    return (event, false);
                }
                false
            }
            // Copilot hardware emits Win + Shift + F23. Accept its release
            // even if the firmware releases the modifiers first.
            FlowKey::Copilot => vk == F23 && (self.held || (down && mods == SHIFT | WIN)),
        };
        if ours {
            self.held = down;
            return (
                Some(if down { KeyEvent::Down } else { KeyEvent::Up }),
                self.key == FlowKey::Copilot,
            );
        }
        if down && vk == 0x1B {
            return (Some(KeyEvent::Escape), false);
        }
        if down && bit == 0 && vk != 0x14 {
            return (Some(KeyEvent::Other), false);
        }
        (None, false)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn key(keys: &mut Keys, vk: u32, down: bool) -> (Option<KeyEvent>, bool) {
        keys.event(vk, 0, false, down, false)
    }

    #[test]
    fn copilot_hold_repeat_and_release_in_either_firmware_order() {
        for modifiers_first in [false, true] {
            let mut keys = Keys::new(FlowKey::Copilot);
            assert_eq!(key(&mut keys, 0x5B, true), (None, false));
            assert_eq!(key(&mut keys, 0xA0, true), (None, false));
            assert_eq!(key(&mut keys, F23, true), (Some(KeyEvent::Down), true));
            assert_eq!(key(&mut keys, F23, true), (Some(KeyEvent::Down), true));
            if modifiers_first {
                key(&mut keys, 0x5B, false);
                key(&mut keys, 0xA0, false);
            }
            assert_eq!(key(&mut keys, F23, false), (Some(KeyEvent::Up), true));
            assert_eq!(key(&mut keys, F23, false), (None, false));
        }
    }

    #[test]
    fn unrelated_f23_shortcuts_and_injected_keys_are_not_claimed() {
        let mut keys = Keys::new(FlowKey::Copilot);
        assert_eq!(key(&mut keys, F23, true), (Some(KeyEvent::Other), false));
        key(&mut keys, 0x5B, true);
        key(&mut keys, 0xA0, true);
        assert_eq!(keys.event(F23, 0, false, true, true), (None, false));
        key(&mut keys, 0xA2, true);
        assert_eq!(key(&mut keys, F23, true), (Some(KeyEvent::Other), false));
        let mut ordinary = Keys::new(FlowKey::RightCtrl);
        key(&mut ordinary, 0x5B, true);
        key(&mut ordinary, 0xA0, true);
        assert_eq!(
            key(&mut ordinary, F23, true),
            (Some(KeyEvent::Other), false)
        );
    }

    #[test]
    fn side_specific_and_generic_right_modifiers_work_without_swallowing() {
        for (choice, vk, generic, scan, extended) in [
            (FlowKey::RightCtrl, 0xA3, 0x11, 0x1D, true),
            (FlowKey::RightAlt, 0xA5, 0x12, 0x38, true),
            (FlowKey::RightShift, 0xA1, 0x10, 0x36, false),
        ] {
            let mut keys = Keys::new(choice);
            assert_eq!(key(&mut keys, vk, true), (Some(KeyEvent::Down), false));
            assert_eq!(key(&mut keys, vk, false), (Some(KeyEvent::Up), false));
            assert_eq!(
                keys.event(generic, scan, extended, true, false),
                (Some(KeyEvent::Down), false)
            );
            assert_eq!(
                keys.event(generic, scan, extended, false, false),
                (Some(KeyEvent::Up), false)
            );
        }
    }

    #[test]
    fn ctrl_win_accepts_both_orders_and_cancels_for_other_keys() {
        for first in [0xA2, 0x5B] {
            let second = if first == 0xA2 { 0x5B } else { 0xA2 };
            let mut keys = Keys::new(FlowKey::LeftCtrlSuper);
            assert_eq!(key(&mut keys, first, true), (None, false));
            assert_eq!(key(&mut keys, second, true), (Some(KeyEvent::Down), false));
            assert_eq!(key(&mut keys, 0x41, true), (Some(KeyEvent::Other), false));
            assert_eq!(key(&mut keys, 0x1B, true), (Some(KeyEvent::Escape), false));
            assert_eq!(key(&mut keys, first, false), (Some(KeyEvent::Up), false));
            assert_eq!(key(&mut keys, second, false), (None, false));
        }
    }
}
