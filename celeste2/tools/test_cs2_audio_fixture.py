"""不依赖原作仓库的小样本，锁定 PICO SFX Instrument 到 FC-16 的编码规则。"""

import unittest

import cs2_convert as cv


class CelesteAudioFixtureTest(unittest.TestCase):
    def test_two_layer_pitch_and_volume_source_mapping(self):
        notes = [(12, 8, 7, 1)] + [(0, 0, 0, 0)] * 31
        sfx = {"speed": 11, "loop_start": 0, "loop_end": 0,
               "filters": (0, 0, 0, 0, 0), "notes": notes}
        outer = cv.encode_sfx(sfx)
        self.assertEqual(tuple(outer[:6]), (22, 0, 32, 0, 0, 0))
        self.assertEqual(tuple(outer[16:20]), (36, 16, 15, 1))

        instrument = {**sfx, "notes": [(24, 7, 7, 3)] + notes[1:]}
        inner = cv.encode_sfx(instrument, instrument=True)
        self.assertEqual(tuple(inner[16:20]), (24, 7, 15, 3))
        final_pitch = outer[16] + inner[16] - 24
        self.assertEqual(final_pitch, 36)
        # PICO 原 note 12 是 C1；FC note 36 对应 MIDI 48，频率保持约 130.81Hz。
        self.assertAlmostEqual(440 * 2 ** ((final_pitch + 12 - 69) / 12),
                               130.81278265, places=7)
        self.assertEqual((outer[18] * inner[18], 15 * 15), (225, 225))

    def test_exclusive_end_32_and_pico_length_encoding(self):
        notes = [(0, 0, 0, 0)] * 32
        sfx = {"speed": 130, "loop_start": 0, "loop_end": 32,
               "filters": (1, 0, 2, 1, 2), "notes": notes}
        encoded = cv.encode_sfx(sfx)
        self.assertEqual(tuple(encoded[:11]), (4, 1, 32, 0, 31, 1, 1, 0, 2, 1, 2))
        self.assertEqual(encoded[16:], bytes([24, 0, 0, 0]) * 32)

        # PICO 以 START>0/END=0 表示短 SFX；尾部静音不改变普通 32 步长度。
        short = cv.encode_sfx({**sfx, "loop_start": 5, "loop_end": 0})
        self.assertEqual(tuple(short[:6]), (4, 1, 5, 0, 0, 0))
        normal = cv.encode_sfx({**sfx, "loop_start": 0, "loop_end": 0})
        self.assertEqual(normal[2], 32)

        one_step = cv.encode_sfx({**sfx, "loop_start": 6, "loop_end": 7})
        self.assertEqual(tuple(one_step[3:6]), (6, 6, 1))


if __name__ == "__main__":
    unittest.main()
