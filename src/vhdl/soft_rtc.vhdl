--------------------------------------------------------------------------------
-- soft_rtc.vhdl -- a battery-less real-time clock for boards without an RTC chip
-- (QMTech K325T CM4 carrier).  Presents the MEGA65 RTC registers ($FFD7110-$FFD7116, the
-- layout the ROM reads on the R3..R6 boards) and counts on its own: 1 Hz from the CPU clock,
-- BCD with carries through minutes, hours, day (month lengths, leap years 2000-2099), month
-- and year, plus the day of the week.  The Rockchip sets it from its network-synchronised
-- clock through the serial monitor (m65d), and programs may set it like a real RTC; a write
-- to the seconds restarts the sub-second counter, so a sync is exact to the clock tick.
--   $FFD7110 seconds  $FFD7111 minutes  $FFD7112 hours (bit 7 = 24 h mode, always set)
--   $FFD7113 day      $FFD7114 month    $FFD7115 year (20yy)  $FFD7116 day of week (0..6)
-- $FFD71F0 XCTL: K325T extension control, cleared by every reset (a real MEGA65 again):
--   bit 0 = 1 MB chip RAM for the CPU/DMA, bit 1 = raster DMA list on,
--   bit 2 = 64 KB colour RAM (VIC-IV, via xctl_out), bit 4 = fast RRB (VIC-IV paints
--   2 pixels per cycle), bit 5 = RRB list mode (LIST token $FFFC in CHR16 rows, see the lab
--   repo's docs/rrb_list_mode.md), bit 6 = RRB list mode v2 (global object table, below);
--   bit 7 = fast token path (VIC-IV, with bit 4: CHR16 text tokens pipelined, full-colour
--   glyph rows as two 32-bit chip RAM reads); bit 3 is unused here (24 extra sprites on
--   branch k325t-extra-sprites)
-- $FFD71F4-$FFD71F7: raster DMA list address (28 bits, little endian)
-- $FFD71F8-$FFD71FA: list mode v2 object table address in chip RAM (20 bits, little endian)
-- $FFD71FB: number of objects (0..255, 16 bytes each)
-- $FFD71FC: bit 0 = HOLD: the VIC-IV keeps its last snapshot of the table (no copy per frame)
-- (gs4510 snoops these writes and acts on them; the copies here are for reading back)
-- $FFD71E0-$FFD71E3: RRB list mode diagnostic counters (16-bit, in the VIC-IV, pixel clock):
--   $FFD71E0 write: select counter 0..31, read: the selected index
--   $FFD71E1 / $FFD71E2 read: low / high byte of the selected counter (synchronised copy; a
--     torn 16-bit read is possible: read until two reads agree; allow ~4 CPU cycles after a
--     select before reading)
--   $FFD71E3 write (any value): clear all counters and maxima (a toggle to the VIC-IV); reads 0
--   Counters saturate at $FFFF unless noted; unused indices read 0:
--    0 frames (table copy starts)            1 copies finished (copying falls)
--    2 expansions started                    3 expansions finished (done)
--    4 expander aborts                       5 line start in ListWait while the copy runs
--                                              (the kept first text row painted plainly)
--    6 v2 rows painted plainly: append point beyond LIMIT - 2 (full-row guard)
--    7 port collisions: expander read while the VIC-IV reads (must stay 0)
--    8 expansions ended by the buffer limit  9 object parts emitted (Gotox0; wraps)
--   10 max expansion duration (pixel cycles, start -> done; aborted ones not counted)
--   11 max copy duration (copy start -> copying falls)
--   12 copy stall cycles (bytes left to issue, port busy)
--   13 expansions of $FFFF rows (row_short)  14 line start during an expansion (abort)
--   15 expansions started with start_scan (v2, no LIST token)
--   16 max cycles from copy start to the first copy read
--   17 line start in ListWait (no copy running) in the edge where the ListWait arm decides:
--      the arm's assignment wins over the line start
--   18 line start in ListRun in the exp_done edge (ListRun's assignment wins)
--   19 expansions started while copying (must stay 0)
--   20 ycounter at the last copy end         21 ycounter at the last abort
--   22 line start in ListWait while copying, in the border-line branch (its FetchFirstCharacter
--      wins over the line start; also counted in 5)
--   23 late pixels: raster buffer writes at or left of the pixel the display reads in that
--      half, inside the text area (must stay 0)   24 ycounter at the last late pixel
--   25 max cycles line start -> end of the line's painting (EndOfChargen; a painting cut off
--      by the next line start counts the cycles it had)
--   26 max cycles line start -> first GOTOX of a list row's expanded part (its first object)
-- All other addresses of the $FFD71xx page read 0.  Until the first write it reads an
-- invalid date (day 0), which the ROM reports as "no RTC".
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity soft_rtc is
  generic ( clock_frequency : integer );
  port (
    clock        : in  std_logic;
    reset_n      : in  std_logic := '1';   -- CPU reset: clears XCTL
    cs           : in  std_logic;
    fastio_addr  : in  unsigned(19 downto 0);
    fastio_write : in  std_logic;
    fastio_read  : in  std_logic;
    fastio_wdata : in  unsigned(7 downto 0);
    fastio_rdata : out unsigned(7 downto 0);
    xctl_out     : out unsigned(7 downto 0);
    xobj_out     : out unsigned(28 downto 0);   -- list mode v2 (VIC-IV): hold & count & table
    diag_sel_out : out unsigned(4 downto 0);    -- list mode diagnostic counters (VIC-IV)
    diag_clr_out : out std_logic;               -- toggles on a write to $FFD71E3
    diag_val_in  : in  unsigned(15 downto 0) := (others => '0')   -- pixel clock domain
  );
end entity;

architecture rtl of soft_rtc is
  signal sec, min, hour : unsigned(7 downto 0) := x"00";       -- BCD
  signal day, month     : unsigned(7 downto 0) := x"00";       -- BCD; 0 = not set
  signal year           : unsigned(7 downto 0) := x"00";       -- BCD, 20yy
  signal dow            : unsigned(7 downto 0) := x"00";
  signal tick_cnt       : integer range 0 to clock_frequency - 1 := 0;
  signal xctl           : unsigned(7 downto 0) := x"00";       -- $FFD71F0
  constant XCTL_BITS    : unsigned(7 downto 0) := x"F7";       -- implemented bits (bit 3: see branch k325t-extra-sprites)
  type rdl_t is array (0 to 3) of unsigned(7 downto 0);
  signal rdma_list      : rdl_t := (others => x"00");          -- $FFD71F4-7
  signal obj_tab        : rdl_t := (others => x"00");          -- $FFD71F8-B (B: count)
  signal obj_hold       : std_logic := '0';                    -- $FFD71FC bit 0
  signal diag_sel       : unsigned(4 downto 0) := (others => '0');   -- $FFD71E0
  signal diag_clr_t     : std_logic := '0';                    -- toggled by $FFD71E3 writes
  signal diag_v1, diag_v2 : unsigned(15 downto 0) := (others => '0');   -- diag_val_in, synchronised

  -- BCD + 1 (no range check)
  function bcd_inc(v : unsigned(7 downto 0)) return unsigned is
  begin
    if v(3 downto 0) >= 9 then
      return (v(7 downto 4) + 1) & x"0";
    else
      return v + 1;
    end if;
  end function;

  function bcd_to_int(v : unsigned(7 downto 0)) return integer is
  begin
    return to_integer(v(7 downto 4)) * 10 + to_integer(v(3 downto 0));
  end function;

  function month_days(m, y : unsigned(7 downto 0)) return integer is
    variable mi : integer;
  begin
    mi := bcd_to_int(m);
    if mi = 2 then
      if bcd_to_int(y) mod 4 = 0 then return 29; else return 28; end if;
    elsif mi = 4 or mi = 6 or mi = 9 or mi = 11 then
      return 30;
    else
      return 31;
    end if;
  end function;
begin
  xctl_out <= xctl;
  xobj_out <= obj_hold & obj_tab(3) & obj_tab(2)(3 downto 0) & obj_tab(1) & obj_tab(0);
  diag_sel_out <= diag_sel;
  diag_clr_out <= diag_clr_t;

  -- reads: combinational onto the shared fastio bus, 'Z' when not selected
  process (cs, fastio_read, fastio_addr, sec, min, hour, day, month, year, dow, xctl, rdma_list, obj_tab, obj_hold, diag_sel, diag_v2) is
  begin
    if cs = '1' and fastio_read = '1' then
      case fastio_addr(7 downto 0) is
        when x"10" => fastio_rdata <= sec;
        when x"11" => fastio_rdata <= min;
        when x"12" => fastio_rdata <= "10" & hour(5 downto 0);   -- 24 h mode
        when x"13" => fastio_rdata <= day;
        when x"14" => fastio_rdata <= month;
        when x"15" => fastio_rdata <= year;
        when x"16" => fastio_rdata <= dow;
        when x"E0" => fastio_rdata <= "000" & diag_sel;
        when x"E1" => fastio_rdata <= diag_v2(7 downto 0);
        when x"E2" => fastio_rdata <= diag_v2(15 downto 8);
        when x"F0" => fastio_rdata <= xctl;
        when x"F4" => fastio_rdata <= rdma_list(0);
        when x"F5" => fastio_rdata <= rdma_list(1);
        when x"F6" => fastio_rdata <= rdma_list(2);
        when x"F7" => fastio_rdata <= rdma_list(3) and x"0F";
        when x"F8" => fastio_rdata <= obj_tab(0);
        when x"F9" => fastio_rdata <= obj_tab(1);
        when x"FA" => fastio_rdata <= obj_tab(2) and x"0F";
        when x"FB" => fastio_rdata <= obj_tab(3);
        when x"FC" => fastio_rdata <= "0000000" & obj_hold;
        when others => fastio_rdata <= x"00";
      end case;
    else
      fastio_rdata <= (others => 'Z');
    end if;
  end process;

  process (clock) is
    variable carry : boolean;
  begin
    if rising_edge(clock) then
      if reset_n = '0' then
        xctl <= x"00";
        obj_tab <= (others => x"00"); obj_hold <= '0';
      elsif cs = '1' and fastio_write = '1' and fastio_addr(7 downto 0) = x"F0" then
        xctl <= fastio_wdata and XCTL_BITS;
      elsif cs = '1' and fastio_write = '1' and fastio_addr(7 downto 2) = "111110" then
        obj_tab(to_integer(fastio_addr(1 downto 0))) <= fastio_wdata;
      elsif cs = '1' and fastio_write = '1' and fastio_addr(7 downto 0) = x"FC" then
        obj_hold <= fastio_wdata(0);
      end if;
      diag_v1 <= diag_val_in; diag_v2 <= diag_v1;
      if cs = '1' and fastio_write = '1' and fastio_addr(7 downto 0) = x"E0" then
        diag_sel <= fastio_wdata(4 downto 0);
      end if;
      if cs = '1' and fastio_write = '1' and fastio_addr(7 downto 0) = x"E3" then
        diag_clr_t <= not diag_clr_t;
      end if;
      if cs = '1' and fastio_write = '1' and fastio_addr(7 downto 2) = "111101" then
        rdma_list(to_integer(fastio_addr(1 downto 0))) <= fastio_wdata;
      end if;
      if cs = '1' and fastio_write = '1' then
        case fastio_addr(7 downto 0) is
          when x"10" => sec   <= fastio_wdata and x"7F"; tick_cnt <= 0;
          when x"11" => min   <= fastio_wdata and x"7F";
          when x"12" => hour  <= fastio_wdata and x"3F";
          when x"13" => day   <= fastio_wdata and x"3F";
          when x"14" => month <= fastio_wdata and x"1F";
          when x"15" => year  <= fastio_wdata;
          when x"16" => dow   <= fastio_wdata and x"07";
          when others => null;
        end case;
      elsif tick_cnt /= clock_frequency - 1 then
        tick_cnt <= tick_cnt + 1;
      else
        tick_cnt <= 0;
        if day /= x"00" then                       -- runs once it has been set
          carry := sec = x"59";
          if carry then sec <= x"00"; else sec <= bcd_inc(sec); end if;
          if carry then
            carry := min = x"59";
            if carry then min <= x"00"; else min <= bcd_inc(min); end if;
          end if;
          if carry then
            carry := hour(5 downto 0) = "100011";   -- 23
            if carry then hour <= x"00"; else hour <= bcd_inc(hour); end if;
          end if;
          if carry then
            if dow >= 6 then dow <= x"00"; else dow <= dow + 1; end if;
            carry := bcd_to_int(day) >= month_days(month, year);
            if carry then day <= x"01"; else day <= bcd_inc(day); end if;
          end if;
          if carry then
            carry := month = x"12";
            if carry then month <= x"01"; else month <= bcd_inc(month); end if;
          end if;
          if carry then
            if year = x"99" then year <= x"00"; else year <= bcd_inc(year); end if;
          end if;
        end if;
      end if;
    end if;
  end process;

end architecture;
