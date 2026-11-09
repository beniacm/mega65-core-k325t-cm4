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
--   glyph rows as two 32-bit chip RAM reads); bit 3 = unpainted pixels show as background (VIC-IV:
--   no stale raster buffer pixels, lines run to the full text width)
-- $FFD71F4-$FFD71F7: raster DMA list address (28 bits, little endian)
-- $FFD71F8-$FFD71FA: list mode v3 object table address in chip RAM (20 bits, little endian)
-- $FFD71FB: number of objects, low byte (a write also clears the high bits: 0..255 for old
--   programs; 32 bytes per entry, the VIC-IV reads bytes 0..15)
-- $FFD71FC: bit 0 = HOLD: the VIC-IV keeps its last snapshot of the table (no copy per frame)
-- $FFD71FD: read only, K325T extension level: 1 = everything up to XCTL bit 3, 2 = + the
--   collides-with mask (object +15) and the list mode expansion overlapping the painting,
--   3 = list mode v3 (32-byte entries, 1023 objects, per-row buckets, circle test, pair
--   budget, the $FFD7200 page)
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
-- $FFD7200-$FFD728C: list mode v3 collisions and table (docs/rrb_list_mode.md "v3 table"):
--   $FFD7200-$FFD727F read: collided objects 0..1023, byte n bit b = object 8n + b
--   $FFD7280 status / control: as $FFD71C0, + read bit 2 = the last pass was truncated by the
--     pair budget, bit 3 = the last bucket build dropped entries (more than 2048)
--   $FFD7282-$FFD7283 r/w: object number (10 bits; shared with $FFD71C1)
--   $FFD7284-$FFD7285 read: its first partner (lowest number, $3FF: none)
--   $FFD7286-$FFD7287 read: number of collided objects (0..1023)
--   $FFD7288-$FFD7289 r/w: pair budget per pass (0 = no limit)
--   $FFD728A-$FFD728B r/w: number of objects (10 bits; $FFD728A = $FFD71FB without clearing
--     the high bits)
--   $FFD728C read: K325T extension level (= $FFD71FD)
-- $FFD71A0-$FFD71C3: collisions of objects 0..255 (docs/rrb_list_mode.md "Collisions"), the
--   result of the VIC-IV's last pass over the frame's snapshot:
--   $FFD71A0-$FFD71BF read: collided objects, byte n bit b = object 8n + b
--   $FFD71C0 read: bit 0 a pass found a collision (latched), bit 1 IRQ enable, bit 7 IRQ
--     pending (set with bit 0); write: bit 1 = IRQ enable, bit 0 = 1 clears bits 0 and 7
--   $FFD71C1 r/w: object number (a write clears the high bits);  $FFD71C2 read: its first
--     partner (lowest number; $FF: none or above 255)
--   $FFD71C3 read: number of collided objects (255 if more)
--   IRQ: active while bit 7 and bit 1 are set (iomapper's IRQ, like the other peripherals)
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
    xobj_out     : out unsigned(30 downto 0);   -- list mode v3 (VIC-IV): hold & count & table
    col_budget_out : out unsigned(15 downto 0);  -- pair budget per collision pass
    diag_sel_out : out unsigned(4 downto 0);    -- list mode diagnostic counters (VIC-IV)
    diag_clr_out : out std_logic;               -- toggles on a write to $FFD71E3
    diag_val_in  : in  unsigned(15 downto 0) := (others => '0');  -- pixel clock domain
    -- list mode v2 collisions (VIC-IV, pixel clock): the last pass's result, stable between
    -- two toggles of col_toggle_in; copied into this clock domain on each toggle
    col_bits_in  : in  std_logic_vector(1023 downto 0) := (others => '0');
    col_count_in : in  unsigned(9 downto 0) := (others => '0');
    col_trunc_in : in  std_logic := '0';         -- (with col_bits_in)
    bk_full_in   : in  std_logic := '0';         -- (quasi static)
    col_toggle_in : in std_logic := '0';
    col_pidx_out : out unsigned(9 downto 0);
    col_pdata_in : in  unsigned(9 downto 0) := (others => '1');
    irq_n        : out std_logic := '1'          -- collision IRQ (active low, to the CPU)
  );
end entity;

architecture rtl of soft_rtc is
  signal sec, min, hour : unsigned(7 downto 0) := x"00";       -- BCD
  signal day, month     : unsigned(7 downto 0) := x"00";       -- BCD; 0 = not set
  signal year           : unsigned(7 downto 0) := x"00";       -- BCD, 20yy
  signal dow            : unsigned(7 downto 0) := x"00";
  signal tick_cnt       : integer range 0 to clock_frequency - 1 := 0;
  signal xctl           : unsigned(7 downto 0) := x"00";       -- $FFD71F0
  constant XCTL_BITS    : unsigned(7 downto 0) := x"FF";       -- implemented bits
  -- $FFD71FD: K325T extension level (1 = XCTL bits 0-7 incl. bit 3; 2 = + collides-with mask
  -- (+15) and the list mode expansion overlapping the painting, 2 KB list rows)
  -- 3 = list mode v3 (32-byte entries, 1023 objects, buckets, circles, budget, $FFD72xx)
  constant K325T_LEVEL  : unsigned(7 downto 0) := x"03";
  type rdl_t is array (0 to 3) of unsigned(7 downto 0);
  signal rdma_list      : rdl_t := (others => x"00");          -- $FFD71F4-7
  signal obj_tab        : rdl_t := (others => x"00");          -- $FFD71F8-B (B: count)
  signal obj_hold       : std_logic := '0';                    -- $FFD71FC bit 0
  signal obj_cnt_hi     : unsigned(1 downto 0) := "00";        -- $FFD728B bits 1..0
  signal col_budget     : unsigned(15 downto 0) := (others => '0');  -- $FFD7288-9
  signal cs71, cs72     : std_logic;                           -- the $FFD71xx / $FFD72xx page
  signal diag_sel       : unsigned(4 downto 0) := (others => '0');   -- $FFD71E0
  signal diag_clr_t     : std_logic := '0';                    -- toggled by $FFD71E3 writes
  signal diag_v1, diag_v2 : unsigned(15 downto 0) := (others => '0');   -- diag_val_in, synchronised
  -- collisions ($FFD71A0-$FFD71C3)
  signal col_ts         : std_logic_vector(2 downto 0) := "000";
  signal col_cbits      : std_logic_vector(1023 downto 0) := (others => '0');
  signal col_ccount     : unsigned(9 downto 0) := (others => '0');
  signal col_any, col_pend, col_irqen, col_ctr : std_logic := '0';
  signal bk_fs          : std_logic_vector(1 downto 0) := "00";
  signal col_pidx       : unsigned(9 downto 0) := (others => '0');

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
  xobj_out <= obj_hold & obj_cnt_hi & obj_tab(3) & obj_tab(2)(3 downto 0) & obj_tab(1) & obj_tab(0);
  col_budget_out <= col_budget;
  cs71 <= cs when fastio_addr(11 downto 8) = x"1" else '0';
  cs72 <= cs when fastio_addr(11 downto 8) = x"2" else '0';
  diag_sel_out <= diag_sel;
  diag_clr_out <= diag_clr_t;
  col_pidx_out <= col_pidx;
  irq_n <= not (col_pend and col_irqen);

  -- reads: combinational onto the shared fastio bus, 'Z' when not selected
  process (cs71, cs72, fastio_read, fastio_addr, sec, min, hour, day, month, year, dow, xctl, rdma_list, obj_tab, obj_hold, diag_sel, diag_v2,
           col_cbits, col_ccount, col_any, col_pend, col_irqen, col_pidx, col_pdata_in, col_ctr, bk_fs,
           col_budget, obj_cnt_hi) is
    variable n : integer range 0 to 31;
    variable m : integer range 0 to 127;
  begin
    if cs72 = '1' and fastio_read = '1' then
      m := to_integer(fastio_addr(6 downto 0));
      if fastio_addr(7) = '0' then
        fastio_rdata <= unsigned(col_cbits(8 * m + 7 downto 8 * m));
      else
        case fastio_addr(7 downto 0) is
          when x"80" => fastio_rdata <= col_pend & "000" & bk_fs(1) & col_ctr & col_irqen & col_any;
          when x"82" => fastio_rdata <= col_pidx(7 downto 0);
          when x"83" => fastio_rdata <= "000000" & col_pidx(9 downto 8);
          when x"84" =>
            if col_cbits(to_integer(col_pidx)) = '0' then fastio_rdata <= x"FF";
            else fastio_rdata <= col_pdata_in(7 downto 0); end if;
          when x"85" =>
            if col_cbits(to_integer(col_pidx)) = '0' then fastio_rdata <= x"03";
            else fastio_rdata <= "000000" & col_pdata_in(9 downto 8); end if;
          when x"86" => fastio_rdata <= col_ccount(7 downto 0);
          when x"87" => fastio_rdata <= "000000" & col_ccount(9 downto 8);
          when x"88" => fastio_rdata <= col_budget(7 downto 0);
          when x"89" => fastio_rdata <= col_budget(15 downto 8);
          when x"8A" => fastio_rdata <= obj_tab(3);
          when x"8B" => fastio_rdata <= "000000" & obj_cnt_hi;
          when x"8C" => fastio_rdata <= K325T_LEVEL;
          when others => fastio_rdata <= x"00";
        end case;
      end if;
    elsif cs71 = '1' and fastio_read = '1' then
      n := to_integer(fastio_addr(4 downto 0));
      case fastio_addr(7 downto 0) is
        when x"A0" | x"A1" | x"A2" | x"A3" | x"A4" | x"A5" | x"A6" | x"A7"
           | x"A8" | x"A9" | x"AA" | x"AB" | x"AC" | x"AD" | x"AE" | x"AF"
           | x"B0" | x"B1" | x"B2" | x"B3" | x"B4" | x"B5" | x"B6" | x"B7"
           | x"B8" | x"B9" | x"BA" | x"BB" | x"BC" | x"BD" | x"BE" | x"BF" =>
          fastio_rdata <= unsigned(col_cbits(8 * n + 7 downto 8 * n));
        when x"C0" => fastio_rdata <= col_pend & "00000" & col_irqen & col_any;
        when x"C1" => fastio_rdata <= col_pidx(7 downto 0);
        when x"C2" =>
          if col_cbits(to_integer(col_pidx)) = '0' or col_pdata_in(9 downto 8) /= "00" then
            fastio_rdata <= x"FF";
          else
            fastio_rdata <= col_pdata_in(7 downto 0);
          end if;
        when x"C3" =>
          if col_ccount > 255 then fastio_rdata <= x"FF";
          else fastio_rdata <= col_ccount(7 downto 0); end if;
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
        when x"FD" => fastio_rdata <= K325T_LEVEL;          -- feature level (read only)
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
        obj_tab <= (others => x"00"); obj_hold <= '0'; obj_cnt_hi <= "00";
        col_budget <= (others => '0');
      elsif cs71 = '1' and fastio_write = '1' and fastio_addr(7 downto 0) = x"F0" then
        xctl <= fastio_wdata and XCTL_BITS;
      elsif cs71 = '1' and fastio_write = '1' and fastio_addr(7 downto 2) = "111110" then
        obj_tab(to_integer(fastio_addr(1 downto 0))) <= fastio_wdata;
        if fastio_addr(1 downto 0) = "11" then obj_cnt_hi <= "00"; end if;   -- $FFD71FB
      elsif cs72 = '1' and fastio_write = '1' and fastio_addr(7 downto 0) = x"8A" then
        obj_tab(3) <= fastio_wdata;
      elsif cs72 = '1' and fastio_write = '1' and fastio_addr(7 downto 0) = x"8B" then
        obj_cnt_hi <= fastio_wdata(1 downto 0);
      elsif cs72 = '1' and fastio_write = '1' and fastio_addr(7 downto 0) = x"88" then
        col_budget(7 downto 0) <= fastio_wdata;
      elsif cs72 = '1' and fastio_write = '1' and fastio_addr(7 downto 0) = x"89" then
        col_budget(15 downto 8) <= fastio_wdata;
      elsif cs71 = '1' and fastio_write = '1' and fastio_addr(7 downto 0) = x"FC" then
        obj_hold <= fastio_wdata(0);
      end if;
      diag_v1 <= diag_val_in; diag_v2 <= diag_v1;
      -- collisions: a new result (the pixel-clock side toggles after copying it into its read
      -- buffer, which then stays stable for the rest of the frame)
      col_ts <= col_ts(1 downto 0) & col_toggle_in;
      if col_ts(2) /= col_ts(1) then
        col_cbits <= col_bits_in; col_ccount <= col_count_in; col_ctr <= col_trunc_in;
        if col_count_in /= 0 then
          col_any <= '1'; col_pend <= '1';
        end if;
      end if;
      bk_fs <= bk_fs(0) & bk_full_in;
      if (cs71 = '1' and fastio_write = '1' and fastio_addr(7 downto 0) = x"C0")
         or (cs72 = '1' and fastio_write = '1' and fastio_addr(7 downto 0) = x"80") then
        col_irqen <= fastio_wdata(1);
        if fastio_wdata(0) = '1' then
          col_any <= '0'; col_pend <= '0';
        end if;
      end if;
      if cs71 = '1' and fastio_write = '1' and fastio_addr(7 downto 0) = x"C1" then
        col_pidx <= "00" & fastio_wdata;
      end if;
      if cs72 = '1' and fastio_write = '1' and fastio_addr(7 downto 0) = x"82" then
        col_pidx(7 downto 0) <= fastio_wdata;
      end if;
      if cs72 = '1' and fastio_write = '1' and fastio_addr(7 downto 0) = x"83" then
        col_pidx(9 downto 8) <= fastio_wdata(1 downto 0);
      end if;
      if reset_n = '0' then
        col_irqen <= '0'; col_pend <= '0'; col_any <= '0';
      end if;
      if cs71 = '1' and fastio_write = '1' and fastio_addr(7 downto 0) = x"E0" then
        diag_sel <= fastio_wdata(4 downto 0);
      end if;
      if cs71 = '1' and fastio_write = '1' and fastio_addr(7 downto 0) = x"E3" then
        diag_clr_t <= not diag_clr_t;
      end if;
      if cs71 = '1' and fastio_write = '1' and fastio_addr(7 downto 2) = "111101" then
        rdma_list(to_integer(fastio_addr(1 downto 0))) <= fastio_wdata;
      end if;
      if cs71 = '1' and fastio_write = '1' then
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
