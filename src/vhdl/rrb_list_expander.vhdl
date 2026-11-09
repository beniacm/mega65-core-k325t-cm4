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
-- List mode v3 (global object table, XCTL bit 6; docs "v3 table"): once per frame (copy_start,
-- top of the frame) the unit copies obj_count (0..1023, at most NOBJ - 1) entries of 32 bytes
-- from chip RAM at tab_addr -- bytes 0..15 of each, bytes 16..31 belong to software and are
-- never read -- into its own table (block RAM, NOBJ x 128 bits; a consistent snapshot: the CPU
-- can rewrite the table at any time).  The address and the count are latched at the copy start.
-- The copy issues a chip RAM read only in cycles with mfree = '1' (the VIC-IV's port is idle)
-- and stalls otherwise.  REL X/Y (+0 / +2 bit 10: the previous table object's X/Y + signed
-- offset) is resolved during the copy: the table holds absolute positions.  Then the unit builds
-- per-row buckets (character rows 0..63, at most 2048 entries in all, in table order: a
-- counting sort, the counts made during the copy): every visible object (draw mask /= 0) is
-- listed in each row its Y range Y..Y+8H-1 touches.  copying stays high until the buckets are
-- complete.  When a row is expanded with scan_en set, after the row's own lists (or right away
-- with start_scan: rows without a LIST token) it walks that row's bucket: every object
-- becomes one or two synthesised entries (the object's top part with Y offset -(y mod 8) and
-- draw mask $FF << (y mod 8), the bottom part of the object row above with +(8 - y mod 8) and
-- the complementary mask), handled exactly like v1 entries.  Entry format (bytes 0..15):
--   +0  X 9..0, bit 10 REL (X = previous table object's X + signed offset)
--   +2  Y 9..0 (signed, pixel rows from the top of character row 0), bit 10 REL (as X)
--   +4  draw mask (ANDed with the computed one; 0 = hidden)
--   +5  height in character rows, bits 5..0 (0 = 1); bit 7 circle (collisions); bit 6 ignored
--   +6  bits 3..0 screen address 19..16, 4 FLIPX, 5 FLIPY, 6 transparent, 7 behind (v1 w1 high)
--   +7  collision group mask (one bit per group)
--   +8  screen address 15..0 of the tokens of object row 0
--   +10 colour RAM offset of the tokens of object row 0
--   +12 row stride: bytes from one object row's tokens to the next (screen and colour)
--   +14 width in pixels for collisions (0 = 8)
--   +15 collides-with mask (0 = the group mask): A and B collide if (gA and wB) and (gB and wA)
-- Collisions (col_*; docs "Collisions"): on col_tick (once per frame) -- after the copy, or on
-- the held snapshot -- a pass compares the pairs of objects sharing a bucket, each pair once (in
-- the first row both are listed in), one pair per cycle.  Two active objects (draw mask /= 0,
-- group /= 0) whose group (+7) meets the other's collides-with mask (+15, 0 = its group mask)
-- both ways collide if their boxes overlap -- X..X+W-1 (W = +14, 0 = 8), Y..Y+8H-1 -- or, with
-- +5 bit 7 (circle) on one or both, if the circle (radius W/2 about the box centre) meets the
-- other circle or box.  col_budget /= 0 limits the pairs per pass (col_trunc: the last pass was
-- cut off).  Results: a bit per object, the first (lowest-numbered) partner per object, the
-- count; double buffered (the pass writes the working set, CSwap makes it readable and toggles
-- col_toggle).  A copy waits for a pass.
-- Diagnostics only (the VIC-IV counters at $FFD71E0-3): ovf pulses when an expansion ends at
-- the buffer limit (EntWait, ObjDrain, Scan, HitEmit), part is high in Gotox0 (one object
-- part / v1 entry emitted), cstall while the copy has bytes left to issue and mfree = '0'.
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity rrb_list_expander is
  generic ( MLAT : integer := 4; CLAT : integer := 1; LIMIT : integer := 1020;
            BUFW : integer := 10;                    -- row buffer index bits (VIC-IV: 11, 2 KB)
            NOBJ : integer := 1024 );                -- table depth: 512 or 1024 objects
  port (
    clk       : in  std_logic;
    start     : in  std_logic;                        -- one cycle
    abort     : in  std_logic := '0';                 -- stop now (raster line restarted)
    ent_addr  : in  unsigned(19 downto 0);            -- chip RAM address of the first entry
    out_start : in  unsigned(BUFW - 1 downto 0);      -- row buffer index of the LIST token
    busy      : out std_logic;
    -- overlap with painting (VIC-IV): reads only while ofree; wpos = next buffer write index
    -- (every index below it is written for good while busy)
    ofree     : in  std_logic := '1';
    -- K325T step 7 (XCTL2 bit 0): faster object parts of the scan -- a one-row hit goes straight
    -- to HitEmit, and the object's first token reads are issued during its GOTOX (same output)
    fastx     : in  std_logic := '0';
    wpos      : out unsigned(BUFW - 1 downto 0);
    done      : out std_logic;                        -- one cycle when finished
    out_len   : out unsigned(BUFW downto 0);          -- buffer index after the end-of-line token (<= LIMIT + 4)
    -- chip RAM (read only)
    mreq      : out std_logic;
    maddr     : out unsigned(19 downto 0);
    mdata     : in  unsigned(7 downto 0);
    -- the aligned 32-bit chip RAM word holding mdata's byte, at mdata's time (fastx: a token at a
    -- 4-byte aligned address shows the $FFFF behind it, so the object ends 2 cycles earlier)
    mdata32   : in  unsigned(31 downto 0) := (others => '0');
    -- colour RAM (read only)
    caddr     : out unsigned(15 downto 0);
    cdata     : in  unsigned(7 downto 0);
    -- row buffers (screen and colour), same index
    bwe       : out std_logic;
    baddr     : out unsigned(BUFW - 1 downto 0);
    bscreen   : out unsigned(7 downto 0);
    bcolour   : out unsigned(7 downto 0);
    -- list mode v3 (global object table)
    scan_en    : in  std_logic := '0';               -- scan the object table after the lists
    start_scan : in  std_logic := '0';               -- with start: no lists, scan right away
    row        : in  unsigned(7 downto 0) := (others => '0');   -- character row number
    obj_count  : in  unsigned(9 downto 0) := (others => '0');
    copy_start : in  std_logic := '0';               -- one cycle: snapshot the table
    tab_addr   : in  unsigned(19 downto 0) := (others => '0');
    mfree      : in  std_logic := '1';               -- chip RAM port free for the copy now
    copying    : out std_logic;
    bk_full    : out std_logic := '0';               -- the last bucket build dropped entries
    -- diagnostics (VIC-IV counters at $FFD71E0-3; no effect on the expansion)
    ovf        : out std_logic := '0';               -- one cycle: ended by the buffer limit
    part       : out std_logic := '0';               -- an object part's GOTOX starts (Gotox0)
    cstall     : out std_logic := '0';               -- copy has bytes to issue, port not free
    -- collisions (docs "Collisions"): one pass per frame over the snapshot's buckets
    col_tick   : in  std_logic := '0';               -- one cycle per frame: run the pass
    col_budget : in  unsigned(15 downto 0) := (others => '0');       -- pairs per pass, 0 = all
    col_bits   : out std_logic_vector(1023 downto 0) := (others => '0');  -- last result
    col_count  : out unsigned(9 downto 0) := (others => '0');        -- objects with bit set
    col_trunc  : out std_logic := '0';               -- the last pass hit the budget
    col_toggle : out std_logic := '0';               -- toggles when a new result is readable
    col_pidx   : in  unsigned(9 downto 0) := (others => '0');        -- object number
    col_pdata  : out unsigned(9 downto 0);           -- its first partner ($3FF: none), async
    col_busy   : out std_logic := '0'                -- the pass runs
  );
end entity;

architecture rtl of rrb_list_expander is
  function nbits(n : integer) return integer is
  begin
    if n <= 512 then return 9; else return 10; end if;
  end function;
  constant NB    : integer := nbits(NOBJ);           -- table index bits
  constant PCAP  : integer := 2048;                  -- bucket entries
  constant NROWS : integer := 64;                    -- character rows with buckets

  type state_t is (Idle, EntReq, EntWait, Gotox0, Gotox1, ObjRun, ObjDrain, Finish0, Finish1, Fin,
                   ScanStart, Scan, HitB2, HitMul, HitEmit);
  signal state : state_t := Idle;

  -- request pipeline: what each in-flight chip RAM read was for
  type kind_t is (KNone, KEnt, KObj);
  type kinds_t is array (1 to MLAT) of kind_t;
  type idx_t is array (1 to MLAT) of unsigned(BUFW - 1 downto 0);
  signal pk   : kinds_t := (others => KNone);
  signal pidx : idx_t := (others => (others => '0'));     -- entry byte number / buffer index
  -- object generation of each in-flight read: a finished object's extra reads (issued until its
  -- $FFFF came back) are ignored, so the next object starts without waiting for them
  type gen_t is array (1 to MLAT) of std_logic;
  signal pg   : gen_t := (others => '0');
  type alo_t is array (1 to MLAT) of unsigned(1 downto 0);
  signal palo : alo_t := (others => "00");                 -- address bits 1..0 of each read
  signal nxt_ff : std_logic := '0';                        -- fastx: the token behind is $FFFF
  signal maddr_i : unsigned(19 downto 0) := (others => '0');  -- (maddr, readable)
  signal og   : std_logic := '0';
  type cdel_t is array (1 to MLAT) of unsigned(7 downto 0);
  signal cdl  : cdel_t := (others => (others => '0'));    -- colour data, delayed

  type ent_t is array (0 to 7) of unsigned(7 downto 0);
  signal ent      : ent_t := (others => (others => '0'));
  signal ent_got  : integer range 0 to 8 := 0;
  signal ent_req  : integer range 0 to 8 := 0;
  signal eaddr    : unsigned(19 downto 0) := (others => '0');
  signal opos     : unsigned(BUFW - 1 downto 0) := (others => '0');   -- next buffer write index
  signal last_x   : unsigned(9 downto 0) := (others => '0');
  signal oaddr    : unsigned(19 downto 0) := (others => '0');  -- next object byte to request
  signal ocol     : unsigned(15 downto 0) := (others => '0');
  signal oreq_idx : unsigned(BUFW - 1 downto 0) := (others => '0');   -- buffer index of next request
  signal flipx, flipy : std_logic := '0';
  signal ended    : std_logic := '0';                          -- object $FFFF seen (or full)
  signal full     : std_logic := '0';                          -- buffer limit reached
  signal prev_ff  : std_logic := '0';                          -- last even screen byte was $FF
  signal x_new    : unsigned(9 downto 0);
  signal gx       : unsigned(9 downto 0) := (others => '0');   -- X of the GOTOX being written
  signal mask_ff  : std_logic;

  -- object table snapshot: one 128-bit word per object (bytes 0..15, X/Y absolute: REL
  -- resolved, the REL bits and bits 15..11 of +0/+2 cleared).  Block RAM, two ports: A = copy
  -- writes, bucket build and collision pass reads; B = row scan reads.
  -- Three block RAMs by reader, so that every port reads all bits of its RAM (synthesis maps a
  -- RAM whose two ports would use different bits to LUT RAM): tab1 = X, Y, draw mask, height
  -- (both ports), tabA = circle, group, width, collides-with (port A), tabB = flags, address,
  -- colour offset, stride (port B).  tab_qa / tab_qb reassemble the 128-bit word (bits a port
  -- does not read are 0).
  type tab1_t is array (0 to NOBJ - 1) of std_logic_vector(33 downto 0);
  type taba_t is array (0 to NOBJ - 1) of std_logic_vector(24 downto 0);
  type tabb_t is array (0 to NOBJ - 1) of std_logic_vector(55 downto 0);
  signal tab1 : tab1_t;
  signal taba : taba_t;
  signal tabb : tabb_t;
  signal t1_qa, t1_qb : std_logic_vector(33 downto 0) := (others => '0');
  signal ta_q : std_logic_vector(24 downto 0) := (others => '0');
  signal tb_q : std_logic_vector(55 downto 0) := (others => '0');
  attribute ram_style : string;
  attribute ram_style of tab1, taba, tabb : signal is "block";
  signal tab_we   : std_logic := '0';
  signal tab_wa   : unsigned(NB - 1 downto 0) := (others => '0');
  signal tab_wd   : std_logic_vector(127 downto 0) := (others => '0');
  signal tab_aa   : unsigned(NB - 1 downto 0) := (others => '0');   -- port A read (build)
  signal ta_sel   : std_logic := '0';                              -- port A read at pool_qa
  signal ta_addr  : unsigned(NB - 1 downto 0);
  signal tab_qa, tab_qb : std_logic_vector(127 downto 0);
  -- buckets: object numbers in table order per row; block RAM, A = build writes, pass reads;
  -- B = row scan reads
  type pool_t is array (0 to PCAP - 1) of std_logic_vector(9 downto 0);
  shared variable pool : pool_t;
  attribute ram_style of pool : variable is "block";
  signal pool_we  : std_logic := '0';
  signal pool_aa  : unsigned(10 downto 0);
  signal pool_ba, pool_ca : unsigned(10 downto 0) := (others => '0');   -- build / pass address
  signal pool_wd  : std_logic_vector(9 downto 0) := (others => '0');
  signal pool_ab  : unsigned(10 downto 0) := (others => '0');
  signal pool_qa, pool_qb : std_logic_vector(9 downto 0) := (others => '0');
  type cnt_t is array (0 to NROWS) of signed(11 downto 0);
  signal bk_d     : cnt_t := (others => (others => '0'));       -- count differences per row
  type st_t is array (0 to NROWS) of unsigned(15 downto 0);
  signal bk_st    : st_t := (others => (others => '0'));        -- bucket start per row (+ end)
  type pt_t is array (0 to NROWS - 1) of unsigned(15 downto 0);
  signal bk_pt    : pt_t := (others => (others => '0'));        -- fill pointer per row
  type nn_t is array (0 to NROWS - 1) of unsigned(10 downto 0);
  signal bk_nn    : nn_t := (others => (others => '0'));        -- entries whose first row it is
  signal bk_f     : integer range 0 to NROWS - 1 := 0;
  type bstate_t is (BIdle, BPref, BRead, BWait, BGet, BRow);
  signal bstate   : bstate_t := BIdle;
  signal bk_run   : std_logic := '0';
  signal bk_r     : integer range 0 to NROWS := 0;
  signal bk_acc   : signed(11 downto 0) := (others => '0');
  signal bk_sum   : unsigned(15 downto 0) := (others => '0');
  signal bk_o     : unsigned(9 downto 0) := (others => '0');
  signal bk_l     : integer range 0 to NROWS - 1 := 0;
  signal bk_ovf   : std_logic := '0';
  signal bu_v     : std_logic := '0';                           -- count update pending
  signal bu_y     : unsigned(9 downto 0) := (others => '0');
  signal bu_h     : unsigned(5 downto 0) := (others => '0');
  signal bu_vis   : std_logic := '0';
  -- copy
  signal cp_run, cp_pend : std_logic := '0';
  signal cp_addr  : unsigned(19 downto 0) := (others => '0');
  signal cp_n, cp_issue : unsigned(13 downto 0) := (others => '0');
  signal cp_count : unsigned(9 downto 0) := (others => '0');    -- object count of the snapshot
  type cpv_t is array (1 to MLAT) of std_logic;
  type cpi_t is array (1 to MLAT) of unsigned(13 downto 0);
  signal cpv      : cpv_t := (others => '0');
  signal cpi      : cpi_t := (others => (others => '0'));
  signal cp_asm   : unsigned(119 downto 0) := (others => '0');
  signal cp_accx, cp_accy : unsigned(9 downto 0) := (others => '0');
  -- scan
  signal scanning : std_logic := '0';
  signal scan_after : std_logic := '0';
  signal row_l    : unsigned(7 downto 0) := (others => '0');
  signal s_issue, s_end : unsigned(11 downto 0) := (others => '0');   -- bucket positions
  signal spv      : std_logic_vector(1 to 3) := "000";
  -- fastx: the scan's next table word, read ahead while an object part is fetched and held
  -- (tab_qb keeps it while no new bucket read is issued) until the scan resumes
  signal sp_held  : std_logic := '0';
  signal sp_hidx  : unsigned(11 downto 0) := (others => '0');
  type spi_t is array (1 to 3) of unsigned(11 downto 0);
  signal spi      : spi_t := (others => (others => '0'));
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
  -- (fabric, not DSP: a DSP would absorb tabb's output register, and tabb would no longer map
  -- to block RAM)
  attribute use_dsp : string;
  attribute use_dsp of h_mul, pa_addr, pb_addr, pa_col, pb_col : signal is "no";

  -- the collision pass: per row, the pairs (i, j) of its bucket with i before j, tested in the
  -- first row both objects are listed in; one pair per cycle, a 6-stage pipeline per pair
  type cstate_t is (CIdle, CRow, CLoadA, CWa1, CWa2, CGetA, CPrepA, CInner, CEndI, CSwap);
  signal cstate   : cstate_t := CIdle;
  signal col_req  : std_logic := '0';
  signal c_row    : integer range 0 to NROWS := 0;
  signal c_p, c_e, c_j : unsigned(11 downto 0) := (others => '0');  -- bucket positions
  signal c_pairs, c_budget : unsigned(15 downto 0) := (others => '0');
  signal c_tr     : std_logic := '0';
  signal c_nnr    : unsigned(10 downto 0) := (others => '0');   -- first-row entries after i
  -- an object's collision shape (from its table word)
  type shape_t is record
    o    : unsigned(9 downto 0);       -- object number
    x0, x1, y0, y1 : signed(12 downto 0);   -- box, inclusive
    cx, cy : signed(13 downto 0);      -- doubled centre
    lx, rx, ly, ry : signed(13 downto 0);   -- doubled box edges (continuous)
    w    : unsigned(8 downto 0);       -- width = doubled radius
    circ : std_logic;
    act  : std_logic;
    grp, wth : unsigned(7 downto 0);
    fr   : unsigned(5 downto 0);       -- first bucketed row
  end record;
  constant SH0 : shape_t := ((others => '0'), (others => '0'), (others => '0'), (others => '0'),
                             (others => '0'), (others => '0'), (others => '0'), (others => '0'),
                             (others => '0'), (others => '0'), (others => '0'), (others => '0'),
                             '0', '0', (others => '0'), (others => '0'), (others => '0'));
  signal c_a      : shape_t := SH0;
  signal c_b3     : shape_t := SH0;                          -- stage 3: object j's shape
  signal c_v      : std_logic_vector(1 to 6) := (others => '0');   -- pipeline valid
  type cj_t is array (1 to 6) of unsigned(9 downto 0);
  signal c_jo     : cj_t := (others => (others => '0'));            -- object j per stage
  signal c_ok4, c_box4, c_cir4, c_ok5, c_box5, c_cir5 : std_logic := '0';
  signal c_dx4, c_dy4 : signed(13 downto 0) := (others => '0');
  signal c_r4     : unsigned(9 downto 0) := (others => '0');
  signal c_dx5, c_dy5 : unsigned(27 downto 0) := (others => '0');
  signal c_r5     : unsigned(19 downto 0) := (others => '0');
  signal c_w      : std_logic_vector(1023 downto 0) := (others => '0');   -- working bits
  signal c_r      : std_logic_vector(1023 downto 0) := (others => '0');   -- readable bits
  signal c_wcount, c_rcount : unsigned(9 downto 0) := (others => '0');
  signal c_pi_v   : std_logic := '0';
  signal c_pi     : unsigned(9 downto 0) := (others => '0');
  signal c_wi0    : std_logic := '0';                      -- object i had partners before
  signal c_rsel, c_tog, c_rtr : std_logic := '0';
  -- first partner per object, two buffers (the pass writes buffer not c_rsel)
  type part_t is array (0 to 1023) of unsigned(9 downto 0);
  signal pram0, pram1 : part_t := (others => (others => '1'));
  signal p_we     : std_logic := '0';
  signal p_wa, p_wd : unsigned(9 downto 0) := (others => '0');

  function any_obj(p : kinds_t) return boolean is
  begin
    for n in p'range loop
      if p(n) = KObj then return true; end if;
    end loop;
    return false;
  end function;

  -- the collision shape of a table word
  function shape(q : std_logic_vector(127 downto 0); o : unsigned(9 downto 0)) return shape_t is
    variable s : shape_t;
    variable u : unsigned(127 downto 0);
    variable w : unsigned(8 downto 0);
    variable h8 : signed(12 downto 0);
    variable fy : signed(12 downto 0);
  begin
    u := unsigned(q);
    s.o := o;
    if u(119 downto 112) = x"00" then w := to_unsigned(8, 9);
    else w := '0' & u(119 downto 112); end if;
    if u(45 downto 40) = "000000" then h8 := to_signed(8, 13);
    else h8 := signed(resize(u(45 downto 40) & "000", 13)); end if;
    s.x0 := signed(resize(u(9 downto 0), 13));
    s.x1 := s.x0 + signed(resize(w, 13)) - 1;
    s.y0 := resize(signed(u(25 downto 16)), 13);
    s.y1 := s.y0 + h8 - 1;
    s.lx := s.x0 & '0'; s.rx := s.lx + signed(resize(w & '0', 14));
    s.ly := s.y0 & '0'; s.ry := s.ly + (h8 & '0');
    s.cx := s.lx + signed(resize(w, 14));
    s.cy := s.ly + h8;
    s.w := w;
    s.circ := u(47);
    if u(39 downto 32) /= x"00" and u(63 downto 56) /= x"00" then s.act := '1'; else s.act := '0'; end if;
    s.grp := u(63 downto 56);
    if u(127 downto 120) = x"00" then s.wth := u(63 downto 56);
    else s.wth := u(127 downto 120); end if;
    fy := shift_right(s.y0, 3);                 -- floor(Y / 8)
    if fy < 0 then s.fr := (others => '0'); else s.fr := unsigned(fy(5 downto 0)); end if;
    return s;
  end function;

  -- distance of c outside [l, r] (0 inside)
  function outside(c, l, r : signed(13 downto 0)) return signed is
  begin
    if c < l then return l - c;
    elsif c > r then return c - r;
    else return to_signed(0, 14); end if;
  end function;
begin
  maddr <= maddr_i;
  busy <= '0' when state = Idle else '1';
  wpos <= opos;
  -- (the VIC-IV starts no expansion then); tab_we: the last table word is written in this cycle
  copying <= cp_run or cp_pend or copy_start or tab_we or bu_v or bk_run;
  part <= '1' when state = Gotox0 else '0';
  cstall <= '1' when cp_run = '1' and cp_issue /= cp_n and mfree = '0' else '0';
  bk_full <= bk_ovf;
  pool_aa <= pool_ba when bk_run = '1' else pool_ca;

  -- table RAM: port A (copy write / build and pass read), port B (scan read, at pool_qb)
  ta_addr <= tab_wa when tab_we = '1'
             else unsigned(pool_qa(NB - 1 downto 0)) when ta_sel = '1'
             else tab_aa;
  process (clk)
    variable ab : integer range 0 to NOBJ - 1;
  begin
    if rising_edge(clk) then
      ab := to_integer(unsigned(pool_qb(NB - 1 downto 0)));
      if tab_we = '1' then
        tab1(to_integer(ta_addr)) <= tab_wd(45 downto 40) & tab_wd(39 downto 32)
                                     & tab_wd(25 downto 16) & tab_wd(9 downto 0);
        taba(to_integer(ta_addr)) <= tab_wd(47) & tab_wd(63 downto 56) & tab_wd(127 downto 112);
        tabb(to_integer(ta_addr)) <= tab_wd(111 downto 64) & tab_wd(55 downto 48);
      end if;
      t1_qa <= tab1(to_integer(ta_addr));
      ta_q <= taba(to_integer(ta_addr));
      t1_qb <= tab1(ab);
      tb_q <= tabb(ab);
    end if;
  end process;
  -- the 128-bit words as the copy wrote them (bits the port does not read: 0)
  tab_qa <= ta_q(15 downto 0) & x"000000000000" & ta_q(23 downto 16) & x"00" & ta_q(24) & '0'
            & t1_qa(33 downto 28) & t1_qa(27 downto 20) & "000000" & t1_qa(19 downto 10)
            & "000000" & t1_qa(9 downto 0);
  tab_qb <= x"0000" & tb_q(55 downto 8) & x"00" & tb_q(7 downto 0) & "00"
            & t1_qb(33 downto 28) & t1_qb(27 downto 20) & "000000" & t1_qb(19 downto 10)
            & "000000" & t1_qb(9 downto 0);
  -- bucket RAM: port A (build write / pass read), port B (scan read)
  process (clk) begin
    if rising_edge(clk) then
      if pool_we = '1' then
        pool(to_integer(pool_aa)) := pool_wd;
      end if;
      pool_qa <= pool(to_integer(pool_aa));
    end if;
  end process;
  process (clk) begin
    if rising_edge(clk) then
      pool_qb <= pool(to_integer(pool_ab));
    end if;
  end process;

  -- collisions: partner RAMs (written by the pass, read asynchronously through col_pidx),
  -- results
  col_bits <= c_r;
  col_count <= c_rcount;
  col_trunc <= c_rtr;
  col_toggle <= c_tog;
  col_busy <= '0' when cstate = CIdle else '1';
  col_pdata <= (others => '1') when c_r(to_integer(col_pidx)) = '0'
               else pram0(to_integer(col_pidx)) when c_rsel = '0'
               else pram1(to_integer(col_pidx));

  process (clk)
    variable b : shape_t;
    variable hit, ok : boolean;
    variable inc : unsigned(9 downto 0);
    variable jj, ii : integer range 0 to 1023;
    variable pw : unsigned(9 downto 0);
    variable e : unsigned(15 downto 0);
    variable fr : unsigned(5 downto 0);
    variable s5 : unsigned(28 downto 0);
  begin
    if rising_edge(clk) then
      p_we <= '0';
      if col_tick = '1' then
        col_req <= '1';
      end if;
      -- pair pipeline: 1 bucket read, 2 table read (at the bucket's object number), 3 shape of
      -- j, 4 tests / distances, 5 squares, 6 result
      c_v(2 to 6) <= c_v(1 to 5); c_v(1) <= '0';
      c_jo(4 to 6) <= c_jo(3 to 5);
      if c_v(2) = '1' then c_jo(3) <= unsigned(pool_qa); end if;
      -- stage 3: object j's shape
      c_b3 <= shape(tab_qa, c_jo(3));
      -- stage 4
      b := c_b3;
      if c_a.fr > b.fr then fr := c_a.fr; else fr := b.fr; end if;
      if c_a.act = '1' and b.act = '1' and (c_a.grp and b.wth) /= x"00" and (b.grp and c_a.wth) /= x"00"
         and to_integer(fr) = c_row then
        c_ok4 <= '1';
      else
        c_ok4 <= '0';
      end if;
      if c_a.x0 <= b.x1 and b.x0 <= c_a.x1 and c_a.y0 <= b.y1 and b.y0 <= c_a.y1 then
        c_box4 <= '1';
      else
        c_box4 <= '0';
      end if;
      c_cir4 <= c_a.circ or b.circ;
      if c_a.circ = '1' and b.circ = '1' then
        c_dx4 <= c_a.cx - b.cx; c_dy4 <= c_a.cy - b.cy;
        c_r4 <= ('0' & c_a.w) + ('0' & b.w);
      elsif c_a.circ = '1' then
        c_dx4 <= outside(c_a.cx, b.lx, b.rx); c_dy4 <= outside(c_a.cy, b.ly, b.ry);
        c_r4 <= '0' & c_a.w;
      else
        c_dx4 <= outside(b.cx, c_a.lx, c_a.rx); c_dy4 <= outside(b.cy, c_a.ly, c_a.ry);
        c_r4 <= '0' & b.w;
      end if;
      -- stage 5: squares (DSP)
      c_dx5 <= unsigned(c_dx4 * c_dx4); c_dy5 <= unsigned(c_dy4 * c_dy4);
      c_r5 <= c_r4 * c_r4;
      c_ok5 <= c_ok4; c_box5 <= c_box4; c_cir5 <= c_cir4;
      -- stage 6: the result
      s5 := ('0' & c_dx5) + ('0' & c_dy5);
      if c_cir5 = '1' then
        hit := s5 <= resize(c_r5, 29);
      else
        hit := c_box5 = '1';
      end if;
      if c_v(6) = '1' and c_ok5 = '1' and hit then
        ii := to_integer(c_a.o); jj := to_integer(c_jo(6));
        inc := (others => '0');
        if c_w(ii) = '0' then inc := inc + 1; end if;
        -- object i: the lowest partner of this inner loop (written in CEndI)
        if c_pi_v = '0' or c_jo(6) < c_pi then c_pi_v <= '1'; c_pi <= c_jo(6); end if;
        -- object j: its lowest partner so far (pairs come in row order, not number order)
        if c_rsel = '0' then pw := pram1(jj); else pw := pram0(jj); end if;
        if c_w(jj) = '0' then
          inc := inc + 1;
          p_we <= '1'; p_wa <= c_jo(6); p_wd <= c_a.o;
        elsif c_a.o < pw then
          p_we <= '1'; p_wa <= c_jo(6); p_wd <= c_a.o;
        end if;
        c_w(ii) <= '1'; c_w(jj) <= '1';
        c_wcount <= c_wcount + inc;
      end if;

      case cstate is
        when CIdle =>
          ta_sel <= '0';
          -- after the copy and the bucket build; with HOLD on the held snapshot
          if col_req = '1' and cp_run = '0' and cp_pend = '0' and copy_start = '0' and tab_we = '0'
             and bu_v = '0' and bk_run = '0' then
            col_req <= '0';
            c_row <= 0;
            c_w <= (others => '0'); c_wcount <= (others => '0');
            c_pairs <= (others => '0'); c_budget <= col_budget; c_tr <= '0';
            cstate <= CRow;
          end if;
        when CRow =>
          ta_sel <= '0';
          if c_row = NROWS then
            cstate <= CSwap;
          else
            -- the row's bucket [start, end), the end clamped to the capacity
            if bk_st(c_row + 1) > PCAP then e := to_unsigned(PCAP, 16); else e := bk_st(c_row + 1); end if;
            -- (a row without objects starting in it has no new pairs: all were tested above)
            if bk_st(c_row) + 1 < e and bk_nn(c_row) /= 0 then
              c_p <= bk_st(c_row)(11 downto 0); c_e <= e(11 downto 0);
              c_nnr <= bk_nn(c_row);
              cstate <= CLoadA;
            else
              c_row <= c_row + 1;
            end if;
          end if;
        when CLoadA =>
          pool_ca <= c_p(10 downto 0); ta_sel <= '1';
          c_pi_v <= '0';
          cstate <= CWa1;
        when CWa1 =>
          cstate <= CWa2;
        when CWa2 =>
          cstate <= CGetA;
        when CGetA =>
          c_a <= shape(tab_qa, unsigned(pool_qa));
          cstate <= CPrepA;
        when CPrepA =>
          c_wi0 <= c_w(to_integer(c_a.o));
          c_j <= c_p + 1;
          if to_integer(c_a.fr) = c_row then
            c_nnr <= c_nnr - 1;                   -- i starts in this row
            cstate <= CInner;
          elsif c_nnr = 0 then
            -- i and every object after it continue from rows above: no new pairs in this row
            c_row <= c_row + 1;
            cstate <= CRow;
          else
            cstate <= CInner;
          end if;
        when CInner =>
          if c_j < c_e and (c_budget = 0 or c_pairs /= c_budget) then
            pool_ca <= c_j(10 downto 0);
            c_v(1) <= '1';
            c_j <= c_j + 1;
            c_pairs <= c_pairs + 1;
          elsif c_v(1 to 6) = "000000" then
            if c_j < c_e then c_tr <= '1'; end if;      -- stopped by the budget
            cstate <= CEndI;
          end if;
        when CEndI =>
          ii := to_integer(c_a.o);
          if c_rsel = '0' then pw := pram1(ii); else pw := pram0(ii); end if;
          if c_pi_v = '1' and (c_wi0 = '0' or c_pi < pw) then
            p_we <= '1'; p_wa <= c_a.o; p_wd <= c_pi;
          end if;
          if c_tr = '1' then
            cstate <= CSwap;
          elsif c_p + 2 < c_e then
            c_p <= c_p + 1;
            cstate <= CLoadA;
          else
            c_row <= c_row + 1;
            cstate <= CRow;
          end if;
        when CSwap =>
          ta_sel <= '0';
          c_r <= c_w; c_rcount <= c_wcount; c_rtr <= c_tr;
          c_rsel <= not c_rsel; c_tog <= not c_tog;
          cstate <= CIdle;
      end case;
      if p_we = '1' then
        if c_rsel = '0' then pram1(to_integer(p_wa)) <= p_wd;
        else pram0(to_integer(p_wa)) <= p_wd; end if;
      end if;
    end if;
  end process;

  -- X of the synthesised GOTOX: absolute, or the previous entry's X + signed offset (REL)
  x_new <= (ent(1)(1 downto 0) & ent(0)) when ent(1)(2) = '0'
           else last_x + (ent(1)(1 downto 0) & ent(0));
  mask_ff <= '1' when ent(2) = x"FF" else '0';

  process (clk)
    variable k : kind_t;
    variable i : unsigned(BUFW - 1 downto 0);
    variable c : unsigned(7 downto 0);
    variable q : std_logic_vector(127 downto 0);
    variable qa : unsigned(127 downto 0);
    variable ax, ay : unsigned(9 downto 0);
    variable rr : signed(10 downto 0);
    variable hh : signed(10 downto 0);
    variable o  : unsigned(2 downto 0);
    variable pa, pb : boolean;
    variable d  : signed(10 downto 0);
    variable ma, mb : unsigned(7 downto 0);
    variable aa : unsigned(19 downto 0);
    variable ca : unsigned(15 downto 0);
    variable fy : std_logic;
    variable yl : signed(12 downto 0);
    variable f, l : integer range -64 to 127;
    variable e, sb : unsigned(15 downto 0);
    variable infl : boolean;
    variable endnow : boolean;
  begin
    if rising_edge(clk) then
      done <= '0';
      bwe <= '0';
      mreq <= '0';
      tab_we <= '0';
      pool_we <= '0';
      ovf <= '0';

      -- table copy: returning bytes, assembled into 128-bit words (they arrive in order)
      for n in MLAT downto 2 loop
        cpv(n) <= cpv(n - 1); cpi(n) <= cpi(n - 1);
      end loop;
      cpv(1) <= '0';
      bu_v <= '0';
      if cpv(MLAT) = '1' then
        if cpi(MLAT)(3 downto 0) = "1111" then
          qa := mdata & cp_asm;
          -- REL resolved here: every object is an anchor (also a hidden one)
          if qa(10) = '1' then ax := cp_accx + qa(9 downto 0); else ax := qa(9 downto 0); end if;
          if qa(26) = '1' then ay := cp_accy + qa(25 downto 16); else ay := qa(25 downto 16); end if;
          cp_accx <= ax; cp_accy <= ay;
          qa(15 downto 0) := "000000" & ax;
          qa(31 downto 16) := "000000" & ay;
          tab_we <= '1'; tab_wa <= cpi(MLAT)(NB + 3 downto 4); tab_wd <= std_logic_vector(qa);
          -- the rows it touches: counted next cycle (bucket sizes)
          bu_v <= '1'; bu_y <= ay; bu_h <= qa(45 downto 40);
          if qa(39 downto 32) /= x"00" then bu_vis <= '1'; else bu_vis <= '0'; end if;
        end if;
        cp_asm <= mdata & cp_asm(119 downto 8);
      end if;
      -- bucket sizes: +1 at the first row, -1 after the last (rows clamped to 0..63)
      if bu_v = '1' and bu_vis = '1' then
        f := to_integer(shift_right(signed(bu_y), 3));
        if bu_h = "000000" then yl := resize(signed(bu_y), 13) + 7;
        else yl := resize(signed(bu_y), 13) + signed(resize(bu_h & "000", 13)) - 1; end if;
        l := to_integer(shift_right(yl, 3));
        if l >= 0 and f < NROWS then
          if f < 0 then f := 0; end if;
          if l > NROWS - 1 then l := NROWS - 1; end if;
          bk_d(f) <= bk_d(f) + 1;
          bk_d(l + 1) <= bk_d(l + 1) - 1;
        end if;
      end if;
      if copy_start = '1' then
        cp_pend <= '1';
      end if;
      if cp_run = '0' and cp_pend = '1' and state = Idle and start = '0' and cstate = CIdle
         and bk_run = '0' then
        cp_pend <= '0'; cp_run <= '1';
        cp_accx <= (others => '0'); cp_accy <= (others => '0');
        cp_addr <= tab_addr; cp_issue <= (others => '0');
        if obj_count > NOBJ - 1 then
          cp_n <= to_unsigned(NOBJ - 1, 10) & "0000";
          cp_count <= to_unsigned(NOBJ - 1, 10);
        else
          cp_n <= obj_count & "0000";           -- 16 bytes per object
          cp_count <= obj_count;                -- part of the snapshot
        end if;
        bk_d <= (others => (others => '0'));
      end if;
      if cp_run = '1' then
        if cp_issue /= cp_n then
          if mfree = '1' then                    -- else stall: the VIC-IV uses the port now
            mreq <= '1';
            -- object o (32 bytes apart), byte 0..15
            maddr_i <= cp_addr + (cp_issue(13 downto 4) & '0' & cp_issue(3 downto 0));
            cpv(1) <= '1'; cpi(1) <= cp_issue;
            cp_issue <= cp_issue + 1;
          end if;
        else
          -- done once no request is in flight (cpv(MLAT) returns in this cycle)
          cp_run <= '0';
          for n in 1 to MLAT - 1 loop
            if cpv(n) = '1' then cp_run <= '1'; end if;
          end loop;
          infl := false;
          for n in 1 to MLAT - 1 loop
            if cpv(n) = '1' then infl := true; end if;
          end loop;
          if cp_run = '1' and not infl then
            bk_run <= '1'; bstate <= BPref;     -- (the last word's count follows in bu_v)
            bk_r <= 0; bk_acc <= (others => '0'); bk_sum <= (others => '0');
          end if;
        end if;
      end if;

      -- bucket build: prefix sums of the counts (starts), then a pass over the table filling
      -- each object into the rows it touches, in table order
      case bstate is
        when BIdle =>
          null;
        when BPref =>
          if bu_v = '0' and tab_we = '0' then
            -- start of row bk_r = sum of the counts of the rows above
            bk_st(bk_r) <= bk_sum;
            if bk_r < NROWS then
              bk_pt(bk_r) <= bk_sum; bk_nn(bk_r) <= (others => '0');
              bk_sum <= bk_sum + unsigned(bk_acc + bk_d(bk_r));
              bk_acc <= bk_acc + bk_d(bk_r);
              bk_r <= bk_r + 1;
            else
              bk_o <= (others => '0'); bk_ovf <= '0';
              bstate <= BRead;
            end if;
          end if;
        when BRead =>
          if bk_o = cp_count then
            bk_run <= '0'; bstate <= BIdle;
          else
            tab_aa <= bk_o(NB - 1 downto 0);
            bstate <= BWait;
          end if;
        when BWait =>
          bstate <= BGet;
        when BGet =>
          f := to_integer(shift_right(signed(tab_qa(25 downto 16)), 3));
          if tab_qa(45 downto 40) = "000000" then yl := resize(signed(tab_qa(25 downto 16)), 13) + 7;
          else yl := resize(signed(tab_qa(25 downto 16)), 13) + signed(resize(unsigned(tab_qa(45 downto 40)) & "000", 13)) - 1; end if;
          l := to_integer(shift_right(yl, 3));
          if tab_qa(39 downto 32) /= x"00" and l >= 0 and f < NROWS then
            if f < 0 then f := 0; end if;
            if l > NROWS - 1 then l := NROWS - 1; end if;
            bk_r <= f; bk_l <= l; bk_f <= f;
            bstate <= BRow;
          else
            bk_o <= bk_o + 1;
            bstate <= BRead;
          end if;
        when BRow =>
          if bk_pt(bk_r) < PCAP then
            pool_we <= '1'; pool_ba <= bk_pt(bk_r)(10 downto 0);
            pool_wd <= std_logic_vector(bk_o);
            if bk_r = bk_f then bk_nn(bk_r) <= bk_nn(bk_r) + 1; end if;
          else
            bk_ovf <= '1';                        -- capacity: dropped
          end if;
          bk_pt(bk_r) <= bk_pt(bk_r) + 1;
          if bk_r = bk_l then
            bk_o <= bk_o + 1;
            bstate <= BRead;
          else
            bk_r <= bk_r + 1;
          end if;
      end case;

      -- shift the request pipeline and the colour data
      for n in MLAT downto 2 loop
        pk(n) <= pk(n - 1); pidx(n) <= pidx(n - 1); cdl(n) <= cdl(n - 1); pg(n) <= pg(n - 1);
      end loop;
      for n in MLAT downto 3 loop palo(n) <= palo(n - 1); end loop;
      palo(2) <= maddr_i(1 downto 0);              -- (the read on the port now is pk(1)'s)
      pk(1) <= KNone;
      cdl(1) <= cdata;

      -- data returning now was requested MLAT cycles ago; caddr leaves this unit registered, so
      -- its colour byte arrived CLAT + 1 cycles after the request and waits in cdl(MLAT-CLAT-1)
      k := pk(MLAT); i := pidx(MLAT);
      -- (fastx: the object's closing $FF$FF is back in this very cycle)
      endnow := k = KObj and ended = '0' and pg(MLAT) = og and i(0) = '1'
                and ((prev_ff = '1' and mdata = x"FF") or (fastx = '1' and nxt_ff = '1'));
      if k = KEnt then
        ent(to_integer(i(2 downto 0))) <= mdata;
        ent_got <= ent_got + 1;
      elsif k = KObj and ended = '0' and pg(MLAT) = og then
        c := cdl(MLAT - CLAT - 1);
        if i(0) = '0' then
          -- low byte of a token (colour byte 0: flip bits, GOTOX flag)
          if i > to_unsigned(LIMIT, BUFW) then
            ended <= '1'; full <= '1'; opos <= i;
          else
            if c(4) = '0' then                    -- a glyph, not a GOTOX inside the object
              c(6) := c(6) xor flipx;
              c(7) := c(7) xor flipy;
            end if;
            bwe <= '1'; baddr <= i; bscreen <= mdata; bcolour <= c;
            if mdata = x"FF" then prev_ff <= '1'; else prev_ff <= '0'; end if;
            if fastx = '1' and palo(MLAT) = "00" and mdata32(31 downto 16) = x"FFFF" then
              nxt_ff <= '1';
            else
              nxt_ff <= '0';
            end if;
          end if;
        else
          if prev_ff = '1' and mdata = x"FF" then
            ended <= '1'; opos <= i - 1;          -- the next GOTOX overwrites the low $FF
          else
            bwe <= '1'; baddr <= i; bscreen <= mdata; bcolour <= c;
            opos <= i + 1;
            if fastx = '1' and nxt_ff = '1' then
              ended <= '1';                       -- (the $FFFF behind was seen in the word)
            end if;
          end if;
        end if;
      end if;

      -- scan pipeline: 1 bucket read (position registered here), 2 table read at the bucket's
      -- object number, 3 the table word
      spv(2 to 3) <= spv(1 to 2); spi(2 to 3) <= spi(1 to 2);
      spv(1) <= '0';
      if spv(3) = '1' and state /= Scan then    -- (fastx read-ahead arrived: hold it)
        sp_held <= '1'; sp_hidx <= spi(3);
      end if;

      if abort = '1' then
        state <= Idle;
        pk <= (others => KNone);
        scanning <= '0'; spv <= "000"; sp_held <= '0';
      else
      case state is
        when Idle =>
          if start = '1' then
            eaddr <= ent_addr; opos <= out_start; last_x <= (others => '0'); full <= '0';
            ent_req <= 0; ent_got <= 0;
            scanning <= '0'; scan_after <= scan_en;
            row_l <= row;
            if start_scan = '1' then
              state <= ScanStart;
            else
              state <= EntReq;
            end if;
          end if;

        when EntReq =>
          if ofree = '1' then                     -- (else: the VIC-IV uses the port next cycle)
            mreq <= '1'; maddr_i <= eaddr + ent_req;
            pk(1) <= KEnt; pidx(1) <= to_unsigned(ent_req, BUFW);
            if ent_req = 7 then state <= EntWait; end if;
            ent_req <= ent_req + 1;
          end if;

        when EntWait =>
          if ent_got = 8 then
            eaddr <= eaddr + 8;
            if opos > to_unsigned(LIMIT - 2, BUFW) then
              state <= Finish0; ovf <= '1';
            elsif ent(0) = x"FF" and ent(1) = x"FF" then
              if scan_after = '1' then
                state <= ScanStart;               -- v3: the global objects follow the lists
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
          if fastx = '1' and scanning = '1' and ofree = '1' and oreq_idx <= to_unsigned(LIMIT + 1, BUFW) then
            mreq <= '1'; maddr_i <= oaddr; caddr <= ocol;
            pk(1) <= KObj; pidx(1) <= oreq_idx; pg(1) <= og;
            oaddr <= oaddr + 1; ocol <= ocol + 1; oreq_idx <= oreq_idx + 1;
          end if;

        when Gotox1 =>
          bwe <= '1'; baddr <= opos + 1;
          -- high byte: Y offset (15..13) and sign (12) as given, REL/reserved cleared, X 9..8
          bscreen <= ent(1)(7 downto 4) & "00" & gx(9 downto 8);
          bcolour <= ent(2);                      -- draw mask
          opos <= opos + 2;
          state <= ObjRun;
          if fastx = '1' and scanning = '1' then
            -- (set up in HitEmit; the reads go on)
            if ofree = '1' and oreq_idx <= to_unsigned(LIMIT + 1, BUFW) then
              mreq <= '1'; maddr_i <= oaddr; caddr <= ocol;
              pk(1) <= KObj; pidx(1) <= oreq_idx; pg(1) <= og;
              oaddr <= oaddr + 1; ocol <= ocol + 1; oreq_idx <= oreq_idx + 1;
            end if;
          else
            flipx <= ent(3)(4); flipy <= ent(3)(5);
            oaddr <= ent(3)(3 downto 0) & ent(5) & ent(4);
            ocol  <= ent(7) & ent(6);
            oreq_idx <= opos + 2;
            ended <= '0'; prev_ff <= '0';
            og <= not og;                         -- a new object: older reads are stale
          end if;

        when ObjRun =>
          if ended = '1' or (fastx = '1' and endnow) then
            -- the object's $FFFF is back: its extra reads in flight are ignored (generation)
            mb := h_mask and (shift_left(to_unsigned(1, 8), to_integer(h_o)) - 1);
            if full = '1' then
              state <= Finish0; ovf <= '1';
            elsif scanning = '1' and fastx = '1' and not (h_pb = '1' and mb /= x"00") then
              -- no other part of this object: on with the scan (HitEmit's last branch)
              h_pa <= '0'; h_pb <= '0';
              state <= Scan;
              if s_issue < s_end and spv = "000" and sp_held = '0' then
                pool_ab <= s_issue(10 downto 0);
                spv(1) <= '1'; spi(1) <= s_issue;
                s_issue <= s_issue + 1;
              end if;
            elsif scanning = '1' then
              state <= HitEmit;                   -- v3: the other part, or on with the scan
            else
              state <= EntReq; ent_req <= 0; ent_got <= 0;
            end if;
          elsif oreq_idx > to_unsigned(LIMIT + 1, BUFW) then
            state <= ObjDrain;
          elsif ofree = '1' then
            mreq <= '1'; maddr_i <= oaddr; caddr <= ocol;
            pk(1) <= KObj; pidx(1) <= oreq_idx; pg(1) <= og;
            oaddr <= oaddr + 1; ocol <= ocol + 1; oreq_idx <= oreq_idx + 1;
          end if;

        when ObjDrain =>
          -- wait until no object read is in flight
          if not any_obj(pk) then
            if full = '1' or ended = '0' then
              state <= Finish0; ovf <= '1';       -- buffer full (requests stopped at the limit)
            elsif scanning = '1' then
              state <= HitEmit;                   -- v3: the other part, or on with the scan
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

        -- v3: walk the bucket of this character row
        when ScanStart =>
          scanning <= '1'; sp_held <= '0';
          if row_l < NROWS then
            if bk_st(to_integer(row_l) + 1) > PCAP then e := to_unsigned(PCAP, 16);
            else e := bk_st(to_integer(row_l) + 1); end if;
            if bk_st(to_integer(row_l)) > PCAP then sb := to_unsigned(PCAP, 16);
            else sb := bk_st(to_integer(row_l)); end if;
            s_issue <= sb(11 downto 0); s_end <= e(11 downto 0);
          else
            s_issue <= (others => '0'); s_end <= (others => '0');
          end if;
          state <= Scan;

        when Scan =>
          if s_issue < s_end then
            pool_ab <= s_issue(10 downto 0);
            spv(1) <= '1'; spi(1) <= s_issue;
            s_issue <= s_issue + 1;
          elsif spv = "000" and sp_held = '0' then
            state <= Finish0;                     -- all objects seen
          end if;
          if opos > to_unsigned(LIMIT - 2, BUFW) then
            state <= Finish0; spv <= "000"; sp_held <= '0'; ovf <= '1';
          elsif spv(3) = '1' or sp_held = '1' then
            sp_held <= '0';
            q := tab_qb;
            ax := unsigned(q(9 downto 0)); ay := unsigned(q(25 downto 16));
            -- object row of this character row's top part: row - floor(y / 8)
            rr := signed(unsigned'("000" & row_l)) - resize(signed(ay(9 downto 3)), 11);
            if q(45 downto 40) = "000000" then
              hh := to_signed(1, 11);
            else
              hh := signed(unsigned'("00000" & unsigned(q(45 downto 40))));
            end if;
            o := ay(2 downto 0);
            pa := q(39 downto 32) /= x"00" and rr >= 0 and rr < hh;
            pb := q(39 downto 32) /= x"00" and o /= "000" and rr >= 1 and rr <= hh;
            if pa or pb then
              h_x <= ax; h_o <= o; h_mask <= unsigned(q(39 downto 32));
              h_flags <= unsigned(q(55 downto 48));
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
              h_addr <= unsigned(q(51 downto 48)) & unsigned(q(79 downto 64));
              h_col <= unsigned(q(95 downto 80));
              h_stride <= unsigned(q(111 downto 96));
              if sp_held = '1' then s_issue <= sp_hidx + 1;
              else s_issue <= spi(3) + 1; end if;  -- resume after this object
              spv <= "000";
              state <= HitB2;
              if fastx = '1' and d = 0 then
                -- object row 0 (no multiply): HitMul's work here, straight to HitEmit
                aa := unsigned(q(51 downto 48)) & unsigned(q(79 downto 64));
                ca := unsigned(q(95 downto 80));
                pa_addr <= aa; pa_col <= ca;
                if not pa then
                  pb_addr <= aa; pb_col <= ca;
                elsif q(53) = '1' then
                  pb_addr <= aa + unsigned(q(111 downto 96)); pb_col <= ca + unsigned(q(111 downto 96));
                else
                  pb_addr <= aa - unsigned(q(111 downto 96)); pb_col <= ca - unsigned(q(111 downto 96));
                end if;
                state <= HitEmit;
              end if;
            end if;
          end if;

        when HitB2 =>
          h_mul <= h_k * h_stride;
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
          if opos > to_unsigned(LIMIT - 2, BUFW) then
            -- buffer limit as in EntWait (a GOTOX + tokens no longer fit): end the row here,
            -- also instead of resuming the scan
            h_pa <= '0'; h_pb <= '0';
            state <= Finish0; ovf <= '1';
          elsif h_pa = '1' and ma /= x"00" then
            h_pa <= '0';
            ent(1) <= h_o & (not fy) & "00" & h_x(9 downto 8);
            ent(2) <= ma;
            state <= Gotox0;
            if fastx = '1' then                   -- (Gotox1's object set-up, done here)
              flipx <= h_flags(4); flipy <= h_flags(5);
              oaddr <= pa_addr; ocol <= pa_col;
              oreq_idx <= opos + 2; ended <= '0'; prev_ff <= '0'; og <= not og;
              -- read the scan's next table word ahead (held until the scan resumes)
              if spv = "000" and sp_held = '0' and s_issue < s_end then
                pool_ab <= s_issue(10 downto 0);
                spv(1) <= '1'; spi(1) <= s_issue;
                s_issue <= s_issue + 1;
              end if;
            end if;
          elsif h_pb = '1' and mb /= x"00" then
            h_pb <= '0'; h_pa <= '0';
            ent(1) <= ((not h_o) + 1) & fy & "00" & h_x(9 downto 8);
            ent(2) <= mb;
            ent(3) <= h_flags(7 downto 4) & pb_addr(19 downto 16);
            ent(4) <= pb_addr(7 downto 0); ent(5) <= pb_addr(15 downto 8);
            ent(6) <= pb_col(7 downto 0); ent(7) <= pb_col(15 downto 8);
            state <= Gotox0;
            if fastx = '1' then                   -- (Gotox1's object set-up, done here)
              flipx <= h_flags(4); flipy <= h_flags(5);
              oaddr <= pb_addr; ocol <= pb_col;
              oreq_idx <= opos + 2; ended <= '0'; prev_ff <= '0'; og <= not og;
              -- read the scan's next table word ahead (held until the scan resumes)
              if spv = "000" and sp_held = '0' and s_issue < s_end then
                pool_ab <= s_issue(10 downto 0);
                spv(1) <= '1'; spi(1) <= s_issue;
                s_issue <= s_issue + 1;
              end if;
            end if;
          else
            h_pa <= '0'; h_pb <= '0';
            state <= Scan;
            -- the scan's next bucket read already now (it resumes one cycle earlier; not when
            -- the fastx read-ahead has one in flight or held)
            if s_issue < s_end and spv = "000" and sp_held = '0' then
              pool_ab <= s_issue(10 downto 0);
              spv(1) <= '1'; spi(1) <= s_issue;
              s_issue <= s_issue + 1;
            end if;
          end if;
      end case;
      end if;
    end if;
  end process;
end architecture;
