--------------------------------------------------------------------------------
-- soft_rtc.vhdl -- a battery-less real-time clock for boards without an RTC chip
-- (QMTech K325T CM4 carrier).  Presents the MEGA65 RTC registers ($FFD7110-$FFD7116, the
-- layout the ROM reads on the R3..R6 boards) and counts on its own: 1 Hz from the CPU clock,
-- BCD with carries through minutes, hours, day (month lengths, leap years 2000-2099), month
-- and year, plus the day of the week.  The Rockchip sets it from its network-synchronised
-- clock through the serial monitor (m65d), and programs may set it like a real RTC; a write
-- to the seconds restarts the sub-second counter, so a sync is exact to the clock tick.
--   $FFD7110 seconds  $FFD7111 minutes  $FFD7112 hours (bit 7 = 24 h mode, always set)
--   $FFD7113 day      $FFD7114 month    $FFD7115 year (20yy)  $FFD7116 day of week (0..6)
-- All other addresses of the $FFD71xx page read 0.  Until the first write it reads an
-- invalid date (day 0), which the ROM reports as "no RTC".
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity soft_rtc is
  generic ( clock_frequency : integer );
  port (
    clock        : in  std_logic;
    cs           : in  std_logic;
    fastio_addr  : in  unsigned(19 downto 0);
    fastio_write : in  std_logic;
    fastio_read  : in  std_logic;
    fastio_wdata : in  unsigned(7 downto 0);
    fastio_rdata : out unsigned(7 downto 0)
  );
end entity;

architecture rtl of soft_rtc is
  signal sec, min, hour : unsigned(7 downto 0) := x"00";       -- BCD
  signal day, month     : unsigned(7 downto 0) := x"00";       -- BCD; 0 = not set
  signal year           : unsigned(7 downto 0) := x"00";       -- BCD, 20yy
  signal dow            : unsigned(7 downto 0) := x"00";
  signal tick_cnt       : integer range 0 to clock_frequency - 1 := 0;

  -- BCD + 1 (no range check)
  function bcd_inc(v : unsigned(7 downto 0)) return unsigned is
  begin
    if v(3 downto 0) >= 9 then
      return (v(7 downto 4) + 1) & x"0";
    else
      return v + 1;
    end if;
  end function;

  function bcd_to_int(v : unsigned(7 downto 0)) return integer is
  begin
    return to_integer(v(7 downto 4)) * 10 + to_integer(v(3 downto 0));
  end function;

  function month_days(m, y : unsigned(7 downto 0)) return integer is
    variable mi : integer;
  begin
    mi := bcd_to_int(m);
    if mi = 2 then
      if bcd_to_int(y) mod 4 = 0 then return 29; else return 28; end if;
    elsif mi = 4 or mi = 6 or mi = 9 or mi = 11 then
      return 30;
    else
      return 31;
    end if;
  end function;
begin

  -- reads: combinational onto the shared fastio bus, 'Z' when not selected
  process (cs, fastio_read, fastio_addr, sec, min, hour, day, month, year, dow) is
  begin
    if cs = '1' and fastio_read = '1' then
      case fastio_addr(7 downto 0) is
        when x"10" => fastio_rdata <= sec;
        when x"11" => fastio_rdata <= min;
        when x"12" => fastio_rdata <= "10" & hour(5 downto 0);   -- 24 h mode
        when x"13" => fastio_rdata <= day;
        when x"14" => fastio_rdata <= month;
        when x"15" => fastio_rdata <= year;
        when x"16" => fastio_rdata <= dow;
        when others => fastio_rdata <= x"00";
      end case;
    else
      fastio_rdata <= (others => 'Z');
    end if;
  end process;

  process (clock) is
    variable carry : boolean;
  begin
    if rising_edge(clock) then
      if cs = '1' and fastio_write = '1' then
        case fastio_addr(7 downto 0) is
          when x"10" => sec   <= fastio_wdata and x"7F"; tick_cnt <= 0;
          when x"11" => min   <= fastio_wdata and x"7F";
          when x"12" => hour  <= fastio_wdata and x"3F";
          when x"13" => day   <= fastio_wdata and x"3F";
          when x"14" => month <= fastio_wdata and x"1F";
          when x"15" => year  <= fastio_wdata;
          when x"16" => dow   <= fastio_wdata and x"07";
          when others => null;
        end case;
      elsif tick_cnt /= clock_frequency - 1 then
        tick_cnt <= tick_cnt + 1;
      else
        tick_cnt <= 0;
        if day /= x"00" then                       -- runs once it has been set
          carry := sec = x"59";
          if carry then sec <= x"00"; else sec <= bcd_inc(sec); end if;
          if carry then
            carry := min = x"59";
            if carry then min <= x"00"; else min <= bcd_inc(min); end if;
          end if;
          if carry then
            carry := hour(5 downto 0) = "100011";   -- 23
            if carry then hour <= x"00"; else hour <= bcd_inc(hour); end if;
          end if;
          if carry then
            if dow >= 6 then dow <= x"00"; else dow <= dow + 1; end if;
            carry := bcd_to_int(day) >= month_days(month, year);
            if carry then day <= x"01"; else day <= bcd_inc(day); end if;
          end if;
          if carry then
            carry := month = x"12";
            if carry then month <= x"01"; else month <= bcd_inc(month); end if;
          end if;
          if carry then
            if year = x"99" then year <= x"00"; else year <= bcd_inc(year); end if;
          end if;
        end if;
      end if;
    end if;
  end process;

end architecture;
