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
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity rrb_list_expander is
  generic ( MLAT : integer := 4; CLAT : integer := 1; LIMIT : integer := 1020 );
  port (
    clk       : in  std_logic;
    start     : in  std_logic;                        -- one cycle
    ent_addr  : in  unsigned(19 downto 0);            -- chip RAM address of the first entry
    out_start : in  unsigned(9 downto 0);             -- row buffer index of the LIST token
    busy      : out std_logic;
    done      : out std_logic;                        -- one cycle when finished
    out_len   : out unsigned(9 downto 0);             -- buffer index after the end-of-line token
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
    bcolour   : out unsigned(7 downto 0)
  );
end entity;

architecture rtl of rrb_list_expander is
  type state_t is (Idle, EntReq, EntWait, Gotox0, Gotox1, ObjRun, ObjDrain, Finish0, Finish1, Fin);
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
  signal mask_ff  : std_logic;

  function any_obj(p : kinds_t) return boolean is
  begin
    for n in p'range loop
      if p(n) = KObj then return true; end if;
    end loop;
    return false;
  end function;
begin
  busy <= '0' when state = Idle else '1';

  -- X of the synthesised GOTOX: absolute, or the previous entry's X + signed offset (REL)
  x_new <= (ent(1)(1 downto 0) & ent(0)) when ent(1)(2) = '0'
           else last_x + (ent(1)(1 downto 0) & ent(0));
  mask_ff <= '1' when ent(2) = x"FF" else '0';

  process (clk)
    variable k : kind_t;
    variable i : unsigned(9 downto 0);
    variable c : unsigned(7 downto 0);
  begin
    if rising_edge(clk) then
      done <= '0';
      bwe <= '0';
      mreq <= '0';

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

      case state is
        when Idle =>
          if start = '1' then
            eaddr <= ent_addr; opos <= out_start; last_x <= (others => '0'); full <= '0';
            state <= EntReq; ent_req <= 0; ent_got <= 0;
          end if;

        when EntReq =>
          mreq <= '1'; maddr <= eaddr + ent_req;
          pk(1) <= KEnt; pidx(1) <= to_unsigned(ent_req, 10);
          if ent_req = 7 then state <= EntWait; end if;
          ent_req <= ent_req + 1;

        when EntWait =>
          if ent_got = 8 then
            eaddr <= eaddr + 8;
            if (ent(0) = x"FF" and ent(1) = x"FF") or opos > to_unsigned(LIMIT - 2, 10) then
              state <= Finish0;
            else
              state <= Gotox0;
            end if;
          end if;

        when Gotox0 =>
          bwe <= '1'; baddr <= opos;
          bscreen <= x_new(7 downto 0);
          -- colour byte 0: bit 7 transparent, bit 6 behind, bit 4 GOTOX, bit 3 ROWMASK enable
          bcolour <= ent(3)(6) & ent(3)(7) & "01" & (not mask_ff) & "000";
          last_x <= x_new;
          state <= Gotox1;

        when Gotox1 =>
          bwe <= '1'; baddr <= opos + 1;
          -- high byte: Y offset (15..13) and sign (12) as given, REL/reserved cleared, X 9..8
          bscreen <= ent(1)(7 downto 4) & "00" & x_new(9 downto 8);
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
              state <= Finish0;                   -- buffer full (requests stopped at the limit)
            else
              state <= EntReq; ent_req <= 0; ent_got <= 0;
            end if;
          end if;

        when Finish0 =>
          bwe <= '1'; baddr <= opos; bscreen <= x"FF"; bcolour <= x"00";
          state <= Finish1;
        when Finish1 =>
          bwe <= '1'; baddr <= opos + 1; bscreen <= x"FF"; bcolour <= x"00";
          out_len <= opos + 2;
          state <= Fin;
        when Fin =>
          done <= '1';
          state <= Idle;
      end case;
    end if;
  end process;
end architecture;
