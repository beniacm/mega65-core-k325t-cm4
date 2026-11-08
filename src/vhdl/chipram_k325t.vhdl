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
--
-- All three blocks are four byte lanes (lane = address(1:0)): port B (VIC-IV) also returns the
-- aligned 32-bit word at addressb(19:2) on dob32 (byte n of the word = address 4w + n), so the
-- VIC-IV's fast token path (XCTL bit 7) reads a full-colour glyph row in two cycles.
-- shadowram-k325t-lo.vhdl is generated with the lanes by src/tools/k325t_chipram_lanes.py.
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
        dob : out unsigned(7 downto 0);
        dob32 : out unsigned(31 downto 0)       -- K325T: the aligned word at addressb(19:2)
        );
end shadowram;

architecture rtl of shadowram is
  signal aa : unsigned(19 downto 0);
  signal lo_we : std_logic;
  signal lo_addr : integer range 0 to 1048575;
  signal lo_addrb : unsigned(19 downto 0);
  signal lo_doa, lo_dob : unsigned(7 downto 0);
  signal lo_dob32 : unsigned(31 downto 0);
  type q_t is array (0 to 3) of unsigned(7 downto 0);
  signal mid_qa, hi_qa, mid_qb, hi_qb : q_t := (others => x"00");
  signal sel_a, sel_b : std_logic_vector(1 downto 0) := "00";   -- registered: 00 lo, 01 mid, 1x hi
  signal byte_a, byte_b : unsigned(1 downto 0) := "00";         -- registered lane of the byte

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
              ClkB => ClkB, addressb => lo_addrb, dob => lo_dob, dob32 => lo_dob32);

  -- mid (128 KB) and hi (512 KB): four byte lanes each
  lanes : for l in 0 to 3 generate
    type midl_t is array (0 to 32767) of unsigned(7 downto 0);
    type hil_t is array (0 to 131071) of unsigned(7 downto 0);
    shared variable midl : midl_t;
    shared variable hil : hil_t;
  begin
    process (ClkA)
    begin
      if rising_edge(ClkA) then
        if wea /= '0' and region(aa) = "01" and aa(1 downto 0) = to_unsigned(l, 2) then
          midl(to_integer(aa(16 downto 2))) := dia;
        end if;
        mid_qa(l) <= midl(to_integer(aa(16 downto 2)));
        if wea /= '0' and aa(19) = '1' and aa(1 downto 0) = to_unsigned(l, 2) then
          hil(to_integer(aa(18 downto 2))) := dia;
        end if;
        hi_qa(l) <= hil(to_integer(aa(18 downto 2)));
      end if;
    end process;
    process (ClkB)
    begin
      if rising_edge(ClkB) then
        mid_qb(l) <= midl(to_integer(addressb(16 downto 2)));
        hi_qb(l) <= hil(to_integer(addressb(18 downto 2)));
      end if;
    end process;
  end generate;

  process (ClkA)
  begin
    if rising_edge(ClkA) then
      sel_a <= region(aa); byte_a <= aa(1 downto 0);
    end if;
  end process;
  process (ClkB)
  begin
    if rising_edge(ClkB) then
      sel_b <= region(addressb); byte_b <= addressb(1 downto 0);
    end if;
  end process;

  doa <= hi_qa(to_integer(byte_a)) when sel_a(1) = '1' else mid_qa(to_integer(byte_a)) when sel_a(0) = '1' else lo_doa;
  dob <= hi_qb(to_integer(byte_b)) when sel_b(1) = '1' else mid_qb(to_integer(byte_b)) when sel_b(0) = '1' else lo_dob;
  dob32 <= hi_qb(3) & hi_qb(2) & hi_qb(1) & hi_qb(0) when sel_b(1) = '1'
           else mid_qb(3) & mid_qb(2) & mid_qb(1) & mid_qb(0) when sel_b(0) = '1'
           else lo_dob32;
end architecture;
