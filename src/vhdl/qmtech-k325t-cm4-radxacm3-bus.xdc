## CM4 GPIO bus to a Radxa CM3 (RK3566) in the same carrier.  Its RK3566 pads on the 28 lines differ
## from the Luckfox Core3566's (Radxa follows the Raspberry Pi functions: SPI on BCM8..11):
##   Service bridge, spi3-m0 master (/dev/spidev3.0):
##     CLK BCM11 D13 (GPIO4_B3), MOSI BCM10 C13 (GPIO4_B2), MISO BCM9 D14 (GPIO4_B0), CS0 BCM8 A12 (GPIO4_A6)
## The only FPGA output on this bus is rk_miso (D14).  BCM7 (B12) is left unused: Radxa's pinout
## sheet calls it SARADC_VIN3 (analogue, 1.8 V max); on the V1.3x board it measured as GPIO4_C5,
## a 3.3 V GPIO (pin test 2026-11-10), so the default UNUSEDPIN pull-up on it is harmless.
## BCM14/15 (C17/A15) are the module's debug console UART: unused here, never driven.
set_property -dict {PACKAGE_PIN D13 IOSTANDARD LVCMOS33 PULLDOWN TRUE} [get_ports rk_sck]
set_property -dict {PACKAGE_PIN C13 IOSTANDARD LVCMOS33 PULLDOWN TRUE} [get_ports rk_mosi]
set_property -dict {PACKAGE_PIN A12 IOSTANDARD LVCMOS33 PULLUP TRUE}   [get_ports rk_cs_n]
set_property -dict {PACKAGE_PIN D14 IOSTANDARD LVCMOS33 DRIVE 8 SLEW FAST} [get_ports rk_miso]
set_property IOB TRUE [get_ports {rk_sck rk_mosi rk_cs_n rk_miso}]
## The module's own picture: of the RK3566's video outputs only VOP_BT656_M1 reaches the FPGA here
## (8 data lines at twice the pixel clock: 54 MHz for 720x576p50; the BT1120 pads feed the module's
## Ethernet PHY).  linux_fb is built with BT656 => true (top generic bt656) and uses bt_d(7..0):
##   clock BCM0 C12 (GPIO4_B4); D0..D7 = BCM25 A13 (GPIO3_C6), BCM18 B15 (C7), BCM19 B9 (D0),
##   BCM21 A8 (D1), BCM20 A9 (D2), BCM24 B14 (D3), BCM23 A14 (D4), BCM4 E18 (D5).  Inputs only.
set_property -dict {PACKAGE_PIN C12 IOSTANDARD LVCMOS33} [get_ports bt_clk]
create_clock -period 18.518 -name bt_clk [get_ports bt_clk]
set_property CLOCK_DEDICATED_ROUTE FALSE [get_nets -of_objects [get_pins -hier -filter {NAME =~ *btclk_bufg/I}]]
set_property -dict {PACKAGE_PIN A13 IOSTANDARD LVCMOS33} [get_ports {bt_d[0]}]
set_property -dict {PACKAGE_PIN B15 IOSTANDARD LVCMOS33} [get_ports {bt_d[1]}]
set_property -dict {PACKAGE_PIN B9  IOSTANDARD LVCMOS33} [get_ports {bt_d[2]}]
set_property -dict {PACKAGE_PIN A8  IOSTANDARD LVCMOS33} [get_ports {bt_d[3]}]
set_property -dict {PACKAGE_PIN A9  IOSTANDARD LVCMOS33} [get_ports {bt_d[4]}]
set_property -dict {PACKAGE_PIN B14 IOSTANDARD LVCMOS33} [get_ports {bt_d[5]}]
set_property -dict {PACKAGE_PIN A14 IOSTANDARD LVCMOS33} [get_ports {bt_d[6]}]
set_property -dict {PACKAGE_PIN E18 IOSTANDARD LVCMOS33} [get_ports {bt_d[7]}]
## bt_d(15..8) are not used in BT.656 mode; parked on free lines of the bus as inputs with a pull-down
## (BCM1 B11, BCM2 C18, BCM3 D18, BCM5 C11, BCM6 D10, BCM12 A10, BCM13 E10, BCM16 B10)
set_property -dict {PACKAGE_PIN B11 IOSTANDARD LVCMOS33 PULLDOWN TRUE} [get_ports {bt_d[8]}]
set_property -dict {PACKAGE_PIN C18 IOSTANDARD LVCMOS33 PULLDOWN TRUE} [get_ports {bt_d[9]}]
set_property -dict {PACKAGE_PIN D18 IOSTANDARD LVCMOS33 PULLDOWN TRUE} [get_ports {bt_d[10]}]
set_property -dict {PACKAGE_PIN C11 IOSTANDARD LVCMOS33 PULLDOWN TRUE} [get_ports {bt_d[11]}]
set_property -dict {PACKAGE_PIN D10 IOSTANDARD LVCMOS33 PULLDOWN TRUE} [get_ports {bt_d[12]}]
set_property -dict {PACKAGE_PIN A10 IOSTANDARD LVCMOS33 PULLDOWN TRUE} [get_ports {bt_d[13]}]
set_property -dict {PACKAGE_PIN E10 IOSTANDARD LVCMOS33 PULLDOWN TRUE} [get_ports {bt_d[14]}]
set_property -dict {PACKAGE_PIN B10 IOSTANDARD LVCMOS33 PULLDOWN TRUE} [get_ports {bt_d[15]}]
set_false_path -from [get_ports {bt_d[*]}]
set_clock_groups -asynchronous -group [get_clocks -include_generated_clocks bt_clk]
