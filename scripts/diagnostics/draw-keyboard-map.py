#!/usr/bin/env python3
"""Draw the MPC2000XL desktop keyboard map from MAME's resolved driver.

The default source is the stack-applied .cache/mame driver, rather than the
individual patch files.  That file is the single resolved source MAME builds,
so later patches and multi-line input declarations cannot be misrepresented.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import os
from pathlib import Path
import re
import sys
import textwrap

from PIL import Image, ImageDraw, ImageFont


ROOT = Path(__file__).resolve().parents[2]
DEFAULT_SOURCE = ROOT / ".cache/mame/src/mame/akai/mpc2000.cpp"
DEFAULT_PLUGIN_SOURCE = ROOT / "scripts/mame-plugins/mpcpi_settings/init.lua"
DEFAULT_OUTPUT = ROOT / "docs/keyboard-map.png"

WIDTH = 1490
HEIGHT = 1405
UNIT = 86
GAP = 8
KEY_HEIGHT = 82

BACKGROUND = "#11151c"
PANEL = "#181e28"
UNBOUND = "#292f3a"
UNBOUND_EDGE = "#3b4350"
BOUND = "#126e75"
BOUND_EDGE = "#35b7be"
PAD = "#7040a5"
PAD_EDGE = "#c18bff"
PLUGIN = "#8a541f"
PLUGIN_EDGE = "#f0a85b"
TEXT = "#f5f7fa"
MUTED = "#8f99a8"
ACCENT = "#efbd53"


@dataclass(frozen=True)
class Key:
    code: str
    cap: str
    x: int
    y: int
    width: int = UNIT
    height: int = KEY_HEIGHT


PAD_NUMBERS = {
    "KEYCODE_0_PAD": 1,
    "KEYCODE_1_PAD": 2,
    "KEYCODE_2_PAD": 3,
    "KEYCODE_3_PAD": 4,
    "KEYCODE_4_PAD": 5,
    "KEYCODE_5_PAD": 6,
    "KEYCODE_6_PAD": 7,
    "KEYCODE_PLUS_PAD": 8,
    "KEYCODE_PGDN": 9,
    "KEYCODE_7_PAD": 10,
    "KEYCODE_8_PAD": 11,
    "KEYCODE_9_PAD": 12,
    "KEYCODE_PGUP": 13,
    "KEYCODE_NUMLOCK": 14,
    "KEYCODE_SLASH_PAD": 15,
    "KEYCODE_ASTERISK": 16,
}


def font(size: int, bold: bool = False) -> ImageFont.FreeTypeFont:
    family = "DejaVuSans-Bold.ttf" if bold else "DejaVuSans.ttf"
    try:
        return ImageFont.truetype(family, size)
    except OSError as exc:
        raise SystemExit(f"error: required font {family!r} is unavailable: {exc}")


def parse_bindings(source: Path) -> tuple[dict[str, str], bool, bool, bool]:
    try:
        text = source.read_text(encoding="utf-8")
    except OSError as exc:
        raise SystemExit(f"error: cannot read stack-applied driver {source}: {exc}")

    if (
        not re.search(r"INPUT_PORTS_START\(\s*mpc2000\s*\)", text)
        or not re.search(r"ROM_START\(\s*mpc2000xl\s*\)", text)
    ):
        raise SystemExit(f"error: {source} does not contain the MPC2000XL input ports")

    statement_re = re.compile(
        r"^[ \t]*PORT_BIT\(.*?"
        r"(?=^[ \t]*(?:PORT_BIT\(|PORT_START\(|PORT_ADJUSTER\(|INPUT_PORTS_END\b)|\Z)",
        re.MULTILINE | re.DOTALL,
    )
    name_re = re.compile(r'PORT_NAME\("((?:[^"\\]|\\.)*)"\)')
    code_re = re.compile(
        r"PORT_CODE(?P<kind>_DEC|_INC)?\((?P<code>KEYCODE_[A-Z0-9_]+)\)"
    )

    found: dict[str, list[str]] = {}
    for match in statement_re.finditer(text):
        statement = match.group(0)
        name_match = name_re.search(statement)
        key_matches = list(code_re.finditer(statement))
        if not key_matches:
            continue
        if not name_match:
            codes = ", ".join(item.group("code") for item in key_matches)
            line = text.count("\n", 0, match.start()) + 1
            raise SystemExit(
                f"error: keyboard binding without PORT_NAME at {source}:{line}: {codes}"
            )

        name = bytes(name_match.group(1), "utf-8").decode("unicode_escape")
        for item in key_matches:
            kind = item.group("kind")
            label = name
            if kind == "_DEC":
                label += " -"
            elif kind == "_INC":
                label += " +"
            found.setdefault(item.group("code"), []).append(label)

    collisions = {
        code: labels for code, labels in found.items() if len(set(labels)) != 1 or len(labels) > 1
    }
    if collisions:
        detail = "\n".join(
            f"  {code}: {', '.join(labels)}" for code, labels in sorted(collisions.items())
        )
        raise SystemExit(f"error: keyboard binding collisions in {source}:\n{detail}")

    bindings = {code: labels[0] for code, labels in found.items()}
    wheel_statement = next(
        (item.group(0) for item in statement_re.finditer(text) if 'PORT_NAME("DATA Wheel")' in item.group(0)),
        "",
    )
    drag_enabled = "IPT_DIAL_V" in wheel_statement
    notch_statement = next(
        (item.group(0) for item in statement_re.finditer(text) if 'PORT_NAME("DATA Wheel Notch")' in item.group(0)),
        "",
    )
    drag_statement = next(
        (item.group(0) for item in statement_re.finditer(text) if 'PORT_NAME("DATA Wheel Drag")' in item.group(0)),
        "",
    )
    drag_gated = "MOUSECODE_BUTTON1" in drag_statement
    scroll_enabled = "MOUSECODE_Z" in notch_statement or (
        "MOUSECODE_Z_NEG_SWITCH" in wheel_statement
        and "MOUSECODE_Z_POS_SWITCH" in wheel_statement
    )
    return bindings, drag_enabled, drag_gated, scroll_enabled


def parse_plugin_hotkeys(source: Path) -> list[str]:
    try:
        text = source.read_text(encoding="utf-8")
    except OSError as exc:
        raise SystemExit(f"error: cannot read settings plugin {source}: {exc}")

    fallback_re = re.compile(
        r"env\(\s*(['\"])MPCPI_SETTINGS_HOTKEY\1\s*,\s*"
        r"(['\"])(KEYCODE_[A-Z0-9_]+)\2\s*\)"
    )
    fallbacks = [match.group(3) for match in fallback_re.finditer(text)]
    table = re.search(
        r"local\s+DEFAULT_HOTKEYS\s*=\s*\{(?P<body>.*?)\}", text, re.DOTALL
    )
    if fallbacks and table:
        raise SystemExit(
            f"error: ambiguous Device Settings hotkey defaults in {source}"
        )
    if len(fallbacks) > 1:
        raise SystemExit(
            f"error: expected one MPCPI_SETTINGS_HOTKEY fallback in {source}, "
            f"found {len(fallbacks)}"
        )
    matches = fallbacks
    if table:
        matches = re.findall(
            r"['\"](KEYCODE_[A-Z0-9_]+)['\"]", table.group("body")
        )
    if not matches:
        raise SystemExit(f"error: no Device Settings hotkey defaults found in {source}")
    if len(matches) != len(set(matches)):
        raise SystemExit(f"error: DEFAULT_HOTKEYS in {source} contains duplicates")
    return matches


def key_width(units: float) -> int:
    return round(units * UNIT + (units - 1) * GAP)


def add_row(keys: list[Key], x: int, y: int, specs: list[tuple[str, str, float]]) -> None:
    for code, cap, units in specs:
        width = key_width(units)
        keys.append(Key(code, cap, x, y, width))
        x += width + GAP


def keyboard() -> list[Key]:
    keys: list[Key] = []
    x0 = 42
    function_y = 154
    main_y = 258
    second_y = 820

    add_row(keys, x0, function_y, [("KEYCODE_ESC", "Esc", 1)])
    x = x0 + key_width(1.5)
    for index in range(1, 5):
        keys.append(Key(f"KEYCODE_F{index}", f"F{index}", x, function_y))
        x += UNIT + GAP
    x += key_width(0.35)
    for index in range(5, 9):
        keys.append(Key(f"KEYCODE_F{index}", f"F{index}", x, function_y))
        x += UNIT + GAP
    x += key_width(0.35)
    for index in range(9, 13):
        keys.append(Key(f"KEYCODE_F{index}", f"F{index}", x, function_y))
        x += UNIT + GAP

    nav_x = 42
    num_x = 390
    add_row(
        keys,
        nav_x,
        second_y,
        [
            ("KEYCODE_PRTSCR", "PrtSc", 1),
            ("KEYCODE_SCRLOCK", "Scroll", 1),
            ("KEYCODE_PAUSE", "Pause", 1),
        ],
    )

    rows = [
        [
            ("KEYCODE_TILDE", "`", 1), ("KEYCODE_1", "1", 1),
            ("KEYCODE_2", "2", 1), ("KEYCODE_3", "3", 1),
            ("KEYCODE_4", "4", 1), ("KEYCODE_5", "5", 1),
            ("KEYCODE_6", "6", 1), ("KEYCODE_7", "7", 1),
            ("KEYCODE_8", "8", 1), ("KEYCODE_9", "9", 1),
            ("KEYCODE_0", "0", 1), ("KEYCODE_MINUS", "-", 1),
            ("KEYCODE_EQUALS", "=", 1), ("KEYCODE_BACKSPACE", "Backspace", 2),
        ],
        [
            ("KEYCODE_TAB", "Tab", 1.5), ("KEYCODE_Q", "Q", 1),
            ("KEYCODE_W", "W", 1), ("KEYCODE_E", "E", 1),
            ("KEYCODE_R", "R", 1), ("KEYCODE_T", "T", 1),
            ("KEYCODE_Y", "Y", 1), ("KEYCODE_U", "U", 1),
            ("KEYCODE_I", "I", 1), ("KEYCODE_O", "O", 1),
            ("KEYCODE_P", "P", 1), ("KEYCODE_OPENBRACE", "[", 1),
            ("KEYCODE_CLOSEBRACE", "]", 1), ("KEYCODE_BACKSLASH", "\\", 1.5),
        ],
        [
            ("KEYCODE_CAPSLOCK", "Caps", 1.75), ("KEYCODE_A", "A", 1),
            ("KEYCODE_S", "S", 1), ("KEYCODE_D", "D", 1),
            ("KEYCODE_F", "F", 1), ("KEYCODE_G", "G", 1),
            ("KEYCODE_H", "H", 1), ("KEYCODE_J", "J", 1),
            ("KEYCODE_K", "K", 1), ("KEYCODE_L", "L", 1),
            ("KEYCODE_COLON", ";", 1), ("KEYCODE_QUOTE", "'", 1),
            ("KEYCODE_ENTER", "Enter", 2.25),
        ],
        [
            ("KEYCODE_LSHIFT", "LShift", 2.25), ("KEYCODE_Z", "Z", 1),
            ("KEYCODE_X", "X", 1), ("KEYCODE_C", "C", 1),
            ("KEYCODE_V", "V", 1), ("KEYCODE_B", "B", 1),
            ("KEYCODE_N", "N", 1), ("KEYCODE_M", "M", 1),
            ("KEYCODE_COMMA", ",", 1), ("KEYCODE_STOP", ".", 1),
            ("KEYCODE_SLASH", "/", 1), ("KEYCODE_RSHIFT", "RShift", 2.75),
        ],
        [
            ("KEYCODE_LCONTROL", "LCtrl", 1.25), ("KEYCODE_LWIN", "Win", 1.25),
            ("KEYCODE_LALT", "LAlt", 1.25), ("KEYCODE_SPACE", "Space", 6.25),
            ("KEYCODE_RALT", "RAlt", 1.25), ("KEYCODE_RWIN", "Win", 1.25),
            ("KEYCODE_MENU", "Menu", 1.25), ("KEYCODE_RCONTROL", "RCtrl", 1.25),
        ],
    ]
    for row, specs in enumerate(rows):
        add_row(keys, x0, main_y + row * (KEY_HEIGHT + GAP), specs)

    nav_rows = [
        [("KEYCODE_INSERT", "Insert", 1), ("KEYCODE_HOME", "Home", 1), ("KEYCODE_PGUP", "PgUp", 1)],
        [("KEYCODE_DEL", "Delete", 1), ("KEYCODE_END", "End", 1), ("KEYCODE_PGDN", "PgDn", 1)],
    ]
    for row, specs in enumerate(nav_rows):
        add_row(keys, nav_x, second_y + (row + 1) * (KEY_HEIGHT + GAP), specs)
    arrow_y = second_y + 3 * (KEY_HEIGHT + GAP)
    keys.extend(
        [
            Key("KEYCODE_UP", "Up", nav_x + UNIT + GAP, arrow_y),
            Key("KEYCODE_LEFT", "Left", nav_x, arrow_y + KEY_HEIGHT + GAP),
            Key("KEYCODE_DOWN", "Down", nav_x + UNIT + GAP, arrow_y + KEY_HEIGHT + GAP),
            Key("KEYCODE_RIGHT", "Right", nav_x + 2 * (UNIT + GAP), arrow_y + KEY_HEIGHT + GAP),
        ]
    )

    add_row(
        keys,
        num_x,
        second_y,
        [
            ("KEYCODE_NUMLOCK", "Num", 1), ("KEYCODE_SLASH_PAD", "/", 1),
            ("KEYCODE_ASTERISK", "*", 1), ("KEYCODE_MINUS_PAD", "-", 1),
        ],
    )
    add_row(
        keys,
        num_x,
        second_y + KEY_HEIGHT + GAP,
        [("KEYCODE_7_PAD", "7", 1), ("KEYCODE_8_PAD", "8", 1), ("KEYCODE_9_PAD", "9", 1)],
    )
    keys.append(Key("KEYCODE_PLUS_PAD", "+", num_x + 3 * (UNIT + GAP), second_y + KEY_HEIGHT + GAP, UNIT, 2 * KEY_HEIGHT + GAP))
    add_row(
        keys,
        num_x,
        second_y + 2 * (KEY_HEIGHT + GAP),
        [("KEYCODE_4_PAD", "4", 1), ("KEYCODE_5_PAD", "5", 1), ("KEYCODE_6_PAD", "6", 1)],
    )
    add_row(
        keys,
        num_x,
        second_y + 3 * (KEY_HEIGHT + GAP),
        [("KEYCODE_1_PAD", "1", 1), ("KEYCODE_2_PAD", "2", 1), ("KEYCODE_3_PAD", "3", 1)],
    )
    keys.append(Key("KEYCODE_ENTER_PAD", "Enter", num_x + 3 * (UNIT + GAP), second_y + 3 * (KEY_HEIGHT + GAP), UNIT, 2 * KEY_HEIGHT + GAP))
    keys.append(Key("KEYCODE_0_PAD", "0", num_x, second_y + 4 * (KEY_HEIGHT + GAP), 2 * UNIT + GAP))
    keys.append(Key("KEYCODE_DEL_PAD", ".", num_x + 2 * (UNIT + GAP), second_y + 4 * (KEY_HEIGHT + GAP)))
    return keys


def draw_centered(draw: ImageDraw.ImageDraw, box: tuple[int, int, int, int], value: str,
                  face: ImageFont.FreeTypeFont, fill: str) -> None:
    left, top, right, bottom = draw.multiline_textbbox((0, 0), value, font=face, spacing=2, align="center")
    width = right - left
    height = bottom - top
    x = box[0] + (box[2] - box[0] - width) / 2
    y = box[1] + (box[3] - box[1] - height) / 2 - top
    draw.multiline_text((x, y), value, font=face, fill=fill, spacing=2, align="center")


def wrap_label(value: str, width: int) -> str:
    chars = max(8, width // 10)
    return "\n".join(textwrap.wrap(value, width=chars, break_long_words=False))


def render(bindings: dict[str, str], plugin_controls: dict[str, bool],
           source: Path, output: Path, drag_enabled: bool,
           drag_gated: bool, scroll_enabled: bool) -> None:
    keys = keyboard()
    placeable = {key.code for key in keys}
    missing = sorted((set(bindings) | set(plugin_controls)) - placeable)
    if missing:
        detail = "\n".join(
            f"  {code}: {bindings.get(code, 'Device Settings')}" for code in missing
        )
        raise SystemExit(f"error: unplaceable keyboard-map keycodes:\n{detail}")

    image = Image.new("RGB", (WIDTH, HEIGHT), BACKGROUND)
    draw = ImageDraw.Draw(image)
    draw.rounded_rectangle((22, 104, WIDTH - 22, 720), radius=24, fill=PANEL)
    draw.rounded_rectangle((22, 744, WIDTH - 22, 1324), radius=24, fill=PANEL)
    draw.text((42, 24), "MPC2000XL desktop keyboard map", font=font(38, True), fill=TEXT)
    draw.text((42, 69), "Bindings parsed from the stack-applied MAME driver and settings plugin", font=font(19), fill=MUTED)
    draw.text((42, 116), "BAND 1  ·  MAIN ANSI BLOCK", font=font(18, True), fill=ACCENT)
    draw.text((42, 762), "BAND 2  ·  NAVIGATION, ARROWS AND NUMPAD PAD GRID", font=font(18, True), fill=ACCENT)

    for key in keys:
        bound = bindings.get(key.code)
        plugin_control = key.code in plugin_controls
        local_override = plugin_controls.get(key.code, False)
        pad_number = PAD_NUMBERS.get(key.code) if bound else None
        if plugin_control:
            fill, edge = PLUGIN, PLUGIN_EDGE
        elif pad_number:
            fill, edge = PAD, PAD_EDGE
        elif bound:
            fill, edge = BOUND, BOUND_EDGE
        else:
            fill, edge = UNBOUND, UNBOUND_EDGE
        box = (key.x, key.y, key.x + key.width, key.y + key.height)
        draw.rounded_rectangle(box, radius=9, fill=fill, outline=edge, width=2)
        draw.text((key.x + 8, key.y + 6), key.cap, font=font(15, True), fill=TEXT if bound or plugin_control else MUTED)
        if plugin_control:
            label_bottom = key.y + key.height - (22 if local_override else 5)
            label_box = (key.x + 5, key.y + 23, key.x + key.width - 5, label_bottom)
            draw_centered(draw, label_box, wrap_label("Device Settings", key.width), font(13, True), TEXT)
            if local_override:
                badge = (key.x + 5, key.y + key.height - 20, key.x + key.width - 5, key.y + key.height - 4)
                draw.rounded_rectangle(badge, radius=5, fill=ACCENT)
                draw_centered(draw, badge, "LOCAL OVERRIDE", font(8, True), BACKGROUND)
        elif bound:
            label_box = (key.x + 5, key.y + 23, key.x + key.width - 5, key.y + key.height - 5)
            draw_centered(draw, label_box, wrap_label(bound, key.width), font(13, True), TEXT)
        if pad_number:
            badge = (key.x + key.width - 33, key.y + 5, key.x + key.width - 5, key.y + 29)
            draw.rounded_rectangle(badge, radius=7, fill=ACCENT)
            draw_centered(draw, badge, str(pad_number), font(13, True), BACKGROUND)

    info_x = 820
    draw.text((info_x, 814), "Legend", font=font(26, True), fill=TEXT)
    legend_y = 858
    for colour, edge, label in [
        (BOUND, BOUND_EDGE, "MPC panel control"),
        (PAD, PAD_EDGE, "MPC pad (badge is pad number)"),
        (PLUGIN, PLUGIN_EDGE, "Device Settings plugin control"),
        (UNBOUND, UNBOUND_EDGE, "Unbound key"),
    ]:
        draw.rounded_rectangle((info_x, legend_y, info_x + 42, legend_y + 32), radius=6, fill=colour, outline=edge, width=2)
        draw.text((info_x + 56, legend_y + 4), label, font=font(18), fill=TEXT)
        legend_y += 48

    notes = ["LShift = MPC Shift", "DATA wheel keys: - decreases; = increases"]
    if drag_enabled:
        if drag_gated:
            notes.append("DATA wheel drag: hold left button and move vertically")
        else:
            notes.append("DATA wheel: drag vertically with the mouse")
    if scroll_enabled:
        notes.append("DATA wheel: scroll down/up decreases/increases")
    notes.append(
        "MPCPI_SETTINGS_HOTKEY in ~/.config/mpcpi/settings.env replaces all three defaults; "
        "the on-screen strip and MAME's Plugin Options menu remain available"
    )
    note_x = info_x
    draw.text((note_x, 1050), "Mouse and modifiers", font=font(26, True), fill=TEXT)
    for index, note in enumerate(notes):
        wrapped = textwrap.wrap(note, width=67, break_long_words=False)
        value = "•  " + "\n   ".join(wrapped)
        draw.multiline_text((note_x, 1092 + index * 36), value, font=font(17), fill=TEXT, spacing=3)

    try:
        source_display = source.resolve().relative_to(ROOT.resolve())
    except ValueError:
        source_display = source.resolve()
    draw.text(
        (42, HEIGHT - 38),
        f"Generator source: {source_display}",
        font=font(16),
        fill=MUTED,
    )

    output.parent.mkdir(parents=True, exist_ok=True)
    image.save(output, format="PNG", optimize=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=DEFAULT_SOURCE)
    parser.add_argument("--plugin-source", type=Path, default=DEFAULT_PLUGIN_SOURCE)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()

    bindings, drag_enabled, drag_gated, scroll_enabled = parse_bindings(args.source)
    default_hotkeys = parse_plugin_hotkeys(args.plugin_source)
    plugin_controls = {hotkey: False for hotkey in default_hotkeys}
    local_override = os.environ.get("MPCPI_SETTINGS_HOTKEY")
    if local_override:
        if not re.fullmatch(r"KEYCODE_[A-Z0-9_]+", local_override):
            raise SystemExit(
                "error: MPCPI_SETTINGS_HOTKEY must be one KEYCODE_* token to render "
                f"a local override, got {local_override!r}"
            )
        plugin_controls = {local_override: True}
    render(
        bindings, plugin_controls, args.source, args.output,
        drag_enabled, drag_gated, scroll_enabled,
    )
    print(f"Rendered {len(bindings)} collision-free driver bindings from {args.source}")
    print(
        f"Rendered Device Settings plugin controls from {args.plugin_source}: "
        f"{', '.join(default_hotkeys)}"
    )
    if local_override:
        print(f"Rendered local Device Settings override: {local_override}")
    print(args.output)
    return 0


if __name__ == "__main__":
    sys.exit(main())
