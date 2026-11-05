--------------------------------------------------------------------------------
-- rk_bridge.vhdl -- Rockchip (CM4 socket) <-> MEGA65 service bridge.
--
-- The Rockchip is SPI master on spi3-m1 (/dev/spidev3.0, mode 0, MSB first,
-- <= ~6 MHz; everything is oversampled in cpuclock = 40.5 MHz).
-- One transaction = CS low, command byte, payload, CS high.
--
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
-- The monitor UART is bridged inside the FPGA at 20 clocks/bit
-- (monitor_ctrl.v divisor 19 -> 2.025 Mbaud at 40.5 MHz).
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity rk_bridge is
  port (
    clk        : in  std_logic;
    -- SPI from the Rockchip (asynchronous)
    spi_sck    : in  std_logic;
    spi_cs_n   : in  std_logic;
    spi_mosi   : in  std_logic;
    spi_miso   : out std_logic;
    -- SD emulator
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
    -- serial monitor
    mon_rx     : out std_logic;              -- to machine RsRx
    mon_tx     : in  std_logic;              -- from machine UART_TXD
    -- keyboard matrix (widget interface) and joysticks
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

  constant VERSION : std_logic_vector(7 downto 0) := x"01";
  constant BIT_CLKS : integer := 20;

  type ram512_t  is array (0 to 511)  of std_logic_vector(7 downto 0);
  type ram1k_t   is array (0 to 1023) of std_logic_vector(7 downto 0);
  type ram16k_t  is array (0 to 16383) of std_logic_vector(7 downto 0);
  type mat_t     is array (0 to 8) of std_logic_vector(7 downto 0);

  signal rbuf : ram512_t;
  signal wbuf : ram512_t;
  signal txf  : ram1k_t;     -- Rockchip -> monitor
  signal rxf  : ram16k_t;    -- monitor  -> Rockchip

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

  -- buffers
  signal wbuf_raddr : unsigned(8 downto 0) := (others => '0');
  signal wbuf_dout  : std_logic_vector(7 downto 0) := (others => '0');
  signal rd_ready_r : std_logic := '0';
  signal rd_error_r : std_logic := '0';
  signal wr_ack_r   : std_logic := '0';

  -- UART FIFOs (pointers carry one extra wrap bit)
  signal txf_wp, txf_rp : unsigned(10 downto 0) := (others => '0');
  signal txf_dout       : std_logic_vector(7 downto 0) := (others => '1');
  signal rxf_wp, rxf_rp : unsigned(14 downto 0) := (others => '0');
  signal rxf_wp_d       : unsigned(14 downto 0) := (others => '0');
  signal rxf_wp_d2      : unsigned(14 downto 0) := (others => '0');
  signal txf_wp_d       : unsigned(10 downto 0) := (others => '0');
  signal txf_wp_d2      : unsigned(10 downto 0) := (others => '0');
  -- RAM write ports (all RAM writes happen in one process -> BRAM inference)
  signal rbuf_we  : std_logic := '0';
  signal rbuf_wa  : unsigned(8 downto 0) := (others => '0');
  signal rbuf_wd  : std_logic_vector(7 downto 0) := (others => '0');
  signal txf_we   : std_logic := '0';
  signal txf_wa   : unsigned(9 downto 0) := (others => '0');
  signal txf_wd   : std_logic_vector(7 downto 0) := (others => '0');
  signal rxf_we   : std_logic := '0';
  signal rxf_wa   : unsigned(13 downto 0) := (others => '0');
  signal rxf_wd   : std_logic_vector(7 downto 0) := (others => '0');
  signal rxf_dout       : std_logic_vector(7 downto 0) := (others => '0');
  signal rx_overflow    : std_logic := '0';
  signal rx_count       : unsigned(14 downto 0);
  signal tx_free        : unsigned(10 downto 0);

  -- serializer to the monitor
  signal ser_busy  : std_logic := '0';
  signal ser_sr    : std_logic_vector(9 downto 0) := (others => '1');
  signal ser_bits  : integer range 0 to 10 := 0;
  signal ser_tmr   : integer range 0 to BIT_CLKS-1 := 0;
  signal ser_wait  : integer range 0 to 3 := 0;
  -- deserializer from the monitor
  signal des_in    : std_logic_vector(1 downto 0) := (others => '1');
  signal des_busy  : std_logic := '0';
  signal des_tmr   : integer range 0 to BIT_CLKS-1 := 0;
  signal des_bits  : integer range 0 to 9 := 0;
  signal des_sr    : std_logic_vector(7 downto 0) := (others => '0');

  -- inputs
  signal ctrl_r  : std_logic_vector(7 downto 0) := (others => '0');
  signal joya_r  : std_logic_vector(4 downto 0) := (others => '0');
  signal joyb_r  : std_logic_vector(4 downto 0) := (others => '0');
  signal mat     : mat_t := (others => (others => '0'));
  signal col_r   : std_logic_vector(7 downto 0) := (others => '1');

begin

  spi_miso    <= miso_r;
  sd_rd_ready <= rd_ready_r;
  sd_rd_error <= rd_error_r;
  sd_wr_ack   <= wr_ack_r;
  joya        <= joya_r;
  joyb        <= joyb_r;
  ctrl        <= ctrl_r;
  -- The keymapper samples the column combinationally while it scans
  -- (a registered lookup shifts every key one column up).
  matrix_col  <= not mat(matrix_col_idx) when matrix_col_idx <= 8 else (others => '1');
  spi_active  <= not cs_s(1);

  rx_count <= rxf_wp_d2 - rxf_rp;
  tx_free  <= to_unsigned(1024, 11) - (txf_wp - txf_rp);

  -- Read buffer: written by SPI (SD_PUT), read by the emulator (sync read).
  -- Write buffer: written by the emulator, read by SPI (SD_GET).
  process (clk)
  begin
    if rising_edge(clk) then
      if rbuf_we = '1' then
        rbuf(to_integer(rbuf_wa)) <= rbuf_wd;
      end if;
      rbuf_data <= rbuf(to_integer(rbuf_addr));
      if txf_we = '1' then
        txf(to_integer(txf_wa)) <= txf_wd;
      end if;
      if rxf_we = '1' then
        rxf(to_integer(rxf_wa)) <= rxf_wd;
      end if;
      if wbuf_we = '1' then
        wbuf(to_integer(wbuf_addr)) <= wbuf_data;
      end if;
      wbuf_dout <= wbuf(to_integer(wbuf_raddr));
      txf_dout  <= txf(to_integer(txf_rp(9 downto 0)));
      rxf_dout  <= rxf(to_integer(rxf_rp(13 downto 0)));
    end if;
  end process;

  process (clk)
    variable rxb   : std_logic_vector(7 downto 0);
    variable nxt   : std_logic_vector(7 downto 0);
    variable st    : integer range 0 to 1023;
    variable put_i : integer range 0 to 1023;
  begin
    if rising_edge(clk) then
      wr_ack_r  <= '0';
      rbuf_we   <= '0';
      txf_we    <= '0';
      rxf_we    <= '0';
      rxf_wp_d  <= rxf_wp;
      rxf_wp_d2 <= rxf_wp_d;
      txf_wp_d  <= txf_wp;
      txf_wp_d2 <= txf_wp_d;

      -- The emulator dropped its read request: the data has been delivered.
      if sd_rd_req = '0' then
        rd_ready_r <= '0';
        rd_error_r <= '0';
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
      elsif sck_s(2) = '0' and sck_s(1) = '1' then
        -- rising SCLK: sample MOSI, then present the next MISO bit
        if bitcnt /= 7 then
          rx_sr  <= rx_sr(5 downto 0) & mosi_s(1);
          bitcnt <= bitcnt + 1;
          miso_r <= tx_sr(6);
          tx_sr  <= tx_sr(5 downto 0) & '0';
        else
          bitcnt <= 0;
          rxb := rx_sr & mosi_s(1);
          nxt := x"00";
          if bidx /= 1023 then
            bidx <= bidx + 1;
          end if;

          if bidx = 0 then
            -- command byte
            cmd <= rxb;
            case rxb is
              when x"11" => wbuf_raddr <= (others => '0');   -- prefetch
              when x"12" => wr_ack_r <= '1';
              when x"13" => rd_error_r <= sd_rd_req;
              when others => null;
            end case;
          else
            case cmd is
              when x"01" =>                 -- STATUS (byte 1 = dummy)
                st := to_integer(bidx) - 1; -- index of the byte to send next
                case st is
                  when 0  => nxt := x"4D";
                  when 1  => nxt := x"65";
                  when 2  => nxt := VERSION;
                  when 3  => nxt := "00" & rd_error_r & rx_overflow & sd_inited & sd_wr_req
                                    & rd_ready_r & sd_rd_req;
                  when 4  => nxt := std_logic_vector(sd_seq);
                  when 5  => nxt := std_logic_vector(sd_lba(31 downto 24));
                  when 6  => nxt := std_logic_vector(sd_lba(23 downto 16));
                  when 7  => nxt := std_logic_vector(sd_lba(15 downto 8));
                  when 8  => nxt := std_logic_vector(sd_lba(7 downto 0));
                  when 9  => nxt := "0" & std_logic_vector(rx_count(14 downto 8));
                  when 10 => nxt := std_logic_vector(rx_count(7 downto 0));
                  when 11 => nxt := "00000" & std_logic_vector(tx_free(10 downto 8));
                  when 12 => nxt := std_logic_vector(tx_free(7 downto 0));
                  when 13 => nxt := std_logic_vector(sd_cmd_cnt);
                  when 14 => nxt := std_logic_vector(sd_last_cmd);
                  when 15 => nxt := ctrl_r;
                  when others => nxt := x"00";
                end case;

              when x"10" =>                 -- SD_PUT: payload bytes 1..512
                put_i := to_integer(bidx) - 1;
                if put_i < 512 then
                  rbuf_we <= '1';
                  rbuf_wa <= to_unsigned(put_i, 9);
                  rbuf_wd <= rxb;
                  if put_i = 511 and sd_rd_req = '1' then
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
                if rx_count /= 0 then
                  nxt := rxf_dout;
                  rxf_rp <= rxf_rp + 1;
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

          -- For SD_GET the first data byte goes out after the dummy byte.
          if bidx = 0 then
            nxt := x"00";
          end if;
          miso_r <= nxt(7);
          tx_sr  <= nxt(6 downto 0);
        end if;
      end if;

      ------------------------------------------------------------------
      -- Serializer: TX FIFO -> monitor RsRx (8N1, 20 clocks/bit)
      ------------------------------------------------------------------
      if ser_busy = '0' then
        mon_rx <= '1';
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
        mon_rx <= ser_sr(0);
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
      des_in <= des_in(0) & mon_tx;
      if des_busy = '0' then
        if des_in(1) = '1' and des_in(0) = '0' then   -- start bit edge
          des_busy <= '1';
          des_tmr  <= 0;
          des_bits <= 0;
        end if;
      else
        if (des_bits = 0 and des_tmr = BIT_CLKS/2 - 1) or
           (des_bits /= 0 and des_tmr = BIT_CLKS-1) then
          des_tmr <= 0;
          if des_bits = 0 then
            if des_in(0) = '1' then       -- false start
              des_busy <= '0';
            end if;
            des_bits <= 1;
          elsif des_bits <= 8 then
            des_sr   <= des_in(0) & des_sr(7 downto 1);
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
