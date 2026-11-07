--------------------------------------------------------------------------------
-- qmtech-k325t-cm4.vhdl
--
-- MEGA65 top level for the QMTech "XC7K325T Development Board" (the carrier
-- with the Raspberry-Pi CM4 socket, 3x Pmod J11/J12/J13, 50-pin JP5 header).
-- NOT the older QMTech K325T core board that src/vhdl/qmtech-k325t.vhdl
-- targets: that pin map puts VGA/Pmod outputs onto this board's CM4 GPIO bus.
--
-- Derived from wukong.vhdl (HDMI via vga_to_hdmi + fabric 10:1 serialiser).
--
--   J11  Sipeed DVI Pmod      HDMI/DVI 576p50, 27 MHz pixel, TMDS_33
--   J12  SD Pmod (Digilent)   internal SD card, SPI mode
--   J13  Sipeed DS2x2 Pmod    two DualShock2 pads -> joystick ports 2 and 1
--   CM4  GPIO bus             Rockchip service bridge on spi3-m1 (rk_bridge):
--                             SD-card emulation (sectors served by the Rockchip),
--                             serial monitor, keyboard matrix, joysticks, reset.
--                             Only the 4 spi3 lines are used: the other CM4
--                             pads may be driven by the Rockchip (BT1120 mux).
--   DDR3 (bank 34)            256 MB MT41K128M16 via MIG: attic RAM, 8 MB after reset
--                             (as a real MEGA65), 64 MB after POKE $BFFFFFC,64; see ddr3_attic.vhdl
--   Ethernet                  MEGA65 MAC <-> eth_vphy (virtual RMII PHY) <-> rk_bridge
--                             <-> Rockchip TAP interface (m65io) -> LAN (routed/NAT)
--   SW3  (U26)                CPU reset (active low)
--   SW2  (V26)                RESTORE (active low)
--   LED2/3/4 (R26/P26/N26)    status
--
-- The J11 green (D1) and clock pairs have the FPGA P ball on the Pmod's
-- N pin, so their 10-bit words are inverted before the serialiser.
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library unisim;
use unisim.vcomponents.all;

use work.cputypes.all;
use work.types_pkg.all;

entity container is
  port (
    clk_in       : in std_logic;      -- 50 MHz, F22
    reset_button : in std_logic;      -- SW3, active low
    restore_btn  : in std_logic;      -- SW2, active low

    -- HDMI on J11 (Sipeed DVI Pmod).
    tmds_data_p : out std_logic_vector(2 downto 0);
    tmds_data_n : out std_logic_vector(2 downto 0);
    tmds_clk_p  : out std_logic;
    tmds_clk_n  : out std_logic;

    -- QSPI configuration flash (S25FL128L).
    qspi_db  : inout unsigned(3 downto 0);
    qspi_csn : out   std_logic;

    -- SD card on J12 (SPI mode).
    sd_cs   : out std_logic;
    sd_clk  : out std_logic;
    sd_mosi : out std_logic;
    sd_miso : in  std_logic;
    sd_dat1 : out std_logic;
    sd_dat2 : out std_logic;

    -- DualShock2 pads on J13 (Sipeed DS2x2 Pmod).
    ds1_clk  : out std_logic;
    ds1_cs   : out std_logic;
    ds1_mosi : out std_logic;
    ds1_miso : in  std_logic;
    ds2_clk  : out std_logic;
    ds2_cs   : out std_logic;
    ds2_mosi : out std_logic;
    ds2_miso : in  std_logic;

    -- Rockchip service bridge (SPI slave; Rockchip spi3-m1 is master).
    rk_sck  : in  std_logic;
    rk_cs_n : in  std_logic;
    rk_mosi : in  std_logic;
    rk_miso : out std_logic;

    -- DDR3 (MT41K128M16, bank 34) -- names match the MIG's generated pin constraints.
    ddr3_dq      : inout std_logic_vector(15 downto 0);
    ddr3_dqs_p   : inout std_logic_vector(1 downto 0);
    ddr3_dqs_n   : inout std_logic_vector(1 downto 0);
    ddr3_addr    : out   std_logic_vector(13 downto 0);
    ddr3_ba      : out   std_logic_vector(2 downto 0);
    ddr3_ras_n   : out   std_logic;
    ddr3_cas_n   : out   std_logic;
    ddr3_we_n    : out   std_logic;
    ddr3_reset_n : out   std_logic;
    ddr3_ck_p    : out   std_logic_vector(0 downto 0);
    ddr3_ck_n    : out   std_logic_vector(0 downto 0);
    ddr3_cke     : out   std_logic_vector(0 downto 0);
    ddr3_dm      : out   std_logic_vector(1 downto 0);
    ddr3_odt     : out   std_logic_vector(0 downto 0);

    -- LEDs (active high).
    led : out std_logic_vector(2 downto 0)
  );
end container;

architecture Behavioral of container is

  signal irq                  : std_logic := '1';
  signal nmi                  : std_logic := '1';
  signal reset_out            : std_logic := '1';
  signal btncpureset          : std_logic := '1';
  signal restore_key          : std_logic := '1';
  signal cpuclock             : std_logic;
  signal pixelclock           : std_logic;
  signal clock27              : std_logic;
  signal clock270             : std_logic;
  signal clock162             : std_logic;  -- rk_bridge fast clock (4 x cpuclock)
  signal sector_buffer_mapped : std_logic;
  signal fpga_temperature     : std_logic_vector(11 downto 0) := (others => '0');

  -- QSPI flash.
  signal qspi_clock  : std_logic;
  signal qspi_db_oe  : std_logic;
  signal qspi_db_out : unsigned(3 downto 0);
  signal qspi_db_in  : unsigned(3 downto 0);
  signal qspi_csn_m  : std_logic;          -- the MEGA65's own flash chip select
  signal qspi_usrclk : std_logic;          -- to STARTUPE2: MEGA65 or Rockchip flash clock
  -- Rockchip pass-through to the configuration flash (rk_bridge command 0x50)
  signal rkfl_act, rkfl_sck, rkfl_cs_n, rkfl_mosi : std_logic;

  -- SYSCTL configuration register.
  signal portp       : unsigned(7 downto 0);
  signal portp_drive : unsigned(7 downto 0);

  -- No physical C64 keyboard matrix on this board.
  signal porta_pins : std_logic_vector(7 downto 0) := (others => '1');
  signal portb_pins : std_logic_vector(7 downto 0) := (others => '1');

  -- Synchronised asynchronous inputs.
  signal ps2clk_s  : std_logic_vector(2 downto 0) := (others => '1');
  signal ps2data_s : std_logic_vector(2 downto 0) := (others => '1');
  signal rsrx_s    : std_logic_vector(1 downto 0) := (others => '1');
  signal reset_s   : std_logic_vector(1 downto 0) := (others => '1');
  signal restore_s : std_logic_vector(1 downto 0) := (others => '1');

  -- DualShock2 pads: snes order {RB LB X A RIGHT LEFT DOWN UP START SELECT Y B},
  -- active high.
  signal pad1 : std_logic_vector(11 downto 0);
  signal pad2 : std_logic_vector(11 downto 0);

  -- Joystick ports (active low).
  signal fa_up, fa_down, fa_left, fa_right, fa_fire : std_logic := '1';
  signal fb_up, fb_down, fb_left, fb_right, fb_fire : std_logic := '1';

  -- Audio (PCM).
  constant clock_frequency      : integer := 40500000;
  constant target_sample_rate   : integer := 48000;
  signal audio_left             : std_logic_vector(19 downto 0);
  signal audio_right            : std_logic_vector(19 downto 0);
  signal audio_left_slow        : std_logic_vector(19 downto 0);
  signal audio_right_slow       : std_logic_vector(19 downto 0);
  signal h_audio_left           : std_logic_vector(19 downto 0);
  signal h_audio_right          : std_logic_vector(19 downto 0);
  signal audio_counter          : integer                       := 0;
  signal sample_ready_toggle    : std_logic                     := '0';
  signal audio_counter_interval : unsigned(25 downto 0)         := to_unsigned(4 * clock_frequency/target_sample_rate, 26);
  signal acr_counter            : integer range 0 to 12288      := 0;
  signal pcm_clk                : std_logic                     := '0';
  signal pcm_rst                : std_logic                     := '1';
  signal pcm_clken              : std_logic                     := '0';
  signal pcm_l                  : std_logic_vector(15 downto 0) := std_logic_vector(to_unsigned(0, 16));
  signal pcm_r                  : std_logic_vector(15 downto 0) := std_logic_vector(to_unsigned(0, 16));
  signal pcm_acr                : std_logic                     := '0';

  -- Video (HDMI).
  signal dvi_reset       : std_logic := '1';
  signal dvi_select      : std_logic := '0';
  signal v_hdmi_hsync    : std_logic;
  signal v_vsync         : std_logic;
  signal v_red           : unsigned(7 downto 0);
  signal v_green         : unsigned(7 downto 0);
  signal v_blue          : unsigned(7 downto 0);
  signal hdmi_dataenable : std_logic;
  signal tmds            : slv_9_0_t(0 to 2);
  signal tmds_pin        : slv_9_0_t(0 to 2);

  -- Rockchip bridge / SD emulator.
  signal sd_cs_int, sd_clk_int, sd_mosi_int, sd_miso_int : std_logic;
  signal emu_miso   : std_logic;
  signal emu_rd_req, emu_wr_req, emu_rd_ready, emu_wr_ack, emu_inited : std_logic;
  signal emu_rd_error : std_logic;
  signal emu_lba    : unsigned(31 downto 0);
  signal emu_seq, emu_ccnt, emu_lcmd : unsigned(7 downto 0);
  signal emu_rba, emu_wba : unsigned(8 downto 0);
  signal emu_rbd, emu_wbd : std_logic_vector(7 downto 0);
  signal emu_wbwe   : std_logic;
  signal mon_rx     : std_logic;
  signal uart_txd_int : std_logic;
  signal widget_idx : integer range 0 to 15;
  signal widget_col : std_logic_vector(7 downto 0);
  signal rk_joya, rk_joyb : std_logic_vector(4 downto 0);
  signal rk_ctrl    : std_logic_vector(7 downto 0);
  signal rk_active  : std_logic;
  signal rk_ctrl_s  : std_logic_vector(7 downto 0) := (others => '0');
  signal monitor_rx, widget_restore_n, widget_capslock_n : std_logic := '1';

  -- DDR3 attic RAM.
  component mig_ddr3 is
    port (
      ddr3_dq             : inout std_logic_vector(15 downto 0);
      ddr3_dqs_p          : inout std_logic_vector(1 downto 0);
      ddr3_dqs_n          : inout std_logic_vector(1 downto 0);
      ddr3_addr           : out   std_logic_vector(13 downto 0);
      ddr3_ba             : out   std_logic_vector(2 downto 0);
      ddr3_ras_n          : out   std_logic;
      ddr3_cas_n          : out   std_logic;
      ddr3_we_n           : out   std_logic;
      ddr3_reset_n        : out   std_logic;
      ddr3_ck_p           : out   std_logic_vector(0 downto 0);
      ddr3_ck_n           : out   std_logic_vector(0 downto 0);
      ddr3_cke            : out   std_logic_vector(0 downto 0);
      ddr3_dm             : out   std_logic_vector(1 downto 0);
      ddr3_odt            : out   std_logic_vector(0 downto 0);
      app_addr            : in    std_logic_vector(27 downto 0);
      app_cmd             : in    std_logic_vector(2 downto 0);
      app_en              : in    std_logic;
      app_wdf_data        : in    std_logic_vector(127 downto 0);
      app_wdf_end         : in    std_logic;
      app_wdf_mask        : in    std_logic_vector(15 downto 0);
      app_wdf_wren        : in    std_logic;
      app_rd_data         : out   std_logic_vector(127 downto 0);
      app_rd_data_end     : out   std_logic;
      app_rd_data_valid   : out   std_logic;
      app_rdy             : out   std_logic;
      app_wdf_rdy         : out   std_logic;
      app_sr_req          : in    std_logic;
      app_ref_req         : in    std_logic;
      app_zq_req          : in    std_logic;
      app_sr_active       : out   std_logic;
      app_ref_ack         : out   std_logic;
      app_zq_ack          : out   std_logic;
      ui_clk              : out   std_logic;
      ui_clk_sync_rst     : out   std_logic;
      init_calib_complete : out   std_logic;
      sys_clk_i           : in    std_logic;
      device_temp_i       : in    std_logic_vector(11 downto 0);
      sys_rst             : in    std_logic
    );
  end component;
  signal clock200          : std_logic;
  signal clock50           : std_logic;   -- RMII clock (same MMCM as clock200 = 4x)
  signal clock200_u, clock50_u : std_logic;  -- unbuffered MMCM outputs
  signal eth_txd_s, eth_rxd_s : unsigned(1 downto 0);
  signal eth_txen_s, eth_rxdv_s : std_logic;
  signal eth_tx_avail, eth_tx_pop, eth_rx_we, eth_rx_push : std_logic;
  signal eth_tx_len, eth_tx_raddr, eth_rx_waddr, eth_rx_len : unsigned(10 downto 0);
  signal eth_tx_rdata, eth_rx_wdata : std_logic_vector(7 downto 0);
  signal eth_tx_drops : unsigned(7 downto 0);
  signal eth_rx_free : unsigned(3 downto 0);
  signal mig_ui_clk        : std_logic;
  signal mig_ui_rst        : std_logic;
  signal mig_calib         : std_logic;
  signal mig_sys_rst_n     : std_logic := '0';
  signal mig_por           : unsigned(15 downto 0) := (others => '0');
  signal app_addr          : std_logic_vector(27 downto 0);
  signal app_cmd           : std_logic_vector(2 downto 0);
  signal app_en, app_rdy, app_wdf_end, app_wdf_wren, app_wdf_rdy : std_logic;
  signal app_wdf_data, app_rd_data : std_logic_vector(127 downto 0);
  signal app_wdf_mask      : std_logic_vector(15 downto 0);
  signal app_rd_data_valid : std_logic;
  signal attic_calibrated  : std_logic;
  signal expansionram_read, expansionram_write : std_logic;
  signal expansionram_address : unsigned(26 downto 0);
  signal expansionram_wdata, expansionram_rdata : unsigned(7 downto 0);
  signal expansionram_data_ready_toggle, expansionram_busy : std_logic;
  -- attic RAM CPU fast path (as R6: line to the CPU and slow_devices)
  signal attic_cache_line  : cache_row_t;
  signal attic_cache_addr  : unsigned(26 downto 3);
  signal attic_cache_valid : std_logic;
  signal attic_cache_inc, attic_cache_dec : std_logic;

  -- Heartbeat.
  signal heartbeat : unsigned(24 downto 0) := (others => '0');

  -- Slow device bus.
  signal slow_access_request_toggle : std_logic;
  signal slow_access_ready_toggle   : std_logic;
  signal slow_access_write          : std_logic;
  signal slow_access_address        : unsigned(27 downto 0);
  signal slow_access_wdata          : unsigned(7 downto 0);
  signal slow_access_rdata          : unsigned(7 downto 0);

  -- Expansion / cartridge port (not present).
  signal cart_ba   : std_logic             := 'Z';
  signal cart_rw   : std_logic             := 'Z';
  signal cart_roml : std_logic             := 'Z';
  signal cart_romh : std_logic             := 'Z';
  signal cart_io1  : std_logic             := 'Z';
  signal cart_io2  : std_logic             := 'Z';
  signal cart_a    : unsigned(15 downto 0) := (others => 'Z');

  -- Verilog module (src/verilog/controller_ds2.v).
  component controller_ds2 is
    generic (FREQ : integer := 21600000);
    port (
      clk          : in  std_logic;
      snes_buttons : out std_logic_vector(11 downto 0);
      ds_clk       : out std_logic;
      ds_miso      : in  std_logic;
      ds_mosi      : out std_logic;
      ds_cs        : out std_logic
    );
  end component;

begin

  -- Direct control of the configuration flash clock (CCLK) from fabric.
  STARTUPE2_inst : STARTUPE2
    generic map(
      PROG_USR      => "FALSE",
      SIM_CCLK_FREQ => 10.0
    )
    port map(
      CLK       => '0',
      GSR       => '0',
      GTS       => '0',
      KEYCLEARB => '0',
      PACK      => '0',
      USRCCLKO  => qspi_usrclk,
      USRCCLKTS => '0',
      USRDONEO  => '1',
      USRDONETS => '1'
    );

  -- Clocks: 27 / 40.5 / 81 / 270 MHz from the 50 MHz oscillator.
  clocks : entity work.clocking50mhz
    port map(
      clk_in   => clk_in,
      clock27  => clock27,
      clock41  => cpuclock,
      clock81p => pixelclock,
      clock162 => clock162,
      clock270 => clock270,
      clock200 => clock200_u,
      clock50  => clock50_u
    );

  -- Explicit global buffers: clock200 feeds the MIG's IDELAYCTRL (must be a BUFG,
  -- DRC PLIDC-9) and the Ethernet MAC; clock50 is the MAC/eth_vphy RMII clock.
  bufg200 : BUFG port map (I => clock200_u, O => clock200);
  bufg50  : BUFG port map (I => clock50_u,  O => clock50);

  ethphy0 : entity work.eth_vphy
    port map(
      clk50 => clock50, clkb => clock162,
      mac_txd => eth_txd_s, mac_txen => eth_txen_s, mac_rxd => eth_rxd_s, mac_rxdv => eth_rxdv_s,
      tx_avail => eth_tx_avail, tx_len => eth_tx_len, tx_raddr => eth_tx_raddr,
      tx_rdata => eth_tx_rdata, tx_pop => eth_tx_pop, tx_drops => eth_tx_drops,
      rx_free => eth_rx_free, rx_we => eth_rx_we, rx_waddr => eth_rx_waddr,
      rx_wdata => eth_rx_wdata, rx_push => eth_rx_push, rx_len_in => eth_rx_len
    );

  -- MIG reset: hold ~1.3 ms after configuration so its input clock is settled.
  process (clk_in) is
  begin
    if rising_edge(clk_in) then
      if mig_por /= x"FFFF" then
        mig_por <= mig_por + 1;
        mig_sys_rst_n <= '0';
      else
        mig_sys_rst_n <= '1';
      end if;
    end if;
  end process;

  mig0 : mig_ddr3
    port map(
      ddr3_dq => ddr3_dq, ddr3_dqs_p => ddr3_dqs_p, ddr3_dqs_n => ddr3_dqs_n,
      ddr3_addr => ddr3_addr, ddr3_ba => ddr3_ba, ddr3_ras_n => ddr3_ras_n,
      ddr3_cas_n => ddr3_cas_n, ddr3_we_n => ddr3_we_n, ddr3_reset_n => ddr3_reset_n,
      ddr3_ck_p => ddr3_ck_p, ddr3_ck_n => ddr3_ck_n, ddr3_cke => ddr3_cke,
      ddr3_dm => ddr3_dm, ddr3_odt => ddr3_odt,
      app_addr => app_addr, app_cmd => app_cmd, app_en => app_en,
      app_wdf_data => app_wdf_data, app_wdf_end => app_wdf_end, app_wdf_mask => app_wdf_mask,
      app_wdf_wren => app_wdf_wren, app_rd_data => app_rd_data, app_rd_data_end => open,
      app_rd_data_valid => app_rd_data_valid, app_rdy => app_rdy, app_wdf_rdy => app_wdf_rdy,
      app_sr_req => '0', app_ref_req => '0', app_zq_req => '0',
      app_sr_active => open, app_ref_ack => open, app_zq_ack => open,
      ui_clk => mig_ui_clk, ui_clk_sync_rst => mig_ui_rst, init_calib_complete => mig_calib,
      sys_clk_i => clock200,
      device_temp_i => fpga_temperature,   -- shared XADC (fpgatemp), MIG has none of its own
      sys_rst => mig_sys_rst_n
    );

  attic0 : entity work.ddr3_attic
    generic map(ATTIC_BITS => 26,          -- 64 MB once unlocked ($BFFFFFC <- 64) ...
                COMPAT_BITS => 23)         -- ... 8 MB + mirrors after reset, like a real MEGA65
    port map(
      cpuclk => pixelclock,                -- slow_devices runs on pixelclock (81 MHz)
      reset_n => reset_out,                -- CPU reset -> back to 8 MB
      ex_read => expansionram_read, ex_write => expansionram_write,
      ex_address => expansionram_address, ex_wdata => expansionram_wdata,
      ex_rdata => expansionram_rdata, ex_data_ready_toggle => expansionram_data_ready_toggle,
      ex_busy => expansionram_busy,
      ui_clk => mig_ui_clk, ui_rst => mig_ui_rst, init_calib_complete => mig_calib,
      app_addr => app_addr, app_cmd => app_cmd, app_en => app_en, app_rdy => app_rdy,
      app_wdf_data => app_wdf_data, app_wdf_end => app_wdf_end, app_wdf_wren => app_wdf_wren,
      app_wdf_mask => app_wdf_mask, app_wdf_rdy => app_wdf_rdy, app_rd_data => app_rd_data,
      app_rd_data_valid => app_rd_data_valid,
      cache_line => attic_cache_line, cache_line_addr => attic_cache_addr,
      cache_line_valid => attic_cache_valid,
      cache_next_toggle => attic_cache_inc, cache_prev_toggle => attic_cache_dec,
      calibrated => attic_calibrated
    );

  fpgatemp0 : entity work.fpgatemp
    generic map(DELAY_CYCLES => 480)
    port map(
      rst  => '0',
      clk  => cpuclock,
      temp => fpga_temperature);

  AUDIO_TONE : entity work.audio_out_test_tone
    generic map(
      fref => 50.0
    )
    port map(
      select_44100        => '0',
      ref_rst             => dvi_reset,
      ref_clk             => clk_in,
      pcm_rst             => pcm_rst,
      pcm_clk             => pcm_clk,
      pcm_clken           => pcm_clken,
      audio_left_slow     => audio_left_slow,
      audio_right_slow    => audio_right_slow,
      sample_ready_toggle => sample_ready_toggle,
      pcm_l               => pcm_l,
      pcm_r               => pcm_r
    );

  hdmi0 : entity work.vga_to_hdmi
    port map(
      select_44100 => '0',
      dvi     => dvi_select,
      vic     => std_logic_vector(to_unsigned(17, 8)), -- 576p50
      aspect  => "01",
      pix_rep => '0',
      vs_pol  => '1',
      hs_pol  => '1',

      vga_rst => dvi_reset,
      vga_clk => clock27,
      vga_vs  => v_vsync,
      vga_hs  => v_hdmi_hsync,
      vga_de  => hdmi_dataenable,
      vga_r   => std_logic_vector(v_red),
      vga_g   => std_logic_vector(v_green),
      vga_b   => std_logic_vector(v_blue),

      pcm_rst   => pcm_rst,
      pcm_clk   => pcm_clk,
      pcm_clken => pcm_clken,
      pcm_l     => pcm_l,
      pcm_r     => pcm_r,
      pcm_acr   => pcm_acr,
      pcm_n     => std_logic_vector(to_unsigned(6144, 20)),
      pcm_cts   => std_logic_vector(to_unsigned(27000, 20)),

      tmds => tmds
    );

  -- J11 polarity: channel 0 (blue, pins 3/9) and channel 2 (red, pins 1/7)
  -- have P on the Pmod P pin; channel 1 (green, pins 2/8) and the clock
  -- (pins 4/10) are swapped on the board, so send the complement.
  tmds_pin(0) <= tmds(0);
  tmds_pin(1) <= not tmds(1);
  tmds_pin(2) <= tmds(2);

  HDMI_CLK : entity work.serialiser_10to1_selectio
    port map(
      clk_x10 => clock270,
      d       => "1111100000",    -- inverted "0000011111"
      out_p   => tmds_clk_p,
      out_n   => tmds_clk_n
    );

  GEN_HDMI_DATA : for i in 0 to 2 generate
  begin
    HDMI_DATA : entity work.serialiser_10to1_selectio
      port map(
        clk_x10 => clock270,
        d       => tmds_pin(i),
        out_p   => tmds_data_p(i),
        out_n   => tmds_data_n(i)
      );
  end generate GEN_HDMI_DATA;

  -- DualShock2 pads (Katsumi Degawa / nand2mario IP), polled at ~61 Hz.
  ds_pad1 : controller_ds2
    generic map(FREQ => clock_frequency)
    port map(
      clk          => cpuclock,
      snes_buttons => pad1,
      ds_clk       => ds1_clk,
      ds_miso      => ds1_miso,
      ds_mosi      => ds1_mosi,
      ds_cs        => ds1_cs
    );

  ds_pad2 : controller_ds2
    generic map(FREQ => clock_frequency)
    port map(
      clk          => cpuclock,
      snes_buttons => pad2,
      ds_clk       => ds2_clk,
      ds_miso      => ds2_miso,
      ds_mosi      => ds2_mosi,
      ds_cs        => ds2_cs
    );

  -- SD card emulator on the internal SD bus; sectors served by the Rockchip.
  sdemu0 : entity work.sd_emu
    port map(
      clk => cpuclock,
      sd_cs_n => sd_cs_int, sd_sclk => sd_clk_int, sd_mosi => sd_mosi_int, sd_miso => emu_miso,
      rd_req => emu_rd_req, wr_req => emu_wr_req, req_lba => emu_lba, req_seq => emu_seq,
      rd_ready => emu_rd_ready, rd_error => emu_rd_error, wr_ack => emu_wr_ack,
      rbuf_addr => emu_rba, rbuf_data => emu_rbd,
      wbuf_we => emu_wbwe, wbuf_addr => emu_wba, wbuf_data => emu_wbd,
      inited => emu_inited, cmd_count => emu_ccnt, last_cmd => emu_lcmd
    );

  rkbridge0 : entity work.rk_bridge
    generic map(BIT_CLKS => 80)          -- 162 MHz / 2.025 Mbaud
    port map(
      clk => clock162, cpuclk => cpuclock,
      spi_sck => rk_sck, spi_cs_n => rk_cs_n, spi_mosi => rk_mosi, spi_miso => rk_miso,
      sd_rd_req => emu_rd_req, sd_wr_req => emu_wr_req, sd_lba => emu_lba, sd_seq => emu_seq,
      sd_inited => emu_inited, sd_cmd_cnt => emu_ccnt, sd_last_cmd => emu_lcmd,
      sd_rd_ready => emu_rd_ready, sd_rd_error => emu_rd_error, sd_wr_ack => emu_wr_ack,
      rbuf_addr => emu_rba, rbuf_data => emu_rbd,
      wbuf_we => emu_wbwe, wbuf_addr => emu_wba, wbuf_data => emu_wbd,
      mon_rx => mon_rx, mon_tx => uart_txd_int,
      matrix_col_idx => widget_idx, matrix_col => widget_col,
      joya => rk_joya, joyb => rk_joyb, ctrl => rk_ctrl,
      eth_tx_avail => eth_tx_avail, eth_tx_len => eth_tx_len, eth_tx_raddr => eth_tx_raddr,
      eth_tx_rdata => eth_tx_rdata, eth_tx_pop => eth_tx_pop, eth_tx_drops => eth_tx_drops,
      eth_rx_free => eth_rx_free, eth_rx_we => eth_rx_we, eth_rx_waddr => eth_rx_waddr,
      eth_rx_wdata => eth_rx_wdata, eth_rx_push => eth_rx_push, eth_rx_len => eth_rx_len,
      flash_active => rkfl_act, flash_sck => rkfl_sck, flash_cs_n => rkfl_cs_n,
      flash_mosi => rkfl_mosi, flash_miso => qspi_db(1),
      iprog_toggle => open, iprog_addr => open,   -- MEGA65: reboot via $D6C8..$D6CF
      spi_active => rk_active
    );

  -- Physical J12 card or the emulator (rk ctrl bit 3 = physical).
  sd_cs   <= sd_cs_int;
  sd_clk  <= sd_clk_int;
  sd_mosi <= sd_mosi_int;
  sd_miso_int <= emu_miso when rk_ctrl(3) = '0' else sd_miso;
  monitor_rx        <= mon_rx;
  widget_restore_n  <= not rk_ctrl(1);
  widget_capslock_n <= not rk_ctrl(2);

  slow_devices0 : entity work.slow_devices
    generic map(
      target => qmtechk325t
    )
    port map(
      cpuclock             => cpuclock,
      pixelclock           => pixelclock,
      reset                => reset_out,
      sector_buffer_mapped => sector_buffer_mapped,

      slow_access_request_toggle => slow_access_request_toggle,
      slow_access_ready_toggle   => slow_access_ready_toggle,
      slow_access_write          => slow_access_write,
      slow_access_address        => slow_access_address,
      slow_access_wdata          => slow_access_wdata,
      slow_access_rdata          => slow_access_rdata,

      expansionram_read              => expansionram_read,
      expansionram_write             => expansionram_write,
      expansionram_rdata             => expansionram_rdata,
      expansionram_wdata             => expansionram_wdata,
      expansionram_address           => expansionram_address,
      expansionram_data_ready_toggle => expansionram_data_ready_toggle,
      expansionram_busy              => expansionram_busy,

      cart_nmi   => 'Z',
      cart_irq   => 'Z',
      cart_dma   => 'Z',
      cart_exrom => 'Z',
      cart_ba    => cart_ba,
      cart_rw    => cart_rw,
      cart_roml  => cart_roml,
      cart_romh  => cart_romh,
      cart_io1   => cart_io1,
      cart_game  => 'Z',
      cart_io2   => cart_io2,
      cart_d_in  => (others => 'Z'),
      cart_a     => cart_a,
      -- as on R6: line + address, but slow_devices' own cache path stays off
      expansionram_current_cache_line         => attic_cache_line,
      expansionram_current_cache_line_address => attic_cache_addr
    );

  machine0 : entity work.machine
    generic map(
      cpu_frequency   => 40500000,
      target          => qmtechk325t,
      hyper_installed => false,
      chipram_size    => 1048576,      -- 1 MB (chipram_k325t.vhdl); 384 KB until $FFD71F0.0 = 1
      chipram_1mb     => '1',
      colour_ram_64k  => true          -- 64 KB colour RAM; 32 KB mirror until $FFD71F0.2 = 1
    )
    port map(
      pixelclock           => pixelclock,
      cpuclock             => cpuclock,
      uartclock            => cpuclock,
      clock162             => '0',
      clock200             => clock200,
      clock27              => clock27,
      clock50mhz           => clock50,
      no_hyppo             => '0',
      kbd_datestamp        => (others => '0'),
      kbd_commit           => (others => '0'),
      btncpureset          => btncpureset,
      reset_out            => reset_out,
      irq                  => irq,
      nmi                  => nmi,
      restore_key          => restore_key,
      cpu_exrom            => '1',
      cpu_game             => '1',
      sector_buffer_mapped => sector_buffer_mapped,
      fpga_temperature     => fpga_temperature,

      -- attic RAM CPU fast path
      slowram_cache_line            => attic_cache_line,
      slowram_cache_line_valid      => attic_cache_valid,
      slowram_cache_line_addr       => attic_cache_addr,
      slowram_cache_line_inc_toggle => attic_cache_inc,
      slowram_cache_line_dec_toggle => attic_cache_dec,

      qspi_clock => qspi_clock,
      qspicsn    => qspi_csn_m,
      qspidb     => qspi_db_out,
      qspidb_in  => qspi_db_in,
      qspidb_oe  => qspi_db_oe,

      audio_left  => audio_left,
      audio_right => audio_right,

      vsync           => v_vsync,
      hdmi_hsync      => v_hdmi_hsync,
      vgared          => v_red,
      vgagreen        => v_green,
      vgablue         => v_blue,
      hdmi_dataenable => hdmi_dataenable,

      slow_access_request_toggle => slow_access_request_toggle,
      slow_access_ready_toggle   => slow_access_ready_toggle,
      slow_access_address        => slow_access_address,
      slow_access_write          => slow_access_write,
      slow_access_wdata          => slow_access_wdata,
      slow_access_rdata          => slow_access_rdata,

      -- CIA1: no physical matrix; joysticks from the DS2 pads.
      porta_pins    => porta_pins,
      portb_pins    => portb_pins,
      caps_lock_key => '1',
      keyleft       => rk_ctrl(5),          -- cursor left / up keys from the Rockchip, as the
      keyup         => rk_ctrl(4),          -- MEGA65 keyboard's dedicated keys (active high)
      fa_fire       => fa_fire,
      fa_up         => fa_up,
      fa_left       => fa_left,
      fa_down       => fa_down,
      fa_right      => fa_right,
      fb_fire       => fb_fire,
      fb_up         => fb_up,
      fb_left       => fb_left,
      fb_down       => fb_down,
      fb_right      => fb_right,
      fa_potx       => '0',
      fa_poty       => '0',
      fb_potx       => '0',
      fb_poty       => '0',

      -- Internal SD card (bus #1) on J12.
      cs_bo  => sd_cs_int,
      sclk_o => sd_clk_int,
      mosi_o => sd_mosi_int,
      miso_i => sd_miso_int,

      -- Serial monitor (Rockchip UART).
      UART_TXD => uart_txd_int,
      RsRx     => monitor_rx,

      portp_out => portp,

      sw    => (others => '0'),
      dipsw => (others => '0'),
      btn   => (others => '1'),

      -- Not present on this board.
      iec_data_external => '1',
      iec_clk_external  => '1',
      iec_srq_external  => '1',
      iec_bus_active    => '0',
      miso2_i           => '1',
      f_index           => '1',
      f_track0          => '1',
      f_writeprotect    => '1',
      f_rdata           => '1',
      f_diskchanged     => '1',
      eth_rxd           => eth_rxd_s,
      eth_txd           => eth_txd_s,
      eth_txen          => eth_txen_s,
      eth_rxer          => '0',
      eth_rxdv          => eth_rxdv_s,
      eth_interrupt     => '0',
      aclMISO           => '1',
      aclInt1           => '1',
      aclInt2           => '1',
      tmpint            => '1',
      tmpct             => '1',
      micData0          => '1',
      micData1          => '1',
      buffereduart_ringindicate => (others => '0'),

      -- PS/2 keyboard.
      ps2data  => ps2data_s(2),
      ps2clock => ps2clk_s(2),

      widget_matrix_col_idx => widget_idx,
      widget_matrix_col => widget_col,
      widget_restore    => widget_restore_n,
      widget_capslock   => widget_capslock_n,
      widget_joya       => (others => '1'),
      widget_joyb       => (others => '1')
    );

  -- 1 kHz ACR pulse train from 12.288 MHz.
  process (pcm_clk) is
  begin
    if rising_edge(pcm_clk) then
      if acr_counter /= (12288 - 1) then
        acr_counter <= acr_counter + 1;
        pcm_acr     <= '0';
      else
        pcm_acr     <= '1';
        acr_counter <= 0;
      end if;
    end if;
  end process;

  process (cpuclock) is
  begin
    if rising_edge(cpuclock) then
      portp_drive <= portp;
      dvi_select  <= portp_drive(1);

      -- Input synchronisers.
      reset_s   <= reset_s(0) & reset_button;
      restore_s <= restore_s(0) & restore_btn;

      rk_ctrl_s   <= rk_ctrl;
      btncpureset <= reset_s(1) and not rk_ctrl_s(0);
      restore_key <= restore_s(1);

      if reset_s(1) = '1' then
        dvi_reset <= '0';
      end if;

      -- DS2 pad 1 -> joystick port 2 (most C64 games), pad 2 -> port 1.
      -- Fire = cross (B) or circle (A).  Rockchip joyA -> port 1, joyB ->
      -- port 2 (b0 up b1 down b2 left b3 right b4 fire).  Active low.
      fb_up    <= not (pad1(4) or rk_joyb(0));
      fb_down  <= not (pad1(5) or rk_joyb(1));
      fb_left  <= not (pad1(6) or rk_joyb(2));
      fb_right <= not (pad1(7) or rk_joyb(3));
      fb_fire  <= not (pad1(0) or pad1(8) or rk_joyb(4));
      fa_up    <= not (pad2(4) or rk_joya(0));
      fa_down  <= not (pad2(5) or rk_joya(1));
      fa_left  <= not (pad2(6) or rk_joya(2));
      fa_right <= not (pad2(7) or rk_joya(3));
      fa_fire  <= not (pad2(0) or pad2(8) or rk_joya(4));

      heartbeat <= heartbeat + 1;

      if audio_counter < to_integer(audio_counter_interval) then
        audio_counter <= audio_counter + 4;
      else
        audio_counter       <= audio_counter - to_integer(audio_counter_interval);
        sample_ready_toggle <= not sample_ready_toggle;
        audio_left_slow     <= h_audio_left;
        audio_right_slow    <= h_audio_right;
      end if;
    end if;
  end process;

  -- Configuration flash: the MEGA65's QSPI controller, or (during a Rockchip 0x50 frame)
  -- the bridge's x1 SPI pass-through (DQ0 = MOSI, DQ1 = MISO, DQ2/DQ3 = WP#/HOLD# high).
  qspi_usrclk <= rkfl_sck when rkfl_act = '1' else qspi_clock;
  qspi_csn    <= rkfl_cs_n when rkfl_act = '1' else qspi_csn_m;
  qspi_db     <= ('1', '1', 'Z', rkfl_mosi) when rkfl_act = '1' else
                 qspi_db_out when qspi_db_oe = '1' else "ZZZZ";
  qspi_db_in <= qspi_db;

  -- SD in SPI mode: DAT1/DAT2 unused, hold high.
  sd_dat1 <= '1';
  sd_dat2 <= '1';

  h_audio_right <= audio_right when portp_drive(7) = '0' else ((not audio_right(19)) & audio_right(18 downto 0));
  h_audio_left  <= audio_left  when portp_drive(7) = '0' else ((not audio_left (19)) & audio_left (18 downto 0));

  -- LED2: heartbeat, LED3: SYSCTL LED bit, LED4: DDR3 calibrated (attic RAM up).
  led(0) <= heartbeat(24);
  led(1) <= portp_drive(4);
  led(2) <= attic_calibrated;

end Behavioral;
