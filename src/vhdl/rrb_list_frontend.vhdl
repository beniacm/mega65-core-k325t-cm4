--------------------------------------------------------------------------------
-- rrb_list_frontend.vhdl -- the parts of the K325T RRB list mode (docs/rrb_list_mode.md in the
-- lab repository) that live beside the VIC-IV's raster FSM rather than in it, moved out of
-- viciv.vhdl unchanged (a pure refactor: same registers, same cycles):
--   * the raster line buffer itself (K325T step 7): four banks by pixel x mod 4, so a painting
--     cycle can write 1, 2 (fast RRB) or 4 adjacent pixels (4 px painting, XCTL2 bit 0) at any
--     alignment; the display reads one pixel per read cycle, as before (one cycle latency);
--   * XCTL bit 3: one valid bit per raster buffer pixel (both halves, all banks), set by every
--     raster buffer write, cleared for the write half after the line start; the display reads
--     the bit with the pixel (cu_vq);
--   * the colour row buffer of list rows (cbuf: the row's own colour bytes copied during the
--     badline fetch, the expander's colour bytes), read like colour RAM at the painter's colour
--     address; and the expander's write frontier one cycle later for the fast token decoder;
--   * the diagnostic counters ($FFD71E0-E3 via soft_rtc; observation only).
-- What stays in viciv.vhdl: the list mode states and branches of the raster FSM (ListWait,
-- ListRun, FrontWait, the fast token decoder, the list mode lead rl_shift/rl_shift2), which are
-- arms of upstream's FSM process; the expander instance (rrb_list_expander.vhdl).  The FSM
-- states the counters need come in as decoded bits (st_*, vic_reads).
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity rrb_list_frontend is
  generic ( LIMIT : integer := 2044 );           -- row buffer limit of the expansion
  port (
    clk              : in  std_logic;            -- the VIC-IV pixel clock
    -- raster buffer: the painter's write (address = the LAST pixel written; 1 pixel, rb_double:
    -- 2 pixels at wa-1 (data 1) and wa (data 2), rb_quad: 4 pixels at wa-3 .. wa (data 1..4)),
    -- the display's read address (next cycle's), the pixel it reads
    rb_wa            : in  unsigned(10 downto 0);
    rb_write, rb_write2, rb_write3, rb_write4 : in std_logic;
    rb_wd1, rb_wd2, rb_wd3, rb_wd4 : in unsigned(17 downto 0);
    rb_double, rb_quad : in std_logic;
    rb_raddr_next    : in  unsigned(10 downto 0);
    rb_rdata         : out unsigned(17 downto 0);
    -- XCTL bit 3: clear, the valid bit of the pixel read
    cu_clr           : in  std_logic;
    cu_clr_half      : in  std_logic;
    cu_vq            : out std_logic := '1';
    -- colour row buffer
    exp_busy         : in  std_logic;
    exp_wpos         : in  unsigned(10 downto 0);
    exp_wpos_d       : out unsigned(10 downto 0) := (others => '0');
    cc_v1            : in  std_logic;
    cc_i1            : in  unsigned(10 downto 0);
    colourramdata_ram : in unsigned(7 downto 0);
    exp_bwe          : in  std_logic;
    exp_baddr        : in  unsigned(10 downto 0);
    exp_bcolour      : in  unsigned(7 downto 0);
    colourramaddress : in  unsigned(15 downto 0);
    row_col_start    : in  unsigned(15 downto 0);
    row_list         : in  std_logic;
    cbuf_dout        : out unsigned(7 downto 0) := x"00";
    cbuf_sel         : out std_logic := '0';
    -- diagnostic counters: events and states of the VIC-IV and the expander
    is_fetch_start, last_was_fetch_start : in std_logic;
    st_listwait, st_listrun, st_eoc, st_dispatch : in std_logic;   -- raster_fetch_state =
    vic_reads        : in  std_logic;            -- the VIC-IV reads chip RAM in this state
    row_fetch        : in  std_logic;            -- this_ramaccess_is_screen_row_fetch
    list_wait0       : in  std_logic;            -- list_wait = 0
    exp_copy_start, exp_copying, exp_start, exp_done, exp_abort, exp_mreq : in std_logic;
    exp_ovf, exp_part, exp_cstall, exp_start_scan, expanding : in std_logic;
    list_found, rv2, row_ff, row_short : in std_logic;
    list_pos, row_end_pos : in unsigned(10 downto 0);
    before_y_chargen_start, justbefore_y_chargen_start : in std_logic;
    rb_ra            : in  unsigned(10 downto 0); -- raster buffer read address
    chargen_active   : in  std_logic;
    xcounter         : in  unsigned(13 downto 0);
    ycounter         : in  unsigned(11 downto 0);
    paint_ready, glyph_goto, list_in_exp, list_save_armed : in std_logic;
    diag_sel         : in  unsigned(4 downto 0);
    diag_clr         : in  std_logic;
    diag_val         : out unsigned(15 downto 0) := (others => '0')
  );
end entity;

architecture rtl of rrb_list_frontend is
  constant display_fetch_start : unsigned(11 downto 0) := to_unsigned(719, 12);   -- as viciv
  -- raster buffer: four banks (pixel x mod 4) of 2 halves x 256 pixels
  type rbank_t is array (0 to 511) of unsigned(17 downto 0);
  type rbanks_t is array (0 to 3) of rbank_t;
  signal rbank : rbanks_t;
  attribute ram_style : string;
  attribute ram_style of rbank : signal is "block";
  type rba_t is array (0 to 3) of unsigned(8 downto 0);
  type rbd_t is array (0 to 3) of unsigned(17 downto 0);
  signal rb_a : rba_t;                                  -- per bank: write address
  signal rb_d : rbd_t;                                  -- per bank: write data
  signal rb_we : std_logic_vector(3 downto 0);          -- per bank: write enable
  signal rb_q : rbd_t := (others => (others => '0'));   -- per bank: read data
  signal rb_rsel : unsigned(1 downto 0) := "00";
  -- XCTL bit 3 valid bits, per bank (index bit 8 = the buffer half)
  type cuv_t is array (0 to 3) of std_logic_vector(511 downto 0);
  signal cu_v : cuv_t := (others => (others => '0'));
  signal cu_we : std_logic_vector(3 downto 0) := (others => '0');
  signal cu_a : rba_t := (others => (others => '0'));
  -- colour row buffer
  type cbuf_t is array (0 to 2047) of unsigned(7 downto 0);
  signal cbuf           : cbuf_t := (others => x"00");
  -- list mode diagnostic counters (indices: soft_rtc.vhdl header, docs/rrb_list_mode.md)
  constant DG_FRAMES     : integer := 0;   -- exp_copy_start pulses
  constant DG_COPY_DONE  : integer := 1;   -- falling edges of exp_copying
  constant DG_EXP_START  : integer := 2;   -- exp_start pulses
  constant DG_EXP_DONE   : integer := 3;   -- exp_done pulses
  constant DG_EXP_ABORT  : integer := 4;   -- exp_abort pulses
  constant DG_WAIT_LOST  : integer := 5;   -- line start in ListWait while the copy runs
  constant DG_ROW_FULL   : integer := 6;   -- v2 row painted plainly: append point > LIMIT - 2
  constant DG_COLLIDE    : integer := 7;   -- exp_mreq while the VIC-IV reads (must stay 0)
  constant DG_OVF        : integer := 8;   -- expansion ended by the buffer limit
  constant DG_PARTS      : integer := 9;   -- object parts emitted (Gotox0), wraps
  constant DG_EXP_MAX    : integer := 10;  -- max expansion duration (pixel cycles)
  constant DG_COPY_MAX   : integer := 11;  -- max copy duration (pixel cycles)
  constant DG_STALL      : integer := 12;  -- copy stall cycles
  constant DG_SHORT      : integer := 13;  -- expansions of $FFFF rows (row_short)
  constant DG_LINE_ABORT : integer := 14;  -- line start while expanding, no exp_done
  constant DG_SCAN_START : integer := 15;  -- expansions started with start_scan
  constant DG_FIRST_MAX  : integer := 16;  -- max cycles copy start -> first copy read
  constant DG_WAIT_RACE  : integer := 17;  -- line start in ListWait (no copy) that the arm overrides
  constant DG_RUN_RACE   : integer := 18;  -- line start in ListRun with exp_done (arm overrides)
  constant DG_START_CP   : integer := 19;  -- exp_start while exp_copying (must stay 0)
  constant DG_COPY_Y     : integer := 20;  -- ycounter at the last copy end
  constant DG_ABORT_Y    : integer := 21;  -- ycounter at the last abort
  constant DG_WAIT_BORDER : integer := 22; -- line start in ListWait, copying, border-line branch
  constant DG_LATE       : integer := 23;  -- raster buffer write behind the display (late pixel)
  constant DG_LATE_Y     : integer := 24;  -- ycounter at the last late write
  constant DG_PAINT_MAX  : integer := 25;  -- max cycles line start -> EndOfChargen (RRB time used)
  constant DG_OBJ_MAX    : integer := 26;  -- max cycles line start -> first GOTOX of the expanded part
  type diag_cnt_t is array (0 to 31) of unsigned(15 downto 0);
  signal dg_cnt         : diag_cnt_t := (others => (others => '0'));
  signal dg_ev          : std_logic_vector(31 downto 0) := (others => '0');   -- events, registered
  signal dg_sel1, dg_sel2 : unsigned(4 downto 0) := (others => '0');
  signal dg_clr_s       : std_logic_vector(2 downto 0) := "000";
  signal dg_copying_d   : std_logic := '0';
  signal dg_exp_run, dg_cp_run, dg_first_pend : std_logic := '0';
  signal dg_exp_t, dg_cp_t : unsigned(15 downto 0) := (others => '0');
  signal dg_ycounter    : unsigned(11 downto 0) := (others => '0');
  signal dg_line_t      : unsigned(15 downto 0) := (others => '0');   -- cycles since the line start
  signal dg_paint_run, dg_obj_pend : std_logic := '0';
begin
  -- raster buffer write: n = 1, 2 or 4 adjacent pixels ending at rb_wa (pixel k of n at
  -- x = rb_wa - (n - 1) + k, within the half of rb_wa(10)); n adjacent pixels are in n different
  -- banks.  For each bank: the pixel that falls into it, if any.
  process (rb_wa, rb_write, rb_write2, rb_write3, rb_write4, rb_wd1, rb_wd2, rb_wd3, rb_wd4,
           rb_double, rb_quad)
    variable n, k : integer range 0 to 7;
    variable x0, x : unsigned(9 downto 0);
    type wv_t is array (0 to 3) of std_logic;
    variable w : wv_t;
    variable d : rbd_t;
  begin
    if rb_quad = '1' then
      n := 4; w := (rb_write, rb_write2, rb_write3, rb_write4); d := (rb_wd1, rb_wd2, rb_wd3, rb_wd4);
    elsif rb_double = '1' then
      n := 2; w := (rb_write, rb_write2, '0', '0'); d := (rb_wd1, rb_wd2, rb_wd1, rb_wd1);
    else
      n := 1; w := (rb_write, '0', '0', '0'); d := (rb_wd1, rb_wd1, rb_wd1, rb_wd1);
    end if;
    x0 := rb_wa(9 downto 0) - to_unsigned(n - 1, 10);
    for b in 0 to 3 loop
      k := to_integer(to_unsigned(b, 2) - x0(1 downto 0));   -- (b - x0) mod 4
      x := x0 + to_unsigned(k, 10);
      rb_a(b) <= rb_wa(10) & x(9 downto 2);
      rb_d(b) <= d(k);
      if k < n then rb_we(b) <= w(k); else rb_we(b) <= '0'; end if;
    end loop;
  end process;
  banks: for b in 0 to 3 generate
    process (clk) begin
      if rising_edge(clk) then
        if rb_we(b) = '1' then
          rbank(b)(to_integer(rb_a(b))) <= rb_d(b);
        end if;
        rb_q(b) <= rbank(b)(to_integer(rb_raddr_next(10) & rb_raddr_next(9 downto 2)));
      end if;
    end process;
  end generate;
  process (clk) begin
    if rising_edge(clk) then rb_rsel <= rb_raddr_next(1 downto 0); end if;
  end process;
  rb_rdata <= rb_q(to_integer(rb_rsel));

  -- K325T XCTL bit 3: valid bits of the raster buffer (see cu_s)
  process (clk)
    variable vb : std_logic;
  begin
    if rising_edge(clk) then
      for b in 0 to 3 loop
        cu_we(b) <= rb_we(b); cu_a(b) <= rb_a(b);
      end loop;
      if cu_clr = '1' then                       -- bit 8 of the index is the buffer half
        for b in 0 to 3 loop
          if cu_clr_half = '0' then cu_v(b)(255 downto 0) <= (others => '0');
          else cu_v(b)(511 downto 256) <= (others => '0'); end if;
        end loop;
      end if;
      for b in 0 to 3 loop
        if cu_we(b) = '1' then cu_v(b)(to_integer(cu_a(b))) <= '1'; end if;
      end loop;
      -- with the pixel the display reads (same address and latency as the buffer's read port)
      vb := cu_v(to_integer(rb_raddr_next(1 downto 0)))(to_integer(rb_raddr_next(10) & rb_raddr_next(9 downto 2)));
      cu_vq <= vb;
    end if;
  end process;

  -- colour row buffer: written by the expander, read like colour RAM (one cycle) at the row
  -- index of the painter's colour RAM address; selected for the expanded part of a list row
  process (clk)
    variable d : unsigned(15 downto 0);
  begin
    if rising_edge(clk) then
      if exp_busy = '1' then exp_wpos_d <= exp_wpos; else exp_wpos_d <= (others => '0'); end if;
      if cc_v1 = '1' then
        cbuf(to_integer(cc_i1)) <= colourramdata_ram;   -- the row's own colour bytes (fetch)
      elsif exp_bwe = '1' then
        cbuf(to_integer(exp_baddr)) <= exp_bcolour;
      end if;
      d := colourramaddress - row_col_start;
      cbuf_dout <= cbuf(to_integer(d(10 downto 0)));
      if row_list = '1' and d(15 downto 11) = "00000" then
        cbuf_sel <= '1';
      else
        cbuf_sel <= '0';
      end if;
    end if;
  end process;

  -- K325T list mode diagnostic counters (read at $FFD71E0-3 via soft_rtc).  Stage 1 registers
  -- one bit per event (dg_ev); stage 2 counts them (16 bits, saturating at $FFFF, except the
  -- parts counter, which wraps) and keeps the maxima.  diag_clr is a toggle from the CPU clock
  -- domain (two flip-flops, then an edge detect); diag_sel is registered twice, diag_val once.
  -- Observation only: nothing here feeds back into the VIC-IV or the expander.
  process (clk)
    variable fs, rd : boolean;
    variable ev : std_logic_vector(31 downto 0);
    variable lo : unsigned(9 downto 0);
  begin
    if rising_edge(clk) then
      -- stage 1: events of this cycle
      fs := is_fetch_start = '1' and last_was_fetch_start = '0';     -- the line start pulse
      rd := vic_reads = '1';                     -- the VIC-IV reads chip RAM in this state
      ev := (others => '0');
      ev(DG_FRAMES) := exp_copy_start;
      if dg_copying_d = '1' and exp_copying = '0' then ev(DG_COPY_DONE) := '1'; end if;
      ev(DG_EXP_START) := exp_start;
      ev(DG_EXP_DONE) := exp_done;
      ev(DG_EXP_ABORT) := exp_abort;
      if fs and st_listwait = '1' and exp_copying = '1' then
        ev(DG_WAIT_LOST) := '1';
      end if;
      -- the ListWait arm's last branch (to FetchFirstCharacter) with v2 on: no LIST token and
      -- the append point ($FFFF position or row end) beyond LIMIT - 2
      if st_listwait = '1' and list_wait0 = '1' and exp_copying = '0'
         and list_found = '0' and rv2 = '1'
         and ((row_ff = '1' and list_pos > to_unsigned(LIMIT - 2, 11))
              or (row_ff = '0' and (row_end_pos(10) = '1'
                                    or row_end_pos > to_unsigned(LIMIT - 2, 11)))) then
        ev(DG_ROW_FULL) := '1';
      end if;
      if exp_mreq = '1' and (row_fetch = '1' or rd) then
        ev(DG_COLLIDE) := '1';
      end if;
      ev(DG_OVF) := exp_ovf;
      ev(DG_PARTS) := exp_part;
      ev(DG_STALL) := exp_cstall;
      ev(DG_SHORT) := exp_start and row_short;
      if fs and expanding = '1' and exp_done = '0' then ev(DG_LINE_ABORT) := '1'; end if;
      ev(DG_SCAN_START) := exp_start and exp_start_scan;
      -- a line start in ListWait / ListRun where the state's case arm assigns a state in the
      -- same edge (the case comes after the line start code, so it wins): ListWait deciding
      -- (no copy running), ListWait's border-line branch while copying, ListRun on exp_done
      if fs and st_listwait = '1' and list_wait0 = '1' and exp_copying = '0' then
        ev(DG_WAIT_RACE) := '1';
      end if;
      if fs and st_listwait = '1' and list_wait0 = '1' and exp_copying = '1'
         and before_y_chargen_start = '1' and justbefore_y_chargen_start = '0' then
        ev(DG_WAIT_BORDER) := '1';
      end if;
      if fs and st_listrun = '1' and exp_done = '1' then ev(DG_RUN_RACE) := '1'; end if;
      ev(DG_START_CP) := exp_start and exp_copying;
      -- late pixel: a raster buffer write into the half the display reads now, at or left of
      -- the pixel it reads, inside the text area and before this line's fetch start (after it
      -- the writes belong to the next painting): that pixel comes too late for this line.
      -- (RAM write enable and address are these registered signals in this very cycle.)
      if (rb_write = '1' or rb_write2 = '1' or rb_write3 = '1' or rb_write4 = '1')
         and chargen_active = '1' and xcounter < display_fetch_start
         and rb_wa(10) = rb_ra(10) then
        lo := rb_wa(9 downto 0);
        if rb_quad = '1' then lo := lo - 3;                       -- pixel 1 of a quad write
        elsif rb_double = '1' then lo := lo - 1; end if;          -- pixel 1 of a double write
        if lo <= rb_ra(9 downto 0) then ev(DG_LATE) := '1'; end if;
      end if;
      dg_ev <= ev;
      dg_copying_d <= exp_copying;
      dg_ycounter <= ycounter;

      -- durations (cycles since the start pulse, saturating)
      if dg_exp_t /= x"FFFF" then dg_exp_t <= dg_exp_t + 1; end if;
      if dg_cp_t /= x"FFFF" then dg_cp_t <= dg_cp_t + 1; end if;
      if exp_start = '1' then
        dg_exp_run <= '1'; dg_exp_t <= (others => '0');
      elsif exp_abort = '1' and exp_done = '0' then
        dg_exp_run <= '0';                        -- an aborted expansion sets no maximum
      elsif exp_done = '1' and dg_exp_run = '1' then
        dg_exp_run <= '0';
        if dg_exp_t > dg_cnt(DG_EXP_MAX) then dg_cnt(DG_EXP_MAX) <= dg_exp_t; end if;
      end if;
      if exp_copy_start = '1' then
        dg_cp_run <= '1'; dg_first_pend <= '1'; dg_cp_t <= (others => '0');
      else
        if dg_first_pend = '1' and exp_mreq = '1' and exp_busy = '0' then   -- a copy read
          dg_first_pend <= '0';
          if dg_cp_t > dg_cnt(DG_FIRST_MAX) then dg_cnt(DG_FIRST_MAX) <= dg_cp_t; end if;
        end if;
        if dg_cp_run = '1' and dg_copying_d = '1' and exp_copying = '0' then
          dg_cp_run <= '0'; dg_first_pend <= '0';
          if dg_cp_t > dg_cnt(DG_COPY_MAX) then dg_cnt(DG_COPY_MAX) <= dg_cp_t; end if;
        end if;
      end if;
      -- RRB time per line: line start -> EndOfChargen (a painting cut off by the next line
      -- start counts with the cycles it had), and line start -> dispatch of the first GOTOX of
      -- a list row's expanded part (its first object part)
      if fs then
        if dg_paint_run = '1' and dg_line_t > dg_cnt(DG_PAINT_MAX) then
          dg_cnt(DG_PAINT_MAX) <= dg_line_t;
        end if;
        dg_line_t <= (others => '0'); dg_paint_run <= '1'; dg_obj_pend <= '1';
      else
        if dg_line_t /= x"FFFF" then dg_line_t <= dg_line_t + 1; end if;
        if dg_paint_run = '1' and st_eoc = '1' then
          dg_paint_run <= '0';
          if dg_line_t > dg_cnt(DG_PAINT_MAX) then dg_cnt(DG_PAINT_MAX) <= dg_line_t; end if;
        end if;
        if dg_obj_pend = '1' and st_dispatch = '1' and paint_ready = '1'
           and glyph_goto = '1' and list_in_exp = '1' and list_save_armed = '1' then
          dg_obj_pend <= '0';
          if dg_line_t > dg_cnt(DG_OBJ_MAX) then dg_cnt(DG_OBJ_MAX) <= dg_line_t; end if;
        end if;
      end if;

      -- stage 2: counters
      for n in 0 to 31 loop
        if (n <= DG_START_CP or n = DG_WAIT_BORDER or n = DG_LATE) and n /= DG_EXP_MAX and n /= DG_COPY_MAX
           and n /= DG_FIRST_MAX and dg_ev(n) = '1' then
          if n = DG_PARTS or dg_cnt(n) /= x"FFFF" then
            dg_cnt(n) <= dg_cnt(n) + 1;
          end if;
        end if;
      end loop;
      if dg_ev(DG_COPY_DONE) = '1' then dg_cnt(DG_COPY_Y) <= x"0" & dg_ycounter; end if;
      if dg_ev(DG_EXP_ABORT) = '1' then dg_cnt(DG_ABORT_Y) <= x"0" & dg_ycounter; end if;
      if dg_ev(DG_LATE) = '1' then dg_cnt(DG_LATE_Y) <= x"0" & dg_ycounter; end if;

      dg_clr_s <= dg_clr_s(1 downto 0) & diag_clr;
      if dg_clr_s(2) /= dg_clr_s(1) then
        dg_cnt <= (others => (others => '0'));
      end if;

      dg_sel1 <= diag_sel; dg_sel2 <= dg_sel1;
      diag_val <= dg_cnt(to_integer(dg_sel2));
    end if;
  end process;
end architecture;
