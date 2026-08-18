# Reference documents

## MASCHINE_MK1_1x_Manual_English.pdf

Maschine **1.5** Reference Manual (document 1.1, 03/2010). This is the one that
matches the hardware: the rig has a **1st-generation MK1 panel**, and NI revised
the controller's printed labels for Maschine 2.0. The 2.x manuals document the
SECOND-generation labels and were downloaded first by mistake - they describe
buttons this panel does not have under those names, which is exactly the kind of
mismatch that produced a `"restart"` binding the decoder could never send.

`mk1-manual.txt` is `pdftotext` output, for grepping.

Three names to keep straight, because all three appear in this project:

| printed on the panel | cabl enum / decoder | control_map key |
|----------------------|---------------------|-----------------|
| RESTART              | `loop`              | `loop`          |
| PAD MODE (2nd gen)   | `keyboard`          | `pad_mode`      |
| GRID                 | `grid`              | `grid`          |

Source: https://www.strumentimusicali.net/manuali/NATIVEINSTRUMENTS_MASCHINE_ENG.pdf
