--------------------------------------------------------------------------------
-- eth_vphy.vhdl -- virtual RMII Ethernet PHY: MEGA65 MAC  <->  frame slots for
-- the Rockchip service bridge (rk_bridge), which forwards frames to a Linux
-- TAP interface on the module.
--
-- MAC side (clk50, the RMII reference clock; 2 bits per clock = 100 Mbit/s):
--   TX: watches txen/txd like a PHY would, strips preamble + SFD and captures
--       the frame (including the MAC's FCS) into the next free TX slot.  If all
--       slots are full the frame is dropped (counted) -- like a congested link.
--   RX: when a filled RX slot is waiting, sends preamble + SFD + the slot's
--       bytes (the server includes the FCS) with rxdv, then a 96-bit gap.
--   RMII bit order: LSB dibit first (preamble 0x55 = "01" dibits, SFD 0xD5
--   ends with "11").
-- Bridge side (clkb): read port for TX slots, write port for RX slots,
--   per-slot toggle handshakes (full/released) synchronised across domains;
--   slot lengths live in registers that are stable while their toggle is set.
--
-- SLOTS slots of 2 KB per direction (8 x 2 KB = 16 KB each, block RAM).
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity eth_vphy is
  port (
    clk50     : in  std_logic;
    clkb      : in  std_logic;
    -- MAC (RMII) side, clk50
    mac_txd   : in  unsigned(1 downto 0);
    mac_txen  : in  std_logic;
    mac_rxd   : out unsigned(1 downto 0) := "00";
    mac_rxdv  : out std_logic := '0';
    -- bridge side, clkb: frames MAC -> Rockchip
    tx_avail  : out std_logic;                    -- a captured frame is waiting
    tx_len    : out unsigned(10 downto 0);        -- its length (bytes incl. FCS)
    tx_raddr  : in  unsigned(10 downto 0);        -- byte offset in that frame
    tx_rdata  : out std_logic_vector(7 downto 0); -- registered (1 clkb)
    tx_pop    : in  std_logic;                    -- pulse: frame consumed
    tx_drops  : out unsigned(7 downto 0);         -- frames lost (no free slot)
    -- bridge side, clkb: frames Rockchip -> MAC
    rx_free   : out unsigned(3 downto 0);         -- free RX slots
    rx_we     : in  std_logic;
    rx_waddr  : in  unsigned(10 downto 0);        -- byte offset in the slot being filled
    rx_wdata  : in  std_logic_vector(7 downto 0);
    rx_push   : in  std_logic;                    -- pulse: slot filled, send it
    rx_len_in : in  unsigned(10 downto 0)
  );
end entity;

architecture rtl of eth_vphy is
  constant SLOTS : integer := 8;
  type ram_t is array (0 to SLOTS * 2048 - 1) of std_logic_vector(7 downto 0);
  type len_arr_t is array (0 to SLOTS - 1) of unsigned(10 downto 0);
  subtype tog_t is std_logic_vector(SLOTS - 1 downto 0);

  signal txram, rxram : ram_t;

  -- MAC -> Rockchip (TX)
  signal tx_full     : tog_t := (others => '0');   -- clk50
  signal tx_rel      : tog_t := (others => '0');   -- clkb
  signal tx_rel_s1, tx_rel_s2   : tog_t := (others => '0');   -- in clk50
  signal tx_full_s1, tx_full_s2 : tog_t := (others => '0');   -- in clkb
  signal tx_lens     : len_arr_t := (others => (others => '0'));  -- clk50 regs
  signal tw          : integer range 0 to SLOTS - 1 := 0;   -- clk50 write slot
  signal tr          : integer range 0 to SLOTS - 1 := 0;   -- clkb read slot
  type cap_t is (C_IDLE, C_PRE, C_DATA, C_DROP);
  signal cap         : cap_t := C_IDLE;
  signal cap_byte    : std_logic_vector(7 downto 0) := (others => '0');
  signal cap_di      : integer range 0 to 3 := 0;
  signal cap_cnt     : unsigned(11 downto 0) := (others => '0');
  signal txram_we    : std_logic := '0';
  signal txram_wa    : unsigned(13 downto 0) := (others => '0');
  signal txram_wd    : std_logic_vector(7 downto 0) := (others => '0');
  signal drops       : unsigned(7 downto 0) := (others => '0');
  signal txen_d      : std_logic := '0';

  -- Rockchip -> MAC (RX)
  signal rx_full     : tog_t := (others => '0');   -- clkb
  signal rx_done     : tog_t := (others => '0');   -- clk50
  signal rx_full_s1, rx_full_s2 : tog_t := (others => '0');   -- in clk50
  signal rx_done_s1, rx_done_s2 : tog_t := (others => '0');   -- in clkb
  signal rx_lens     : len_arr_t := (others => (others => '0'));  -- clkb regs
  signal rw          : integer range 0 to SLOTS - 1 := 0;   -- clkb write slot
  signal rr          : integer range 0 to SLOTS - 1 := 0;   -- clk50 send slot
  type snd_t is (S_IDLE, S_PRE, S_DATA, S_GAP);
  signal snd         : snd_t := S_IDLE;
  signal snd_di      : integer range 0 to 3 := 0;
  signal snd_cnt     : unsigned(10 downto 0) := (others => '0');
  signal snd_len     : unsigned(10 downto 0) := (others => '0');
  signal snd_pre     : integer range 0 to 31 := 0;
  signal snd_gap     : integer range 0 to 63 := 0;
  signal snd_byte    : std_logic_vector(7 downto 0) := (others => '0');
  signal rxram_ra    : unsigned(13 downto 0) := (others => '0');
  signal rxram_rd    : std_logic_vector(7 downto 0) := (others => '0');

  attribute ASYNC_REG : string;
  attribute ASYNC_REG of tx_rel_s1, tx_rel_s2, tx_full_s1, tx_full_s2,
    rx_full_s1, rx_full_s2, rx_done_s1, rx_done_s2 : signal is "TRUE";

  function popcount_eq(a, b : tog_t) return unsigned is
    variable n : unsigned(3 downto 0) := (others => '0');
  begin
    for i in a'range loop
      if a(i) = b(i) then n := n + 1; end if;
    end loop;
    return n;
  end function;

begin

  ---------------------------------------------------------------------------
  -- RAM ports
  ---------------------------------------------------------------------------
  process (clk50)
  begin
    if rising_edge(clk50) then
      if txram_we = '1' then
        txram(to_integer(txram_wa)) <= txram_wd;
      end if;
      rxram_rd <= rxram(to_integer(rxram_ra));
    end if;
  end process;

  process (clkb)
  begin
    if rising_edge(clkb) then
      tx_rdata <= txram(tr * 2048 + to_integer(tx_raddr));
      if rx_we = '1' then
        rxram(rw * 2048 + to_integer(rx_waddr)) <= rx_wdata;
      end if;
    end if;
  end process;

  ---------------------------------------------------------------------------
  -- clkb side: handshakes
  ---------------------------------------------------------------------------
  tx_avail <= '1' when tx_full_s2(tr) /= tx_rel(tr) else '0';
  tx_len   <= tx_lens(tr);                 -- stable while tx_avail
  rx_free  <= popcount_eq(rx_full, rx_done_s2);
  tx_drops <= drops;                       -- quasi-static counter (debug)

  process (clkb)
  begin
    if rising_edge(clkb) then
      tx_full_s1 <= tx_full;  tx_full_s2 <= tx_full_s1;
      rx_done_s1 <= rx_done;  rx_done_s2 <= rx_done_s1;
      if tx_pop = '1' and tx_full_s2(tr) /= tx_rel(tr) then
        tx_rel(tr) <= not tx_rel(tr);
        tr <= (tr + 1) mod SLOTS;
      end if;
      if rx_push = '1' and rx_full(rw) = rx_done_s2(rw) then
        rx_lens(rw) <= rx_len_in;
        rx_full(rw) <= not rx_full(rw);
        rw <= (rw + 1) mod SLOTS;
      end if;
    end if;
  end process;

  ---------------------------------------------------------------------------
  -- clk50 side: capture frames from the MAC (TX) and send frames to it (RX)
  ---------------------------------------------------------------------------
  process (clk50)
    variable b : std_logic_vector(7 downto 0);
  begin
    if rising_edge(clk50) then
      tx_rel_s1  <= tx_rel;   tx_rel_s2  <= tx_rel_s1;
      rx_full_s1 <= rx_full;  rx_full_s2 <= rx_full_s1;
      txram_we <= '0';
      txen_d   <= mac_txen;

      -- ---------------- capture (MAC TX) ----------------
      case cap is
        when C_IDLE =>
          if mac_txen = '1' and txen_d = '0' then
            if tx_full(tw) = tx_rel_s2(tw) then
              cap <= C_PRE;
            else
              cap <= C_DROP;
              drops <= drops + 1;
            end if;
          end if;
        when C_PRE =>
          if mac_txen = '0' then
            cap <= C_IDLE;
          elsif mac_txd = "11" then          -- last dibit of the SFD
            cap     <= C_DATA;
            cap_di  <= 0;
            cap_cnt <= (others => '0');
          end if;
        when C_DATA =>
          if mac_txen = '1' then
            b := std_logic_vector(mac_txd) & cap_byte(7 downto 2);
            cap_byte <= b;
            if cap_di = 3 then
              cap_di <= 0;
              if cap_cnt < 2048 then
                txram_we <= '1';
                txram_wa <= to_unsigned(tw * 2048, 14) + cap_cnt(10 downto 0);
                txram_wd <= b;
                cap_cnt  <= cap_cnt + 1;
              end if;
            else
              cap_di <= cap_di + 1;
            end if;
          else
            -- end of frame: publish it (runts below 18 bytes are discarded)
            if cap_cnt >= 18 then
              tx_lens(tw) <= cap_cnt(10 downto 0);
              tx_full(tw) <= not tx_full(tw);
              tw <= (tw + 1) mod SLOTS;
            end if;
            cap <= C_IDLE;
          end if;
        when C_DROP =>
          if mac_txen = '0' then
            cap <= C_IDLE;
          end if;
      end case;

      -- ---------------- send (MAC RX) ----------------
      case snd is
        when S_IDLE =>
          mac_rxdv <= '0';
          mac_rxd  <= "00";
          if rx_full_s2(rr) /= rx_done(rr) then
            snd_len  <= rx_lens(rr);           -- stable while the slot is full
            snd_pre  <= 0;
            rxram_ra <= to_unsigned(rr * 2048, 14);
            snd      <= S_PRE;
          end if;
        when S_PRE =>
          -- 7 x 0x55 + 0xD5 = 31 dibits "01" then "11"
          mac_rxdv <= '1';
          if snd_pre = 31 then
            mac_rxd  <= "11";
            snd_byte <= rxram_rd;              -- byte 0 (address set in IDLE)
            rxram_ra <= rxram_ra + 1;
            snd_cnt  <= (others => '0');
            snd_di   <= 0;
            snd      <= S_DATA;
          else
            mac_rxd <= "01";
            snd_pre <= snd_pre + 1;
          end if;
        when S_DATA =>
          if snd_cnt = snd_len then
            mac_rxdv <= '0';
            mac_rxd  <= "00";
            rx_done(rr) <= not rx_done(rr);
            rr <= (rr + 1) mod SLOTS;
            snd_gap <= 0;
            snd <= S_GAP;
          else
            mac_rxdv <= '1';
            mac_rxd  <= unsigned(snd_byte(2 * snd_di + 1 downto 2 * snd_di));
            if snd_di = 3 then
              snd_di   <= 0;
              snd_cnt  <= snd_cnt + 1;
              snd_byte <= rxram_rd;            -- next byte (prefetched)
              rxram_ra <= rxram_ra + 1;
            else
              snd_di <= snd_di + 1;
            end if;
          end if;
        when S_GAP =>                          -- 96 bit times = 48 clocks
          mac_rxdv <= '0';
          if snd_gap = 47 then
            snd <= S_IDLE;
          else
            snd_gap <= snd_gap + 1;
          end if;
      end case;
    end if;
  end process;

end architecture;
