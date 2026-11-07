# mega65-core — QMTech XC7K325T CM4 carrier port (`qmtech-k325t-cm4`)

A fork of [MEGA65/mega65-core](https://github.com/MEGA65/mega65-core) that adds the
**`qmtech-k325t-cm4`** target: the MEGA65 on a QMTech XC7K325T development board with a CM4
carrier, whose Luckfox Core3566 (Rockchip) module serves the SD card, keyboard, joysticks,
mouse, serial monitor, Ethernet and RTC over one SPI link.  Not an official MEGA65 product.

**Branch `qmtech-k325t-cm4`** (default here) = upstream `development` + this port.  Upstream's
own README is [`README.md`](../README.md); this file only describes the port.

The board harness — build and test scripts, the Rockchip daemons, the Rockchip boot image,
simulation testbenches and the full write-up — is
**[beniacm/mega65-k325t-cm4](https://github.com/beniacm/mega65-k325t-cm4)**.  The C64 core for
the same board is [beniacm/c64mega65-k325t-cm4](https://github.com/beniacm/c64mega65-k325t-cm4).

## What the port adds

| file | role |
|---|---|
| `src/vhdl/qmtech-k325t-cm4.vhdl`, `.xdc` | top level (derived from `wukong.vhdl`): clocks, HDMI on J11 (Sipeed DVI Pmod), QSPI, MIG, bridge |
| `src/vhdl/rk_bridge.vhdl` | SPI slave to the Rockchip: SD sectors (with a 16-slot read cache), keyboard matrix, joysticks/pots, monitor UART, Ethernet frames, flash pass-through, reconfiguration |
| `src/vhdl/sd_emu.vhdl` | SPI SDHC card emulator in front of the MEGA65's SD controller |
| `src/vhdl/ddr3_attic.vhdl`, `qmtech-k325t-cm4_mig_ddr3.prj` | attic RAM on the board's DDR3 (8 MB after reset, 64 MB via `$BFFFFFC`) |
| `src/vhdl/eth_vphy.vhdl` | virtual RMII PHY: the MEGA65 Ethernet MAC through the Rockchip |
| `src/vhdl/soft_rtc.vhdl` | battery-less RTC at `$FFD7110` (set from the Rockchip's NTP time) + the XCTL register |
| `src/vhdl/chipram_k325t.vhdl`, `colourram_k325t.vhdl` | 1 MB chip RAM, 64 KB colour RAM (K325T extensions) |
| `src/vhdl/rk_iprog.vhdl` | warm boot into another flash slot (core switching) |
| `src/verilog/controller_ds2.v`, `dualshock_controller.v` | optional DualShock2 pads on J13 (Sipeed DS2x2 Pmod) |
| `vivado/qmtech-k325t-cm4_gen.tcl`, `_impl.tcl` | Vivado project |

**K325T extensions** — off after every reset, so the machine is a real MEGA65 until a program
asks; XCTL **`$FFD71F0`** (cleared by reset): bit 0 = **1 MB chip RAM** for the CPU/DMA (the
CPU and VIC-IV already had `chipram_size` generics), bit 1 = **raster DMA list** (`$FFD71F4-7`
= list address, started every frame; the new DMA job options `$D0 lo` / `$D1 hi` wait until
that raster line and give the CPU back meanwhile), bit 2 = **64 KB colour RAM**.  Details in
the harness README, section "K325T extensions".

**Changes to shared upstream files** are small and gated (target `qmtechk325t` or generics whose
defaults keep every other board unchanged): `gs4510.vhdl` (chip RAM size gate, raster DMA list,
`raster_line` input), `viciv.vhdl` (optional 64 KB colour RAM), `machine.vhdl` / `iomapper.vhdl`
(generics, XCTL wiring), `Makefile` (target + generated `shadowram-k325t-lo.vhdl`).  Two general
fixes: `cia6526.vhdl` powers up the timer latches/counters as `$FFFF` like a MOS 6526 (the ROM's
RTC-less clock calibration hung on `$0001`), and `megaflash/mf_utility.c` reads board ids
>= `$20` as whole bytes (it split `$62` into model 2 / minor 6, i.e. "R2", 4 MB slots).

## Build

```
make bin/qmtech-k325t-cm4.bit          # or the harness's scripts/build.sh (handles host quirks)
```
Vivado 2025.2 was used.  Load with JTAG for testing, or write it to the configuration flash
from the Rockchip (`m65flash.py write 0 …` in the harness).

## Following upstream

```
git remote add upstream https://github.com/MEGA65/mega65-core.git   # fetch only
git fetch upstream && git merge upstream/development
```
Nothing here is pushed to upstream.

## Licences

As upstream: VHDL under the LGPL-3.0 unless marked otherwise (`LICENSE.txt`).  The port's own
files are under the same terms.  `src/verilog/dualshock_controller.v` (Katsumi Degawa) is
"freeware for non-commercial use" per its header, as in the other open FPGA projects that ship
it; it is only used by the optional J13 pad interface.
