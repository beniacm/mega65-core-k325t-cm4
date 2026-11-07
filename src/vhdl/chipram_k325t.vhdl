--------------------------------------------------------------------------------
-- chipram_k325t.vhdl -- 1 MB chip RAM for the QMTech K325T (entity "shadowram", the name
-- gs4510 instantiates).  The CPU and the VIC-IV already take a chip RAM size (generics
-- chipram_size / chipram_1mb, unused by every real board); the K325T has the block RAM.
--
--   $00000-$5FFFF  384 KB  shadowram_lo: the generated, pre-loaded chip RAM
--                          (shadowram-k325t-lo.vhdl = shadowram-no-attic.vhdl renamed)
--   $60000-$7FFFF  128 KB  mid: plain RAM, indexed by address(16:0)
--   $80000-$FFFFF  512 KB  hi:  plain RAM, indexed by address(18:0)
--
-- The extra blocks are indexed by raw address bits (no adder in the address path).  Same
-- interface and latency as shadowram: one clock on both ports.  Whether the CPU may use
-- $60000-$FFFFF is decided in gs4510 (compat: 384 KB after reset, $FFD71F0 bit 0 = 1 MB).
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity shadowram is
  port (ClkA : in std_logic;
        addressa : in integer range 0 to 1048575;
        wea : in std_logic;
        dia : in unsigned(7 downto 0);
        writes : out unsigned(7 downto 0);
        no_writes : out unsigned(7 downto 0);
        doa : out unsigned(7 downto 0);
        ClkB : in std_logic;
        addressb : in unsigned(19 downto 0);
        dob : out unsigned(7 downto 0)
        );
end shadowram;

architecture rtl of shadowram is
  type mid_t is array (0 to 131071) of unsigned(7 downto 0);
  type hi_t is array (0 to 524287) of unsigned(7 downto 0);
  shared variable mid : mid_t;
  shared variable hi : hi_t;

  signal aa : unsigned(19 downto 0);
  signal lo_we : std_logic;
  signal lo_addr : integer range 0 to 1048575;
  signal lo_addrb : unsigned(19 downto 0);
  signal lo_doa, lo_dob : unsigned(7 downto 0);
  signal mid_doa, hi_doa, mid_dob, hi_dob : unsigned(7 downto 0) := x"00";
  signal sel_a, sel_b : std_logic_vector(1 downto 0) := "00";   -- registered: 00 lo, 01 mid, 1x hi

  function region(a : unsigned(19 downto 0)) return std_logic_vector is
  begin
    if a(19) = '1' then
      return "10";
    elsif a(18 downto 17) = "11" then
      return "01";
    else
      return "00";
    end if;
  end function;
begin
  aa <= to_unsigned(addressa, 20);
  lo_we <= wea when region(aa) = "00" else '0';
  lo_addr <= addressa when region(aa) = "00" else 0;          -- shadowram_lo ends at 384 KB
  lo_addrb <= addressb when region(addressb) = "00" else (others => '0');

  lo : entity work.shadowram_lo
    port map (ClkA => ClkA, addressa => lo_addr, wea => lo_we, dia => dia,
              writes => writes, no_writes => no_writes, doa => lo_doa,
              ClkB => ClkB, addressb => lo_addrb, dob => lo_dob);

  process (ClkA)
  begin
    if rising_edge(ClkA) then
      sel_a <= region(aa);
      if wea /= '0' and region(aa) = "01" then
        mid(to_integer(aa(16 downto 0))) := dia;
      end if;
      mid_doa <= mid(to_integer(aa(16 downto 0)));
      if wea /= '0' and aa(19) = '1' then
        hi(to_integer(aa(18 downto 0))) := dia;
      end if;
      hi_doa <= hi(to_integer(aa(18 downto 0)));
    end if;
  end process;

  process (ClkB)
  begin
    if rising_edge(ClkB) then
      sel_b <= region(addressb);
      mid_dob <= mid(to_integer(addressb(16 downto 0)));
      hi_dob <= hi(to_integer(addressb(18 downto 0)));
    end if;
  end process;

  doa <= hi_doa when sel_a(1) = '1' else mid_doa when sel_a(0) = '1' else lo_doa;
  dob <= hi_dob when sel_b(1) = '1' else mid_dob when sel_b(0) = '1' else lo_dob;
end architecture;
