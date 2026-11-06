-- rk_iprog.vhdl -- warm-boot the 7-series FPGA into the bitstream at a flash address
-- (UG470 "IPROG using ICAPE2"), requested by rk_bridge command 0x60 (iprog_toggle).
-- Only for designs that have no ICAPE2 of their own (the MEGA65 core has one in
-- sdcardio/reconfig; the Rockchip triggers that via $D6C8..$D6CF instead).
-- clk <= 100 MHz (ICAPE2 limit).  addr is the byte address in the SPI flash; WBSTAR takes it
-- divided by 256 (as the MEGA65's own utilities do: "addresses for WBSTAR are shifted by 8 bits").
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library unisim;
use unisim.vcomponents.all;

entity rk_iprog is
  port (
    clk          : in std_logic;
    iprog_toggle : in std_logic;                       -- from rk_bridge (other clock)
    iprog_addr   : in std_logic_vector(31 downto 0)    -- stable before the toggle
  );
end entity;

architecture rtl of rk_iprog is
  type words_t is array (0 to 7) of std_logic_vector(31 downto 0);
  signal tog_s  : std_logic_vector(2 downto 0) := (others => '0');
  signal addr_s : std_logic_vector(31 downto 0) := (others => '0');
  signal idx    : integer range 0 to 8 := 8;
  signal csib   : std_logic := '1';
  signal din    : std_logic_vector(31 downto 0) := (others => '1');

  attribute ASYNC_REG : string;
  attribute ASYNC_REG of tog_s : signal is "TRUE";

  -- ICAPE2 takes each byte bit-reversed
  function swap(w : std_logic_vector(31 downto 0)) return std_logic_vector is
    variable r : std_logic_vector(31 downto 0);
  begin
    for b in 0 to 3 loop
      for i in 0 to 7 loop
        r(8 * b + i) := w(8 * b + 7 - i);
      end loop;
    end loop;
    return r;
  end function;
begin
  process (clk)
    variable words : words_t;
  begin
    if rising_edge(clk) then
      tog_s <= tog_s(1 downto 0) & iprog_toggle;
      csib  <= '1';
      if tog_s(2) /= tog_s(1) then
        addr_s <= iprog_addr;
        idx    <= 0;
      elsif idx < 8 then
        words := (x"FFFFFFFF",              -- dummy
                  x"AA995566",              -- sync
                  x"20000000",              -- NOOP
                  x"30020001",              -- write 1 word to WBSTAR
                  x"00" & addr_s(31 downto 8),  -- WBSTAR: SPI start address in 256-byte units
                  x"30008001",              -- write 1 word to CMD
                  x"0000000F",              -- IPROG
                  x"20000000");             -- NOOP
        din  <= swap(words(idx));
        csib <= '0';
        idx  <= idx + 1;
      end if;
    end if;
  end process;

  icap : ICAPE2
    generic map (ICAP_WIDTH => "X32")
    port map (CLK => clk, CSIB => csib, RDWRB => '0', I => din, O => open);
end architecture;
