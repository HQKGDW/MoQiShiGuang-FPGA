# Project Architecture

The source tree separates modules by responsibility while preserving the
verified module interfaces and HDL contents from the 1280x720 design.

| Layer | Directory | Main responsibilities |
| --- | --- | --- |
| Application | `rtl/application` | Image selection, automatic playback, and status display |
| Audio | `rtl/audio` | Image-linked PCM tone generation and HDMI audio clock regeneration |
| Display | `rtl/display` | Frame-locked status HUD, scrolling subtitle overlay, audio waveform/peak overlay, four-bank thumbnail layout, font rendering, and single-read-port transitions |
| Filesystem | `rtl/filesystem` | FAT32 volume discovery, root-directory traversal, and FAT-chain streaming |
| Protocol | `rtl/protocol` | SD commands, sector transfer, BMP parsing, and AXI-stream adaptation |
| Buffer | `rtl/buffer` | Cross-clock FIFOs, four-bank frame residency, and SDRAM access |
| Drivers | `rtl/drivers` | SPI, HDMI PHY, video timing, reset, debounce, and board-facing logic |
| Integration | `rtl/integration` | Clock-domain and module wiring at the top level |

Generated and encrypted Anlogic/HDMI files are isolated under `vendor_ip`.
Constraints are isolated under `constraints`. Do not move or edit encrypted IP
files unless the corresponding TD project paths are updated and the full design
is rebuilt.

## Brightness, Contrast, and Volume Controls

The active-low board controls are assigned as follows:

| Control | Function |
| --- | --- |
| K1 (`A2`) | Increase the selected parameter in parameter mode; next image in normal mode |
| K2 (`B2`) | Decrease the selected parameter in parameter mode; previous image in normal mode |
| K3 (`B1`) | Reserved/idle; the former external K1 reset input is disabled and retained as a comment in the top module |
| K4 (`C1`) | Existing automatic/manual slideshow control |
| SW1 (`C8`), SW2 (`C7`) | Mode selector: logical `00` normal image controls, `01` brightness, `10` contrast, `11` volume |

In parameter mode, a short K1/K2 press adjusts the selected parameter by one
percent. Holding a key for 500 ms starts continuous 60 ms repeats without an
extra short-press step. The user-facing range saturates at 0-100 percent. The
`00` switch state returns to normal image controls. Parameters are synchronized into the
video clock domain and latch at a frame boundary. The top OSD continuously
reports `B:xxx C:xxx S:xxx` as percentages; the highest available seven-segment
digit shows `B`, `C`, or `S` during the two-second adjustment window, followed by
the selected decimal percentage. The eight-digit panel uses `SEL0` as the
leftmost digit and `SEL7` as the rightmost digit. Normal mode shows logical
`SW2 SW1`, five blank digits, and the current image number in decimal at the
rightmost digit.

## Frame Buffer Layout

The board SDRAM primitive is `EG_PHY_SDRAM_2M_32`, providing 2,097,152
32-bit words. Four uncompressed 1280x720 RGB888 frames would require 3,686,400
words and cannot fit. The buffer layer therefore converts BMP RGB888 pixels to
RGB565 at its write boundary, stores two pixels per 32-bit SDRAM word, and
expands RGB565 back to RGB888 at its read boundary. TF-card files and HDMI data
remain 24-bit RGB.

Each frame occupies 460,800 words. Bank bases are 0, 460,800, 921,600, and
1,382,400; bank 3 ends at word 1,843,199, leaving 253,952 words unused. The
`PACK_RGB565` parameter in `frame_read_write.v` reserves the original 32-bit
storage path for a future board with at least 3,686,400 addressable words.
