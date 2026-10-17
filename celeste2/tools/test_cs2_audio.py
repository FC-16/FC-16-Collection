"""逐字段核对 Celeste 2 原卡带音频与 FC-16 可重复转换结果。

运行：python3 -m unittest discover -s celeste2/tools -p 'test_cs2_audio.py'
需要并列的 ../Celeste2 原始 .p8 文件。
"""

import unittest

import cs2_convert as cv


class CelesteAudioConversionTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.cart = cv.load_sections(cv.SRC / "celeste2.p8")
        cls.source_sfx = cv.parse_sfx(cls.cart)
        cls.source_music = cv.parse_music(cls.cart)
        cls.sfx, cls.waves, cls.instruments, cls.music, _ = cv.build_audio(cls.cart)

    def test_original_p8_audio_sections_match_all_level_carts(self):
        for index in range(1, 9):
            level = cv.load_sections(cv.SRC / f"{index}.p8")
            for section in ("sfx", "music"):
                self.assertEqual(level[section], self.cart[section], (index, section))

    def test_every_original_note_filter_loop_and_speed_survives(self):
        self.assertEqual(len(self.sfx), 128 * 144)
        self.assertEqual(len(self.instruments), 16 * 144)
        self.assertEqual(self.waves, bytes(8 * 80))
        for source_id in (51, 53):
            slot = self.sfx[source_id * 144:(source_id + 1) * 144]
            self.assertEqual(tuple(slot[2:6]), (32, 0, 31, 1), source_id)
        for source_id, source in enumerate(self.source_sfx):
            slot = self.sfx[source_id * 144:(source_id + 1) * 144]
            self.assertEqual(int.from_bytes(slot[0:2], "little"),
                             2 * source["speed"], source_id)
            self.assertEqual(slot[2], cv.sfx_length(source), source_id)
            looping = source["loop_end"] > source["loop_start"]
            self.assertEqual((slot[3], slot[4], slot[5]),
                             (source["loop_start"], source["loop_end"] - 1, 1)
                             if looping else (0, 0, 0), source_id)
            self.assertEqual(tuple(slot[6:11]), source["filters"], source_id)
            self.assertEqual(slot[11:16], bytes(5), source_id)
            for step, (pitch, waveform, volume, effect) in enumerate(source["notes"]):
                offset = 16 + step * 4
                self.assertEqual(tuple(slot[offset:offset + 4]),
                                 (pitch + 24, waveform if waveform < 8 else waveform + 8,
                                  (15 * volume + 3) // 7, effect), (source_id, step))

        # PICO SFX 0–7 是有时间线的 Instrument；其音高相对于 C2，不加外层的 +24。
        for source_id in range(8):
            outer = self.sfx[source_id * 144:(source_id + 1) * 144]
            inner = self.instruments[source_id * 144:(source_id + 1) * 144]
            self.assertEqual(inner[:16], outer[:16], source_id)
            for step, (pitch, waveform, volume, effect) in enumerate(
                    self.source_sfx[source_id]["notes"]):
                offset = 16 + step * 4
                self.assertEqual(tuple(inner[offset:offset + 4]),
                                 (pitch, waveform, (15 * volume + 3) // 7, effect),
                                 (source_id, step))

        # 第 64 号是 Row 38 的公开静音时长资源，不改动原始 0–63 号声音。
        timer = self.sfx[64 * 144:65 * 144]
        self.assertEqual(tuple(timer[:6]), (4, 1, 32, 0, 0, 0))
        self.assertEqual(timer[6:], bytes(138))
        self.assertEqual(self.sfx[65 * 144:], bytes(63 * 144))
        self.assertEqual(self.instruments[8 * 144:], bytes(8 * 144))

    def test_music_channels_flags_and_row_duration(self):
        self.assertEqual(len(self.music), 32 + 64 * 32)
        self.assertEqual(self.music[0], 42)
        self.assertEqual(self.music[1:32], bytes(31))
        expected_duration = [704] * 36 + [8320, 8320, 8320, 704, 896, 1024]
        for row_id, row in enumerate(self.source_music):
            data = self.music[32 + row_id * 32:32 + (row_id + 1) * 32]
            channels = [0xff if ref is None else ref for ref in row["chans"]]
            if row_id == 38:
                self.assertIsNone(cv.music_duration(self.source_sfx, row["chans"])[0])
                self.assertIsNone(row["chans"][0])
                channels[0] = 64
            self.assertEqual(list(data[:8]), channels + [0xff] * 4, row_id)
            self.assertEqual(data[8:16], bytes(8), row_id)
            self.assertEqual(tuple(data[16:19]),
                             tuple((row["flags"] >> bit) & 1 for bit in range(3)), row_id)
            self.assertEqual(data[19:], bytes(13), row_id)
            durations = []
            for ref in data[:8]:
                if ref == 0xff:
                    continue
                sfx_head = self.sfx[ref * 144:ref * 144 + 16]
                if sfx_head[5] == 0:
                    durations.append(int.from_bytes(sfx_head[:2], "little") * sfx_head[2])
            self.assertEqual(max(durations), expected_duration[row_id], row_id)
        for row_id in range(42, 64):
            data = self.music[32 + row_id * 32:32 + (row_id + 1) * 32]
            self.assertEqual(data, bytes([0xff] * 8 + [0] * 24), row_id)

    def test_generated_files_match_converter(self):
        for name, expected in (("sfx", self.sfx), ("waveforms", self.waves),
                               ("instruments", self.instruments), ("music", self.music)):
            self.assertEqual((cv.BUILD / f"{name}.bin").read_bytes(), expected, name)


if __name__ == "__main__":
    unittest.main()
