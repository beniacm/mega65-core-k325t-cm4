## qmtech-k325t-cm4.xdc
## QMTech XC7K325T Development Board (CM4-socket carrier), xc7k325tffg676-1.
## Pin sources: vendor schematic 2023-11-20 sheet 2, plus the Pmod/HDMI/SD
## mappings proven on this board in ~/qmtech/tm_fpga (hdmi_sipeed, bt1120_sd).
## All Pmods are 3V3 banks (J11 = bank 15, J12/J13 = bank 14).

set_property CFGBVS                         VCCO    [current_design]
set_property CONFIG_VOLTAGE                 3.3     [current_design]
set_property BITSTREAM.CONFIG.UNUSEDPIN     PULLUP  [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH  4       [current_design]
set_property CONFIG_MODE                    SPIx4   [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE    50      [current_design]
set_property BITSTREAM.GENERAL.COMPRESS     TRUE    [current_design]

## 50 MHz oscillator, buttons, LEDs
set_property -dict {PACKAGE_PIN F22 IOSTANDARD LVCMOS33} [get_ports clk_in]
create_clock -period 20.000 [get_ports clk_in]
set_property -dict {PACKAGE_PIN U26 IOSTANDARD LVCMOS33} [get_ports reset_button]
set_property -dict {PACKAGE_PIN V26 IOSTANDARD LVCMOS33} [get_ports restore_btn]
set_property -dict {PACKAGE_PIN R26 IOSTANDARD LVCMOS33} [get_ports {led[0]}]
set_property -dict {PACKAGE_PIN P26 IOSTANDARD LVCMOS33} [get_ports {led[1]}]
set_property -dict {PACKAGE_PIN N26 IOSTANDARD LVCMOS33} [get_ports {led[2]}]

## J11: Sipeed DVI Pmod.  Sipeed pairs are vertical (k, k+6), P on pins 1-4.
##   ch2 red   (1,7)  P=C16 pin1  N=B16 pin7
##   ch1 green (2,8)  P=B17 pin8  N=A17 pin2   <- swapped on board, data inverted in RTL
##   ch0 blue  (3,9)  P=A18 pin3  N=A19 pin9
##   clock     (4,10) P=B20 pin10 N=A20 pin4   <- swapped on board, pattern inverted in RTL
set_property -dict {PACKAGE_PIN C16 IOSTANDARD TMDS_33} [get_ports {tmds_data_p[2]}]
set_property -dict {PACKAGE_PIN B16 IOSTANDARD TMDS_33} [get_ports {tmds_data_n[2]}]
set_property -dict {PACKAGE_PIN B17 IOSTANDARD TMDS_33} [get_ports {tmds_data_p[1]}]
set_property -dict {PACKAGE_PIN A17 IOSTANDARD TMDS_33} [get_ports {tmds_data_n[1]}]
set_property -dict {PACKAGE_PIN A18 IOSTANDARD TMDS_33} [get_ports {tmds_data_p[0]}]
set_property -dict {PACKAGE_PIN A19 IOSTANDARD TMDS_33} [get_ports {tmds_data_n[0]}]
set_property -dict {PACKAGE_PIN B20 IOSTANDARD TMDS_33} [get_ports tmds_clk_p]
set_property -dict {PACKAGE_PIN A20 IOSTANDARD TMDS_33} [get_ports tmds_clk_n]

## J12: SD Pmod, Digilent order (1=DAT3/CS 2=CMD/MOSI 3=DAT0/MISO 4=CLK 7=DAT1 8=DAT2)
set_property -dict {PACKAGE_PIN E21 IOSTANDARD LVCMOS33 DRIVE 8}             [get_ports sd_cs]
set_property -dict {PACKAGE_PIN D23 IOSTANDARD LVCMOS33 DRIVE 8}             [get_ports sd_mosi]
set_property -dict {PACKAGE_PIN D25 IOSTANDARD LVCMOS33 PULLUP TRUE}         [get_ports sd_miso]
set_property -dict {PACKAGE_PIN F23 IOSTANDARD LVCMOS33 DRIVE 8 SLEW FAST}   [get_ports sd_clk]
set_property -dict {PACKAGE_PIN E22 IOSTANDARD LVCMOS33}                     [get_ports sd_dat1]
set_property -dict {PACKAGE_PIN D24 IOSTANDARD LVCMOS33}                     [get_ports sd_dat2]

## J13: Sipeed DS2x2 Pmod (pins 1-4 = pad 1: cs mosi miso clk; 7-10 = pad 2).
## Derived from the Primer25K dock numbering used in ~/projects/spectrumnext.
## If the pads come out swapped (player 1 <-> 2) the module rows are reversed.
set_property -dict {PACKAGE_PIN A24 IOSTANDARD LVCMOS33}             [get_ports ds1_cs]
set_property -dict {PACKAGE_PIN B26 IOSTANDARD LVCMOS33}             [get_ports ds1_mosi]
set_property -dict {PACKAGE_PIN D26 IOSTANDARD LVCMOS33 PULLUP TRUE} [get_ports ds1_miso]
set_property -dict {PACKAGE_PIN F25 IOSTANDARD LVCMOS33}             [get_ports ds1_clk]
set_property -dict {PACKAGE_PIN A23 IOSTANDARD LVCMOS33}             [get_ports ds2_cs]
set_property -dict {PACKAGE_PIN B25 IOSTANDARD LVCMOS33}             [get_ports ds2_mosi]
set_property -dict {PACKAGE_PIN C26 IOSTANDARD LVCMOS33 PULLUP TRUE} [get_ports ds2_miso]
set_property -dict {PACKAGE_PIN E26 IOSTANDARD LVCMOS33}             [get_ports ds2_clk]

## >>> CM bus: this section is replaced for other modules (qmtech-k325t-cm4-radxacm3-bus.xdc, Makefile)
## CM4 GPIO bus to the Rockchip (see ~/qmtech/PINMAP.md).
## The only FPGA output on this bus is rk_miso (B9) -> Rockchip spi3 MISO (an input).
##   Service bridge, Rockchip spi3-m1 master (/dev/spidev3.0), pins proven in ~/qmtech:
##     CLK BCM21 A8 (GPIO4_C2), MOSI BCM20 A9 (GPIO4_C3), MISO BCM19 B9 (GPIO4_C5), CS0 BCM18 B15 (GPIO4_C6)
set_property -dict {PACKAGE_PIN A8  IOSTANDARD LVCMOS33 PULLDOWN TRUE} [get_ports rk_sck]
set_property -dict {PACKAGE_PIN A9  IOSTANDARD LVCMOS33 PULLDOWN TRUE} [get_ports rk_mosi]
set_property -dict {PACKAGE_PIN B15 IOSTANDARD LVCMOS33 PULLUP TRUE}   [get_ports rk_cs_n]
set_property -dict {PACKAGE_PIN B9  IOSTANDARD LVCMOS33 DRIVE 8 SLEW FAST} [get_ports rk_miso]
## The bridge oversamples SCK at 162 MHz and switches MISO 2-3 clocks after a rising SCK edge;
## the master samples it one SCK period later (25 ns at 40 MHz).  The first sampling flip-flops
## and the MISO register sit in the I/O cells, so pad delays are fixed and short whatever the
## placement of the rest (a build with MISO placed far from B9 lost the link above 25 MHz).
set_property IOB TRUE [get_ports {rk_sck rk_mosi rk_cs_n rk_miso}]
## The Rockchip's own picture: BT1120 (clock + 16 data) from the boot DTB's vp2 output
## (rockchip/boot_dtb, 720x576@50 = 27 MHz), pins from the board bring-up (PINMAP.md,
## bt1120_hdmi.xdc, verified to 74.25 MHz there).  Inputs only.
set_property -dict {PACKAGE_PIN B10 IOSTANDARD LVCMOS33} [get_ports bt_clk]
create_clock -period 13.468 -name bt_clk [get_ports bt_clk]
## B10 is not a clock-capable pin: route it to its BUFG through the fabric, as the bring-up
## design did (pixel-clean there up to 74.25 MHz; here 27 MHz).
set_property CLOCK_DEDICATED_ROUTE FALSE [get_nets -of_objects [get_pins -hier -filter {NAME =~ *btclk_bufg/I}]]
set_property -dict {PACKAGE_PIN A14 IOSTANDARD LVCMOS33} [get_ports {bt_d[0]}]
set_property -dict {PACKAGE_PIN B14 IOSTANDARD LVCMOS33} [get_ports {bt_d[1]}]
set_property -dict {PACKAGE_PIN A13 IOSTANDARD LVCMOS33} [get_ports {bt_d[2]}]
set_property -dict {PACKAGE_PIN A12 IOSTANDARD LVCMOS33} [get_ports {bt_d[3]}]
set_property -dict {PACKAGE_PIN B12 IOSTANDARD LVCMOS33} [get_ports {bt_d[4]}]
set_property -dict {PACKAGE_PIN C9  IOSTANDARD LVCMOS33} [get_ports {bt_d[5]}]
set_property -dict {PACKAGE_PIN D16 IOSTANDARD LVCMOS33} [get_ports {bt_d[6]}]
set_property -dict {PACKAGE_PIN E10 IOSTANDARD LVCMOS33} [get_ports {bt_d[7]}]
set_property -dict {PACKAGE_PIN A10 IOSTANDARD LVCMOS33} [get_ports {bt_d[8]}]
set_property -dict {PACKAGE_PIN D18 IOSTANDARD LVCMOS33} [get_ports {bt_d[9]}]
set_property -dict {PACKAGE_PIN C18 IOSTANDARD LVCMOS33} [get_ports {bt_d[10]}]
set_property -dict {PACKAGE_PIN B11 IOSTANDARD LVCMOS33} [get_ports {bt_d[11]}]
set_property -dict {PACKAGE_PIN C12 IOSTANDARD LVCMOS33} [get_ports {bt_d[12]}]
set_property -dict {PACKAGE_PIN C13 IOSTANDARD LVCMOS33} [get_ports {bt_d[13]}]
set_property -dict {PACKAGE_PIN D14 IOSTANDARD LVCMOS33} [get_ports {bt_d[14]}]
set_property -dict {PACKAGE_PIN D13 IOSTANDARD LVCMOS33} [get_ports {bt_d[15]}]
set_false_path -from [get_ports {bt_d[*]}]
## bt_clk is unrelated to the core's clocks; linux_fb crosses via a dual-clock BRAM and a
## 2-FF synchroniser for the select bit.
set_clock_groups -asynchronous -group [get_clocks -include_generated_clocks bt_clk]
## (No other CM4 line is used; the boot DTB's BT1120 mux drives exactly these pads.)
## <<< CM bus

## QSPI configuration flash (S25FL128L); CCLK is driven via STARTUPE2.
set_property -dict {PACKAGE_PIN B24 IOSTANDARD LVCMOS33 PULLUP TRUE} [get_ports {qspi_db[0]}]
set_property -dict {PACKAGE_PIN A25 IOSTANDARD LVCMOS33 PULLUP TRUE} [get_ports {qspi_db[1]}]
set_property -dict {PACKAGE_PIN B22 IOSTANDARD LVCMOS33 PULLUP TRUE} [get_ports {qspi_db[2]}]
set_property -dict {PACKAGE_PIN A22 IOSTANDARD LVCMOS33 PULLUP TRUE} [get_ports {qspi_db[3]}]
set_property -dict {PACKAGE_PIN C23 IOSTANDARD LVCMOS33}             [get_ports qspi_csn]

## Clocks
create_generated_clock -name clock81p [get_pins clocks/mmcm_adv0/CLKOUT2]
create_generated_clock -name clock41  [get_pins clocks/mmcm_adv0/CLKOUT3]
create_generated_clock -name clock27  [get_pins clocks/mmcm_adv0/CLKOUT4]
create_generated_clock -name clock270 [get_pins clocks/mmcm_adv0/CLKOUT6]
create_generated_clock -name clock162 [get_pins clocks/mmcm_adv0/CLKOUT5]
## rk_bridge runs in clock162 and talks to the cpuclock side only through
## synchronisers / dual-clock RAMs / quasi-static registers.
set_clock_groups -asynchronous -group [get_clocks clock162] -group [get_clocks clock41]
## DDR3 attic RAM: clock200 (from the otherwise unused "eth" MMCM) feeds only the MIG;
## the MIG's ui_clk and PHY clocks are generated from it.  That whole tree meets the
## cpuclock side only through ddr3_attic's toggle handshakes (payload held stable).
## (Referencing clocks by the generated tree, not by the MIG's nets, also works while
## the MIG is still a black box during synthesis.)
## DDR3 pin LOCs/IOSTANDARDs come from the MIG's generated constraints.
create_generated_clock -name clock200 [get_pins clocks/mmcm_adv1_eth/CLKOUT2]
## clock50 = RMII clock of the MEGA65 MAC + eth_vphy, same MMCM as clock200 (MAC needs 4x).
## The MAC crosses into cpuclock internally (as on real boards); eth_vphy meets the bridge
## (clock162) only through toggle handshakes and dual-clock RAMs.
create_generated_clock -name clock50 [get_pins clocks/mmcm_adv1_eth/CLKOUT1]
set_clock_groups -asynchronous \
  -group [get_clocks -include_generated_clocks {clock200 clock50}] \
  -group [get_clocks {clock41 clock162 clock81p clock27 clock270}]
create_generated_clock -name clock60  [get_pins AUDIO_TONE/CLOCK/MMCM/CLKOUT1]
set_false_path -from [get_clocks clock41] -to [get_clocks clock60]

## Asynchronous inputs (synchronised in RTL)
set_false_path -from [get_ports {reset_button restore_btn ds1_miso ds2_miso sd_miso rk_sck rk_cs_n rk_mosi}]
set_false_path -to   [get_ports rk_miso]
set_false_path -to   [get_ports {led[*]}]

## Rockchip configuration-flash pass-through (rk_bridge 0x50) shares the QSPI pins;
## a slot that fails to configure falls back to the image at address 0.
set_property BITSTREAM.CONFIG.CONFIGFALLBACK ENABLE [current_design]
set_false_path -to   [get_ports {qspi_csn qspi_db[*]}]
set_false_path -from [get_ports {qspi_db[*]}]

## neoTRNG (gs4510 trng0): its ring oscillators are intended combinational loops (as in
## mega65r2.xdc).  Without this, write_bitstream's DRC LUTLP-1 stops the build whenever
## synthesis keeps them as LUT loops (first seen with the 1 MB chip RAM build).
set trng_cells [get_cells -hier -regexp .*trng0.* -filter {NAME =~ .*/inv_chain_.* || NAME =~ .*/enable_sreg_.*}]
set_property ALLOW_COMBINATORIAL_LOOPS true [get_nets -of_objects $trng_cells]
set_disable_timing -to O [get_timing_arcs -of_objects $trng_cells]
