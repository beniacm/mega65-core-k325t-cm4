--------------------------------------------------------------------------------
-- colourram_k325t.vhdl -- 64 KB colour RAM for the QMTech K325T.  The VIC-IV already decodes
-- $FF80000-$FF8FFFF and fetches with 16-bit colour RAM addresses; real boards have 32 KB, so
-- the top half mirrors the bottom.  Here: the existing pre-loaded ram8x32k for $0000-$7FFF plus
-- 32 KB of plain block RAM for $8000-$FFFF.  en64 = '0' (after reset, XCTL bit 2 clear) forces
-- address bit 15 to 0 on both ports, i.e. exactly the 32 KB mirror of a real MEGA65.
-- Port A: CPU (fastio, cpuclock); port B: VIC-IV fetch (pixelclock), read only.
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity ram8x64k_k325t is
  port (
    en64  : in  std_logic;                       -- XCTL bit 2 (any clock: static)
    clka  : in  std_logic;
    ena   : in  std_logic;
    wea   : in  std_logic_vector(0 downto 0);
    addra : in  std_logic_vector(15 downto 0);
    dina  : in  std_logic_vector(7 downto 0);
    douta : out std_logic_vector(7 downto 0);
    clkb  : in  std_logic;
    addrb : in  std_logic_vector(15 downto 0);
    doutb : out std_logic_vector(7 downto 0)
  );
end entity;

architecture rtl of ram8x64k_k325t is
  type hi_t is array (0 to 32767) of std_logic_vector(7 downto 0);
  shared variable hi : hi_t := (others => x"00");
  signal en_a, en_b : std_logic_vector(1 downto 0) := "00";
  signal ha, hb : std_logic;                     -- address bit 15 after gating
  signal sel_a, sel_b : std_logic := '0';
  signal lo_doa, lo_dob, hi_doa, hi_dob : std_logic_vector(7 downto 0);
  signal lo_wea : std_logic_vector(0 downto 0);
  attribute ASYNC_REG : string;
  attribute ASYNC_REG of en_a, en_b : signal is "TRUE";
begin
  process (clka) begin
    if rising_edge(clka) then en_a <= en_a(0) & en64; end if;
  end process;
  process (clkb) begin
    if rising_edge(clkb) then en_b <= en_b(0) & en64; end if;
  end process;
  ha <= addra(15) and en_a(1);
  hb <= addrb(15) and en_b(1);
  lo_wea(0) <= wea(0) and not ha;

  lo : entity work.ram8x32k
    port map (clka => clka, ena => ena, wea => lo_wea, addra => addra(14 downto 0),
              dina => dina, douta => lo_doa,
              clkb => clkb, web => "0", addrb => addrb(14 downto 0), dinb => x"00",
              doutb => lo_dob);

  process (clka)
  begin
    if rising_edge(clka) then
      if ena = '1' then
        sel_a <= ha;
        if wea(0) = '1' and ha = '1' then
          hi(to_integer(unsigned(addra(14 downto 0)))) := dina;
        end if;
        hi_doa <= hi(to_integer(unsigned(addra(14 downto 0))));
      end if;
    end if;
  end process;

  process (clkb)
  begin
    if rising_edge(clkb) then
      sel_b <= hb;
      hi_dob <= hi(to_integer(unsigned(addrb(14 downto 0))));
    end if;
  end process;

  douta <= hi_doa when sel_a = '1' else lo_doa;
  doutb <= hi_dob when sel_b = '1' else lo_dob;
end architecture;
