#!/usr/bin/env python3
"""Behavioral regression for the registered PPS-counter TDD window.

The RTL pipelines boundary-minus-two equality events to avoid a combinational
32-bit range comparison at the 245.76 MHz LibreSDR interface clock. This model
proves that the registered implementation retains the documented half-open
[start, stop) behavior for every valid window in representative frame sizes.
"""
import unittest


def expected(position: int, start: int, stop: int) -> bool:
    return stop != 0 and start <= position < stop


def initial(frame_len: int, start: int, stop: int) -> tuple[int, bool, bool, bool, bool]:
    return (
        0,
        expected(0, start, stop),
        frame_len == 1,
        start == 1,
        stop == 1,
    )

def advance(state: tuple[int, bool, bool, bool, bool], frame_len: int,
            start: int, stop: int,
            pps_reset: bool = False) -> tuple[int, bool, bool, bool, bool]:
    position, active, wrap_event, start_event, stop_event = state
    if pps_reset or wrap_event:
        return initial(frame_len, start, stop)

    old_position = position
    position += 1
    if start_event:
        active = stop != 0
    if stop_event:
        active = False
    wrap_event = old_position == ((frame_len - 2) & 0xFFFFFFFF)
    start_event = old_position == ((start - 2) & 0xFFFFFFFF)
    stop_event = old_position == ((stop - 2) & 0xFFFFFFFF)
    return position, active, wrap_event, start_event, stop_event


class RegisteredWindowTest(unittest.TestCase):
    def check_window(self, frame_len: int, start: int, stop: int) -> None:
        state = initial(frame_len, start, stop)
        for _ in range(frame_len * 3):
            position, active, _, _, _ = state
            self.assertEqual(
                active,
                expected(position, start, stop),
                (frame_len, start, stop, position),
            )
            state = advance(state, frame_len, start, stop)

        # A PPS re-anchor must immediately restore the frame-zero state.
        state = advance(state, frame_len, start, stop, pps_reset=True)
        position, active, _, _, _ = state
        self.assertEqual(position, 0)
        self.assertEqual(active, expected(0, start, stop))

    def test_all_valid_windows(self) -> None:
        for frame_len in (1, 2, 3, 8, 17, 100):
            self.check_window(frame_len, 0, 0)  # disabled
            for start in range(frame_len):
                for stop in range(start + 1, frame_len + 1):
                    self.check_window(frame_len, start, stop)


if __name__ == "__main__":
    unittest.main()
