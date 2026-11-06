--------------------------------------------------------------------------------
-- ddr3_attic.vhdl -- MEGA65 "attic" expansion RAM ($8000000-$87FFFFF) on DDR3.
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
-- Size: ATTIC_BITS address bits are used (23 = 8 MB, like the HyperRAM of a
-- real MEGA65); higher addresses mirror.  The DDR3 holds 256 MB, so this can
-- grow to the interface's 128 MB by raising ATTIC_BITS to 27.
--
-- CPU fast path (as the sdram/hyperram controllers of real boards): every
-- completed read publishes its 8-byte line (cache_line/_addr/_valid); the
-- CPU reads hits straight from it, and its inc/dec toggles ask for a silent
-- read of the next/previous line (published, but no data_ready_toggle).
-- Writes to the published line update it in place (write-through); the
-- match is on the PHYSICAL address (ATTIC_BITS), so a write through an 8 MB
-- mirror alias keeps a line cached under another alias coherent.
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
    ATTIC_BITS : integer := 23
  );
  port (
    -- slow_devices expansion RAM interface (cpuclk)
    cpuclk            : in  std_logic;
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

  -- ui_clk domain
  type st_t is (S_IDLE, S_WR, S_RD, S_RDW, S_DONE);
  signal st         : st_t := S_IDLE;
  signal req_u      : std_logic_vector(2 downto 0) := (others => '0');
  signal u_write    : std_logic := '0';
  signal u_addr     : unsigned(26 downto 0) := (others => '0');
  signal u_wdata    : std_logic_vector(7 downto 0) := (others => '0');
  signal cmd_ok     : std_logic := '0';
  signal dat_ok     : std_logic := '0';
  signal ack_toggle : std_logic := '0';
  signal rdata_u    : std_logic_vector(63 downto 0) := (others => '0');  -- 8-byte half

  attribute ASYNC_REG : string;
  attribute ASYNC_REG of ack_c, calib_c, req_u, next_s, prev_s : signal is "TRUE";

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

      if busy_c = '0' and calib_c(1) = '1' and (ex_read = '1' or ex_write = '1') then
        req_write  <= ex_write;
        req_addr   <= ex_address;
        req_wdata  <= ex_wdata;
        req_silent <= '0';
        req_toggle <= not req_toggle;
        busy_c     <= '1';
        -- write-through: keep the published line coherent (physical match)
        if ex_write = '1' and line_valid_r = '1'
           and ex_address(ATTIC_BITS - 1 downto 3) = line_addr_r(ATTIC_BITS - 1 downto 3) then
          line_r(to_integer(ex_address(2 downto 0))) <= ex_wdata;
        end if;
      elsif busy_c = '0' and calib_c(1) = '1' and line_valid_r = '1'
            and (next_s(1) /= next_seen or prev_s(1) /= prev_seen) then
        -- CPU asks for the next / previous line: silent prefetch read
        req_write  <= '0';
        if next_s(1) /= next_seen then
          req_addr <= (line_addr_r + 1) & "000";
        else
          req_addr <= (line_addr_r - 1) & "000";
        end if;
        next_seen  <= next_s(1);
        prev_seen  <= prev_s(1);
        req_silent <= '1';
        req_toggle <= not req_toggle;
        busy_c     <= '1';
      elsif busy_c = '1' and ack_c(2) /= ack_c(1) then
        -- request finished in the ui_clk domain (rdata_u stable since then)
        busy_c <= '0';
        if req_write = '0' then
          for b in 0 to 7 loop
            line_r(b) <= unsigned(rdata_u(8 * b + 7 downto 8 * b));
          end loop;
          line_addr_r  <= req_addr(26 downto 3);
          line_valid_r <= '1';
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
  app_addr     <= "0" & std_logic_vector(resize(u_addr(ATTIC_BITS - 1 downto 4), 24)) & "000";
  app_cmd      <= CMD_WR when st = S_WR else CMD_RD;
  app_en       <= '1' when (st = S_RD) or (st = S_WR and cmd_ok = '0') else '0';
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
              u_wdata <= std_logic_vector(req_wdata);
              if req_write = '1' then
                st <= S_WR;
              else
                st <= S_RD;
              end if;
            end if;

          when S_WR =>
            if app_rdy = '1' and cmd_ok = '0' then
              cmd_ok <= '1';
            end if;
            if app_wdf_rdy = '1' and dat_ok = '0' then
              dat_ok <= '1';
            end if;
            if (cmd_ok = '1' or app_rdy = '1') and (dat_ok = '1' or app_wdf_rdy = '1') then
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
