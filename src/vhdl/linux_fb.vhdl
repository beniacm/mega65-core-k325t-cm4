--------------------------------------------------------------------------------
-- linux_fb.vhdl -- the Rockchip's own picture as a second HDMI source (QMTech K325T).
--
-- The Rockchip outputs its display (720x576@50, 27 MHz) as BT1120 on the CM4 bus
-- (GPIO3_A6 = clock, 16 data lines; see rockchip/boot_dtb).  bt1120_video (from the
-- board bring-up) recovers RGB888 + data enable; this module stores it as RGB332 in its OWN
-- video buffer (720 x 576 x 8 bit = 414,720 bytes of block RAM) -- MEGA65 memory is never
-- touched -- and, when show_linux = '1', replaces the core's picture with that buffer at the
-- input of the HDMI encoder.  The output timing is always the core's own (576p50 from
-- clock27), so switching is seamless (no monitor resync); the Rockchip frame is written
-- asynchronously (a slow tear line is possible).
--
-- Frame start on both sides: data enable low for longer than one line (= vertical blank),
-- independent of the sync polarities.  The input is cropped per line to WIDTH x HEIGHT, so any
-- Rockchip mode works (e.g. 1280x720 shows its top-left 720x576).  The core's signals are
-- delayed by one clock27 cycle (the buffer's read latency); sync is delayed with them, so the
-- picture does not move.
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
library unisim;
use unisim.vcomponents.all;

entity linux_fb is
  generic ( WIDTH : integer := 720; HEIGHT : integer := 576 );
  port (
    -- BT1120 from the Rockchip
    bt_clk     : in  std_logic;                       -- 27 or 74.25 MHz (already on a BUFG)
    bt_d       : in  std_logic_vector(15 downto 0);
    -- the core's picture (clock27 domain, into vga_to_hdmi)
    clk27      : in  std_logic;
    show_linux : in  std_logic;                       -- any clock (static); synchronised here
    cap_rise   : in  std_logic := '0';                -- any clock (static): '1' = sample the BT1120
                                                      -- data on the rising clock edge, else falling
    diag       : out std_logic_vector(31 downto 0);   -- bt_clk domain, read as quasi-static:
                                                      -- frames(8) | lines(12) | flags(4) | px/line(11:4)
    diag2      : out std_logic_vector(63 downto 0);   -- raw bus, per 2^20 bt_clk window: lines seen
                                                      -- high(16) | lines seen low(16) | FF on low
                                                      -- byte(8) | FF on high byte(8) | clock count(16)
    in_de, in_hs, in_vs : in std_logic;
    in_r, in_g, in_b    : in unsigned(7 downto 0);
    out_de, out_hs, out_vs : out std_logic;
    out_r, out_g, out_b    : out unsigned(7 downto 0);
    linux_locked : out std_logic                      -- bt1120_video saw frames recently
  );
end entity;

architecture rtl of linux_fb is
  constant PIXELS : integer := WIDTH * HEIGHT;
  type fb_t is array (0 to PIXELS - 1) of std_logic_vector(7 downto 0);
  shared variable fb : fb_t;

  -- RGB332 -> 8 bits per channel (bit replication).  Written as functions with a typed
  -- result: a bare "a & b" inside unsigned() would be ambiguous next to fb_t's implicit "&".
  function exp3(v : std_logic_vector(2 downto 0)) return unsigned is
    variable r : unsigned(7 downto 0);
  begin
    r := unsigned(v) & unsigned(v) & unsigned(v(2 downto 1));
    return r;
  end function;
  function exp2(v : std_logic_vector(1 downto 0)) return unsigned is
    variable r : unsigned(7 downto 0);
  begin
    r := unsigned(v) & unsigned(v) & unsigned(v) & unsigned(v);
    return r;
  end function;

  component bt1120_video is
    port (pclk : in std_logic; rst_n : in std_logic; bt_d : in std_logic_vector(15 downto 0);
          rgb : out std_logic_vector(23 downto 0); de : out std_logic;
          hsync : out std_logic; vsync : out std_logic;
          locked : out std_logic; yc_swapped : out std_logic);
  end component;

  attribute ASYNC_REG : string;

  -- write side (bt_clk)
  signal bt_q     : std_logic_vector(15 downto 0) := (others => '0');
  signal rgb      : std_logic_vector(23 downto 0);
  signal de_w     : std_logic;
  signal wblank   : integer range 0 to 4095 := 0;
  signal wx       : integer range 0 to 4095 := 0;       -- pixel in the current line
  signal wy       : integer range 0 to 4095 := 0;       -- line in the current frame
  signal wrow     : integer range 0 to PIXELS := 0;     -- wy * WIDTH, kept by adding
  signal de_d     : std_logic := '0';
  signal we1      : std_logic := '0';                   -- registered write (74 MHz timing)
  signal wa1      : integer range 0 to PIXELS - 1 := 0;
  signal wd1      : std_logic_vector(7 downto 0) := x"00";
  signal bt_r, bt_f : std_logic_vector(15 downto 0);   -- IDDR: rising / falling edge samples
  signal rise_s   : std_logic_vector(1 downto 0) := "00";
  signal frames   : unsigned(7 downto 0) := x"00";
  signal lines_l  : unsigned(11 downto 0) := (others => '0');   -- lines of the last frame
  signal px_l     : unsigned(11 downto 0) := (others => '0');   -- pixels of the last line
  signal seen_de  : std_logic := '0';
  signal lock_i, swap_i : std_logic;
  signal win      : unsigned(19 downto 0) := (others => '0');
  signal clkcnt   : unsigned(31 downto 0) := (others => '0');
  signal acc_hi, acc_lo, seen_hi, seen_lo : std_logic_vector(15 downto 0) := (others => '0');
  signal ffl, ffh, ffl_l, ffh_l : unsigned(7 downto 0) := x"00";
  attribute ASYNC_REG of rise_s : signal is "TRUE";

  -- read side (clk27)
  signal raddr    : integer range 0 to PIXELS - 1 := 0;
  signal rblank   : integer range 0 to 4095 := 0;
  signal rdata    : std_logic_vector(7 downto 0) := x"00";
  signal sel_s    : std_logic_vector(1 downto 0) := "00";
  signal d_de, d_hs, d_vs : std_logic := '0';
  signal d_r, d_g, d_b    : unsigned(7 downto 0) := x"00";
  attribute ASYNC_REG of sel_s : signal is "TRUE";
begin
  -- capture both edges in the IOB (IDDR); the bring-up design sampled on the falling edge
  -- (mid-eye with its MMCM-deskewed clock).  Here the clock comes over a fabric route without
  -- an MMCM, so the edge is selectable at run time (rk_bridge VIDEO bit 1).
  cap : for i in 0 to 15 generate
    iddr_i : IDDR
      generic map (DDR_CLK_EDGE => "SAME_EDGE_PIPELINED", INIT_Q1 => '0', INIT_Q2 => '0', SRTYPE => "SYNC")
      port map (Q1 => bt_r(i), Q2 => bt_f(i), C => bt_clk, CE => '1', D => bt_d(i), R => '0', S => '0');
  end generate;
  process (bt_clk) begin
    if rising_edge(bt_clk) then
      rise_s <= rise_s(0) & cap_rise;
      if rise_s(1) = '1' then bt_q <= bt_r; else bt_q <= bt_f; end if;
    end if;
  end process;

  -- raw bus statistics (diagnosis of the BT1120 wiring): which lines toggle, how often a
  -- TRS-like FF byte appears on either byte lane, and a clock counter for the frequency
  process (bt_clk) begin
    if rising_edge(bt_clk) then
      clkcnt <= clkcnt + 1;
      win <= win + 1;
      if win = 0 then
        seen_hi <= acc_hi; seen_lo <= acc_lo; ffl_l <= ffl; ffh_l <= ffh;
        acc_hi <= bt_q; acc_lo <= not bt_q; ffl <= x"00"; ffh <= x"00";
      else
        acc_hi <= acc_hi or bt_q; acc_lo <= acc_lo or not bt_q;
        if bt_q(7 downto 0) = x"FF" and ffl /= x"FF" then ffl <= ffl + 1; end if;
        if bt_q(15 downto 8) = x"FF" and ffh /= x"FF" then ffh <= ffh + 1; end if;
      end if;
    end if;
  end process;
  diag2 <= seen_hi & seen_lo & std_logic_vector(ffl_l) & std_logic_vector(ffh_l)
           & std_logic_vector(clkcnt(31 downto 16));

  video0 : bt1120_video
    port map (pclk => bt_clk, rst_n => '1', bt_d => bt_q, rgb => rgb, de => de_w,
              hsync => open, vsync => open, locked => lock_i, yc_swapped => swap_i);
  linux_locked <= lock_i;
  diag <= std_logic_vector(frames) & std_logic_vector(lines_l) & rise_s(1) & seen_de & swap_i & lock_i
          & std_logic_vector(px_l(11 downto 4));

  -- write: RGB332 into the buffer, cropped to WIDTH x HEIGHT; a new line starts with each
  -- data-enable run, a new frame after a long data-enable gap (vertical blank)
  process (bt_clk) begin
    if rising_edge(bt_clk) then
      de_d <= de_w;
      we1 <= '0';
      if de_w = '1' then
        wblank <= 0;
        seen_de <= '1';
        if wx < WIDTH and wy < HEIGHT then
          we1 <= '1';
          wa1 <= wrow + wx;
          wd1 <= rgb(23 downto 21) & rgb(15 downto 13) & rgb(7 downto 6);
        end if;
        if wx /= 4095 then wx <= wx + 1; end if;
      else
        wx <= 0;
        if de_d = '1' then                                  -- end of a line
          px_l <= to_unsigned(wx, 12);
          if wy /= 4095 then wy <= wy + 1; end if;
          if wy < HEIGHT then wrow <= wrow + WIDTH; end if;
        end if;
        if wblank /= 4095 then wblank <= wblank + 1; end if;
        if wblank > 3000 then wy <= 0; wrow <= 0; end if;   -- > 2 lines without data: vblank
        if wblank = 3001 then                               -- once per frame
          frames <= frames + 1;
          lines_l <= to_unsigned(wy, 12);
        end if;
      end if;
      if we1 = '1' then
        fb(wa1) := wd1;
      end if;
    end if;
  end process;

  -- read + switch (clock27)
  process (clk27)
    variable px : std_logic_vector(7 downto 0);
  begin
    if rising_edge(clk27) then
      sel_s <= sel_s(0) & show_linux;
      rdata <= fb(raddr);
      if in_de = '1' then
        rblank <= 0;
        if raddr < PIXELS - 1 then raddr <= raddr + 1; end if;
      else
        if rblank /= 4095 then rblank <= rblank + 1; end if;
        if rblank > 2000 then raddr <= 0; end if;
      end if;
      -- one-cycle delay of the core's picture = the buffer's read latency
      d_de <= in_de; d_hs <= in_hs; d_vs <= in_vs;
      d_r <= in_r; d_g <= in_g; d_b <= in_b;
    end if;
  end process;

  out_de <= d_de; out_hs <= d_hs; out_vs <= d_vs;
  out_r <= exp3(rdata(7 downto 5)) when sel_s(1) = '1' else d_r;
  out_g <= exp3(rdata(4 downto 2)) when sel_s(1) = '1' else d_g;
  out_b <= exp2(rdata(1 downto 0)) when sel_s(1) = '1' else d_b;
end architecture;
