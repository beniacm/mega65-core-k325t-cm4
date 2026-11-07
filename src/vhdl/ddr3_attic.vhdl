--------------------------------------------------------------------------------
-- ddr3_attic.vhdl -- MEGA65 "attic" expansion RAM ($8000000-...) on DDR3.
--
-- Presents the slow_devices expansion-RAM byte interface (the one the
-- hyperram/sdram controllers implement on real MEGA65 boards) on top of a
-- Xilinx MIG 7-series native UI (x16 DDR3, BL8 -> 128-bit = 16-byte words,
-- app_addr in 16-bit units, so one word = 8 address steps).
--
--   cpuclk side (slow_devices; on the MEGA65 that is pixelclock, 81 MHz -- the
--   expansion-RAM strobes are one pixelclock cycle long):
--     busy=0 means a request may be issued (busy stays 1 until DDR3
--     calibration completes, so slow_devices keeps reporting "no RAM"
--     until then); read/write are one-cycle strobes with address/wdata.
--     A write is fire-and-forget (busy until committed); a read returns
--     rdata and flips data_ready_toggle (slow_devices allows ~128 cycles).
--   ui_clk side (MIG): one masked 16-byte write or one 16-byte read per
--     request; the byte is selected by address(3:0) on both paths.
--
-- Size: after reset the attic is COMPAT_BITS wide (23 = 8 MB, the HyperRAM of a real
-- MEGA65) and mirrors above, so unmodified software sees exactly what it expects.
-- Software that knows the board unlocks the full ATTIC_BITS (26 = 64 MB on the K325T;
-- the DDR3 holds 256 MB, the interface allows 27 = 128 MB) with the size register:
--   $BFFFFFC  write 64 = 64 MB (2^ATTIC_BITS / 1 MB), anything else = 8 MB;
--             read = current size in MB (8 or 64).  Any CPU reset returns to 8 MB.
--   from BASIC 65:  POKE $BFFFFFC,64 : PRINT PEEK($BFFFFFC)
-- $BFFFFF0-$BFFFFFF are controller registers in both sizes, as on the real MEGA65
-- (its HyperRAM controller's registers sit there; it ignores writes to $BFFFFFC, where
-- it reads back a cache address byte).  The other 15 read 0 and ignore writes, so in
-- 64 MB mode the top 16 bytes of the attic are not RAM.
--
-- CPU fast path (as the sdram/hyperram controllers of real boards): every
-- completed read publishes its 8-byte line (cache_line/_addr/_valid); the
-- CPU reads hits straight from it, and its inc/dec toggles ask for a silent
-- read of the next/previous line (published, but no data_ready_toggle).
-- Writes to the published line update it in place (write-through); the
-- match is on the PHYSICAL address (ATTIC_BITS), so a write through a mirror
-- alias keeps a line cached under another alias coherent.
--
-- Clock crossing: request = toggle + payload held stable (payload is
-- captured in ui_clk only after the toggle has passed a 2-FF synchroniser);
-- answer = toggle + rdata, the same way back.
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.cputypes.all;

entity ddr3_attic is
  generic (
    ATTIC_BITS  : integer := 23;      -- full size (address bits)
    COMPAT_BITS : integer := 23       -- size after reset (8 MB, like a real MEGA65)
  );
  port (
    -- slow_devices expansion RAM interface (cpuclk)
    cpuclk            : in  std_logic;
    reset_n           : in  std_logic := '1';   -- CPU reset (any clock): back to COMPAT_BITS
    ex_read           : in  std_logic;
    ex_write          : in  std_logic;
    ex_address        : in  unsigned(26 downto 0);
    ex_wdata          : in  unsigned(7 downto 0);
    ex_rdata          : out unsigned(7 downto 0);
    ex_data_ready_toggle : out std_logic;
    ex_busy           : out std_logic;
    -- MIG native UI (ui_clk)
    ui_clk            : in  std_logic;
    ui_rst            : in  std_logic;
    init_calib_complete : in std_logic;
    app_addr          : out std_logic_vector(27 downto 0);
    app_cmd           : out std_logic_vector(2 downto 0);
    app_en            : out std_logic;
    app_rdy           : in  std_logic;
    app_wdf_data      : out std_logic_vector(127 downto 0);
    app_wdf_end       : out std_logic;
    app_wdf_wren      : out std_logic;
    app_wdf_mask      : out std_logic_vector(15 downto 0);
    app_wdf_rdy       : in  std_logic;
    app_rd_data       : in  std_logic_vector(127 downto 0);
    app_rd_data_valid : in  std_logic;
    -- CPU fast path (cpuclk side)
    cache_line        : out cache_row_t := (others => (others => '0'));
    cache_line_addr   : out unsigned(26 downto 3) := (others => '0');
    cache_line_valid  : out std_logic := '0';
    cache_next_toggle : in  std_logic := '0';
    cache_prev_toggle : in  std_logic := '0';
    -- status
    calibrated        : out std_logic
  );
end entity;

architecture rtl of ddr3_attic is

  constant CMD_WR : std_logic_vector(2 downto 0) := "000";
  constant CMD_RD : std_logic_vector(2 downto 0) := "001";

  -- cpuclk domain
  signal req_toggle   : std_logic := '0';
  signal req_write    : std_logic := '0';
  signal req_addr     : unsigned(26 downto 0) := (others => '0');
  signal req_wdata    : unsigned(7 downto 0) := (others => '0');
  signal busy_c       : std_logic := '0';
  signal ack_c        : std_logic_vector(2 downto 0) := (others => '0');
  signal calib_c      : std_logic_vector(1 downto 0) := (others => '0');
  signal ready_toggle : std_logic := '0';
  signal req_silent   : std_logic := '0';     -- prefetch read: publish only
  signal line_r       : cache_row_t := (others => (others => '0'));
  signal line_addr_r  : unsigned(26 downto 3) := (others => '0');
  signal line_valid_r : std_logic := '0';
  signal next_s, prev_s : std_logic_vector(1 downto 0) := (others => '0');
  signal next_seen, prev_seen : std_logic := '0';
  signal big          : std_logic := '0';     -- '1' = ATTIC_BITS, '0' = COMPAT_BITS
  signal req_big      : std_logic := '0';
  signal rst_s        : std_logic_vector(1 downto 0) := (others => '1');

  constant SIZE_MB : integer := 2 ** (ATTIC_BITS - 20);
  constant COMPAT_MB : integer := 2 ** (COMPAT_BITS - 20);

  -- $BFFFFF0-$BFFFFFF (expansion address $3FFFFFx, bit 26 ignored as in hyperram.vhdl)
  function is_reg(a : unsigned(26 downto 0)) return boolean is
  begin
    return a(25 downto 4) = (25 downto 4 => '1');
  end function;
  function is_reg_line(l : unsigned(26 downto 3)) return boolean is
  begin
    return l(25 downto 4) = (25 downto 4 => '1');
  end function;
  -- physical address bits of the current size (for the write-through alias match)
  function phys(a : unsigned(26 downto 3); b : std_logic) return unsigned is
    variable r : unsigned(26 downto 3) := a;
  begin
    if b = '1' then
      r(26 downto ATTIC_BITS) := (others => '0');
    else
      r(26 downto COMPAT_BITS) := (others => '0');
    end if;
    return r;
  end function;

  -- ui_clk domain
  type st_t is (S_IDLE, S_WR, S_RD, S_RDW, S_DONE);
  signal st         : st_t := S_IDLE;
  signal req_u      : std_logic_vector(2 downto 0) := (others => '0');
  signal u_write    : std_logic := '0';
  signal u_addr     : unsigned(26 downto 0) := (others => '0');
  signal u_big      : std_logic := '0';
  signal u_wdata    : std_logic_vector(7 downto 0) := (others => '0');
  signal cmd_ok     : std_logic := '0';
  signal dat_ok     : std_logic := '0';
  signal ack_toggle : std_logic := '0';
  signal rdata_u    : std_logic_vector(63 downto 0) := (others => '0');  -- 8-byte half

  attribute ASYNC_REG : string;
  attribute ASYNC_REG of ack_c, calib_c, req_u, next_s, prev_s, rst_s : signal is "TRUE";

begin

  -------------------------------------------------------------------------
  -- cpuclk side
  -------------------------------------------------------------------------
  ex_busy <= busy_c or not calib_c(1);
  ex_data_ready_toggle <= ready_toggle;
  calibrated <= calib_c(1);
  cache_line       <= line_r;
  cache_line_addr  <= line_addr_r;
  cache_line_valid <= line_valid_r;

  process (cpuclk)
    variable byte_i : integer range 0 to 7;
  begin
    if rising_edge(cpuclk) then
      calib_c <= calib_c(0) & init_calib_complete;
      ack_c   <= ack_c(1 downto 0) & ack_toggle;
      next_s  <= next_s(0) & cache_next_toggle;
      prev_s  <= prev_s(0) & cache_prev_toggle;
      rst_s   <= rst_s(0) & reset_n;

      if rst_s(1) = '0' then
        -- CPU reset: back to the real MEGA65's size (the mirrors change meaning)
        if big = '1' then
          line_valid_r <= '0';
        end if;
        big <= '0';
      end if;

      if busy_c = '0' and calib_c(1) = '1' and (ex_read = '1' or ex_write = '1')
         and is_reg(ex_address) then
        -- controller registers: answered at once, no DDR3 access
        if ex_write = '1' then
          if ex_address(3 downto 0) = x"C" then
            if to_integer(ex_wdata) = SIZE_MB then
              big <= '1';
              if big = '0' then line_valid_r <= '0'; end if;
            else
              big <= '0';
              if big = '1' then line_valid_r <= '0'; end if;
            end if;
          end if;
        else
          if ex_address(3 downto 0) = x"C" then
            if big = '1' then
              ex_rdata <= to_unsigned(SIZE_MB, 8);
            else
              ex_rdata <= to_unsigned(COMPAT_MB, 8);
            end if;
          else
            ex_rdata <= x"00";
          end if;
          ready_toggle <= not ready_toggle;
        end if;
      elsif busy_c = '0' and calib_c(1) = '1' and (ex_read = '1' or ex_write = '1') then
        req_write  <= ex_write;
        req_big    <= big;
        req_addr   <= ex_address;
        req_wdata  <= ex_wdata;
        req_silent <= '0';
        req_toggle <= not req_toggle;
        busy_c     <= '1';
        -- write-through: keep the published line coherent (physical match)
        if ex_write = '1' and line_valid_r = '1'
           and phys(ex_address(26 downto 3), big) = phys(line_addr_r, big) then
          line_r(to_integer(ex_address(2 downto 0))) <= ex_wdata;
        end if;
      elsif busy_c = '0' and calib_c(1) = '1' and line_valid_r = '1'
            and (next_s(1) /= next_seen or prev_s(1) /= prev_seen) then
        -- CPU asks for the next / previous line: silent prefetch read (never into the
        -- register line, which must not be published as RAM)
        req_write  <= '0';
        req_big    <= big;
        if next_s(1) /= next_seen then
          req_addr <= (line_addr_r + 1) & "000";
        else
          req_addr <= (line_addr_r - 1) & "000";
        end if;
        next_seen  <= next_s(1);
        prev_seen  <= prev_s(1);
        req_silent <= '1';
        if (next_s(1) /= next_seen and not is_reg_line(line_addr_r + 1)) or
           (next_s(1) = next_seen and not is_reg_line(line_addr_r - 1)) then
          req_toggle <= not req_toggle;
          busy_c     <= '1';
        end if;
      elsif busy_c = '1' and ack_c(2) /= ack_c(1) then
        -- request finished in the ui_clk domain (rdata_u stable since then)
        busy_c <= '0';
        if req_write = '0' then
          for b in 0 to 7 loop
            line_r(b) <= unsigned(rdata_u(8 * b + 7 downto 8 * b));
          end loop;
          line_addr_r  <= req_addr(26 downto 3);
          line_valid_r <= '1';
          if req_big /= big then
            line_valid_r <= '0';            -- the size changed while this read was in flight
          end if;
          if req_silent = '0' then
            byte_i := to_integer(req_addr(2 downto 0));
            ex_rdata     <= unsigned(rdata_u(8 * byte_i + 7 downto 8 * byte_i));
            ready_toggle <= not ready_toggle;
          end if;
        end if;
      end if;
    end if;
  end process;

  -------------------------------------------------------------------------
  -- ui_clk side: one MIG command per request.  Command and data handshakes
  -- are tracked separately so each write issues exactly one command and one
  -- data beat even when app_rdy and app_wdf_rdy assert on different cycles.
  -------------------------------------------------------------------------
  app_addr     <= "0" & std_logic_vector(resize(u_addr(ATTIC_BITS - 1 downto 4), 24)) & "000"
                  when u_big = '1' else
                  "0" & std_logic_vector(resize(u_addr(COMPAT_BITS - 1 downto 4), 24)) & "000";
  app_cmd      <= CMD_WR when st = S_WR else CMD_RD;
  -- Writes: data first, command once the data is (being) taken.  UG586 allows the data
  -- at most two cycles after its command, which app_wdf_rdy back-pressure could break.
  app_en       <= '1' when (st = S_RD) or
                           (st = S_WR and cmd_ok = '0' and (dat_ok = '1' or app_wdf_rdy = '1'))
                  else '0';
  app_wdf_wren <= '1' when st = S_WR and dat_ok = '0' else '0';
  app_wdf_end  <= '1' when st = S_WR and dat_ok = '0' else '0';
  gen_wdata : for i in 0 to 15 generate
    app_wdf_data(8 * i + 7 downto 8 * i) <= u_wdata;
    app_wdf_mask(i) <= '0' when to_integer(u_addr(3 downto 0)) = i else '1';  -- 1 = keep
  end generate;

  process (ui_clk)
  begin
    if rising_edge(ui_clk) then
      req_u <= req_u(1 downto 0) & req_toggle;
      if ui_rst = '1' then
        st     <= S_IDLE;
        cmd_ok <= '0';
        dat_ok <= '0';
      else
        case st is
          when S_IDLE =>
            cmd_ok <= '0';
            dat_ok <= '0';
            if req_u(2) /= req_u(1) and init_calib_complete = '1' then
              -- payload has been stable since before the toggle was synchronised
              u_write <= req_write;
              u_addr  <= req_addr;
              u_big   <= req_big;
              u_wdata <= std_logic_vector(req_wdata);
              if req_write = '1' then
                st <= S_WR;
              else
                st <= S_RD;
              end if;
            end if;

          when S_WR =>
            if app_rdy = '1' and cmd_ok = '0' and (dat_ok = '1' or app_wdf_rdy = '1') then
              cmd_ok <= '1';
            end if;
            if app_wdf_rdy = '1' and dat_ok = '0' then
              dat_ok <= '1';
            end if;
            if (cmd_ok = '1' or (app_rdy = '1' and (dat_ok = '1' or app_wdf_rdy = '1'))) and
               (dat_ok = '1' or app_wdf_rdy = '1') then
              st <= S_DONE;
            end if;

          when S_RD =>
            if app_rdy = '1' then             -- command accepted (app_en high)
              st <= S_RDW;
            end if;

          when S_RDW =>
            if app_rd_data_valid = '1' then
              -- the 8-byte half of the 16-byte word holding the address
              if u_addr(3) = '0' then
                rdata_u <= app_rd_data(63 downto 0);
              else
                rdata_u <= app_rd_data(127 downto 64);
              end if;
              st <= S_DONE;
            end if;

          when S_DONE =>
            ack_toggle <= not ack_toggle;
            st <= S_IDLE;
        end case;
      end if;
    end if;
  end process;

end architecture;
