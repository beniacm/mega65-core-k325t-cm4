--------------------------------------------------------------------------------
-- rk_bridge.vhdl -- Rockchip (CM4 socket) <-> MEGA65 service bridge.
--
-- The Rockchip is SPI master on spi3-m1 (/dev/spidev3.0, mode 0, MSB first).
-- The SPI slave, command decoder, FIFOs and UART engine run in a FAST clock
-- (clk, 162 MHz on the K325T = 4 x cpuclock from the same MMCM).  SCK is
-- oversampled there, so the link runs at up to ~25 MHz (v1 sampled at
-- 40.5 MHz and topped out near 4-6 MHz).  Everything the MEGA65 side uses is
-- resynchronised into cpuclk; the sector buffers are dual-clock block RAMs.
--
-- One transaction = CS low, command byte, payload, CS high.
--   0x01 STATUS   : cmd, dummy, then status bytes (see below)
--   0x10 SD_PUT   : cmd, 512 bytes  -> read buffer; marks read data ready
--   0x11 SD_GET   : cmd, dummy, 512 bytes of the captured write block
--   0x12 SD_WACK  : cmd             -> write block consumed, release busy
--   0x13 SD_RERR  : cmd             -> pending read is out of range (error token)
--   0x20 UART_PUT : cmd, N bytes    -> MEGA65 serial monitor input (RsRx)
--   0x21 UART_GET : cmd, dummy, N bytes of monitor output (0x00 when empty)
--   0x30 INPUT    : cmd, ctrl, joyA, joyB, col0..col8   (all active high)
--                   ctrl: b0 hold CPU reset, b1 RESTORE, b2 CAPS LOCK,
--                         b3 use physical J12 SD instead of the emulator
--                   joy : b0 up b1 down b2 left b3 right b4 fire
--                   colN: MEGA65 keyboard matrix column N, bit = row
--
-- STATUS bytes (after cmd + dummy):
--   0 'M'(0x4D) 1 0x65 2 version 3 flags 4 sd seq 5..8 sd lba (BE)
--   9..10 uart rx count (BE) 11..12 uart tx free (BE) 13 sd cmd count
--   14 last sd cmd (b7 = ACMD) 15 ctrl readback
--   flags: b0 rd_req b1 rd_ready b2 wr_req b3 sd inited b4 uart rx overflow
--          b5 rd_error
--
-- Handshake with sd_emu (levels, safe across the clock domains):
--   rd_ready / rd_error rise when the server answers and fall once the
--   emulator drops rd_req; wr_ack rises on SD_WACK and falls once the
--   emulator drops wr_req.
--
-- The monitor UART is bridged at BIT_CLKS fast clocks per bit
-- (80 @ 162 MHz = 2.025 Mbaud, the monitor's 40.5 MHz / 20).
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity rk_bridge is
  generic (
    BIT_CLKS : integer := 80
  );
  port (
    clk        : in  std_logic;              -- fast bridge clock (162 MHz)
    cpuclk     : in  std_logic;              -- MEGA65 cpuclock (40.5 MHz)
    -- SPI from the Rockchip (asynchronous)
    spi_sck    : in  std_logic;
    spi_cs_n   : in  std_logic;
    spi_mosi   : in  std_logic;
    spi_miso   : out std_logic;
    -- SD emulator (cpuclk domain)
    sd_rd_req  : in  std_logic;
    sd_wr_req  : in  std_logic;
    sd_lba     : in  unsigned(31 downto 0);
    sd_seq     : in  unsigned(7 downto 0);
    sd_inited  : in  std_logic;
    sd_cmd_cnt : in  unsigned(7 downto 0);
    sd_last_cmd: in  unsigned(7 downto 0);
    sd_rd_ready: out std_logic;
    sd_rd_error: out std_logic;
    sd_wr_ack  : out std_logic;
    rbuf_addr  : in  unsigned(8 downto 0);
    rbuf_data  : out std_logic_vector(7 downto 0);
    wbuf_we    : in  std_logic;
    wbuf_addr  : in  unsigned(8 downto 0);
    wbuf_data  : in  std_logic_vector(7 downto 0);
    -- serial monitor (cpuclk domain)
    mon_rx     : out std_logic;              -- to machine RsRx
    mon_tx     : in  std_logic;              -- from machine UART_TXD
    -- keyboard matrix (widget interface) and joysticks (cpuclk domain)
    matrix_col_idx : in  integer range 0 to 15;
    matrix_col     : out std_logic_vector(7 downto 0);   -- active low
    joya           : out std_logic_vector(4 downto 0);   -- active high
    joyb           : out std_logic_vector(4 downto 0);
    ctrl           : out std_logic_vector(7 downto 0);
    -- activity
    spi_active     : out std_logic
  );
end entity;

architecture rtl of rk_bridge is

  constant VERSION : std_logic_vector(7 downto 0) := x"02";

  type ram512_t  is array (0 to 511)  of std_logic_vector(7 downto 0);
  type ram1k_t   is array (0 to 1023) of std_logic_vector(7 downto 0);
  type ram16k_t  is array (0 to 16383) of std_logic_vector(7 downto 0);
  type mat_t     is array (0 to 8) of std_logic_vector(7 downto 0);

  signal rbuf : ram512_t;   -- written in clk, read in cpuclk
  signal wbuf : ram512_t;   -- written in cpuclk, read in clk
  signal txf  : ram1k_t;    -- Rockchip -> monitor (clk only)
  signal rxf  : ram16k_t;   -- monitor  -> Rockchip (clk only)

  -- ---------------- fast (clk) domain ----------------
  -- SPI slave
  signal sck_s  : std_logic_vector(2 downto 0) := (others => '0');
  signal cs_s   : std_logic_vector(1 downto 0) := (others => '1');
  signal mosi_s : std_logic_vector(1 downto 0) := (others => '0');
  signal rx_sr  : std_logic_vector(6 downto 0) := (others => '0');
  signal bitcnt : integer range 0 to 7 := 0;
  signal bidx   : unsigned(9 downto 0) := (others => '0');  -- byte index, saturating
  signal cmd    : std_logic_vector(7 downto 0) := (others => '0');
  signal miso_r : std_logic := '0';
  signal tx_sr  : std_logic_vector(6 downto 0) := (others => '0');

  -- inputs from the cpuclk domain, synchronised
  signal rd_req_s, wr_req_s, inited_s : std_logic_vector(1 downto 0) := (others => '0');
  signal lba_f   : unsigned(31 downto 0) := (others => '0');
  signal seq_f, ccnt_f, lcmd_f : unsigned(7 downto 0) := (others => '0');

  -- buffers / handshake
  signal wbuf_raddr : unsigned(8 downto 0) := (others => '0');
  signal wbuf_dout  : std_logic_vector(7 downto 0) := (others => '0');
  signal rd_ready_r : std_logic := '0';
  signal rd_error_r : std_logic := '0';
  signal wr_ack_r   : std_logic := '0';
  signal rbuf_we    : std_logic := '0';
  signal rbuf_wa    : unsigned(8 downto 0) := (others => '0');
  signal rbuf_wd    : std_logic_vector(7 downto 0) := (others => '0');

  -- UART FIFOs (pointers carry one extra wrap bit)
  signal txf_wp, txf_rp : unsigned(10 downto 0) := (others => '0');
  signal txf_wp_d, txf_wp_d2 : unsigned(10 downto 0) := (others => '0');
  signal txf_dout       : std_logic_vector(7 downto 0) := (others => '1');
  signal txf_we         : std_logic := '0';
  signal txf_wa         : unsigned(9 downto 0) := (others => '0');
  signal txf_wd         : std_logic_vector(7 downto 0) := (others => '0');
  signal rxf_wp, rxf_rp : unsigned(14 downto 0) := (others => '0');
  -- UART_GET pre-loads the next byte before the master clocks it; it is only
  -- committed (rxf_rp advanced) once actually shifted out, so the byte loaded
  -- for a position the master never clocks (end of transaction) stays queued.
  signal rxf_pp         : unsigned(14 downto 0) := (others => '0');  -- peek pointer
  signal cur_from_fifo  : std_logic := '0';
  signal rxf_wp_d, rxf_wp_d2 : unsigned(14 downto 0) := (others => '0');
  signal rxf_dout       : std_logic_vector(7 downto 0) := (others => '0');
  signal rxf_we         : std_logic := '0';
  signal rxf_wa         : unsigned(13 downto 0) := (others => '0');
  signal rxf_wd         : std_logic_vector(7 downto 0) := (others => '0');
  signal rx_overflow    : std_logic := '0';
  signal rx_count       : unsigned(14 downto 0);
  signal tx_free        : unsigned(10 downto 0);

  -- serializer to the monitor / deserializer from the monitor
  signal ser_busy  : std_logic := '0';
  signal ser_sr    : std_logic_vector(9 downto 0) := (others => '1');
  signal ser_bits  : integer range 0 to 10 := 0;
  signal ser_tmr   : integer range 0 to BIT_CLKS-1 := 0;
  signal ser_wait  : integer range 0 to 3 := 0;
  signal mon_rx_f  : std_logic := '1';
  signal des_in    : std_logic_vector(2 downto 0) := (others => '1');
  signal des_busy  : std_logic := '0';
  signal des_tmr   : integer range 0 to BIT_CLKS-1 := 0;
  signal des_bits  : integer range 0 to 9 := 0;
  signal des_sr    : std_logic_vector(7 downto 0) := (others => '0');

  -- input registers
  signal ctrl_r  : std_logic_vector(7 downto 0) := (others => '0');
  signal joya_r  : std_logic_vector(4 downto 0) := (others => '0');
  signal joyb_r  : std_logic_vector(4 downto 0) := (others => '0');
  signal mat     : mat_t := (others => (others => '0'));

  -- ---------------- cpuclk domain copies ----------------
  signal rd_ready_c, rd_error_c, wr_ack_c : std_logic_vector(1 downto 0) := (others => '0');
  signal mon_rx_c : std_logic_vector(1 downto 0) := (others => '1');
  signal mat_c1, mat_c2 : mat_t := (others => (others => '0'));
  signal ctrl_c1, ctrl_c2 : std_logic_vector(7 downto 0) := (others => '0');
  signal joya_c1, joya_c2, joyb_c1, joyb_c2 : std_logic_vector(4 downto 0) := (others => '0');

  attribute ASYNC_REG : string;
  attribute ASYNC_REG of rd_req_s, wr_req_s, inited_s, rd_ready_c, rd_error_c,
    wr_ack_c, mon_rx_c, mat_c1, mat_c2, ctrl_c1, ctrl_c2, joya_c1, joya_c2,
    joyb_c1, joyb_c2, sck_s, cs_s, mosi_s : signal is "TRUE";

begin

  -------------------------------------------------------------------------
  -- cpuclk side: buffer ports and synchronised outputs
  -------------------------------------------------------------------------
  process (cpuclk)
  begin
    if rising_edge(cpuclk) then
      rbuf_data <= rbuf(to_integer(rbuf_addr));
      if wbuf_we = '1' then
        wbuf(to_integer(wbuf_addr)) <= wbuf_data;
      end if;
      rd_ready_c <= rd_ready_c(0) & rd_ready_r;
      rd_error_c <= rd_error_c(0) & rd_error_r;
      wr_ack_c   <= wr_ack_c(0) & wr_ack_r;
      mon_rx_c   <= mon_rx_c(0) & mon_rx_f;
      mat_c1  <= mat;    mat_c2  <= mat_c1;
      ctrl_c1 <= ctrl_r; ctrl_c2 <= ctrl_c1;
      joya_c1 <= joya_r; joya_c2 <= joya_c1;
      joyb_c1 <= joyb_r; joyb_c2 <= joyb_c1;
    end if;
  end process;

  sd_rd_ready <= rd_ready_c(1);
  sd_rd_error <= rd_error_c(1);
  sd_wr_ack   <= wr_ack_c(1);
  mon_rx      <= mon_rx_c(1);
  ctrl        <= ctrl_c2;
  joya        <= joya_c2;
  joyb        <= joyb_c2;
  -- The keymapper samples the column combinationally while it scans
  -- (a registered lookup shifts every key one column up).
  matrix_col  <= not mat_c2(matrix_col_idx) when matrix_col_idx <= 8 else (others => '1');

  -------------------------------------------------------------------------
  -- fast side
  -------------------------------------------------------------------------
  spi_miso   <= miso_r;
  spi_active <= not cs_s(1);
  rx_count   <= rxf_wp_d2 - rxf_rp;
  tx_free    <= to_unsigned(1024, 11) - (txf_wp - txf_rp);

  -- RAM ports in the fast domain (one write process per RAM -> BRAM)
  process (clk)
  begin
    if rising_edge(clk) then
      if rbuf_we = '1' then
        rbuf(to_integer(rbuf_wa)) <= rbuf_wd;
      end if;
      wbuf_dout <= wbuf(to_integer(wbuf_raddr));
      if txf_we = '1' then
        txf(to_integer(txf_wa)) <= txf_wd;
      end if;
      txf_dout <= txf(to_integer(txf_rp(9 downto 0)));
      if rxf_we = '1' then
        rxf(to_integer(rxf_wa)) <= rxf_wd;
      end if;
      rxf_dout <= rxf(to_integer(rxf_pp(13 downto 0)));
    end if;
  end process;

  process (clk)
    variable rxb   : std_logic_vector(7 downto 0);
    variable nxt   : std_logic_vector(7 downto 0);
    variable st    : integer range 0 to 1023;
    variable put_i : integer range 0 to 1023;
  begin
    if rising_edge(clk) then
      rbuf_we   <= '0';
      txf_we    <= '0';
      rxf_we    <= '0';
      rxf_wp_d  <= rxf_wp;
      rxf_wp_d2 <= rxf_wp_d;
      txf_wp_d  <= txf_wp;
      txf_wp_d2 <= txf_wp_d;

      -- emulator state, synchronised (lba/seq are stable whenever a request
      -- flag is seen: the emulator sets them long before raising the flag)
      rd_req_s <= rd_req_s(0) & sd_rd_req;
      wr_req_s <= wr_req_s(0) & sd_wr_req;
      inited_s <= inited_s(0) & sd_inited;
      lba_f  <= sd_lba;
      seq_f  <= sd_seq;
      ccnt_f <= sd_cmd_cnt;
      lcmd_f <= sd_last_cmd;

      -- level handshakes fall once the emulator has withdrawn the request
      if rd_req_s(1) = '0' then
        rd_ready_r <= '0';
        rd_error_r <= '0';
      end if;
      if wr_req_s(1) = '0' then
        wr_ack_r <= '0';
      end if;

      ------------------------------------------------------------------
      -- SPI slave
      ------------------------------------------------------------------
      sck_s  <= sck_s(1 downto 0) & spi_sck;
      cs_s   <= cs_s(0) & spi_cs_n;
      mosi_s <= mosi_s(0) & spi_mosi;

      if cs_s(1) = '1' then
        bitcnt <= 0;
        bidx   <= (others => '0');
        miso_r <= '0';
        tx_sr  <= (others => '0');
        rxf_pp <= rxf_rp;          -- un-sent pre-loaded byte stays in the FIFO
        cur_from_fifo <= '0';
      elsif sck_s(2) = '0' and sck_s(1) = '1' then
        -- rising SCLK: sample MOSI, then present the next MISO bit (the master
        -- samples it a full SCK period later)
        if bitcnt /= 7 then
          rx_sr  <= rx_sr(5 downto 0) & mosi_s(1);
          bitcnt <= bitcnt + 1;
          miso_r <= tx_sr(6);
          tx_sr  <= tx_sr(5 downto 0) & '0';
        else
          bitcnt <= 0;
          rxb := rx_sr & mosi_s(1);
          nxt := x"00";
          -- the byte that just finished shifting out came from the FIFO: commit it
          if cur_from_fifo = '1' then
            rxf_rp <= rxf_rp + 1;
          end if;
          cur_from_fifo <= '0';
          if bidx /= 1023 then
            bidx <= bidx + 1;
          end if;

          if bidx = 0 then
            cmd <= rxb;
            case rxb is
              when x"11" => wbuf_raddr <= (others => '0');   -- prefetch
              when x"12" => wr_ack_r   <= wr_req_s(1);
              when x"13" => rd_error_r <= rd_req_s(1);
              when others => null;
            end case;
          else
            case cmd is
              when x"01" =>                 -- STATUS (byte 1 = dummy)
                st := to_integer(bidx) - 1;
                case st is
                  when 0  => nxt := x"4D";
                  when 1  => nxt := x"65";
                  when 2  => nxt := VERSION;
                  when 3  => nxt := "00" & rd_error_r & rx_overflow & inited_s(1) & wr_req_s(1)
                                    & rd_ready_r & rd_req_s(1);
                  when 4  => nxt := std_logic_vector(seq_f);
                  when 5  => nxt := std_logic_vector(lba_f(31 downto 24));
                  when 6  => nxt := std_logic_vector(lba_f(23 downto 16));
                  when 7  => nxt := std_logic_vector(lba_f(15 downto 8));
                  when 8  => nxt := std_logic_vector(lba_f(7 downto 0));
                  when 9  => nxt := "0" & std_logic_vector(rx_count(14 downto 8));
                  when 10 => nxt := std_logic_vector(rx_count(7 downto 0));
                  when 11 => nxt := "00000" & std_logic_vector(tx_free(10 downto 8));
                  when 12 => nxt := std_logic_vector(tx_free(7 downto 0));
                  when 13 => nxt := std_logic_vector(ccnt_f);
                  when 14 => nxt := std_logic_vector(lcmd_f);
                  when 15 => nxt := ctrl_r;
                  when others => nxt := x"00";
                end case;

              when x"10" =>                 -- SD_PUT: payload bytes 1..512
                put_i := to_integer(bidx) - 1;
                if put_i < 512 then
                  rbuf_we <= '1';
                  rbuf_wa <= to_unsigned(put_i, 9);
                  rbuf_wd <= rxb;
                  if put_i = 511 and rd_req_s(1) = '1' then
                    rd_ready_r <= '1';
                  end if;
                end if;

              when x"11" =>                 -- SD_GET: byte 1 dummy, then data
                nxt := wbuf_dout;
                wbuf_raddr <= wbuf_raddr + 1;

              when x"20" =>                 -- UART_PUT
                if (txf_wp - txf_rp) /= 1024 then
                  txf_we <= '1';
                  txf_wa <= txf_wp(9 downto 0);
                  txf_wd <= rxb;
                  txf_wp <= txf_wp + 1;
                end if;

              when x"21" =>                 -- UART_GET: byte 1 dummy, then data
                if rxf_wp_d2 /= rxf_pp then
                  nxt := rxf_dout;
                  rxf_pp <= rxf_pp + 1;
                  cur_from_fifo <= '1';
                end if;

              when x"30" =>                 -- INPUT
                case to_integer(bidx) is
                  when 1 => ctrl_r <= rxb;
                  when 2 => joya_r <= rxb(4 downto 0);
                  when 3 => joyb_r <= rxb(4 downto 0);
                  when 4 to 12 => mat(to_integer(bidx) - 4) <= rxb;
                  when others => null;
                end case;

              when others => null;
            end case;
          end if;

          if bidx = 0 then
            nxt := x"00";
          end if;
          miso_r <= nxt(7);
          tx_sr  <= nxt(6 downto 0);
        end if;
      end if;

      ------------------------------------------------------------------
      -- Serializer: TX FIFO -> monitor RsRx (8N1, BIT_CLKS clocks/bit)
      ------------------------------------------------------------------
      if ser_busy = '0' then
        mon_rx_f <= '1';
        if ser_wait /= 0 then
          ser_wait <= ser_wait - 1;
        elsif txf_wp_d2 /= txf_rp then
          ser_sr   <= '1' & txf_dout & '0';   -- stop, data, start (LSB first)
          txf_rp   <= txf_rp + 1;
          ser_bits <= 10;
          ser_tmr  <= 0;
          ser_busy <= '1';
        end if;
      else
        mon_rx_f <= ser_sr(0);
        if ser_tmr /= BIT_CLKS-1 then
          ser_tmr <= ser_tmr + 1;
        else
          ser_tmr <= 0;
          ser_sr  <= '1' & ser_sr(9 downto 1);
          if ser_bits = 1 then
            ser_busy <= '0';
            ser_wait <= 3;      -- lets txf_dout settle on the new read pointer
          end if;
          ser_bits <= ser_bits - 1;
        end if;
      end if;

      ------------------------------------------------------------------
      -- Deserializer: monitor UART_TXD -> RX FIFO
      ------------------------------------------------------------------
      des_in <= des_in(1 downto 0) & mon_tx;
      if des_busy = '0' then
        if des_in(2) = '1' and des_in(1) = '0' then   -- start bit edge
          des_busy <= '1';
          des_tmr  <= 0;
          des_bits <= 0;
        end if;
      else
        if (des_bits = 0 and des_tmr = BIT_CLKS/2 - 1) or
           (des_bits /= 0 and des_tmr = BIT_CLKS-1) then
          des_tmr <= 0;
          if des_bits = 0 then
            if des_in(1) = '1' then       -- false start
              des_busy <= '0';
            end if;
            des_bits <= 1;
          elsif des_bits <= 8 then
            des_sr   <= des_in(1) & des_sr(7 downto 1);
            des_bits <= des_bits + 1;
          else                            -- stop bit
            des_busy <= '0';
            if (rxf_wp - rxf_rp) /= 16384 then
              rxf_we <= '1';
              rxf_wa <= rxf_wp(13 downto 0);
              rxf_wd <= des_sr;
              rxf_wp <= rxf_wp + 1;
            else
              rx_overflow <= '1';
            end if;
          end if;
        else
          des_tmr <= des_tmr + 1;
        end if;
      end if;

    end if;
  end process;

end architecture;
