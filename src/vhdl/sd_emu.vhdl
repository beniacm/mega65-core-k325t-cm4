--------------------------------------------------------------------------------
-- sd_emu.vhdl -- SPI-mode SDHC card emulator for the MEGA65 SD controller.
--
-- Sits on the internal SD bus (cs_bo/sclk_o/mosi_o -> miso_i) in the SAME
-- clock domain as the controller (cpuclock).  It does not store data: every
-- CMD17 raises rd_req + lba, and the card answers 0xFF ("not ready yet") until
-- an external server (the Rockchip, via rk_bridge) has filled the read
-- buffer.  Writes (CMD24/CMD25) are captured into the write buffer, the card
-- signals busy until the server acknowledges with wr_ack.  The MEGA65
-- controller waits indefinitely for the data token / busy release, and HYPPO
-- allows ~0.4 s per operation, so on-demand serving is fine.
--
-- Timing model (see sdcard.vhdl): the controller toggles sclk_r every
-- (divider+1) clocks and samples miso / changes mosi on the clock edge that
-- ends the HIGH phase.  An "event" here is the first clock edge on which
-- sclk is seen high (sclk='1', sclk_d='0').  On that edge the controller
-- samples miso (pre-edge value) and we sample mosi (pre-edge value) and then
-- present the next miso bit, which the controller samples on the next event.
--
-- Supported: CMD0, CMD8 (R7 echo), CMD55/ACMD41, CMD58 (OCR, CCS=1), CMD59,
-- CMD17, CMD24, CMD25 (+FC/FD tokens), CMD23, CMD12; others answer R1=0x04.
-- Addresses are treated as block numbers (SDHC); HYPPO's misaligned-read
-- probe therefore succeeds and it selects SDHC mode.
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity sd_emu is
  port (
    clk      : in  std_logic;
    -- SD SPI bus from the MEGA65 controller
    sd_cs_n  : in  std_logic;
    sd_sclk  : in  std_logic;
    sd_mosi  : in  std_logic;
    sd_miso  : out std_logic;
    -- request interface to the server
    rd_req   : out std_logic;              -- read pending
    wr_req   : out std_logic;              -- write block captured, awaiting ack
    req_lba  : out unsigned(31 downto 0);
    req_seq  : out unsigned(7 downto 0);   -- +1 per request
    rd_ready : in  std_logic;              -- read buffer filled for this request
    wr_ack   : in  std_logic;              -- one-clock pulse: write consumed
    -- read buffer (filled by the server), synchronous read
    rbuf_addr : out unsigned(8 downto 0);
    rbuf_data : in  std_logic_vector(7 downto 0);
    -- write buffer (filled by us)
    wbuf_we   : out std_logic;
    wbuf_addr : out unsigned(8 downto 0);
    wbuf_data : out std_logic_vector(7 downto 0);
    -- status / debug
    inited    : out std_logic;
    cmd_count : out unsigned(7 downto 0);
    last_cmd  : out unsigned(7 downto 0)
  );
end entity;

architecture rtl of sd_emu is

  type mode_t is (M_IDLE, M_CMD, M_RESP, M_RD_WAIT, M_RD_DATA, M_W_RX,
                  M_W_RESP, M_W_BUSY, M_W_REL);
  type after_t is (A_IDLE, A_READ, A_WRITE);
  type wsub_t is (W_TOKEN, W_DATA, W_CRC);
  type q_t is array (0 to 5) of std_logic_vector(7 downto 0);

  signal mode    : mode_t := M_IDLE;
  signal nxt_act : after_t := A_IDLE;
  signal wsub    : wsub_t := W_TOKEN;
  signal multi   : std_logic := '0';

  signal sclk_d  : std_logic := '0';
  signal cs_d    : std_logic := '1';

  -- MISO transmitter
  signal miso_r  : std_logic := '1';
  signal tx_sr   : std_logic_vector(7 downto 0) := (others => '1');
  signal tx_left : integer range 0 to 7 := 0;

  -- response queue
  signal q       : q_t := (others => x"FF");
  signal q_len   : integer range 0 to 6 := 0;
  signal q_idx   : integer range 0 to 6 := 0;

  -- command receiver
  signal cmd_sr  : std_logic_vector(47 downto 0) := (others => '1');
  signal cmd_cnt : integer range 0 to 48 := 0;

  -- byte receiver (write data)
  signal rx_sr   : std_logic_vector(7 downto 0) := (others => '1');
  signal rx_cnt  : integer range 0 to 7 := 0;
  signal tok_sr  : std_logic_vector(7 downto 0) := (others => '1');

  signal idx     : unsigned(9 downto 0) := (others => '0');
  signal crc_cnt : integer range 0 to 2 := 0;

  signal inited_r : std_logic := '0';
  signal app_r    : std_logic := '0';
  signal rd_req_r : std_logic := '0';
  signal wr_req_r : std_logic := '0';
  signal lba_r    : unsigned(31 downto 0) := (others => '0');
  signal seq_r    : unsigned(7 downto 0) := (others => '0');
  signal ack_l    : std_logic := '0';
  signal cmd_count_r : unsigned(7 downto 0) := (others => '0');
  signal last_cmd_r  : unsigned(7 downto 0) := (others => '0');

begin

  sd_miso   <= miso_r;
  rd_req    <= rd_req_r;
  wr_req    <= wr_req_r;
  req_lba   <= lba_r;
  req_seq   <= seq_r;
  inited    <= inited_r;
  rbuf_addr <= idx(8 downto 0);
  cmd_count <= cmd_count_r;
  last_cmd  <= last_cmd_r;

  process (clk)
    variable ev     : boolean;
    variable nb     : std_logic_vector(7 downto 0);
    variable full   : std_logic_vector(47 downto 0);
    variable ci     : integer range 0 to 63;
    variable arg    : std_logic_vector(31 downto 0);
    variable r1     : std_logic_vector(7 downto 0);
    variable byte_v : std_logic_vector(7 downto 0);

    -- present byte b: bit 7 now, the rest on the following events
    procedure load_byte(b : std_logic_vector(7 downto 0)) is
    begin
      miso_r  <= b(7);
      tx_sr   <= b(6 downto 0) & '1';
      tx_left <= 7;
    end procedure;

  begin
    if rising_edge(clk) then
      wbuf_we <= '0';
      sclk_d  <= sd_sclk;
      cs_d    <= sd_cs_n;
      if wr_ack = '1' then
        ack_l <= '1';
      end if;

      ev := (sd_sclk = '1' and sclk_d = '0');

      if sd_cs_n = '1' and cs_d = '0' then
        -- Deselect: abandon whatever was going on.
        mode     <= M_IDLE;
        miso_r   <= '1';
        cmd_cnt  <= 0;
        rd_req_r <= '0';
      elsif ev then
        case mode is

          when M_IDLE | M_CMD =>
            miso_r <= '1';
            if mode = M_IDLE then
              if sd_mosi = '0' then        -- start bit of a command
                cmd_sr  <= cmd_sr(46 downto 0) & sd_mosi;
                cmd_cnt <= 1;
                mode    <= M_CMD;
              end if;
            else
              full := cmd_sr(46 downto 0) & sd_mosi;
              cmd_sr <= full;
              if cmd_cnt /= 47 then
                cmd_cnt <= cmd_cnt + 1;
              else
                -- full 48-bit command received; decode
                cmd_cnt <= 0;
                ci  := to_integer(unsigned(full(45 downto 40)));
                arg := full(39 downto 8);
                cmd_count_r <= cmd_count_r + 1;
                last_cmd_r    <= to_unsigned(ci, 8);
                last_cmd_r(7) <= app_r;  -- bit 7 = ACMD
                r1 := "0000000" & not inited_r;
                q(0) <= x"FF";          -- Ncr: one byte of 1s
                q(1) <= r1;
                q_len <= 2;
                nxt_act <= A_IDLE;
                app_r <= '0';
                case ci is
                  when 0 =>
                    inited_r <= '0';
                    q(1) <= x"01";
                  when 8 =>
                    q(2) <= x"00"; q(3) <= x"00";
                    q(4) <= "0000" & arg(11 downto 8);
                    q(5) <= arg(7 downto 0);
                    q_len <= 6;
                  when 55 =>
                    app_r <= '1';
                  when 41 =>
                    if app_r = '1' then
                      inited_r <= '1';
                      q(1) <= x"00";
                    else
                      q(1) <= x"04";
                    end if;
                  when 58 =>
                    q(2) <= x"C0"; q(3) <= x"FF"; q(4) <= x"80"; q(5) <= x"00";
                    q_len <= 6;
                  when 59 | 23 | 12 | 16 =>
                    null;
                  when 17 =>
                    q(1)  <= x"00";
                    nxt_act <= A_READ;
                    lba_r <= unsigned(arg);
                  when 24 | 25 =>
                    q(1)  <= x"00";
                    nxt_act <= A_WRITE;
                    lba_r <= unsigned(arg);
                    if ci = 25 then multi <= '1'; else multi <= '0'; end if;
                  when others =>
                    q(1) <= r1 or x"04";   -- illegal command
                end case;
                -- The controller samples the first response bit on the next
                -- event, so present the first queued byte (0xFF) now.
                load_byte(x"FF");
                q_idx <= 1;
                mode  <= M_RESP;
              end if;
            end if;

          when M_RESP =>
            if tx_left /= 0 then
              miso_r  <= tx_sr(7);
              tx_sr   <= tx_sr(6 downto 0) & '1';
              tx_left <= tx_left - 1;
            elsif q_idx < q_len then
              load_byte(q(q_idx));
              q_idx <= q_idx + 1;
            else
              -- response finished (its last bit was sampled on this event)
              case nxt_act is
                when A_IDLE =>
                  miso_r <= '1';
                  mode   <= M_IDLE;
                when A_READ =>
                  rd_req_r <= '1';
                  seq_r    <= seq_r + 1;
                  load_byte(x"FF");      -- the controller's "prime" byte
                  mode     <= M_RD_WAIT;
                when A_WRITE =>
                  miso_r <= '1';
                  rx_cnt <= 0;
                  wsub   <= W_TOKEN;
                  mode   <= M_W_RX;
              end case;
            end if;

          when M_RD_WAIT | M_RD_DATA =>
            if sd_mosi = '0' then
              -- Host abandoned the read and is sending a new command.
              rd_req_r <= '0';
              miso_r   <= '1';
              cmd_sr   <= cmd_sr(46 downto 0) & sd_mosi;
              cmd_cnt  <= 1;
              mode     <= M_CMD;
            elsif tx_left /= 0 then
              miso_r  <= tx_sr(7);
              tx_sr   <= tx_sr(6 downto 0) & '1';
              tx_left <= tx_left - 1;
            elsif mode = M_RD_WAIT then
              if rd_ready = '1' then
                load_byte(x"FE");        -- start token
                idx  <= (others => '0'); -- prefetch byte 0
                mode <= M_RD_DATA;
              else
                load_byte(x"FF");
              end if;
            else
              if idx < 512 then
                load_byte(rbuf_data);
                idx <= idx + 1;
              elsif idx < 514 then
                load_byte(x"FF");        -- CRC (ignored by the controller)
                idx <= idx + 1;
              else
                rd_req_r <= '0';
                miso_r   <= '1';
                mode     <= M_IDLE;
              end if;
            end if;

          when M_W_RX =>
            miso_r <= '1';
            byte_v := rx_sr(6 downto 0) & sd_mosi;
            rx_sr  <= byte_v;
            if wsub = W_TOKEN then
              -- Token search uses a sliding window, not byte alignment: the
              -- controller emits 3 extra SCLK pulses (DESELECT) between the
              -- blocks of a CMD25, but none before the stop token.
              -- Single block: FE.  Multi block: FC (data) / FD (stop).
              -- Neither can false-match inside 0xFF..token sequences.
              byte_v := tok_sr(6 downto 0) & sd_mosi;
              tok_sr <= byte_v;
              rx_cnt <= 0;
              if (multi = '0' and byte_v = x"FE") or (multi = '1' and byte_v = x"FC") then
                idx    <= (others => '0');
                tok_sr <= (others => '1');
                wsub   <= W_DATA;
              elsif multi = '1' and byte_v = x"FD" then
                tok_sr <= (others => '1');
                mode   <= M_IDLE;        -- stop transmission; not busy
              end if;
            elsif rx_cnt /= 7 then
              rx_cnt <= rx_cnt + 1;
            else
              rx_cnt <= 0;
              case wsub is
                when W_TOKEN =>
                  null;
                when W_DATA =>
                  wbuf_we   <= '1';
                  wbuf_addr <= idx(8 downto 0);
                  wbuf_data <= byte_v;
                  if idx = 511 then
                    crc_cnt <= 0;
                    wsub    <= W_CRC;
                  end if;
                  idx <= idx + 1;
                when W_CRC =>
                  if crc_cnt = 0 then
                    crc_cnt <= 1;
                  else
                    load_byte(x"E5");    -- data response: accepted
                    mode <= M_W_RESP;
                  end if;
              end case;
            end if;

          when M_W_RESP =>
            if tx_left /= 0 then
              miso_r  <= tx_sr(7);
              tx_sr   <= tx_sr(6 downto 0) & '1';
              tx_left <= tx_left - 1;
            else
              miso_r   <= '0';           -- busy
              wr_req_r <= '1';
              seq_r    <= seq_r + 1;
              ack_l    <= '0';
              mode     <= M_W_BUSY;
            end if;

          when M_W_BUSY =>
            if ack_l = '1' then
              ack_l    <= '0';
              wr_req_r <= '0';
              miso_r   <= '1';           -- release busy
              mode     <= M_W_REL;
            else
              miso_r <= '0';
            end if;

          when M_W_REL =>
            -- The controller sampled the '1' on this event and leaves WR_WAIT.
            miso_r <= '1';
            if multi = '1' then
              lba_r  <= lba_r + 1;
              rx_cnt <= 0;
              wsub   <= W_TOKEN;
              mode   <= M_W_RX;
            else
              mode <= M_IDLE;
            end if;

        end case;
      end if;
    end if;
  end process;

end architecture;
