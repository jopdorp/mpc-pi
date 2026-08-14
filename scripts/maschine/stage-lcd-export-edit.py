#!/usr/bin/env python3
# Staged edit for the LCD frame export (future patch 0039). Run from
# .cache/mame with the full patch stack applied; then rebuild and gate.
#
# Adds MAME_MPC_LCD_EXPORT=<path>: whenever screen_update sees a changed
# frame, the 248x60 monochrome frame is written to <path> as a 16-byte
# header (magic 'MPCL', u32 sequence, u16 width, u16 height, u32 reserved)
# plus one byte per pixel. Consumed by scripts/maschine/mpc-mk1-display.py.
import sys

p = 'src/mame/akai/mpc2000.cpp'
s = open(p).read()

anchor = "	bool const changed = !m_lcd_skip_unchanged || m_lcd_dirty;"
assert s.count(anchor) == 1, "0033 hook not found; apply the patch stack first"

s = s.replace(anchor, anchor + """
	if (changed && m_lcd_export_file)
	{
		// 16-byte header + one byte per pixel; rewritten in place so the
		// consumer sees a consistent snapshot keyed by the sequence number.
		uint8_t frame[16 + 248 * 60];
		frame[0] = 'M'; frame[1] = 'P'; frame[2] = 'C'; frame[3] = 'L';
		m_lcd_export_seq++;
		frame[4] = uint8_t(m_lcd_export_seq);
		frame[5] = uint8_t(m_lcd_export_seq >> 8);
		frame[6] = uint8_t(m_lcd_export_seq >> 16);
		frame[7] = uint8_t(m_lcd_export_seq >> 24);
		frame[8] = 248; frame[9] = 0;
		frame[10] = 60; frame[11] = 0;
		frame[12] = frame[13] = frame[14] = frame[15] = 0;
		for (int y = 0; y < 60; y++)
			for (int x = 0; x < 248; x++)
				frame[16 + y * 248 + x] = m_vram[(y * 256) + x] ? 1 : 0;
		fseek(m_lcd_export_file, 0, SEEK_SET);
		fwrite(frame, 1, sizeof(frame), m_lcd_export_file);
		fflush(m_lcd_export_file);
	}""", 1)

decl_anchor = "	bool m_lcd_dirty;"
assert s.count(decl_anchor) == 1
s = s.replace(decl_anchor, decl_anchor + """
	FILE *m_lcd_export_file = nullptr;
	uint32_t m_lcd_export_seq = 0;""", 1)

init_anchor = "	m_lcd_skip_unchanged = lcd_skip_unchanged && std::strcmp(lcd_skip_unchanged, \"0\");"
assert s.count(init_anchor) == 1
s = s.replace(init_anchor, init_anchor + """
	if (char const *const lcd_export = osd_getenv("MAME_MPC_LCD_EXPORT"))
		m_lcd_export_file = fopen(lcd_export, "wb");""", 1)

open(p, 'w').write(s)
print("LCD export edit applied; rebuild and run the PCM + pixel gates")
