--------------------------------------------------------------------------------
-- rrb_list_expander.vhdl -- RRB list mode for the VIC-IV (QMTech K325T extension, after
-- upstream issue #747 "Make RRB even more amazing" + #597 flip).  See docs/rrb_list_mode.md
-- in the lab repository for the format.
--
-- At the badline, after the ordinary screen row has been fetched, the VIC-IV starts this unit
-- at the position of the LIST token ($FFFC).  For each 8-byte list entry (read from chip RAM at
-- ent_addr, ent_addr+8, ...) it writes into the row buffers
--   * a synthesised GOTOX token (X, Y offset, draw mask, background flags from the entry),
--   * the object's RRB tokens (screen bytes from chip RAM, colour bytes from colour RAM),
--     up to (not including) the object's $FFFF end-of-list word,
-- until an entry whose word 0 is $FFFF; then it writes a $FFFF end-of-line token.
--
-- Memory interfaces are fixed-latency: a chip RAM request (mreq, maddr, both registered
-- outputs) returns its byte on mdata exactly MLAT cycles after the edge that issued it; colour
-- RAM returns cdata CLAT cycles after caddr (a registered output) changes; CLAT <= MLAT - 2.  Requests already in flight when an object's $FFFF arrives are discarded.
-- One byte per cycle.  If the buffer would overflow (out position > LIMIT) the expansion ends
-- there with the end-of-line token (like running out of RRB time).
--
-- List mode v2 (global object table, XCTL bit 6): once per frame (copy_start, top of the frame)
-- the unit copies obj_count 16-byte objects from chip RAM at tab_addr into its own table (LUT
-- RAM, 512 x 64 bits; a consistent snapshot: the CPU can rewrite the table at any time).  The
-- address and the count are latched at the copy start; every scan uses the latched count.  The
-- copy issues a chip RAM read only in cycles with mfree = '1' (the VIC-IV's port is idle) and
-- stalls otherwise; copying stays high until the last table word is written.  When a row is expanded
-- with scan_en set, after the row's own lists (or right away with start_scan: rows without a
-- LIST token) it scans that table: every object whose Y range covers character row `row`
-- becomes one or two synthesised entries (the object's top part with Y offset -(y mod 8) and
-- draw mask $FF << (y mod 8), the bottom part of the object row above with +(8 - y mod 8) and
-- the complementary mask), handled exactly like v1 entries.  Object format (16 bytes):
--   +0  X 9..0, bit 10 REL (X = previous table object's X + signed offset)
--   +2  Y 9..0 (signed, pixel rows from the top of character row 0), bit 10 REL (as X)
--   +4  draw mask (ANDed with the computed one; 0 = hidden)
--   +5  height in character rows, bits 5..0 (0 = 1; bits 7..6 ignored)
--   +6  bits 3..0 screen address 19..16, 4 FLIPX, 5 FLIPY, 6 transparent, 7 behind (v1 w1 high)
--   +7  collision group mask (one bit per group)
--   +8  screen address 15..0 of the tokens of object row 0
--   +10 colour RAM offset of the tokens of object row 0
--   +12 row stride: bytes from one object row's tokens to the next (screen and colour)
--   +14 width in pixels for collisions (0 = 8)
-- Collisions (col_*; docs "Collisions"): during the copy every object's box is resolved (REL
-- as in the scan) into a box RAM: X..X+W-1 (W = +14, 0 = 8), Y..Y+8H-1 (Y signed, H = +5 bits
-- 5..0, 0 = 1), the group mask (+7), active = draw mask /= 0 and group /= 0.  On col_tick (once
-- per frame) -- after the copy, or on the held snapshot -- a pass compares all pairs i < j of the
-- snapshot's objects, one per cycle (n(n-1)/2 + ~7n cycles: 34164 for 255 objects): two active
-- objects with a common group bit and overlapping boxes collide.  Results: a bit per object,
-- the first (lowest-numbered) partner per object, the count; double buffered (the pass writes
-- the working set, CSwap makes it readable and toggles col_toggle).  A copy waits for a pass.
-- Diagnostics only (the VIC-IV counters at $FFD71E0-3): ovf pulses when an expansion ends at
-- the buffer limit (EntWait, ObjDrain, Scan, HitEmit), part is high in Gotox0 (one object
-- part / v1 entry emitted), cstall while the copy has bytes left to issue and mfree = '0'.
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity rrb_list_expander is
  generic ( MLAT : integer := 4; CLAT : integer := 1; LIMIT : integer := 1020 );
  port (
    clk       : in  std_logic;
    start     : in  std_logic;                        -- one cycle
    abort     : in  std_logic := '0';                 -- stop now (raster line restarted)
    ent_addr  : in  unsigned(19 downto 0);            -- chip RAM address of the first entry
    out_start : in  unsigned(9 downto 0);             -- row buffer index of the LIST token
    busy      : out std_logic;
    done      : out std_logic;                        -- one cycle when finished
    out_len   : out unsigned(10 downto 0);            -- buffer index after the end-of-line token (<= LIMIT + 4)
    -- chip RAM (read only)
    mreq      : out std_logic;
    maddr     : out unsigned(19 downto 0);
    mdata     : in  unsigned(7 downto 0);
    -- colour RAM (read only)
    caddr     : out unsigned(15 downto 0);
    cdata     : in  unsigned(7 downto 0);
    -- row buffers (screen and colour), same index
    bwe       : out std_logic;
    baddr     : out unsigned(9 downto 0);
    bscreen   : out unsigned(7 downto 0);
    bcolour   : out unsigned(7 downto 0);
    -- list mode v2 (global object table)
    scan_en    : in  std_logic := '0';               -- scan the object table after the lists
    start_scan : in  std_logic := '0';               -- with start: no lists, scan right away
    row        : in  unsigned(7 downto 0) := (others => '0');   -- character row number
    obj_count  : in  unsigned(7 downto 0) := (others => '0');
    copy_start : in  std_logic := '0';               -- one cycle: snapshot the table
    tab_addr   : in  unsigned(19 downto 0) := (others => '0');
    mfree      : in  std_logic := '1';               -- chip RAM port free for the copy now
    copying    : out std_logic;
    -- diagnostics (VIC-IV counters at $FFD71E0-3; no effect on the expansion)
    ovf        : out std_logic := '0';               -- one cycle: ended by the buffer limit
    part       : out std_logic := '0';               -- an object part's GOTOX starts (Gotox0)
    cstall     : out std_logic := '0';               -- copy has bytes to issue, port not free
    -- v2 collisions (docs "Collisions"): one pass per frame over the snapshot
    col_tick   : in  std_logic := '0';               -- one cycle per frame: run the pass
    col_bits   : out std_logic_vector(255 downto 0) := (others => '0');  -- last result: collided
    col_count  : out unsigned(7 downto 0) := (others => '0');            -- objects with bit set
    col_toggle : out std_logic := '0';               -- toggles when a new result is readable
    col_pidx   : in  unsigned(7 downto 0) := (others => '0');            -- object number
    col_pdata  : out unsigned(7 downto 0);           -- its first partner (255: none), async
    col_busy   : out std_logic := '0'                -- the pass runs
  );
end entity;

architecture rtl of rrb_list_expander is
  type state_t is (Idle, EntReq, EntWait, Gotox0, Gotox1, ObjRun, ObjDrain, Finish0, Finish1, Fin,
                   ScanStart, Scan, HitB0, HitB1, HitB2, HitMul, HitEmit);
  signal state : state_t := Idle;

  -- request pipeline: what each in-flight chip RAM read was for
  type kind_t is (KNone, KEnt, KObj);
  type kinds_t is array (1 to MLAT) of kind_t;
  type idx_t is array (1 to MLAT) of unsigned(9 downto 0);
  signal pk   : kinds_t := (others => KNone);
  signal pidx : idx_t := (others => (others => '0'));     -- entry byte number / buffer index
  type cdel_t is array (1 to MLAT) of unsigned(7 downto 0);
  signal cdl  : cdel_t := (others => (others => '0'));    -- colour data, delayed

  type ent_t is array (0 to 7) of unsigned(7 downto 0);
  signal ent      : ent_t := (others => (others => '0'));
  signal ent_got  : integer range 0 to 8 := 0;
  signal ent_req  : integer range 0 to 8 := 0;
  signal eaddr    : unsigned(19 downto 0) := (others => '0');
  signal opos     : unsigned(9 downto 0) := (others => '0');   -- next buffer write index
  signal last_x   : unsigned(9 downto 0) := (others => '0');
  signal oaddr    : unsigned(19 downto 0) := (others => '0');  -- next object byte to request
  signal ocol     : unsigned(15 downto 0) := (others => '0');
  signal oreq_idx : unsigned(9 downto 0) := (others => '0');   -- buffer index of next request
  signal flipx, flipy : std_logic := '0';
  signal ended    : std_logic := '0';                          -- object $FFFF seen (or full)
  signal full     : std_logic := '0';                          -- buffer limit reached
  signal prev_ff  : std_logic := '0';                          -- last even screen byte was $FF
  signal x_new    : unsigned(9 downto 0);
  signal gx       : unsigned(9 downto 0) := (others => '0');   -- X of the GOTOX being written
  signal mask_ff  : std_logic;

  -- v2: object table snapshot, 2 x 64 bits per object (bytes 0..7, 8..15)
  type tab_t is array (0 to 511) of unsigned(63 downto 0);
  signal tab      : tab_t := (others => (others => '0'));
  signal tab_ra   : unsigned(8 downto 0) := (others => '0');
  signal tab_q    : unsigned(63 downto 0) := (others => '0');
  signal tab_we   : std_logic := '0';
  signal tab_wa   : unsigned(8 downto 0) := (others => '0');
  signal tab_wd   : unsigned(63 downto 0) := (others => '0');
  -- copy
  signal cp_run, cp_pend : std_logic := '0';
  signal cp_addr  : unsigned(19 downto 0) := (others => '0');
  signal cp_n, cp_issue : unsigned(12 downto 0) := (others => '0');
  signal cp_count : unsigned(7 downto 0) := (others => '0');    -- object count of the snapshot
  type cpv_t is array (1 to MLAT) of std_logic;
  type cpi_t is array (1 to MLAT) of unsigned(11 downto 0);
  signal cpv      : cpv_t := (others => '0');
  signal cpi      : cpi_t := (others => (others => '0'));
  signal cp_asm   : unsigned(55 downto 0) := (others => '0');
  -- scan
  signal scanning : std_logic := '0';
  signal scan_after : std_logic := '0';
  signal row_l    : unsigned(7 downto 0) := (others => '0');
  signal cnt_l    : unsigned(8 downto 0) := (others => '0');
  signal s_issue  : unsigned(8 downto 0) := (others => '0');
  signal spv      : std_logic_vector(1 to 2) := "00";
  type spi_t is array (1 to 2) of unsigned(7 downto 0);
  signal spi      : spi_t := (others => (others => '0'));
  signal acc_x    : unsigned(9 downto 0) := (others => '0');
  signal acc_y    : unsigned(9 downto 0) := (others => '0');
  signal h_obj    : unsigned(7 downto 0) := (others => '0');
  signal h_x      : unsigned(9 downto 0) := (others => '0');
  signal h_o      : unsigned(2 downto 0) := (others => '0');
  signal h_k      : unsigned(5 downto 0) := (others => '0');   -- object row of the top part
  signal h_mask   : unsigned(7 downto 0) := (others => '0');
  signal h_flags  : unsigned(7 downto 0) := (others => '0');
  signal h_pa, h_pb : std_logic := '0';
  signal h_bsel   : std_logic_vector(1 downto 0) := "00";       -- bottom part: same/-/+ stride
  signal h_addr   : unsigned(19 downto 0) := (others => '0');
  signal h_col, h_stride : unsigned(15 downto 0) := (others => '0');
  signal h_mul    : unsigned(21 downto 0) := (others => '0');
  signal pa_addr, pb_addr : unsigned(19 downto 0) := (others => '0');
  signal pa_col, pb_col : unsigned(15 downto 0) := (others => '0');

  -- v2 collisions: per object a box, written during the copy (REL resolved as the scan does)
  --   bits 10..0 x0, 21..11 x1 (x0 + width - 1), 33..22 y0 (signed), 45..34 y1 (y0 + 8 h - 1),
  --   53..46 group mask, 54 active (draw mask /= 0 and group /= 0)
  type box_t is array (0 to 255) of unsigned(55 downto 0);
  signal cbox     : box_t := (others => (others => '0'));
  signal cb_we    : std_logic := '0';
  signal cb_wa    : unsigned(7 downto 0) := (others => '0');
  signal cb_wd    : unsigned(55 downto 0) := (others => '0');
  signal cb_ra    : unsigned(7 downto 0) := (others => '0');
  signal cb_q     : unsigned(55 downto 0) := (others => '0');
  signal cb_accx, cb_accy : unsigned(9 downto 0) := (others => '0');
  signal cb_x0, cb_y0 : unsigned(9 downto 0) := (others => '0');
  signal cb_h     : unsigned(5 downto 0) := (others => '0');
  signal cb_g     : unsigned(7 downto 0) := (others => '0');
  signal cb_act   : std_logic := '0';
  -- the pass: all pairs i < j of the snapshot's objects, one compare per cycle
  type cstate_t is (CIdle, CLoadA, CWaitA, CGetA, CInner, CEndI, CSwap);
  signal cstate   : cstate_t := CIdle;
  signal col_req  : std_logic := '0';
  signal c_n      : unsigned(8 downto 0) := (others => '0');
  signal c_i, c_j : unsigned(8 downto 0) := (others => '0');
  signal c_a      : unsigned(55 downto 0) := (others => '0');
  signal c_pv1, c_pv2 : std_logic := '0';
  signal c_pj1, c_pj2 : unsigned(7 downto 0) := (others => '0');
  signal c_w      : std_logic_vector(255 downto 0) := (others => '0');   -- working bits
  signal c_r      : std_logic_vector(255 downto 0) := (others => '0');   -- readable bits
  signal c_wcount, c_rcount : unsigned(7 downto 0) := (others => '0');
  signal c_pi_v   : std_logic := '0';
  signal c_pi     : unsigned(7 downto 0) := (others => '0');
  signal c_rsel, c_tog : std_logic := '0';
  -- first partner per object, two buffers (the pass writes buffer not c_rsel)
  type part_t is array (0 to 255) of unsigned(7 downto 0);
  signal pram0, pram1 : part_t := (others => x"FF");
  signal p_we     : std_logic := '0';
  signal p_wa, p_wd : unsigned(7 downto 0) := (others => '0');

  function any_obj(p : kinds_t) return boolean is
  begin
    for n in p'range loop
      if p(n) = KObj then return true; end if;
    end loop;
    return false;
  end function;
begin
  busy <= '0' when state = Idle else '1';
  -- (the VIC-IV starts no expansion then); tab_we: the last table word is written in this cycle
  copying <= cp_run or cp_pend or copy_start or tab_we;
  part <= '1' when state = Gotox0 else '0';
  cstall <= '1' when cp_run = '1' and cp_issue /= cp_n and mfree = '0' else '0';

  -- v2 collisions: box RAM (written during the copy, read by the pass), partner RAMs (written
  -- by the pass, read asynchronously through col_pidx), results
  process (clk) begin
    if rising_edge(clk) then
      if cb_we = '1' then
        cbox(to_integer(cb_wa)) <= cb_wd;
      end if;
      cb_q <= cbox(to_integer(cb_ra));
      if p_we = '1' then
        if c_rsel = '0' then pram1(to_integer(p_wa)) <= p_wd;
        else pram0(to_integer(p_wa)) <= p_wd; end if;
      end if;
    end if;
  end process;
  col_bits <= c_r;
  col_count <= c_rcount;
  col_toggle <= c_tog;
  col_busy <= '0' when cstate = CIdle else '1';
  col_pdata <= x"FF" when c_r(to_integer(col_pidx)) = '0'
               else pram0(to_integer(col_pidx)) when c_rsel = '0'
               else pram1(to_integer(col_pidx));

  process (clk)
    variable a, b : unsigned(55 downto 0);
    variable hit : boolean;
    variable inc : unsigned(7 downto 0);
    variable jj : integer range 0 to 255;
    variable ii : integer range 0 to 255;
  begin
    if rising_edge(clk) then
      p_we <= '0';
      if col_tick = '1' then
        col_req <= '1';
      end if;
      -- index pipeline of the box reads (the box RAM read is registered: data 2 cycles later)
      c_pv2 <= c_pv1; c_pj2 <= c_pj1;
      c_pv1 <= '0';
      case cstate is
        when CIdle =>
          -- after the copy (the snapshot is complete); with HOLD on the held snapshot
          if col_req = '1' and cp_run = '0' and cp_pend = '0' and copy_start = '0' and tab_we = '0' then
            col_req <= '0';
            c_n <= '0' & cp_count;
            c_i <= (others => '0');
            c_w <= (others => '0'); c_wcount <= (others => '0');
            if cp_count < 2 then
              cstate <= CSwap;
            else
              cstate <= CLoadA;
            end if;
          end if;
        when CLoadA =>
          cb_ra <= c_i(7 downto 0);
          c_pi_v <= '0';
          cstate <= CWaitA;
        when CWaitA =>
          cstate <= CGetA;
        when CGetA =>
          c_a <= cb_q;
          c_j <= c_i + 1;
          cstate <= CInner;
        when CInner =>
          if c_j < c_n then
            cb_ra <= c_j(7 downto 0);
            c_pv1 <= '1'; c_pj1 <= c_j(7 downto 0);
            c_j <= c_j + 1;
          elsif c_pv1 = '0' and c_pv2 = '0' then
            cstate <= CEndI;
          end if;
          -- stage 2: box j against box i
          if c_pv2 = '1' then
            a := c_a; b := cb_q;
            hit := a(54) = '1' and b(54) = '1' and (a(53 downto 46) and b(53 downto 46)) /= x"00"
                   and a(10 downto 0) <= b(21 downto 11) and b(10 downto 0) <= a(21 downto 11)
                   and signed(a(33 downto 22)) <= signed(b(45 downto 34))
                   and signed(b(33 downto 22)) <= signed(a(45 downto 34));
            if hit then
              ii := to_integer(c_i(7 downto 0)); jj := to_integer(c_pj2);
              inc := (others => '0');
              if c_w(ii) = '0' then
                inc := inc + 1;
                if c_pi_v = '0' then c_pi_v <= '1'; c_pi <= c_pj2; end if;   -- its first partner
              end if;
              if c_w(jj) = '0' then
                inc := inc + 1;
                p_we <= '1'; p_wa <= c_pj2; p_wd <= c_i(7 downto 0);         -- lowest partner
              end if;
              c_w(ii) <= '1'; c_w(jj) <= '1';
              c_wcount <= c_wcount + inc;
            end if;
          end if;
        when CEndI =>
          if c_pi_v = '1' then
            p_we <= '1'; p_wa <= c_i(7 downto 0); p_wd <= c_pi;
          end if;
          if c_i + 2 >= c_n then
            cstate <= CSwap;
          else
            c_i <= c_i + 1;
            cstate <= CLoadA;
          end if;
        when CSwap =>
          c_r <= c_w; c_rcount <= c_wcount;
          c_rsel <= not c_rsel; c_tog <= not c_tog;
          cstate <= CIdle;
      end case;
    end if;
  end process;

  -- object table: LUT RAM (simple dual port, registered read)
  process (clk) begin
    if rising_edge(clk) then
      if tab_we = '1' then
        tab(to_integer(tab_wa)) <= tab_wd;
      end if;
      tab_q <= tab(to_integer(tab_ra));
    end if;
  end process;

  -- X of the synthesised GOTOX: absolute, or the previous entry's X + signed offset (REL)
  x_new <= (ent(1)(1 downto 0) & ent(0)) when ent(1)(2) = '0'
           else last_x + (ent(1)(1 downto 0) & ent(0));
  mask_ff <= '1' when ent(2) = x"FF" else '0';

  process (clk)
    variable k : kind_t;
    variable i : unsigned(9 downto 0);
    variable c : unsigned(7 downto 0);
    variable q : unsigned(63 downto 0);
    variable ax, ay : unsigned(9 downto 0);
    variable rr : signed(10 downto 0);
    variable hh : signed(10 downto 0);
    variable o  : unsigned(2 downto 0);
    variable pa, pb : boolean;
    variable d  : signed(10 downto 0);
    variable ma, mb : unsigned(7 downto 0);
    variable aa, ab : unsigned(19 downto 0);
    variable ca, cb : unsigned(15 downto 0);
    variable fy : std_logic;
    variable cbw : unsigned(10 downto 0);
    variable cbh, cby : unsigned(11 downto 0);
  begin
    if rising_edge(clk) then
      done <= '0';
      bwe <= '0';
      mreq <= '0';
      tab_we <= '0';
      cb_we <= '0';
      ovf <= '0';

      -- v2 table copy: returning bytes, assembled into 64-bit words (they arrive in order)
      for n in MLAT downto 2 loop
        cpv(n) <= cpv(n - 1); cpi(n) <= cpi(n - 1);
      end loop;
      cpv(1) <= '0';
      if cpv(MLAT) = '1' then
        if cpi(MLAT)(2 downto 0) = "111" then
          tab_we <= '1'; tab_wa <= cpi(MLAT)(11 downto 3); tab_wd <= mdata & cp_asm;
          -- collision box of the object (REL as in the scan: every object is an anchor)
          q := mdata & cp_asm;
          if cpi(MLAT)(3) = '0' then
            if q(10) = '1' then ax := cb_accx + q(9 downto 0); else ax := q(9 downto 0); end if;
            if q(26) = '1' then ay := cb_accy + q(25 downto 16); else ay := q(25 downto 16); end if;
            cb_accx <= ax; cb_accy <= ay;
            cb_x0 <= ax; cb_y0 <= ay;
            cb_h <= q(45 downto 40); cb_g <= q(63 downto 56);
            if q(39 downto 32) /= x"00" and q(63 downto 56) /= x"00" then cb_act <= '1'; else cb_act <= '0'; end if;
          else
            -- +14: width in pixels (0 = 8); height: rows x 8 (0 = 1 row)
            if q(55 downto 48) = x"00" then cbw := to_unsigned(8, 11);
            else cbw := "000" & q(55 downto 48); end if;
            if cb_h = "000000" then cbh := to_unsigned(8, 12);
            else cbh := "000" & cb_h & "000"; end if;
            cby := unsigned(resize(signed(cb_y0), 12));
            cb_we <= '1'; cb_wa <= cpi(MLAT)(11 downto 4);
            cb_wd <= '0' & cb_act & cb_g & (cby + cbh - 1) & cby & (("0" & cb_x0) + cbw - 1) & ("0" & cb_x0);
          end if;
        end if;
        cp_asm <= mdata & cp_asm(55 downto 8);
      end if;
      if copy_start = '1' then
        cp_pend <= '1';
      end if;
      if cp_run = '0' and cp_pend = '1' and state = Idle and start = '0' and cstate = CIdle then
        cp_pend <= '0'; cp_run <= '1';
        cb_accx <= (others => '0'); cb_accy <= (others => '0');
        cp_addr <= tab_addr; cp_issue <= (others => '0');
        cp_n <= '0' & obj_count & "0000";        -- 16 bytes per object
        cp_count <= obj_count;                   -- part of the snapshot (scans use this count)
      end if;
      if cp_run = '1' then
        if cp_issue /= cp_n(12 downto 0) then
          if mfree = '1' then                    -- else stall: the VIC-IV uses the port now
            mreq <= '1'; maddr <= cp_addr + cp_issue;
            cpv(1) <= '1'; cpi(1) <= cp_issue(11 downto 0);
            cp_issue <= cp_issue + 1;
          end if;
        else
          -- done once no request is in flight (cpv(MLAT) returns in this cycle)
          cp_run <= '0';
          for n in 1 to MLAT - 1 loop
            if cpv(n) = '1' then cp_run <= '1'; end if;
          end loop;
        end if;
      end if;

      -- shift the request pipeline and the colour data
      for n in MLAT downto 2 loop
        pk(n) <= pk(n - 1); pidx(n) <= pidx(n - 1); cdl(n) <= cdl(n - 1);
      end loop;
      pk(1) <= KNone;
      cdl(1) <= cdata;

      -- data returning now was requested MLAT cycles ago; caddr leaves this unit registered, so
      -- its colour byte arrived CLAT + 1 cycles after the request and waits in cdl(MLAT-CLAT-1)
      k := pk(MLAT); i := pidx(MLAT);
      if k = KEnt then
        ent(to_integer(i(2 downto 0))) <= mdata;
        ent_got <= ent_got + 1;
      elsif k = KObj and ended = '0' then
        c := cdl(MLAT - CLAT - 1);
        if i(0) = '0' then
          -- low byte of a token (colour byte 0: flip bits, GOTOX flag)
          if i > to_unsigned(LIMIT, 10) then
            ended <= '1'; full <= '1'; opos <= i;
          else
            if c(4) = '0' then                    -- a glyph, not a GOTOX inside the object
              c(6) := c(6) xor flipx;
              c(7) := c(7) xor flipy;
            end if;
            bwe <= '1'; baddr <= i; bscreen <= mdata; bcolour <= c;
            if mdata = x"FF" then prev_ff <= '1'; else prev_ff <= '0'; end if;
          end if;
        else
          if prev_ff = '1' and mdata = x"FF" then
            ended <= '1'; opos <= i - 1;          -- the next GOTOX overwrites the low $FF
          else
            bwe <= '1'; baddr <= i; bscreen <= mdata; bcolour <= c;
            opos <= i + 1;
          end if;
        end if;
      end if;

      -- v2 scan pipeline (table read: address registered here, data two edges later)
      spv(2) <= spv(1); spi(2) <= spi(1);
      spv(1) <= '0';

      if abort = '1' then
        state <= Idle;
        pk <= (others => KNone);
        scanning <= '0'; spv <= "00";
      else
      case state is
        when Idle =>
          if start = '1' then
            eaddr <= ent_addr; opos <= out_start; last_x <= (others => '0'); full <= '0';
            ent_req <= 0; ent_got <= 0;
            scanning <= '0'; scan_after <= scan_en;
            row_l <= row; cnt_l <= '0' & cp_count;   -- the snapshot's count, not the live one
            if start_scan = '1' then
              state <= ScanStart;
            else
              state <= EntReq;
            end if;
          end if;

        when EntReq =>
          mreq <= '1'; maddr <= eaddr + ent_req;
          pk(1) <= KEnt; pidx(1) <= to_unsigned(ent_req, 10);
          if ent_req = 7 then state <= EntWait; end if;
          ent_req <= ent_req + 1;

        when EntWait =>
          if ent_got = 8 then
            eaddr <= eaddr + 8;
            if opos > to_unsigned(LIMIT - 2, 10) then
              state <= Finish0; ovf <= '1';
            elsif ent(0) = x"FF" and ent(1) = x"FF" then
              if scan_after = '1' then
                state <= ScanStart;               -- v2: the global objects follow the lists
              else
                state <= Finish0;
              end if;
            else
              state <= Gotox0;
            end if;
          end if;

        when Gotox0 =>
          bwe <= '1'; baddr <= opos;
          bscreen <= x_new(7 downto 0);
          gx <= x_new;                            -- latched: last_x changes now, and a REL
                                                  -- x_new would move with it in Gotox1
          -- colour byte 0: bit 7 transparent, bit 6 behind, bit 4 GOTOX, bit 3 ROWMASK enable
          bcolour <= ent(3)(6) & ent(3)(7) & "01" & (not mask_ff) & "000";
          last_x <= x_new;
          state <= Gotox1;

        when Gotox1 =>
          bwe <= '1'; baddr <= opos + 1;
          -- high byte: Y offset (15..13) and sign (12) as given, REL/reserved cleared, X 9..8
          bscreen <= ent(1)(7 downto 4) & "00" & gx(9 downto 8);
          bcolour <= ent(2);                      -- draw mask
          flipx <= ent(3)(4); flipy <= ent(3)(5);
          oaddr <= ent(3)(3 downto 0) & ent(5) & ent(4);
          ocol  <= ent(7) & ent(6);
          oreq_idx <= opos + 2;
          opos <= opos + 2;
          ended <= '0'; prev_ff <= '0';
          state <= ObjRun;

        when ObjRun =>
          if ended = '1' or oreq_idx > to_unsigned(LIMIT + 1, 10) then
            state <= ObjDrain;
          else
            mreq <= '1'; maddr <= oaddr; caddr <= ocol;
            pk(1) <= KObj; pidx(1) <= oreq_idx;
            oaddr <= oaddr + 1; ocol <= ocol + 1; oreq_idx <= oreq_idx + 1;
          end if;

        when ObjDrain =>
          -- wait until no object read is in flight
          if not any_obj(pk) then
            if full = '1' or ended = '0' then
              state <= Finish0; ovf <= '1';       -- buffer full (requests stopped at the limit)
            elsif scanning = '1' then
              state <= HitEmit;                   -- v2: the other part, or on with the scan
            else
              state <= EntReq; ent_req <= 0; ent_got <= 0;
            end if;
          end if;

        when Finish0 =>
          bwe <= '1'; baddr <= opos; bscreen <= x"FF"; bcolour <= x"00";
          state <= Finish1;
        when Finish1 =>
          bwe <= '1'; baddr <= opos + 1; bscreen <= x"FF"; bcolour <= x"00";
          out_len <= ('0' & opos) + 2;
          state <= Fin;
        when Fin =>
          done <= '1';
          scanning <= '0';
          state <= Idle;

        -- v2: scan the object table for objects covering this character row
        when ScanStart =>
          scanning <= '1';
          s_issue <= (others => '0');
          acc_x <= (others => '0'); acc_y <= (others => '0');
          state <= Scan;

        when Scan =>
          if s_issue < cnt_l then
            tab_ra <= s_issue(7 downto 0) & '0';
            spv(1) <= '1'; spi(1) <= s_issue(7 downto 0);
            s_issue <= s_issue + 1;
          elsif spv = "00" then
            state <= Finish0;                     -- all objects seen
          end if;
          if opos > to_unsigned(LIMIT - 2, 10) then
            state <= Finish0; spv <= "00"; ovf <= '1';
          elsif spv(2) = '1' then
            q := tab_q;
            if q(10) = '1' then ax := acc_x + q(9 downto 0); else ax := q(9 downto 0); end if;
            if q(26) = '1' then ay := acc_y + q(25 downto 16); else ay := q(25 downto 16); end if;
            acc_x <= ax; acc_y <= ay;
            -- object row of this character row's top part: row - floor(y / 8)
            rr := signed(unsigned'("000" & row_l)) - resize(signed(ay(9 downto 3)), 11);
            if q(45 downto 40) = "000000" then
              hh := to_signed(1, 11);
            else
              hh := signed(unsigned'("00000" & q(45 downto 40)));
            end if;
            o := ay(2 downto 0);
            pa := q(39 downto 32) /= x"00" and rr >= 0 and rr < hh;
            pb := q(39 downto 32) /= x"00" and o /= "000" and rr >= 1 and rr <= hh;
            if pa or pb then
              h_obj <= spi(2); h_x <= ax; h_o <= o; h_mask <= q(39 downto 32);
              h_flags <= q(55 downto 48);
              if pa then h_pa <= '1'; else h_pa <= '0'; end if;
              if pb then h_pb <= '1'; else h_pb <= '0'; end if;
              -- object row of the top part (bottom part: the row above); FLIPY: rows in
              -- reverse order.  Without a top part the bottom part's row is computed directly.
              if q(53) = '1' then
                if pa then d := hh - 1 - rr; else d := hh - rr; end if;
              else
                if pa then d := rr; else d := rr - 1; end if;
              end if;
              h_k <= unsigned(d(5 downto 0));
              if not pa then h_bsel <= "00"; elsif q(53) = '1' then h_bsel <= "10"; else h_bsel <= "01"; end if;
              s_issue <= ('0' & spi(2)) + 1;      -- resume after this object
              spv <= "00";
              state <= HitB0;
            end if;
          end if;

        when HitB0 =>
          tab_ra <= h_obj & '1';
          state <= HitB1;
        when HitB1 =>
          state <= HitB2;
        when HitB2 =>
          h_addr <= h_flags(3 downto 0) & tab_q(15 downto 0);
          h_col <= tab_q(31 downto 16);
          h_stride <= tab_q(47 downto 32);
          h_mul <= h_k * tab_q(47 downto 32);
          state <= HitMul;
        when HitMul =>
          aa := h_addr + h_mul(19 downto 0);
          ca := h_col + h_mul(15 downto 0);
          pa_addr <= aa; pa_col <= ca;
          -- the bottom part comes from the object row above (below with FLIPY)
          case h_bsel is
            when "10" => pb_addr <= aa + h_stride; pb_col <= ca + h_stride;
            when "01" => pb_addr <= aa - h_stride; pb_col <= ca - h_stride;
            when others => pb_addr <= aa; pb_col <= ca;
          end case;
          state <= HitEmit;
        when HitEmit =>
          ma := h_mask and shift_left(to_unsigned(255, 8), to_integer(h_o));
          mb := h_mask and (shift_left(to_unsigned(1, 8), to_integer(h_o)) - 1);
          fy := h_flags(5);       -- FLIPY: the VIC-IV applies the Y offset the other way round
          ent(0) <= h_x(7 downto 0);
          ent(3) <= h_flags(7 downto 4) & pa_addr(19 downto 16);
          ent(4) <= pa_addr(7 downto 0); ent(5) <= pa_addr(15 downto 8);
          ent(6) <= pa_col(7 downto 0); ent(7) <= pa_col(15 downto 8);
          if opos > to_unsigned(LIMIT - 2, 10) then
            -- buffer limit as in EntWait (a GOTOX + tokens no longer fit): end the row here,
            -- also instead of resuming the scan
            h_pa <= '0'; h_pb <= '0';
            state <= Finish0; ovf <= '1';
          elsif h_pa = '1' and ma /= x"00" then
            h_pa <= '0';
            ent(1) <= h_o & (not fy) & "00" & h_x(9 downto 8);
            ent(2) <= ma;
            state <= Gotox0;
          elsif h_pb = '1' and mb /= x"00" then
            h_pb <= '0'; h_pa <= '0';
            ent(1) <= ((not h_o) + 1) & fy & "00" & h_x(9 downto 8);
            ent(2) <= mb;
            ent(3) <= h_flags(7 downto 4) & pb_addr(19 downto 16);
            ent(4) <= pb_addr(7 downto 0); ent(5) <= pb_addr(15 downto 8);
            ent(6) <= pb_col(7 downto 0); ent(7) <= pb_col(15 downto 8);
            state <= Gotox0;
          else
            h_pa <= '0'; h_pb <= '0';
            state <= Scan;
          end if;
      end case;
      end if;
    end if;
  end process;
end architecture;
