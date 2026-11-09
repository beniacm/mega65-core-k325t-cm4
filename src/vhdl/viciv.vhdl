--
-- Written by
--    Paul Gardner-Stephen <hld@c64.org>  2013-2014
--
-- *  This program is free software; you can redistribute it and/or modify
-- *  it under the terms of the GNU Lesser General Public License as
-- *  published by the Free Software Foundation; either version 3 of the
-- *  License, or (at your option) any later version.
-- *
-- *  This program is distributed in the hope that it will be useful,
-- *  but WITHOUT ANY WARRANTY; without even the implied warranty of
-- *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
-- *  GNU General Public License for more details.
-- *
-- *  You should have received a copy of the GNU Lesser General Public License
-- *  along with this program; if not, write to the Free Software
-- *  Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA
-- *  02111-1307  USA.
----------------------------------------------------------------------------------
-- Company:
-- Engineer:
--
-- Create Date:    19:11:30 01/02/2014
-- Design Name:
-- Module Name:    vga - Behavioral
-- Project Name:
-- Target Devices:
-- Tool versions:
-- Description:
--
-- Dependencies:
--
-- Revision:
-- Revision 0.01 - File Created
-- Additional Comments:
--
----------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use ieee.numeric_std.all;
use Std.TextIO.all;
use work.debugtools.all;
use work.victypes.all;
use work.all;

-- Uncomment the following library declaration if using
-- arithmetic functions with Signed or Unsigned values
--use IEEE.NUMERIC_STD.ALL;

-- Uncomment the following library declaration if instantiating
-- any Xilinx primitives in this code.
--library UNISIM;
--use UNISIM.VComponents.all;

entity viciv is
  generic (
    chipram_size : integer := 393216;
    -- K325T: 64 KB colour RAM ($FF80000-$FF8FFFF), 32 KB mirror until colour_ram_64k_en
    colour_ram_64k : boolean := false;
    -- K325T RRB list mode v3: object table depth (snapshot, 4 RAMB36 at 1024, 2 at 512)
    rrb_nobj : integer := 1024;
    hyper_installed : boolean := false
    );
  Port (
    all_pause : in std_logic;

    hypervisor_mode : in std_logic;

    hw_errata_level : in unsigned(7 downto 0);
    hw_errata_enable_toggle : inout std_logic;
    hw_errata_disable_toggle : inout std_logic;

    xcounter_out : out integer range 0 to 4095 := 0;
    ycounter_out : out integer range 0 to 2047 := 0;
    ----------------------------------------------------------------------
    -- dot clock
    ----------------------------------------------------------------------
    pixelclock : in  STD_LOGIC;
    ----------------------------------------------------------------------
    -- CPU clock (used for chipram and fastio interfaces)
    ----------------------------------------------------------------------
    cpuclock : in std_logic;

    -- CPU IRQ
    irq : out std_logic;

    reset : in std_logic;

    dd00_bits : in unsigned(1 downto 0);

    upscale_enable : out std_logic := '0';

    -- Touch event to simulate light pen
    touch_x : in unsigned(13 downto 0);
    touch_y : in unsigned(11 downto 0);
    touch_active : in std_logic := '0';

    -- Internal drive LED status for OSD
    led : in std_logic;
    motor : in std_logic;

    -- Actual drive LED (including blink status) for keyboard
    -- (the F011 does this on a real C65)
    drive_led_out : out std_logic;

    vicii_2mhz : out std_logic;
    viciii_fast : out std_logic;
    viciv_fast : out std_logic;

    viciv_frame_indicate : out std_logic := '0';

    interlace_mode : out std_logic := '0';
    mono_mode : out std_logic := '0';
    v400_mode : out std_logic := '0';

    -- Used to tell the CPU when to steal cycles to simulate badlines
    badline_toggle : out std_logic := '0';
    vicii_raster_out : out unsigned(11 downto 0) := to_unsigned(0,12);

    d031_written : out std_logic;
    xray_mode : in std_logic;
    test_pattern_enable : buffer std_logic := '0';

    dat_even : out std_logic;
    dat_offset : out unsigned(15 downto 0);
    dat_bitplane_bank : out unsigned(2 downto 0) := "000";
    dat_bitplane_addresses : out sprite_vector_eight;

    -- Used to synchronise our frame with an external frame generator
    -- (Used to provide stable frame generation for LCD displays, as well
    -- as to support a genlock input).
    external_frame_x_zero : in std_logic;
    external_frame_y_zero : in std_logic := '0';
    -- Similarly, we get told when we should be presenting a new pixel, so
    -- that we don't have to figure out all the fiddly timing ourselves
    external_pixel_strobe_in : in std_logic := '0';

    ----------------------------------------------------------------------
    -- VGA output
    ----------------------------------------------------------------------
    vsync_polarity : out  STD_LOGIC := '0';
    hsync_polarity : out  STD_LOGIC := '0';
    pal50_select : out std_logic := '0';
    vga60_select : out std_logic := '0';

    lcd_pixel_strobe : out std_logic;
    vga_in_frame : in std_logic;
    vgared : out  UNSIGNED (7 downto 0);
    vgagreen : out  UNSIGNED (7 downto 0);
    vgablue : out  UNSIGNED (7 downto 0);
    viciv_outofframe : out std_logic := '0';

    pixel_stream_out : out unsigned (7 downto 0);
    pixel_red_out : out unsigned (7 downto 0);
    pixel_green_out : out unsigned (7 downto 0);
    pixel_blue_out : out unsigned (7 downto 0);
    pixel_y : out unsigned (11 downto 0) := (others => '0');
    pixel_x_out : out integer := 0;
    pixel_strobe_out : out std_logic;
    pixel_newframe : out std_logic;
    pixel_frame_toggle : buffer std_logic;
    pixel_newraster : out std_logic;
    -- Pixel x counter scaled to count to about 640
    pixel_x_640 : out integer := 0;
    -- And as above, but with the 800 pixel resolution.
    pixel_x_800 : out integer := 0;
    -- And pixel X counter scaled to actual video mode (typically 800)
    -- (and corrected for video pipeline depth)
    -- This one holds at zero until the first VIC-II/III sprite position in the
    -- left border.
    native_x_640 : out integer := 0;
    native_y_200 : out integer := 0;
    native_y_400 : out integer := 0;
    -- Scale for 200 and 400px high modes (used by compositors)
    pixel_y_scale_400 : out unsigned(3 downto 0) := (others => '0');
    pixel_y_scale_200 : out unsigned(3 downto 0) := (others => '0');

    ---------------------------------------------------------------------------
    -- CPU Interface to ChipRAM in video controller (allow upto 1MB)
    ---------------------------------------------------------------------------
    --chipram_we : IN STD_LOGIC;
    chipram_address : OUT unsigned(19 DOWNTO 0);
    chipram_datain : IN unsigned(7 DOWNTO 0);
    -- K325T: the aligned 32-bit word at chipram_address(19:2), one clock (chipram_k325t dob32)
    chipram_datain32 : IN unsigned(31 DOWNTO 0) := (others => '0');

    ---------------------------------------------------------------------------
    -- Direct interface to HyperRAM for fetching 256 colour glyph data etc
    ---------------------------------------------------------------------------
    hyper_addr : out unsigned(18 downto 3) := (others => '0');
    hyper_request_toggle : out std_logic := '0';
    hyper_data_in : in unsigned(7 downto 0) := x"00";
    hyper_data_strobe_in : in std_logic := '0';

    -----------------------------------------------------------------------------
    -- FastIO interface for accessing video registers
    -----------------------------------------------------------------------------
    fastio_addr : in std_logic_vector(19 downto 0);
    fastio_read : in std_logic;
    fastio_write : in std_logic;
    fastio_wdata : in std_logic_vector(7 downto 0);
    fastio_rdata : out std_logic_vector(7 downto 0);
    colour_ram_fastio_rdata : out std_logic_vector(7 downto 0);
    colour_ram_cs : in std_logic;
    colour_ram_64k_en : in std_logic := '0';   -- XCTL bit 2 (K325T)
    fast_rrb_en : in std_logic := '0';        -- XCTL bit 4: paint 2 pixels per cycle (K325T)
    rrb_list_en : in std_logic := '0';        -- XCTL bit 5: RRB list mode (K325T, upstream #747)
    fast_token_en : in std_logic := '0';      -- XCTL bit 7 (with bit 4): fast token path (K325T)
    clear_unpainted_en : in std_logic := '0'; -- XCTL bit 3: unpainted pixels show as background (K325T)
    rrb_v2_en : in std_logic := '0';          -- XCTL bit 6: list mode v2, global object table
    obj_tab_addr : in unsigned(19 downto 0) := (others => '0');   -- $FFD71F8-A
    obj_count : in unsigned(9 downto 0) := (others => '0');       -- $FFD71FB, $FFD728B
    obj_hold : in std_logic := '0';                               -- $FFD71FC bit 0
    -- K325T list mode diagnostic counters ($FFD71E0-3, soft_rtc.vhdl; CPU clock domain)
    diag_sel : in unsigned(4 downto 0) := (others => '0');        -- counter index
    diag_clr : in std_logic := '0';                               -- toggles: clear all counters
    diag_val : out unsigned(15 downto 0) := (others => '0');      -- selected counter (registered)
    -- K325T list mode v2 collisions (rrb_list_expander; read at $FFD71A0-C3 via soft_rtc)
    col_bits : out std_logic_vector(1023 downto 0) := (others => '0');
    col_count : out unsigned(9 downto 0) := (others => '0');
    col_toggle : out std_logic := '0';
    col_pidx : in unsigned(9 downto 0) := (others => '0');
    col_pdata : out unsigned(9 downto 0) := (others => '1');
    col_budget : in unsigned(15 downto 0) := (others => '0');      -- $FFD7288-9
    col_trunc : out std_logic := '0';
    bk_full : out std_logic := '0';
    charrom_fastio_rdata : out std_logic_vector(7 downto 0);
    charrom_cs : in std_logic;

    viciii_iomode : out std_logic_vector(1 downto 0) := "11";

    iomode_set : in std_logic_vector(1 downto 0);
    iomode_set_toggle : in std_logic;

    colourram_at_dc00 : out std_logic := '0';
    rom_at_e000 : out std_logic;
    rom_at_c000 : out std_logic;
    rom_at_a000 : out std_logic;
    rom_at_8000 : out std_logic
    );
end viciv;

architecture Behavioral of viciv is

  signal reset_drive : std_logic := '0';

  signal bitplane_bank_select : unsigned(2 downto 0) := "000";

  signal iomode_set_toggle_last : std_logic := '0';

  signal before_y_chargen_start : std_logic := '1';
  signal justbefore_y_chargen_start : std_logic := '0';
  signal stop_chargen_raster_counter : unsigned(7 downto 0) := x"00";
  signal stop_chargen_delay : unsigned(7 downto 0) := to_unsigned(3,8);

  signal vicii_2mhz_internal : std_logic := '1';
  signal viciii_fast_internal : std_logic := '1';
  signal viciv_fast_internal : std_logic := '1';
  signal viciv_bitplane_chargen_on : std_logic := '0';

  signal reg_xcounter_delay : integer range 0 to 31 := 4;
  signal xcounter_pipeline_delayed : integer := 0;
  signal external_pixel_strobe_log : std_logic_vector(31 downto 0) := (others => '0');
  signal sprite_h640_delayed : std_logic := '0';
  signal sprite_v400s_delayed : std_logic_vector(7 downto 0) := x"00";
  signal reg_h640_delayed : std_logic := '0';
  signal reg_h1280_delayed : std_logic := '0';
  signal external_frame_x_zero_latched : std_logic := '0';
  signal last_external_frame_x_zero_latched : std_logic := '0';
  signal last_external_frame_y_zero : std_logic := '0';

  -- last value written to key register
  signal reg_key : unsigned(7 downto 0) := x"00";

  signal last_dd00_bits : unsigned(1 downto 0) := "11";
  signal vicii_hot_regs_enable : std_logic := '1';
  signal viciv_legacy_mode_registers_touched : std_logic := '0';
  signal viciv_single_side_border_width_touched : std_logic := '0';
  signal reg_d018_screen_addr : unsigned(3 downto 0) := x"1";

  signal bump_screen_row_address : std_logic := '0';

  -- Drive stage for IRQ signal in attempt to allieviate timing problems.
  signal irq_drive : std_logic := '1';

  -- Buffer VGA signal to save some time. Similarly pipeline
  -- palette lookup.
  signal vga_buffer_red : UNSIGNED (7 downto 0) := (others => '0');
  signal vga_buffer_green : UNSIGNED (7 downto 0) := (others => '0');
  signal vga_buffer_blue : UNSIGNED (7 downto 0) := (others => '0');
  signal vga_buffer2_red : UNSIGNED (7 downto 0) := (others => '0');
  signal vga_buffer2_green : UNSIGNED (7 downto 0) := (others => '0');
  signal vga_buffer2_blue : UNSIGNED (7 downto 0) := (others => '0');
  signal vga_buffer3_red : UNSIGNED (7 downto 0) := (others => '0');
  signal vga_buffer3_green : UNSIGNED (7 downto 0) := (others => '0');
  signal vga_buffer3_blue : UNSIGNED (7 downto 0) := (others => '0');
  signal vga_buffer4_red : UNSIGNED (7 downto 0) := (others => '0');
  signal vga_buffer4_green : UNSIGNED (7 downto 0) := (others => '0');
  signal vga_buffer4_blue : UNSIGNED (7 downto 0) := (others => '0');
  signal vga_buffer5_red : UNSIGNED (7 downto 0) := (others => '0');
  signal vga_buffer5_green : UNSIGNED (7 downto 0) := (others => '0');
  signal vga_buffer5_blue : UNSIGNED (7 downto 0) := (others => '0');
  signal vga_filtered_red : UNSIGNED (9 downto 0) := (others => '0');
  signal vga_filtered_green : UNSIGNED (9 downto 0) := (others => '0');
  signal vga_filtered_blue : UNSIGNED (9 downto 0) := (others => '0');
  signal vga_palin_red : UNSIGNED (7 downto 0) := (others => '0');
  signal vga_palin_green : UNSIGNED (7 downto 0) := (others => '0');
  signal vga_palin_blue : UNSIGNED (7 downto 0) := (others => '0');
  signal vga_palout_red : UNSIGNED (7 downto 0) := (others => '0');
  signal vga_palout_green : UNSIGNED (7 downto 0) := (others => '0');
  signal vga_palout_blue : UNSIGNED (7 downto 0) := (others => '0');
  signal vga_out_red : UNSIGNED (7 downto 0) := (others => '0');
  signal vga_out_green : UNSIGNED (7 downto 0) := (others => '0');
  signal vga_out_blue : UNSIGNED (7 downto 0) := (others => '0');
  signal pixel_colour : unsigned(7 downto 0) := x"00";
  signal pixel_alpha : unsigned(7 downto 0) := x"00";

  -- Select which of the four video modes to use at any point in time.
  signal vicii_ntsc : std_logic := '1';
  signal vga60_select_internal : std_logic := '0';

  -- Video mode definition
  -- NOTE: These get overwritten by $D06F PAL/NTSC flags
  -- The values here are simply those that apply on power up.
  -- NOTE: frame_h_front is deprecated due to the pixel_driver now?
  -- In any case, it seems to cause the trimming of frame_h_front pixels
  constant frame_h_front : unsigned(7 downto 0) := to_unsigned(0,8);
  -- 800x480 @ 50Hz for 100MHz pixelclock
  signal single_side_border : unsigned(13 downto 0) := to_unsigned(80,14);
  constant display_width : unsigned(11 downto 0) := to_unsigned(800,12);
  -- We double-buffer the rendering of chargen raster data, so that we can begin
  -- the fetch early.  We just need to allow a few pixels after xcount=0 to let
  -- things get started.
  -- (Sprite fetching should happen as soon as the border begins, so that we have
  -- maximum time to do the fetch.)
  constant display_fetch_start : unsigned(11 downto 0) := to_unsigned(719,12);
  constant display_height_pal : unsigned(11 downto 0) := to_unsigned(623-20,12);
  constant display_height_ntsc : unsigned(11 downto 0) := to_unsigned(526-20,12);
  signal display_height : unsigned(11 downto 0);
  signal raster_buffer_half_toggle : std_logic := '0';
  signal vicii_ycounter_scale_minus_zero : unsigned(3 downto 0) := to_unsigned(2-1,4);
  signal chargen_x_scale : unsigned(7 downto 0) := to_unsigned(120,8);
  signal sprite_first_x : unsigned(13 downto 0) := to_unsigned(31,14);
  signal sprite_y_adjust : unsigned(7 downto 0) := to_unsigned(0,8);
  signal sprite_x_counting : std_logic := '0';
  signal sprite_x_scale_toggle : std_logic := '0';
  -- Each character pixel will be (n+1) pixels high
  signal chargen_y_scale : unsigned(7 downto 0) := x"01";  -- x"04"
  -- smooth scrolling position in natural pixels.
  -- Set in the same way as the border
  signal x_chargen_start : unsigned(13 downto 0) := to_unsigned(safe_to_integer(frame_h_front),14);

  -- PAL/NTSC raster layout
  signal vicii_first_raster : unsigned(8 downto 0) := to_unsigned(0,9);
  constant ntsc_max_raster : unsigned(8 downto 0) := to_unsigned(262,9);
  constant pal_max_raster : unsigned(8 downto 0) := to_unsigned(312,9);
  signal vicii_max_raster : unsigned(8 downto 0) := pal_max_raster;
  -- Setting this value positive causes the chargen and screen to move down the
  -- screen relative to the VIC-II raster counter.
  constant raster_correction : integer := 3;

  -- Calculated dynamically
  signal x_end_of_raster : unsigned(13 downto 0) := to_unsigned(0,14);
  signal vicii_ycounter_scale : unsigned(3 downto 0) := to_unsigned(0,4);

  constant frame_v_front : integer := 1;

  -- Frame generator counters
  -- DEBUG: Start frame at a point that will soon trigger a badline
  signal xcounter : unsigned(13 downto 0) := to_unsigned(0,14);
  signal xcounter_last : unsigned(13 downto 0) := to_unsigned(0,14);
  signal xcounter_delayed : unsigned(13 downto 0) := to_unsigned(0,14);

  -- Pipeline delay for export of xcounter
  signal xcounter_17 : unsigned(13 downto 0) := to_unsigned(0,14);
  signal xcounter_16 : unsigned(13 downto 0) := to_unsigned(0,14);
  signal xcounter_15 : unsigned(13 downto 0) := to_unsigned(0,14);
  signal xcounter_14 : unsigned(13 downto 0) := to_unsigned(0,14);
  signal xcounter_13 : unsigned(13 downto 0) := to_unsigned(0,14);
  signal xcounter_12 : unsigned(13 downto 0) := to_unsigned(0,14);
  signal xcounter_11 : unsigned(13 downto 0) := to_unsigned(0,14);
  signal xcounter_10 : unsigned(13 downto 0) := to_unsigned(0,14);
  signal xcounter_9 : unsigned(13 downto 0) := to_unsigned(0,14);
  signal xcounter_8 : unsigned(13 downto 0) := to_unsigned(0,14);
  signal xcounter_7 : unsigned(13 downto 0) := to_unsigned(0,14);
  signal xcounter_6 : unsigned(13 downto 0) := to_unsigned(0,14);
  signal xcounter_5 : unsigned(13 downto 0) := to_unsigned(0,14);
  signal xcounter_4 : unsigned(13 downto 0) := to_unsigned(0,14);
  signal xcounter_3 : unsigned(13 downto 0) := to_unsigned(0,14);
  signal xcounter_2 : unsigned(13 downto 0) := to_unsigned(0,14);
  signal xcounter_1 : unsigned(13 downto 0) := to_unsigned(0,14);

  signal ycounter_last : unsigned(13 downto 0) := to_unsigned(0,14);
  signal ycounter_export_countdown : integer range 0 to 31 := 0;

  signal xcounter_drive : unsigned(13 downto 0) := (others => '0');
  signal ycounter : unsigned(11 downto 0) := to_unsigned(625,12);
  signal ycounter_drive : unsigned(11 downto 0) := (others => '0');
  signal last_ycounter : unsigned(11 downto 0) := to_unsigned(625,12);
  -- Virtual raster number for VIC-II
  -- (On powerup set to a PAL only raster so that ROM doesn't need to wait a
  -- whole frame.  This is really just to make testing through simulation quicker
  -- since a whole frame takes ~20 minutes to simulate).
  signal vicii_ycounter : unsigned(8 downto 0) := to_unsigned(0,9);
  signal vicii_ycounter_continuous : unsigned(8 downto 0) := to_unsigned(0,9);
  signal vicii_ycounter_driver : unsigned(8 downto 0) := to_unsigned(0,9);
  signal vicii_ycounter_minus_one : unsigned(8 downto 0) := to_unsigned(0,9);
  signal vicii_sprite_ycounter : unsigned(8 downto 0) := to_unsigned(0,9);

  signal vicii_ycounter_v400 : unsigned(9 downto 0) := to_unsigned(0,10);
  signal last_vicii_ycounter : unsigned(8 downto 0) := to_unsigned(0,9);
  signal vicii_ycounter_phase : unsigned(3 downto 0) := (others => '0');
  signal vicii_ycounter_max_phase : unsigned(3 downto 0) := (others => '0');
  signal vicii_ycounter_phase_v400 : unsigned(3 downto 0) := (others => '0');
  signal vicii_ycounter_max_phase_v400 : unsigned(3 downto 0) := (others => '0');
  -- Is the VIC-II virtual raster number the active one for interrupts, or
  -- are we comparing to physical rasters?  This is decided by which register
  -- gets written to last.
  signal vicii_is_raster_source : std_logic := '1';

  signal vicii_xcounter_320 : unsigned(8 downto 0) := (others => '0');
  signal vicii_xcounter_640 : unsigned(9 downto 0) := (others => '0');
  signal last_vicii_xcounter_640 : unsigned(9 downto 0) := (others => '0');

  -- Actual pixel positions in the frame
  signal displayy : unsigned(11 downto 0) := to_unsigned(0,12);

  -- Mark if we are in the top line of display
  -- (used for overlaying drive LED on first row of pixels)
  signal displayline0 : std_logic := '1';
  signal displaycolumn0 : std_logic := '1';

  -- Asserted if in the displayed part of vertical frame
  -- DEBUG: Power up with in frame to make simulation in ghdl much quicker.
  signal vert_in_frame : std_logic := '1';

  -- Used for counting down cycles while waiting for RAM to respond
  signal delay : std_logic_vector(1 downto 0) := "00";

  -- Interface to buffer for screen ram (converts 64 bits wide to 8 bits
  -- wide for us)
  signal screen_ram_buffer_write  : std_logic := '0';
  -- (K325T: 11 bits, the 2 KB row buffer of RRB list rows; other rows use bit 10 = 0 as before)
  signal screen_ram_buffer_read_address : unsigned(10 downto 0) := to_unsigned(0,11);
  signal screen_ram_buffer_write_address : unsigned(10 downto 0) := to_unsigned(0,11);
  signal screen_ram_buffer_din : unsigned(7 downto 0) := x"00";
  signal screen_ram_buffer_dout : unsigned(7 downto 0) := x"00";

  -- Internal registers used to keep track of the screen ram for the current row
  signal screen_row_address : unsigned(19 downto 0) := to_unsigned(0,20);
  signal screen_row_current_address : unsigned(19 downto 0) := to_unsigned(0,20);

  signal full_colour_fetch_count : integer range 0 to 8 := 0;
  signal full_colour_data : unsigned(63 downto 0) := (others => '0');
  signal paint_full_colour_data : unsigned(63 downto 0) := (others => '0');
  signal paint_alternate_palette : std_logic := '0';

  -- chipram access management registers
  signal next_ramaddress : unsigned(19 downto 0) := to_unsigned(0,20);
  signal next_ramaccess_is_screen_row_fetch : std_logic := '0';
  signal this_ramaccess_is_screen_row_fetch : std_logic := '0';
  signal last_ramaccess_is_screen_row_fetch : std_logic := '0';
  signal final_ramaccess_is_screen_row_fetch : std_logic := '0';
  signal next_ramaccess_is_glyph_data_fetch : std_logic := '0';
  signal this_ramaccess_is_glyph_data_fetch : std_logic := '0';
  signal last_ramaccess_is_glyph_data_fetch : std_logic := '0';
  signal final_ramaccess_is_glyph_data_fetch : std_logic := '0';
  signal next_ramaccess_is_sprite_data_fetch : std_logic := '0';
  signal this_ramaccess_is_sprite_data_fetch : std_logic := '0';
  signal last_ramaccess_is_sprite_data_fetch : std_logic := '0';
  signal final_ramaccess_is_sprite_data_fetch : std_logic := '0';
  signal this_ramaccess_screen_row_buffer_address : unsigned(9 downto 0) := to_unsigned(0,10);
  signal next_ramaccess_screen_row_buffer_address : unsigned(9 downto 0) := to_unsigned(0,10);
  signal last_ramaccess_screen_row_buffer_address : unsigned(9 downto 0) := to_unsigned(0,10);
  signal final_ramaccess_screen_row_buffer_address : unsigned(9 downto 0) := to_unsigned(0,10);
  signal next_screen_row_fetch_address : unsigned(19 downto 0) := to_unsigned(0,20);
  signal this_screen_row_fetch_address : unsigned(19 downto 0) := to_unsigned(0,20);
  signal last_screen_row_fetch_address : unsigned(19 downto 0) := to_unsigned(0,20);
  signal final_screen_row_fetch_address : unsigned(19 downto 0) := to_unsigned(0,20);
  signal final_ramdata : unsigned(7 downto 0) := to_unsigned(0,8);

  signal vgared_driver : unsigned(7 downto 0) := x"00";
  signal vgablue_driver : unsigned(7 downto 0) := x"00";
  signal vgagreen_driver  : unsigned(7 downto 0) := x"00";

  signal ycounter_driver : unsigned(11 downto 0) := to_unsigned(625,12);

  -- Internal registers for drawing a single raster of character data to the
  -- raster buffer.
  signal character_number : unsigned(10 downto 0) := to_unsigned(0,11);
  type vic_chargen_fsm is (Idle,
                           FetchScreenRamLine,
                           FetchScreenRamLine2,
                           FetchScreenRamNext,
                           ListWait,           -- K325T RRB list mode: drain the row fetch
                           ListRun,            -- K325T RRB list mode: expander running
                           FetchFirstCharacter,
                           FetchNextCharacter,
                           FetchCharHighByte,
                           FetchTextCell,
                           FetchTextCellColourAndSource,
                           FetchBitmapCell,
                           FetchBitmapData,
                           PaintFullColourFetch,
                           PaintFullColourHyperRAMFetch,
                           PaintMemWait,
                           PaintMemWait2,
                           PaintMemWait3,
                           PaintDispatch,
                           TurboWait,          -- K325T fast token path: wait for the decoder
                           FrontWait,          -- K325T step 5: wait for the expander's write position
                           TurboFetch32,       -- K325T fast token path: full-colour row assembled
                           EndOfChargen,
                           SpritePointerFetch,
                           SpritePointerFetch2,
                           SpritePointerCompute1,
                           SpritePointerCompute,
                           SpritePointerComputeMSB,
                           SpriteDataFetch,
                           SpriteDataFetch2);
  signal raster_fetch_state : vic_chargen_fsm := Idle;
  signal raster_fetch_state_init : vic_chargen_fsm := Idle;
  signal raster_fetch_restart : std_logic := '0';
  type vic_paint_fsm is (Idle,
                         PaintFullColour,Paint4bitColourPixels,PaintFullColourPixels,PaintFullColourDone,
                         PaintMono,PaintMonoDrive,PaintMonoBits,
                         PaintMultiColour,PaintMultiColourDrive,
                         PaintMultiColourBits,PaintMultiColourHold);
  signal paint_fsm_state : vic_paint_fsm := Idle;
  signal paint_ready : std_logic := '0';
  signal paint_from_charrom : std_logic := '0';
  signal paint_flip_horizontal : std_logic := '0';
  signal paint_foreground : unsigned(7 downto 0) := to_unsigned(0,8);
  signal paint_background : unsigned(7 downto 0) := to_unsigned(0,8);
  signal paint_background_with_any_reverse : unsigned(7 downto 0) := to_unsigned(0,8);
  signal paint_mc1 : unsigned(7 downto 0) := to_unsigned(0,8);
  signal paint_mc2 : unsigned(7 downto 0) := to_unsigned(0,8);
  signal paint_buffer_hflip_chardata : unsigned(7 downto 0) := to_unsigned(0,8);
  signal paint_buffer_noflip_chardata : unsigned(7 downto 0) := to_unsigned(0,8);
  signal paint_buffer_hflip_ramdata : unsigned(7 downto 0) := to_unsigned(0,8);
  signal paint_buffer_noflip_ramdata : unsigned(7 downto 0) := to_unsigned(0,8);
  signal paint_buffer : unsigned(7 downto 0) := to_unsigned(0,8);
  signal paint_bits_remaining : integer range 0 to 16 := 0;
  signal paint_chardata : unsigned(7 downto 0) := to_unsigned(0,8);
  signal paint_ramdata : unsigned(7 downto 0) := to_unsigned(0,8);

  signal horizontal_filter : std_logic := '1';
  signal pal_simulate : std_logic := '0';
  signal shadow_mask_enable : std_logic := '0';
  signal upscale_enable_int : std_logic := '0';
  signal bold_is_alt : std_logic := '0';
  signal rrb_wraparound_allowed : std_logic := '1';
  signal rrb_overtime_allowed : std_logic := '1';

  signal debug_x : unsigned(13 downto 0) := "11111111111110";
  signal debug_y : unsigned(11 downto 0) := "111111111110";
  signal debug_pixel_red : unsigned(7 downto 0) := to_unsigned(0,8);
  signal debug_pixel_green : unsigned(7 downto 0) := to_unsigned(0,8);
  signal debug_pixel_blue : unsigned(7 downto 0) := to_unsigned(0,8);
  signal debug_channel_select : std_logic_vector(1 downto 0) := "00";
  signal debug_screen_ram_buffer_address : unsigned(9 downto 0) := to_unsigned(0,10);
  signal debug_raster_buffer_read_address : unsigned(7 downto 0) := to_unsigned(0,8);
  signal debug_raster_buffer_write_address : unsigned(7 downto 0) := to_unsigned(0,8);
  signal debug_cycles_to_next_card : unsigned(7 downto 0) := to_unsigned(0,8);
  signal debug_raster_fetch_state : vic_chargen_fsm := Idle;
  signal debug_paint_fsm_state : vic_paint_fsm := Idle;
  signal debug_chargen_active : std_logic := '0';
  signal debug_chargen_active_soon : std_logic := '0';
  signal debug_character_data_from_rom : std_logic := '0';
  signal debug_charaddress : unsigned(11 downto 0) := to_unsigned(0,12);
  signal debug_charrow : std_logic_vector(7 downto 0) := x"00";

  signal debug_screen_ram_buffer_address_drive : unsigned(9 downto 0) := to_unsigned(0,10);
  signal debug_cycles_to_next_card_drive : unsigned(7 downto 0) := to_unsigned(0,8);
  signal debug_raster_fetch_state_drive : vic_chargen_fsm := Idle;
  signal debug_paint_fsm_state_drive : vic_paint_fsm := Idle;
  signal debug_chargen_active_drive : std_logic := '0';
  signal debug_chargen_active_soon_drive : std_logic := '0';
  signal debug_character_data_from_rom_drive : std_logic := '0';
  signal debug_charaddress_drive : unsigned(11 downto 0) := to_unsigned(0,12);
  signal debug_charrow_drive : std_logic_vector(7 downto 0)  := x"00";
  signal debug_raster_buffer_read_address_drive : unsigned(7 downto 0) := to_unsigned(0,8);
  signal debug_raster_buffer_write_address_drive : unsigned(7 downto 0) := to_unsigned(0,8);

  signal debug_screen_ram_buffer_address_drive2 : unsigned(9 downto 0) := to_unsigned(0,10);
  signal debug_raster_buffer_read_address_drive2 : unsigned(7 downto 0) := to_unsigned(0,8);
  signal debug_raster_buffer_write_address_drive2 : unsigned(7 downto 0) := to_unsigned(0,8);
  signal debug_raster_fetch_state_drive2 : vic_chargen_fsm := Idle;
  signal debug_paint_fsm_state_drive2 : vic_paint_fsm := Idle;
  signal debug_chargen_active_drive2 : std_logic := '0';
  signal debug_chargen_active_soon_drive2 : std_logic := '0';
  signal debug_character_data_from_rom_drive2 : std_logic := '0';
  signal debug_charaddress_drive2 : unsigned(11 downto 0) := to_unsigned(0,12);
  signal debug_charrow_drive2 : std_logic_vector(7 downto 0) := x"00";

  -----------------------------------------------------------------------------
  -- Video controller registers
  -----------------------------------------------------------------------------

  -- New control registers

  -- These next two can be used to make a screen which is a huge playfield with
  -- just a portion visible at any point in time.
  -- Number added to card number for each row of characters, i.e., how many bytes
  -- should we skip as we advance each row.
  signal virtual_row_width : unsigned(15 downto 0) := to_unsigned(40,16);
  -- And display_row_width is how many characters to display on each row
  signal display_row_width : unsigned(9 downto 0) := to_unsigned(40,10);
  signal display_row_width_minus1 : unsigned(9 downto 0) := to_unsigned(40,10);
  signal display_row_count : unsigned(7 downto 0) := to_unsigned(25-1,8);
  signal display_row_number : unsigned(7 downto 0) := to_unsigned(25,8);

  signal end_of_row_16 : std_logic := '0';
  signal end_of_row : std_logic := '0';
  signal chargen_x_scale_drive : unsigned(7 downto 0) := to_unsigned(0,8);
  signal x_chargen_start_minus1 : unsigned(13 downto 0) := to_unsigned(0,14);

  -- DEBUG: Start character generator in first raster on power up to make ghdl
  -- simulation much quicker
  signal y_chargen_start : unsigned(11 downto 0) := to_unsigned(1,12);  -- 0
  signal y_chargen_start_minus_one : unsigned(11 downto 0) := to_unsigned(0,12);  --
                                                                                  --auto-calculated signal
  -- Charset is 16bit (2 bytes per char) when this mode is enabled.
  signal sixteenbit_charset : std_logic := '1';
  -- Characters >255 are full-colour blocks when enabled.
  signal fullcolour_extendedchars : std_logic := '1';
  -- Characters <256 are full-colour blocks when enabled
  signal fullcolour_8bitchars : std_logic := '1';
  -- Optionally fetch full-colour chars from HyperRAM
  signal glyphs_from_hyperram : std_logic := '0';

  -- VIC-II style Mode control bits (correspond to bits in $D016 etc)
  -- -- Text/graphics mode select
  signal text_mode : std_logic := '1';
  -- -- Basic multicolour mode bit
  signal multicolour_mode : std_logic := '0';
  -- -- Enable 256 colours in multicolour text mode
  signal fullcolour_mcm : std_logic := '0';
  -- -- Extended background colour mode (reduces charset to 64 entries)
  signal extended_background_mode : std_logic := '0';

  -- Border dimensions
  -- DEBUG: No top or left borders on power up to make ghdl simulation of frame
  -- drawing much quicker.
  signal border_x_left : unsigned(13 downto 0) := to_unsigned(0,14);
  signal border_x_right : unsigned(13 downto 0) := to_unsigned(2000,14);
  signal border_y_top : unsigned(11 downto 0) := to_unsigned(1,12);
  signal border_y_bottom : unsigned(11 downto 0) := to_unsigned(600,12);
  signal blank : std_logic := '0';
  -- intermediate calculations for whether we are in the border to improve timing.
  signal vertical_border : std_logic := '1';

  -- Colour registers ($D020 - $D024)
  signal screen_colour : unsigned(7 downto 0) := x"08";  -- orange
  signal border_colour : unsigned(7 downto 0) := x"04";  -- green
  signal multi1_colour : unsigned(7 downto 0) := x"01";  -- multi-colour mode #1
  signal multi2_colour : unsigned(7 downto 0) := x"02";  -- multi-colour mode #2
  signal multi3_colour : unsigned(7 downto 0) := x"03";  -- multi-colour mode #3
  -- XXX move reading of sprite registers to vicii_sprites module
  signal sprite_multi0_colour : unsigned(7 downto 0) := x"04";
  signal sprite_multi1_colour : unsigned(7 downto 0) := x"05";
  signal sprite_x : sprite_vector_eight := (others => x"02");
  signal sprite_y : sprite_vector_eight := (others => x"02");
  signal sprite_colours : sprite_vector_eight := (others => x"00");

  -- VIC-III bitplane registers
  signal bitplane_mode : std_logic := '0';
  signal bitplane_enables : std_logic_vector(7 downto 0) := "00000000";
  signal bitplane_complements : std_logic_vector(7 downto 0) := "00000000";
  signal bitplane_sixteen_colour_mode_flags : std_logic_vector(7 downto 0) := "00000000";
  signal bitplanes_x_start : unsigned(7 downto 0) := to_unsigned(0,8);
  signal bitplanes_y_start : unsigned(7 downto 0) := to_unsigned(0,8);
  signal bitplanes_x_start_drive : unsigned(7 downto 0) := to_unsigned(0,8);
  signal bitplanes_y_start_drive : unsigned(7 downto 0) := to_unsigned(0,8);
  signal dat_x : unsigned(6 downto 0) := to_unsigned(0,7);
  signal dat_y : unsigned(8 downto 0) := to_unsigned(0,9);
  signal dat_bitplane_offset : unsigned(15 downto 0) := x"0000";
  signal bitplane_addresses : sprite_vector_eight;
  signal max_sprite_fetch_byte_number : integer range 0 to 399 := 0;

  -- Extended sprite features
  signal sprite_extended_height_enables : std_logic_vector(7 downto 0) := "00000000";
  signal sprite_extended_height_size : unsigned(7 downto 0) := to_unsigned(21,8);
  signal sprite_extended_width_enables : std_logic_vector(7 downto 0) := "00000000";
  signal sprite_horizontal_tile_enables : std_logic_vector(7 downto 0) := "00000000";
  signal sprite_bitplane_enables : std_logic_vector(7 downto 0) := "00000000";
  signal sprite_alpha_blend_enables : std_logic_vector(7 downto 0) := "00000000";
  signal sprite_alpha_blend_value : unsigned(7 downto 0) := x"80";
  signal sprite_sixteen_colour_enables : std_logic_vector(7 downto 0) := "00000000";

  -- VIC-II sprites are in a separate module as a chain.  To avoid the need to
  -- route to all sprites from the main VIC-IV section, they are arranged as a
  -- chain.  However, the VIC-IV must perform the memory accesses for the
  -- VIC-II sprites.  Thus we have a bus that passes through each of these
  -- sprites delivering the data they need.  We also have a separate bus that
  -- delivers the current row number for each sprite so that the VIC-IV knows
  -- which bytes of memory to deliver to the sprites.  This arrangement allows
  -- for normal VIC-II semantics for the sprites, including priority order etc.
  -- The only difference we intend to implement here is to have a register that
  -- allows the number of rows in each sprite to be varied from the usual 21,
  -- since there is no reason to maintain this fairly artificial limit.  Even
  -- in the VIC-II the only logic cost would have been the extra register (or
  -- register per sprite).
  --
  -- C65 VIC-III bitplanes will be implemented using the same sprite data pipeline
  -- so that no further stress is placed on the VIC-IV memory access logic,
  -- which is already rather strained at the 192MHz pixel clock.
  signal sprite_data_offset_rx : integer range 0 to 65535;
  signal sprite_number_counter : integer range 0 to 15 := 0;
  signal sprite_number_for_data_tx : integer range 0 to 15 := 0;
  signal sprite_number_for_data_rx : integer range 0 to 15;
  type sprite_data_offset_8 is array(0 to 15) of integer range 0 to 65535;
  signal sprite_data_offsets : sprite_data_offset_8;
  -- Similarly we need to deliver the bytes of data to the VIC-II sprite chain
  signal sprite_datavalid : std_logic;
  signal sprite_bytenumber : spritebytenumber := 0;
  signal sprite_spritenumber : spritenumber := 0;
  signal sprite_data_byte : unsigned(7 downto 0) := to_unsigned(0,7+1);
  -- The sprite chain also has the opportunity to modify the pixel colour being
  -- drawn so that the sprites can be overlayed on the display.
  signal pixel_is_foreground : std_logic;
  signal pixel_is_background : std_logic;
  signal pixel_is_foreground_in : std_logic;
  signal pixel_is_background_in : std_logic;
  signal composite_bg_red : unsigned(7 downto 0) := to_unsigned(0,7+1);
  signal composite_bg_green : unsigned(7 downto 0) := to_unsigned(0,7+1);
  signal composite_bg_blue : unsigned(7 downto 0) := to_unsigned(0,7+1);
  signal composite_red : unsigned(7 downto 0) := to_unsigned(0,7+1);
  signal composite_green : unsigned(7 downto 0) := to_unsigned(0,7+1);
  signal composite_blue : unsigned(7 downto 0) := to_unsigned(0,7+1);
  signal composited_red : std_logic_vector(9 downto 0) := std_logic_vector(to_unsigned(0,9+1));
  signal composited_green : std_logic_vector(9 downto 0) := std_logic_vector(to_unsigned(0,9+1));
  signal composited_blue : std_logic_vector(9 downto 0) := std_logic_vector(to_unsigned(0,9+1));
  signal compositer_enable : std_logic := '1';
  signal is_background_in : std_logic;
  signal pixel_is_background_out : std_logic;
  signal pixel_is_foreground_out : std_logic;
  signal chargen_pixel_colour : unsigned(7 downto 0) := to_unsigned(0,7+1);
  signal chargen_alpha_value : unsigned(7 downto 0) := to_unsigned(0,7+1);
  signal postsprite_pixel_colour : unsigned(7 downto 0) := to_unsigned(0,7+1);
  signal postsprite_alpha_value : unsigned(7 downto 0) := to_unsigned(0,7+1);
  signal postsprite_sprite_number : integer range 0 to 7;
  signal postsprite_alternate_palette : std_logic := '0';
  signal postsprite_alternate_palette_delayed : std_logic := '0';
  signal alpha_blend_alpha : unsigned(7 downto 0) := to_unsigned(0,7+1);
  signal pixel_is_sprite : std_logic;

  signal sprite_fetch_drive : std_logic := '0';
  signal sprite_fetch_sprite_number : integer range 0 to 31 := 0;
  signal sprite_fetch_byte_number : integer range 0 to 319 := 0;
  signal sprite_fetch_sprite_number_drive : integer range 0 to 31 := 0;
  signal sprite_fetch_byte_number_drive : integer range 0 to 319 := 0;
  signal sprite_pointer_address : unsigned(19 downto 0) := to_unsigned(0,20);
  signal sprite_data_address : unsigned(19 downto 0) := to_unsigned(0,20);
  signal sprite_data_addresses : spritebaseaddresses := (others => to_unsigned(0,20));
  signal sprite_h640_msbs : std_logic_vector(7 downto 0) := x"00";

  -- Compatibility registers
  signal twentyfourlines : std_logic := '0';
  signal thirtyeightcolumns : std_logic := '0';
  signal vicii_raster_compare : unsigned(10 downto 0) := to_unsigned(256,11);
  signal viciv_rasterx_compare : unsigned(13 downto 0) := to_unsigned(8191,14);
  signal vicii_raster_compare_plus_one : unsigned(10 downto 0) := to_unsigned(256,11);
  signal vicii_x_smoothscroll : unsigned(2 downto 0) := to_unsigned(0,2+1);
  signal vicii_y_smoothscroll : unsigned(2 downto 0) := to_unsigned(0,2+1);
  -- NOTE: these are here for reading. the actual used VIC-II sprite
  -- registers are defined in vicii_sprites.vhdl
  signal vicii_sprite_enables : std_logic_vector(7 downto 0) := x"FF";
  signal vicii_sprite_xmsbs : std_logic_vector(7 downto 0) := std_logic_vector(to_unsigned(0,7+1));
  signal vicii_sprite_x_expand : std_logic_vector(7 downto 0) := std_logic_vector(to_unsigned(0,7+1));
  signal vicii_sprite_y_expand : std_logic_vector(7 downto 0) := std_logic_vector(to_unsigned(0,7+1));
  signal vicii_sprite_priority_bits : std_logic_vector(7 downto 0) := std_logic_vector(to_unsigned(0,7+1));
  signal vicii_sprite_multicolour_bits : std_logic_vector(7 downto 0) := std_logic_vector(to_unsigned(0,7+1));

  -- Here are the signals received from the sprites, which get ored onto
  -- the following signals.
  signal vicii_sprite_sprite_collision_map : std_logic_vector(7 downto 0) := std_logic_vector(to_unsigned(0,7+1));
  signal vicii_sprite_bitmap_collision_map : std_logic_vector(7 downto 0) := std_logic_vector(to_unsigned(0,7+1));

  -- HEre is what gets read from the VIC-II register (and then zeroed in the process)
  -- and which also get checked for interrupt generation
  signal vicii_sprite_sprite_collisions : std_logic_vector(7 downto 0) := std_logic_vector(to_unsigned(0,7+1));
  signal vicii_sprite_bitmap_collisions : std_logic_vector(7 downto 0) := std_logic_vector(to_unsigned(0,7+1));

  signal viciii_extended_attributes : std_logic := '1';
  signal irq_lightpen : std_logic := '0';
  signal irq_collisionspritesprite : std_logic := '0';
  signal irq_collisionspritebitmap : std_logic := '0';
  signal irq_raster : std_logic := '0';
  signal irq_rasterx : std_logic := '0';
  signal irq_extras_enable : std_logic := '0';
  signal ack_lightpen : std_logic := '0';
  signal ack_collisionspritesprite : std_logic := '0';
  signal ack_collisionspritebitmap : std_logic := '0';
  signal ack_raster : std_logic := '0';
  signal ack_rasterx : std_logic := '0';
  signal mask_lightpen : std_logic := '0';
  signal mask_collisionspritesprite : std_logic := '0';
  signal mask_collisionspritebitmap : std_logic := '0';
  signal mask_raster : std_logic := '0';
  signal mask_rasterx : std_logic := '0';
  signal clear_collisionspritebitmap : std_logic := '0';
  signal clear_collisionspritebitmap_1 : std_logic := '0';
  signal clear_collisionspritesprite : std_logic := '0';
  signal clear_collisionspritesprite_1 : std_logic := '0';

  signal lightpen_x_latch : unsigned(7 downto 0) := to_unsigned(0,7+1);
  signal lightpen_y_latch : unsigned(7 downto 0) := to_unsigned(0,7+1);

  -- Used for hardware character blinking ala C65
  signal viciii_blink_phase : std_logic := '0';
  -- 60 frames = 1 second, and means no tearing.
  signal viciii_blink_phase_counter : integer range 0 to 30 := 0;

  -- And faster version for blinking drive led
  signal drive_blink_phase : std_logic := '0';
  signal drive_blink_phase_counter : integer range 0 to 15 := 0;


  -- NOTE: The following registers require 64-bit alignment. Default addresses
  -- are fairly arbitrary.
  -- Colour RAM offset (we just use some normal RAM for colour RAM, since in the
  -- worst case we can need >32KB of it.  Must correspond to a ChipRAM address,
  -- so the MSBs are irrelevant.
  signal colour_ram_base : unsigned(15 downto 0) := x"0000";
  -- Screen RAM offset ( @ $1000 on boot for debug purposes)
  signal screen_ram_base : unsigned(27 downto 0) := x"0000400";
  -- Pointer to the VIC-II compatibility sprite source vector, usually
  -- screen+$3F8 in 40 column mode, or +$7F8 in VIC-III 80 column mode
  signal vicii_sprite_pointer_address : unsigned(27 downto 0) := x"00013F8";

  -- Character set address.
  -- Size of character set depends on resolution of characters, and whether
  -- full-colour characters are enabled.
  signal character_set_address : unsigned(27 downto 0) := x"0000000";
  signal character_data_from_rom : std_logic := '1';
  -----------------------------------------------------------------------------

  -- Character generator state. Also used for graphics modes, since graphics
  -- modes on the C64 are all card-based, anyway.
  signal card_number : unsigned(15 downto 0) := x"0000";
  signal card_number_drive : unsigned(15 downto 0) := x"0000";
  signal card_number_is_extended : std_logic;  -- set if card_number > $00FF
  signal first_card_of_row : unsigned(15 downto 0) := to_unsigned(0,15+1);
  -- DEBUG: Set previous first card of row to all high so that a badline gets
  -- triggered on the first raster being drawn.
  -- Also used so that last pixel row in bitmap char cards doesn't show data
  -- from the next char card down the screen.
  signal prev_first_card_of_row : unsigned(15 downto 0) := (others => '1');
  -- coordinates after applying the above scaling factors
  signal chargen_x : unsigned(2 downto 0) := (others => '0');
  signal chargen_y : unsigned(2 downto 0) := (others => '0');
  signal chargen_y_next : unsigned(2 downto 0) := (others => '0');
  signal chargen_y_hold : unsigned(2 downto 0) := (others => '0');
  -- fractional pixel position for scaling
  signal chargen_y_sub : unsigned(4 downto 0) := to_unsigned(0,4+1);
  -- Allow double vertical resolution of chars in V200 mode
  -- by multiplexing between normal and shifted charset
  signal charrow_repeated : std_logic := '0';
  signal reg_char_y16 : std_logic := '0';

  -- Common bitmap and character drawing info
  signal glyph_data_address : unsigned(19 downto 0) := to_unsigned(0,20);

  -- For holding pre-calculated expressions to flatten logic
  signal bitmap_glyph_data_address : unsigned(19 downto 0) := to_unsigned(0,20);


  -- Bitmap drawing info
  signal bitmap_colour_foreground : unsigned(7 downto 0) := x"00";
  signal bitmap_colour_background : unsigned(7 downto 0) := x"00";

  -- Character drawing info
  signal background_colour_select : unsigned(1 downto 0) := "00";
  signal glyph_number : unsigned(12 downto 0) := to_unsigned(0,13);
  signal glyph_y_offset : integer range 0 to 7 := 0;
  signal glyph_nve_y_offset : std_logic := '0';
  signal glyph_colour_drive : unsigned(7 downto 0) := x"00";
  signal glyph_colour_drive2 : unsigned(7 downto 0) := x"00";
  signal glyph_colour : unsigned(7 downto 0) := x"00";
  signal glyph_attributes : unsigned(3 downto 0) := "0000";
  signal glyph_visible_drive : std_logic := '0';
  signal glyph_visible : std_logic := '0';
  signal glyph_bold : std_logic := '0';
  signal glyph_bold_drive : std_logic := '0';
  signal glyph_underline_drive : std_logic := '0';
  signal glyph_underline : std_logic := '0';
  signal glyph_xor : std_logic := '0';
  signal glyph_reverse : std_logic := '0';
  signal glyph_reverse_drive : std_logic := '0';
  signal glyph_full_colour : std_logic := '0';
  signal glyph_4bit : std_logic := '0';
  signal glyph_flip_horizontal : std_logic := '0';
  signal glyph_flip_vertical : std_logic := '0';
  signal glyph_goto : std_logic := '0';
  signal glyph_width_deduct : unsigned(3 downto 0) := to_unsigned(0,3+1);
  signal glyph_width : integer range 0 to 16;
  signal paint_glyph_width : integer range 0 to 16;
  signal paint_glyph_4bit : std_logic := '0';
  signal glyph_blink : std_logic := '0';
  signal glyph_blink_drive : std_logic := '0';
  signal paint_blink : std_logic := '0';
  signal glyph_with_alpha : std_logic := '0';
  signal paint_with_alpha : std_logic := '0';
  signal glyph_trim_top : integer range 0 to 7;
  signal glyph_trim_bottom : integer range 0 to 7;
  signal glyph_paint_background : std_logic := '1';
  signal glyph_alternate_palette_invert : std_logic := '0';
  signal glyph_bold_and_reverse : std_logic := '0';
  signal force_chars_foreground : std_logic := '1';
  signal force_chars_background : std_logic := '0';
  signal last_hyper_request_toggle : std_logic := '0';
  signal transparent_pixel_will_come_from_primary_palette : std_logic := '0';
  
  signal short_line : std_logic := '0';
  signal short_line_length : integer range 0 to 512;
  signal screen_ram_is_ff : std_logic := '0';
  signal screen_ram_high_is_ff : std_logic := '0';
  signal row_advance : integer range 0 to 512;

  signal card_of_row : unsigned(7 downto 0) := to_unsigned(0,7+1);
  signal chargen_active : std_logic := '0';
  signal chargen_active_drive : std_logic := '0';
  signal chargen_active_soon : std_logic := '0';
  signal chargen_active_soon_drive : std_logic := '0';

  -- Delayed versions of signals to allow character fetching pipeline
  signal chargen_x_t1 : unsigned(2 downto 0) := (others => '0');
  signal chargen_x_t2 : unsigned(2 downto 0) := (others => '0');
  signal chargen_x_t3 : unsigned(2 downto 0) := (others => '0');
  signal card_number_t1 : unsigned(7 downto 0) := (others => '0');
  signal card_number_t2 : unsigned(7 downto 0) := (others => '0');
  signal card_number_t3 : unsigned(7 downto 0) := (others => '0');
  signal cards_differ : std_logic := '0';
  signal indisplay_t1 : std_logic := '0';
  signal indisplay_t2 : std_logic := '0';
  signal indisplay_t3 : std_logic := '0';
  signal cycles_to_next_card : unsigned(7 downto 0) := to_unsigned(0,7+1);
  signal cycles_to_next_card_drive : unsigned(7 downto 0) := to_unsigned(0,7+1);

  -- Interface to character generator rom
  signal charaddress : integer range 0 to 4095;
  signal chardata : std_logic_vector(7 downto 0) := std_logic_vector(to_unsigned(0,7+1));
  signal chardata_drive : unsigned(7 downto 0) := to_unsigned(0,7+1);
  -- buffer of read data to improve timing
  signal charrow : std_logic_vector(7 downto 0) := std_logic_vector(to_unsigned(0,7+1));
  signal charrow_t1 : std_logic_vector(7 downto 0) := std_logic_vector(to_unsigned(0,7+1));
  signal charrow_t2 : std_logic_vector(7 downto 0) := std_logic_vector(to_unsigned(0,7+1));

  -- C65 style 2K colour RAM
  signal colourram_at_dc00_internal : std_logic := '0';
  -- C65 ROM mapping
  signal reg_rom_e000 : std_logic := '0';
  signal reg_rom_c000 : std_logic := '0';
  signal reg_rom_a000 : std_logic := '0';
  signal reg_rom_8000 : std_logic := '0';
  signal reg_c65_charset : std_logic := '0';
  signal reg_palrom : std_logic := '0';

  signal reg_h640 : std_logic := '0';
  signal reg_h1280 : std_logic := '0';
  signal reg_v400 : std_logic := '0';
  signal reg_mono : std_logic := '0';
  signal reg_interlace : std_logic := '0';
  signal sprite_h640 : std_logic := '1';
  signal sprite_v400s : std_logic_vector(7 downto 0) := x"00";
  signal sprite_v400_msbs : std_logic_vector(7 downto 0) := x"00";
  signal sprite_v400_super_msbs : std_logic_vector(7 downto 0) := x"00";

  type rgb is
  record
    red   : unsigned(7 downto 0);
    green : unsigned(7 downto 0);
    blue  : unsigned(7 downto 0);
  end record;

  -- Border generation signals
  -- (see video registers section for the registers that define the border size)
  signal inborder : std_logic := '0';
  signal pixel_alt_palette : std_logic := '0';
  signal postsprite_inborder : std_logic := '0';
  signal inborder_drive : std_logic := '0';
  signal inborder_drive2 : std_logic := '0';
  signal xfrontporch : std_logic := '0';
  signal xfrontporch_drive : std_logic := '0';
  signal xbackporch : std_logic := '0';
  signal xbackporch_edge : std_logic := '0';

  signal last_ramaddress : unsigned(19 downto 0) := to_unsigned(0,19+1);
  signal ramaddress : unsigned(19 downto 0) := to_unsigned(0,19+1);
  signal ramdata : unsigned(7 downto 0) := to_unsigned(0,7+1);
  signal ramdata_drive : unsigned(7 downto 0) := to_unsigned(0,7+1);

  -- Precalculated mono/multicolour pixel bits
  signal multicolour_bits : std_logic_vector(1 downto 0) := (others => '0');
  signal monobit : std_logic := '0';

  -- Raster buffer
  -- Read address is in 128th of pixels
  signal raster_buffer_read_address : unsigned(10 downto 0) := to_unsigned(0,10+1);
  signal raster_buffer_read_address_sub : unsigned(9 downto 0) := to_unsigned(0,9+1);
  signal raster_buffer_read_address_next : unsigned(10 downto 0) := to_unsigned(0,10+1);
  signal raster_buffer_read_address_sub_next : unsigned(9 downto 0) := to_unsigned(0,9+1);
  signal raster_buffer_read_data : unsigned(17 downto 0) := to_unsigned(0,17+1);
  signal raster_buffer_write_address : unsigned(10 downto 0) := to_unsigned(0,10+1);
  signal raster_buffer_write_data : unsigned(17 downto 0) := to_unsigned(0,17+1);
  signal raster_buffer_write : std_logic := '0';
  -- K325T fast RRB (XCTL bit 4): the raster buffer is split into even/odd pixel banks so that
  -- the paint FSM can write two adjacent pixels per cycle.  rb_double = this cycle writes two:
  -- pixel 1 (raster_buffer_write_data / _write) at raster_buffer_write_address - 1, pixel 2
  -- (raster_buffer_write_data2 / _write2) at raster_buffer_write_address, which keeps its
  -- meaning "address of the last pixel written" for everything else.
  signal rb_fast_s : std_logic_vector(1 downto 0) := "00";
  signal rb_double : std_logic := '0';
  signal raster_buffer_write2 : std_logic := '0';
  signal raster_buffer_write_data2 : unsigned(17 downto 0) := (others => '0');
  signal rb_addr0, rb_addr1 : unsigned(10 downto 0) := (others => '0');
  signal rb_din0, rb_din1 : unsigned(17 downto 0) := (others => '0');
  signal rb_we0, rb_we1 : std_logic := '0';
  signal rb_dout0, rb_dout1 : unsigned(17 downto 0) := (others => '0');
  signal rb_rsel : std_logic := '0';
  -- K325T XCTL bit 3 (cu_*): a pixel not painted in this painting of its buffer half shows as
  -- background (screen colour, alpha $FF, not foreground), and the line runs to the full text
  -- width.  One valid bit per pixel of each half and bank, in flip-flops: the write half's bits
  -- are cleared a few cycles after the line start (after the display has passed the end of the
  -- text area, before the painting's first write), every raster buffer write sets its bit
  -- (one cycle later), the display reads the bit with the pixel.  Off: nothing changes.
  signal cu_s : std_logic_vector(1 downto 0) := "00";
  signal cu_v0, cu_v1 : std_logic_vector(1023 downto 0) := (others => '0');   -- even / odd bank
  signal cu_we0, cu_we1 : std_logic := '0';
  signal cu_a0, cu_a1 : unsigned(9 downto 0) := (others => '0');
  signal cu_clr : std_logic := '0';
  signal cu_clr_half : std_logic := '0';
  signal cu_clr_cnt : integer range 0 to 7 := 0;
  signal cu_vq : std_logic := '1';
  signal rb_raddr : unsigned(10 downto 0) := (others => '0');

  -- one painted pixel as the raster buffer word (bit 17 alt palette, 16..9 alpha,
  -- 8 foreground, 7..0 colour) -- exactly what the 1-pixel paint states write
  -- K325T step 5: the token at row buffer index a (bytes a, a+1) can be read: no expansion runs,
  -- it is one of the row's own tokens, or the expander has written beyond it
  function rd_ok(a : unsigned(10 downto 0); exping : std_logic; lp : unsigned(10 downto 0);
                 busy : std_logic; wp : unsigned(10 downto 0)) return boolean is
  begin
    return exping = '0' or a < lp or (busy = '1' and a + 1 < wp);
  end function;
  -- K325T: the painter's next screen row buffer index; a list row may use the whole 2 KB, any
  -- other row wraps at 1 KB as before
  function srb_next(a : unsigned(10 downto 0); list_row : std_logic) return unsigned is
    variable r : unsigned(10 downto 0);
  begin
    r := a + 1;
    if list_row = '0' then r(10) := '0'; end if;
    return r;
  end function;

  function rb_fcm_px(b : unsigned(7 downto 0); with_alpha, force_fg, force_bg, transp_primary : std_logic;
                     fg, bg : unsigned(7 downto 0); cur17 : std_logic) return unsigned is
    variable r : unsigned(17 downto 0);
  begin
    r(17) := cur17;
    if b = x"00" then
      r(16 downto 9) := x"FF"; r(8) := force_fg; r(7 downto 0) := bg;
      if transp_primary = '1' then r(17) := '0'; end if;
    elsif with_alpha = '0' then
      r(16 downto 9) := x"FF"; r(8) := not force_bg;
      if b /= x"FF" then r(7 downto 0) := b; else r(7 downto 0) := fg; end if;
    else
      r(16 downto 9) := b; r(8) := (b(7) or force_fg) and (not force_bg); r(7 downto 0) := fg;
    end if;
    return r;
  end function;
  function rb_nib_px(n : unsigned(3 downto 0); with_alpha, force_fg, force_bg : std_logic;
                     fg, bg : unsigned(7 downto 0); cur17 : std_logic) return unsigned is
    variable r : unsigned(17 downto 0);
  begin
    r(17) := cur17;
    if n = x"0" then
      r(16 downto 9) := x"FF"; r(8) := force_fg; r(7 downto 0) := bg;
    elsif with_alpha = '0' then
      r(16 downto 9) := x"FF"; r(8) := not force_bg;
      if n /= x"F" then r(7 downto 0) := fg(7 downto 4) & n; else r(7 downto 0) := fg; end if;
    else
      r(16 downto 13) := n; r(12 downto 9) := (others => n(0));
      r(8) := (n(3) or force_fg) and (not force_bg); r(7 downto 0) := fg;
    end if;
    return r;
  end function;
  function rb_mono_px(bit : std_logic; force_fg, force_bg : std_logic;
                      fg, bg : unsigned(7 downto 0); cur17 : std_logic) return unsigned is
    variable r : unsigned(17 downto 0);
  begin
    r(17) := cur17; r(16 downto 9) := x"FF";
    if bit = '1' then r(8) := not force_bg; r(7 downto 0) := fg;
    else r(8) := not force_fg; r(7 downto 0) := bg; end if;
    return r;
  end function;
  function rb_mc_px(bits : unsigned(1 downto 0); force_fg, force_bg : std_logic;
                    fg, bg, mc1, mc2 : unsigned(7 downto 0); cur17 : std_logic) return unsigned is
    variable r : unsigned(17 downto 0);
  begin
    r(17) := cur17; r(16 downto 9) := x"FF";
    case bits is
      when "00" => r(8) := not force_fg; r(7 downto 0) := bg;
      when "01" => r(8) := not force_bg; r(7 downto 0) := mc1;
      when "10" => r(8) := not force_bg; r(7 downto 0) := mc2;
      when others => r(8) := not force_bg; r(7 downto 0) := fg;
    end case;
    return r;
  end function;

  signal raster_buffer_max_write_address : unsigned(9 downto 0) := to_unsigned(0,9+1);
  signal raster_buffer_max_write_address_hold : unsigned(9 downto 0) := to_unsigned(0,9+1);
  signal raster_buffer_max_write_address_prev : unsigned(9 downto 0) := to_unsigned(0,9+1);

  signal no_raster_buffer_delay : std_logic := '1';
  signal raster_buffer_double_line : std_logic := '0';

  -- Colour RAM access for video controller
  signal colourramaddress : unsigned(15 downto 0) := to_unsigned(0,15+1);
  signal colourramdata : unsigned(7 downto 0) := to_unsigned(0,7+1);
  -- ... and for CPU
  signal colour_ram_fastio_address : unsigned(15 downto 0) := to_unsigned(0,15+1);

  -- Palette RAM access via fastio port
  signal palette_we : std_logic_vector(3 downto 0) := (others => '0');
  signal palette_fastio_address : std_logic_vector(9 downto 0) := std_logic_vector(to_unsigned(0,9+1));
  signal palette_fastio_rdata : std_logic_vector(31 downto 0) := std_logic_vector(to_unsigned(0,31+1));

  -- Palette RAM access for video controller
  -- -- colour lookup for primary pixel pipeline
  signal palette_address : std_logic_vector(9 downto 0) := std_logic_vector(to_unsigned(0,9+1));
  signal palette_rdata : std_logic_vector(31 downto 0) := std_logic_vector(to_unsigned(0,31+1));
  -- -- colour lookup for anti-aliased font foreground colour
  signal alias_palette_address : std_logic_vector(9 downto 0) := std_logic_vector(to_unsigned(0,9+1));
  signal alias_palette_rdata : std_logic_vector(31 downto 0) := std_logic_vector(to_unsigned(0,31+1));
  -- -- colour lookup for alpha blending of visible sprite over
  --    character generator
  signal sprite_alias_palette_address : std_logic_vector(9 downto 0) := std_logic_vector(to_unsigned(0,9+1));
  signal sprite_alias_palette_rdata : std_logic_vector(31 downto 0) := std_logic_vector(to_unsigned(0,31+1));

  -- Palette bank selection registers
  signal palette_bank_fastio : std_logic_vector(1 downto 0) := "11";
  signal palette_bank_chargen : std_logic_vector(1 downto 0) := "11";
  signal palette_bank_chargen_alt : std_logic_vector(1 downto 0) := "11";
  signal palette_bank_sprites : std_logic_vector(1 downto 0) := "11";

  signal vsync_polarity_internal : std_logic := '0';
  signal hsync_polarity_internal : std_logic := '0';

  -- Mode line calculations
  signal text_height_200 : integer := 0;
  signal text_height_400 : integer := 0;

  signal text_height : integer;
  signal chargen_y_scale_200 : unsigned(7 downto 0) := (others => '0');
  signal chargen_y_scale_400 : unsigned(7 downto 0) := (others => '0');
  signal chargen_y_pixels : integer := 0;
  -- Initialise the top border height to be > 6 to avoid boundary violations
  -- during start up in simulation
  signal top_borders_height_200 : unsigned(11 downto 0) := to_unsigned(16,12);
  signal top_borders_height_400 : unsigned(11 downto 0) := to_unsigned(16,12);
  signal single_top_border_200 : unsigned(11 downto 0) := to_unsigned(16,12);
  signal single_top_border_400 : unsigned(11 downto 0) := to_unsigned(16,12);

  signal viciv_flyback : std_logic := '0';

  signal pixel_newframe_internal : std_logic := '0';

  -- Signals for managing the state of the programmable screen RAM lists
  -- We have a simple call-stack scheme, where GOTO tokens and GOSUB tokens
  -- can cause redirection of the screen RAM stream being read. This happens
  -- during the badline fetch, i.e., once per character row.
  type screenline_return_stack_t is  array (0 to 3) of unsigned(19 downto 0);
  signal screenline_return_stack : screenline_return_stack_t;
  signal screenline_return_stack_count : integer range 0 to 3 := 0;
  -- We also allow shoving characters up or down, so that by displaying
  -- a set of screen characters (possibly via a GOSUB token), they can be
  -- displayed at any vertical offset, as well as horizontal offset via the
  -- GOTOX tokens.
  -- The draw_mask combined with the Y fine address offset mechanism allows
  -- shifting a character up or down, and then masking off the parts that would
  -- come from the previous or next character
  signal screenline_draw_mask : unsigned(7 downto 0) := (others => '1');
  signal screenline_draw_mask_drive : unsigned(7 downto 0) := (others => '1');
  signal draw_mask_blank : std_logic := '0';

  -- For accumulating the last token
  signal screen_line_last_token : unsigned(15 downto 0) := x"0000";
  -- Count down used to extracting read 16-bit character tokens from the
  -- badline data stream (corrects for pipeline delay, and only every other
  -- byte completing a 16-bit token).
  signal badlineprog_countdown : integer := 0;
  -- Count down used when branching in a badline program to flush the memory
  -- fetch pipeline.
  signal badlineprog_inhibit_screen_row_buffer_write_counter : integer := 0;
  -- Indicates if the next 16 bit screen token will be a GOTO/GOSUB token
  signal next_token_is_goto : std_logic := '0';

  -- K325T RRB list mode (docs/rrb_list_mode.md in the lab repo): a LIST token ($FFFC) in a
  -- CHR16 row starts a list of 8-byte object entries; rrb_list_expander writes a GOTOX + the
  -- object's tokens per entry into the row buffer, colour bytes into a colour row buffer.
  signal rl_en_s        : std_logic_vector(1 downto 0) := "00";
  signal list_found     : std_logic := '0';           -- LIST token seen in this row's fetch
  signal list_lo_fc     : std_logic := '0';           -- last even row byte was $FC
  signal list_lo_ff     : std_logic := '0';           -- last even row byte was $FF
  signal row_ff         : std_logic := '0';           -- $FFFF (end of row) seen first, at list_pos
  signal row_short      : std_logic := '0';           -- v2 objects replace the row's $FFFF
  signal list_pos       : unsigned(10 downto 0) := (others => '0');  -- buffer index of LIST
  signal row_list       : std_logic := '0';           -- current character row is expanded
  signal row_scr_base   : unsigned(19 downto 0) := (others => '0');
  signal row_col_start  : unsigned(15 downto 0) := (others => '0');
  signal list_line_end  : std_logic := '0';
  signal list_wait      : integer range 0 to 7 := 0;
  signal expanding      : std_logic := '0';
  signal exp_start, exp_busy, exp_done, exp_mreq, exp_bwe : std_logic := '0';
  signal exp_abort      : std_logic := '0';
  -- The visible end of a raster line is where the last glyph was painted
  -- (raster_buffer_max_write_address follows the write position).  Objects of a list row must
  -- not shorten the row: the end of the row's ordinary part is saved at the first GOTOX of the
  -- expanded part, and the line ends at the larger of the two.
  signal list_in_exp    : std_logic := '0';
  signal list_save_armed : std_logic := '0';
  signal list_saved_max : unsigned(9 downto 0) := (others => '0');
  signal exp_out_len    : unsigned(11 downto 0);
  signal exp_baddr      : unsigned(10 downto 0);
  signal exp_maddr      : unsigned(19 downto 0);
  signal exp_caddr      : unsigned(15 downto 0);
  signal exp_bscreen, exp_bcolour : unsigned(7 downto 0);
  signal exp_ent_addr   : unsigned(19 downto 0);
  signal colour_addrb   : unsigned(15 downto 0);
  signal colourramdata_ram : unsigned(7 downto 0);
  type cbuf_t is array (0 to 2047) of unsigned(7 downto 0);
  signal cbuf           : cbuf_t := (others => x"00");
  signal cbuf_dout      : unsigned(7 downto 0) := x"00";
  signal cbuf_sel       : std_logic := '0';
  -- K325T step 5: painting overlaps the expansion (list rows).  During the badline fetch the row's
  -- own colour bytes are copied into cbuf (cc_*: the colour RAM port is idle then; during the
  -- expansion it is the expander's), so list rows take all colours from cbuf.  Painting starts
  -- after the fetch; a token at or beyond the expander's write position (exp_wpos) is waited for
  -- (decoder D0 / FrontWait); the expander reads chip RAM only when the VIC-IV cannot read in the
  -- next cycle (exp_ofree); the mono/multicolour glyph byte is latched in PaintMemWait2 (mono_l)
  -- instead of being held on the port.
  signal cc_act         : std_logic := '0';
  signal cc_addr        : unsigned(15 downto 0) := (others => '0');
  signal cc_idx, cc_n   : unsigned(10 downto 0) := (others => '0');
  signal cc_v1          : std_logic := '0';
  signal cc_i1          : unsigned(10 downto 0) := (others => '0');
  signal exp_wpos       : unsigned(10 downto 0);
  -- exp_wpos one cycle later (0 while idle), for the decoder: a byte the expander writes in
  -- cycle k is in the row buffer from k + 2 (the buffer write is registered once more here), and
  -- D0 reads the low byte in the cycle it decides, D1 the high byte one cycle later
  signal exp_wpos_d     : unsigned(10 downto 0) := (others => '0');
  signal exp_ofree      : std_logic;
  signal mono_l         : unsigned(7 downto 0) := x"00";
  -- list mode v2: object table snapshot per frame, scanned for every CHR16 row
  signal rv2_s, hold_s  : std_logic_vector(1 downto 0) := "00";
  signal exp_copy_start, exp_copying, exp_start_scan : std_logic := '0';
  signal exp_col_tick : std_logic := '0';             -- v2 collisions: one pass per frame
  signal exp_row        : unsigned(7 downto 0) := (others => '0');
  signal row_end_pos    : unsigned(10 downto 0) := (others => '0');  -- saturates at 1024
  signal exp_mfree      : std_logic;
  constant RRB_LIST_LIMIT : integer := 2044;          -- row buffer limit of the expansion (2 KB)
  -- List mode lead (docs/rrb_list_mode.md, "First raster line budget"): with XCTL bit 5 or 6 on
  -- (and $D051 NORRDEL = 1, DBLRR = 0, the defaults) every raster line is painted one line
  -- earlier and shown one line later, so the picture stays where it is and every pixel the
  -- line's painting writes before the next line start is in time (a badline's fetch +
  -- expansion included).  Three parts, all inactive with rl_shift = '0':
  --   * the fetch side's vertical position (pixels_since_last_char, before_ / justbefore_
  --     y_chargen_start) uses displayy + 1 (displayy_p1): the whole row schedule (chargen_y,
  --     badlines, first_card_of_row, the forced badlines above the text, the stop at the end)
  --     runs one line ahead;
  --   * the raster buffer is double buffered as with NORRDEL = 0: the painting that starts in
  --     line N is shown in line N + 2;
  --   * the display side's text-area mask (chargen_active forced off above / below the text)
  --     is the fetch side's mask of the line before (rl_mask: sampled at x = 0 at the end of
  --     that line), i.e. the original mask of the line shown.
  -- Latched at the top of each frame (switching never happens inside a frame).
  -- With DBLRR ($D051 bit 6: a line start every other line, two lines per painting) the same
  -- by two lines (rl_shift2): fetch side at displayy + 2, double buffered (the painting that
  -- starts in line N, N even, is shown in lines N + 3 and N + 4 instead of N + 1 and N + 2),
  -- the mask two lines late.  Each painting then has its two lines and is shown complete.
  signal rl_shift, rl_shift2 : std_logic := '0';

  -- K325T fast token path (XCTL bit 7 with bit 4; docs/rrb_list_mode.md "Fast token path"):
  -- CHR16 text lines only.  A decoder (fp_dec) reads token k+1's screen and colour bytes and
  -- computes its glyph address into the n_* registers (the work of FetchNextCharacter ..
  -- FetchTextCellColourAndSource) while token k is fetched and dispatched; at k's dispatch the
  -- n_* registers become the glyph_* registers (fp_take) and k+1 goes straight to
  -- PaintMemWait.  Full-colour rows come as two 32-bit words (chipram_datain32; TurboFetch32
  -- assembles the 8 bytes and does PaintMemWait3's work), and the painter takes the next
  -- full-colour or mono glyph in its last pixel cycle (no setup/idle cycles in between).  A
  -- token decoded behind a GOTOX that is not dispatched yet waits (fp_goto_pend): the GOTOX
  -- changes the draw mask and Y offset the decoder uses.
  signal fp_s           : std_logic_vector(1 downto 0) := "00";
  signal fp_line        : std_logic := '0';
  type fp_dec_t is (DIdle, D0, D1, D2, D3, DFull);
  signal fp_dec         : fp_dec_t := DIdle;
  signal fp_goto_pend   : std_logic := '0';
  signal fcm_w0         : unsigned(31 downto 0) := (others => '0');
  signal n_glyph_number : unsigned(12 downto 0) := (others => '0');
  signal n_bg_select    : unsigned(1 downto 0) := "00";
  signal n_flip_h, n_flip_v, n_alpha, n_goto, n_4bit, n_full_colour : std_logic := '0';
  signal n_width_deduct : unsigned(3 downto 0) := (others => '0');
  signal n_is_ff, n_high_is_ff : std_logic := '0';
  signal n_list_in_exp, n_list_line_end, n_short_line : std_logic := '0';
  signal n_short_line_length : integer range 0 to 512 := 0;
  signal n_draw_mask_blank, n_from_rom : std_logic := '0';
  signal n_glyph_data_address : unsigned(19 downto 0) := (others => '0');
  signal n_colour_drive : unsigned(7 downto 0) := x"00";
  signal n_bold_drive, n_underline_drive, n_reverse_drive, n_visible_drive, n_blink_drive : std_logic := '0';
  signal n_draw_mask_drive : unsigned(7 downto 0) := x"FF";
  signal n_bold_and_reverse : std_logic := '0';
  signal displayy_p1    : unsigned(11 downto 0) := to_unsigned(1,12);   -- always displayy + 1
  signal displayy_p2    : unsigned(11 downto 0) := to_unsigned(2,12);   -- always displayy + 2
  signal rl_mask1, rl_mask : std_logic := '1';
  -- list mode diagnostic counters (indices: soft_rtc.vhdl header, docs/rrb_list_mode.md)
  constant DG_FRAMES     : integer := 0;   -- exp_copy_start pulses
  constant DG_COPY_DONE  : integer := 1;   -- falling edges of exp_copying
  constant DG_EXP_START  : integer := 2;   -- exp_start pulses
  constant DG_EXP_DONE   : integer := 3;   -- exp_done pulses
  constant DG_EXP_ABORT  : integer := 4;   -- exp_abort pulses
  constant DG_WAIT_LOST  : integer := 5;   -- line start in ListWait while the copy runs
  constant DG_ROW_FULL   : integer := 6;   -- v2 row painted plainly: append point > LIMIT - 2
  constant DG_COLLIDE    : integer := 7;   -- exp_mreq while the VIC-IV reads (must stay 0)
  constant DG_OVF        : integer := 8;   -- expansion ended by the buffer limit
  constant DG_PARTS      : integer := 9;   -- object parts emitted (Gotox0), wraps
  constant DG_EXP_MAX    : integer := 10;  -- max expansion duration (pixel cycles)
  constant DG_COPY_MAX   : integer := 11;  -- max copy duration (pixel cycles)
  constant DG_STALL      : integer := 12;  -- copy stall cycles
  constant DG_SHORT      : integer := 13;  -- expansions of $FFFF rows (row_short)
  constant DG_LINE_ABORT : integer := 14;  -- line start while expanding, no exp_done
  constant DG_SCAN_START : integer := 15;  -- expansions started with start_scan
  constant DG_FIRST_MAX  : integer := 16;  -- max cycles copy start -> first copy read
  constant DG_WAIT_RACE  : integer := 17;  -- line start in ListWait (no copy) that the arm overrides
  constant DG_RUN_RACE   : integer := 18;  -- line start in ListRun with exp_done (arm overrides)
  constant DG_START_CP   : integer := 19;  -- exp_start while exp_copying (must stay 0)
  constant DG_COPY_Y     : integer := 20;  -- ycounter at the last copy end
  constant DG_ABORT_Y    : integer := 21;  -- ycounter at the last abort
  constant DG_WAIT_BORDER : integer := 22; -- line start in ListWait, copying, border-line branch
  constant DG_LATE       : integer := 23;  -- raster buffer write behind the display (late pixel)
  constant DG_LATE_Y     : integer := 24;  -- ycounter at the last late write
  constant DG_PAINT_MAX  : integer := 25;  -- max cycles line start -> EndOfChargen (RRB time used)
  constant DG_OBJ_MAX    : integer := 26;  -- max cycles line start -> first GOTOX of the expanded part
  type diag_cnt_t is array (0 to 31) of unsigned(15 downto 0);
  signal dg_cnt         : diag_cnt_t := (others => (others => '0'));
  signal dg_ev          : std_logic_vector(31 downto 0) := (others => '0');   -- events, registered
  signal dg_sel1, dg_sel2 : unsigned(4 downto 0) := (others => '0');
  signal dg_clr_s       : std_logic_vector(2 downto 0) := "000";
  signal dg_copying_d   : std_logic := '0';
  signal dg_exp_run, dg_cp_run, dg_first_pend : std_logic := '0';
  signal dg_exp_t, dg_cp_t : unsigned(15 downto 0) := (others => '0');
  signal dg_ycounter    : unsigned(11 downto 0) := (others => '0');
  signal exp_ovf, exp_part, exp_cstall : std_logic;
  signal dg_line_t      : unsigned(15 downto 0) := (others => '0');   -- cycles since the line start
  signal dg_paint_run, dg_obj_pend : std_logic := '0';

  signal reg_alpha_delay : unsigned(3 downto 0) := x"1";

  signal is_fetch_start : std_logic := '0';
  signal last_was_fetch_start : std_logic := '0';

  signal d031_writes : unsigned(7 downto 0) := x"00";
  signal d031_written_internal : std_logic := '0';

  signal badline_toggle_internal : std_logic := '0';
  signal enable_raster_delay : std_logic := '1';
  signal pixels_since_last_char : unsigned(2 downto 0) := "000";

  signal render_activity : std_logic_vector(2 downto 0) := "000";
  signal show_render_activity : std_logic := '0';

  signal hyper_data : unsigned(7 downto 0) := x"00";
  signal hyper_addr_drive : unsigned(18 downto 3) := x"0000";
  signal hyper_data_strobe : std_logic := '0';
  signal hyper_request_toggle_drive : std_logic := '0';
  signal hyper_request_toggle_drive2 : std_logic := '0';
  signal hyper_request_toggle_drive3 : std_logic := '0';
  signal hyper_data_counter : unsigned(31 downto 0) := to_unsigned(0,32);

  signal sprite_continuous_pointer_monitoring : std_logic := '1';

  -- Set to 0 to disable bug compatibility D016 positioning
  signal prev_hw_errata_level : unsigned(7 downto 0) := to_unsigned(0,8);
  signal bug_compat_mode : std_logic := '1';
  signal prev_bug_compat_mode : std_logic := '1';
  signal bug_compat_vic_iii_d016_delta : integer := 2;

begin

  -- Raster buffer as even/odd pixel banks (K325T fast RRB; one write per bank per cycle).
  -- Single writes (all of upstream's paint states): the bank of the address.  Double writes:
  -- pixel 1 at address-1 and pixel 2 at address are always in different banks.
  process (raster_buffer_write_address, raster_buffer_write, raster_buffer_write_data,
           rb_double, raster_buffer_write2, raster_buffer_write_data2)
    variable a1 : unsigned(10 downto 0);
  begin
    rb_addr0 <= resize(raster_buffer_write_address(10 downto 1), 11);
    rb_addr1 <= resize(raster_buffer_write_address(10 downto 1), 11);
    rb_din0 <= raster_buffer_write_data;
    rb_din1 <= raster_buffer_write_data;
    rb_we0 <= raster_buffer_write and not raster_buffer_write_address(0);
    rb_we1 <= raster_buffer_write and raster_buffer_write_address(0);
    if rb_double = '1' then
      a1 := raster_buffer_write_address;
      a1(9 downto 0) := raster_buffer_write_address(9 downto 0) - 1;
      if raster_buffer_write_address(0) = '1' then
        -- pixel 1 even (bank 0 @ a1/2), pixel 2 odd (bank 1 @ addr/2)
        rb_addr0 <= resize(a1(10 downto 1), 11);
        rb_din0 <= raster_buffer_write_data;  rb_we0 <= raster_buffer_write;
        rb_din1 <= raster_buffer_write_data2; rb_we1 <= raster_buffer_write2;
      else
        -- pixel 1 odd (bank 1 @ a1/2), pixel 2 even (bank 0 @ addr/2)
        rb_addr1 <= resize(a1(10 downto 1), 11);
        rb_din1 <= raster_buffer_write_data;  rb_we1 <= raster_buffer_write;
        rb_din0 <= raster_buffer_write_data2; rb_we0 <= raster_buffer_write2;
      end if;
    end if;
  end process;

  -- K325T XCTL bit 3: valid bits of the raster buffer (see cu_s)
  process (pixelclock)
    variable vb : std_logic;
  begin
    if rising_edge(pixelclock) then
      cu_we0 <= rb_we0; cu_a0 <= rb_addr0(9 downto 0);
      cu_we1 <= rb_we1; cu_a1 <= rb_addr1(9 downto 0);
      if cu_clr = '1' then                       -- bit 9 of the index is the buffer half
        if cu_clr_half = '0' then
          cu_v0(511 downto 0) <= (others => '0'); cu_v1(511 downto 0) <= (others => '0');
        else
          cu_v0(1023 downto 512) <= (others => '0'); cu_v1(1023 downto 512) <= (others => '0');
        end if;
      end if;
      if cu_we0 = '1' then cu_v0(to_integer(cu_a0)) <= '1'; end if;
      if cu_we1 = '1' then cu_v1(to_integer(cu_a1)) <= '1'; end if;
      -- with the pixel the display reads (same address and latency as the buffer's read port)
      if raster_buffer_read_address_next(0) = '1' then
        vb := cu_v1(to_integer(raster_buffer_read_address_next(10 downto 1)));
      else
        vb := cu_v0(to_integer(raster_buffer_read_address_next(10 downto 1)));
      end if;
      cu_vq <= vb;
    end if;
  end process;

  rasterbuffer_even: entity work.ram18x2k
    port map (
      clkl => pixelclock,
      clkr => pixelclock,
      wel(0) => rb_we0,
      dinl => std_logic_vector(rb_din0),
      unsigned(doutr) => rb_dout0,
      addrl => std_logic_vector(rb_addr0),
      addrr => std_logic_vector(rb_raddr)
      );
  rasterbuffer_odd: entity work.ram18x2k
    port map (
      clkl => pixelclock,
      clkr => pixelclock,
      wel(0) => rb_we1,
      dinl => std_logic_vector(rb_din1),
      unsigned(doutr) => rb_dout1,
      addrl => std_logic_vector(rb_addr1),
      addrr => std_logic_vector(rb_raddr)
      );
  process (pixelclock) begin
    if rising_edge(pixelclock) then rb_rsel <= raster_buffer_read_address_next(0); end if;
  end process;
  raster_buffer_read_data <= rb_dout1 when rb_rsel = '1' else rb_dout0;
  rb_raddr <= resize(raster_buffer_read_address_next(10 downto 1), 11);

  buffer1: entity work.screen_ram_buffer
    port map (
      clka => pixelclock,
      clkb => pixelclock,
      dina    => std_logic_vector(screen_ram_buffer_din),
      unsigned(doutb)   => screen_ram_buffer_dout,
      wea(0)  => screen_ram_buffer_write,
      addra  => std_logic_vector(screen_ram_buffer_write_address),
      addrb  => std_logic_vector(screen_ram_buffer_read_address)
      );

  colourram64: if colour_ram_64k generate
    colourram1 : entity work.ram8x64k_k325t
      port map (
        en64 => colour_ram_64k_en,
        clka => cpuclock, ena => colour_ram_cs, wea(0) => fastio_write,
        addra => std_logic_vector(colour_ram_fastio_address),
        dina => fastio_wdata, douta => colour_ram_fastio_rdata,
        clkb => pixelclock,
        addrb => std_logic_vector(colour_addrb),
        unsigned(doutb) => colourramdata_ram);
  end generate;

  colourram: if not colour_ram_64k generate
    colourram1 : entity work.ram8x32k
      PORT MAP (
        clka => cpuclock,
        ena => colour_ram_cs,
        wea(0) => fastio_write,
--        wea => fastio_write,
        addra => std_logic_vector(colour_ram_fastio_address(14 downto 0)),
        dina => fastio_wdata,
        douta => colour_ram_fastio_rdata,
        -- video controller use port b of the dual-port colour ram.
        -- The CPU uses port a via the fastio interface
        clkb => pixelclock,
        web => (others => '0'),
--        web => '0',
        addrb => std_logic_vector(colour_addrb(14 downto 0)),
        dinb => (others => '0'),
        unsigned(doutb) => colourramdata_ram
        );
  end generate;

  -- K325T RRB list mode: expander + colour row buffer
  colour_addrb <= exp_caddr when expanding = '1' else cc_addr when cc_act = '1' else colourramaddress;
  colourramdata <= cbuf_dout when cbuf_sel = '1' else colourramdata_ram;
  exp_ent_addr <= row_scr_base + list_pos + 2;

  rrblist0 : entity work.rrb_list_expander
    generic map (MLAT => 3, CLAT => 1, LIMIT => RRB_LIST_LIMIT, BUFW => 11, NOBJ => rrb_nobj)
    port map (clk => pixelclock, start => exp_start, abort => exp_abort, ent_addr => exp_ent_addr,
              out_start => list_pos, busy => exp_busy, done => exp_done, out_len => exp_out_len,
              mreq => exp_mreq, maddr => exp_maddr, mdata => final_ramdata,
              caddr => exp_caddr, cdata => colourramdata_ram,
              bwe => exp_bwe, baddr => exp_baddr, bscreen => exp_bscreen, bcolour => exp_bcolour,
              scan_en => rv2_s(1), start_scan => exp_start_scan, row => exp_row,
              obj_count => obj_count, copy_start => exp_copy_start, tab_addr => obj_tab_addr,
              mfree => exp_mfree, copying => exp_copying, ofree => exp_ofree, wpos => exp_wpos,
              ovf => exp_ovf, part => exp_part, cstall => exp_cstall,
              col_tick => exp_col_tick, col_bits => col_bits, col_count => col_count,
              col_toggle => col_toggle, col_pidx => col_pidx, col_pdata => col_pdata,
              col_budget => col_budget, col_trunc => col_trunc, bk_full => bk_full);

  -- K325T list mode diagnostic counters (read at $FFD71E0-3 via soft_rtc).  Stage 1 registers
  -- one bit per event (dg_ev); stage 2 counts them (16 bits, saturating at $FFFF, except the
  -- parts counter, which wraps) and keeps the maxima.  diag_clr is a toggle from the CPU clock
  -- domain (two flip-flops, then an edge detect); diag_sel is registered twice, diag_val once.
  -- Observation only: nothing here feeds back into the VIC-IV or the expander.
  process (pixelclock)
    variable fs, rd : boolean;
    variable ev : std_logic_vector(31 downto 0);
    variable lo : unsigned(9 downto 0);
  begin
    if rising_edge(pixelclock) then
      -- stage 1: events of this cycle
      fs := is_fetch_start = '1' and last_was_fetch_start = '0';     -- the line start pulse
      case raster_fetch_state is
        when FetchBitmapData | FetchTextCellColourAndSource | PaintFullColourFetch
           | SpritePointerFetch2 | SpritePointerCompute1 | SpriteDataFetch | SpriteDataFetch2 =>
          rd := true;
        when PaintMemWait | PaintMemWait2 =>
          rd := glyph_full_colour = '1' or fp_line = '1';   -- (fast token path: every glyph)
        when others =>
          rd := false;
      end case;
      ev := (others => '0');
      ev(DG_FRAMES) := exp_copy_start;
      if dg_copying_d = '1' and exp_copying = '0' then ev(DG_COPY_DONE) := '1'; end if;
      ev(DG_EXP_START) := exp_start;
      ev(DG_EXP_DONE) := exp_done;
      ev(DG_EXP_ABORT) := exp_abort;
      if fs and raster_fetch_state = ListWait and exp_copying = '1' then
        ev(DG_WAIT_LOST) := '1';
      end if;
      -- the ListWait arm's last branch (to FetchFirstCharacter) with v2 on: no LIST token and
      -- the append point ($FFFF position or row end) beyond LIMIT - 2
      if raster_fetch_state = ListWait and list_wait = 0 and exp_copying = '0'
         and list_found = '0' and rv2_s(1) = '1'
         and ((row_ff = '1' and list_pos > to_unsigned(RRB_LIST_LIMIT - 2, 11))
              or (row_ff = '0' and (row_end_pos(10) = '1'
                                    or row_end_pos > to_unsigned(RRB_LIST_LIMIT - 2, 11)))) then
        ev(DG_ROW_FULL) := '1';
      end if;
      if exp_mreq = '1' and (this_ramaccess_is_screen_row_fetch = '1' or rd) then
        ev(DG_COLLIDE) := '1';
      end if;
      ev(DG_OVF) := exp_ovf;
      ev(DG_PARTS) := exp_part;
      ev(DG_STALL) := exp_cstall;
      ev(DG_SHORT) := exp_start and row_short;
      if fs and expanding = '1' and exp_done = '0' then ev(DG_LINE_ABORT) := '1'; end if;
      ev(DG_SCAN_START) := exp_start and exp_start_scan;
      -- a line start in ListWait / ListRun where the state's case arm assigns a state in the
      -- same edge (the case comes after the line start code, so it wins): ListWait deciding
      -- (no copy running), ListWait's border-line branch while copying, ListRun on exp_done
      if fs and raster_fetch_state = ListWait and list_wait = 0 and exp_copying = '0' then
        ev(DG_WAIT_RACE) := '1';
      end if;
      if fs and raster_fetch_state = ListWait and list_wait = 0 and exp_copying = '1'
         and before_y_chargen_start = '1' and justbefore_y_chargen_start = '0' then
        ev(DG_WAIT_BORDER) := '1';
      end if;
      if fs and raster_fetch_state = ListRun and exp_done = '1' then ev(DG_RUN_RACE) := '1'; end if;
      ev(DG_START_CP) := exp_start and exp_copying;
      -- late pixel: a raster buffer write into the half the display reads now, at or left of
      -- the pixel it reads, inside the text area and before this line's fetch start (after it
      -- the writes belong to the next painting): that pixel comes too late for this line.
      -- (RAM write enable and address are these registered signals in this very cycle.)
      if (raster_buffer_write = '1' or raster_buffer_write2 = '1') and chargen_active = '1'
         and xcounter < display_fetch_start
         and raster_buffer_write_address(10) = raster_buffer_read_address(10) then
        lo := raster_buffer_write_address(9 downto 0);
        if rb_double = '1' then lo := lo - 1; end if;            -- pixel 1 of a double write
        if lo <= raster_buffer_read_address(9 downto 0) then ev(DG_LATE) := '1'; end if;
      end if;
      dg_ev <= ev;
      dg_copying_d <= exp_copying;
      dg_ycounter <= ycounter;

      -- durations (cycles since the start pulse, saturating)
      if dg_exp_t /= x"FFFF" then dg_exp_t <= dg_exp_t + 1; end if;
      if dg_cp_t /= x"FFFF" then dg_cp_t <= dg_cp_t + 1; end if;
      if exp_start = '1' then
        dg_exp_run <= '1'; dg_exp_t <= (others => '0');
      elsif exp_abort = '1' and exp_done = '0' then
        dg_exp_run <= '0';                        -- an aborted expansion sets no maximum
      elsif exp_done = '1' and dg_exp_run = '1' then
        dg_exp_run <= '0';
        if dg_exp_t > dg_cnt(DG_EXP_MAX) then dg_cnt(DG_EXP_MAX) <= dg_exp_t; end if;
      end if;
      if exp_copy_start = '1' then
        dg_cp_run <= '1'; dg_first_pend <= '1'; dg_cp_t <= (others => '0');
      else
        if dg_first_pend = '1' and exp_mreq = '1' and exp_busy = '0' then   -- a copy read
          dg_first_pend <= '0';
          if dg_cp_t > dg_cnt(DG_FIRST_MAX) then dg_cnt(DG_FIRST_MAX) <= dg_cp_t; end if;
        end if;
        if dg_cp_run = '1' and dg_copying_d = '1' and exp_copying = '0' then
          dg_cp_run <= '0'; dg_first_pend <= '0';
          if dg_cp_t > dg_cnt(DG_COPY_MAX) then dg_cnt(DG_COPY_MAX) <= dg_cp_t; end if;
        end if;
      end if;
      -- RRB time per line: line start -> EndOfChargen (a painting cut off by the next line
      -- start counts with the cycles it had), and line start -> dispatch of the first GOTOX of
      -- a list row's expanded part (its first object part)
      if fs then
        if dg_paint_run = '1' and dg_line_t > dg_cnt(DG_PAINT_MAX) then
          dg_cnt(DG_PAINT_MAX) <= dg_line_t;
        end if;
        dg_line_t <= (others => '0'); dg_paint_run <= '1'; dg_obj_pend <= '1';
      else
        if dg_line_t /= x"FFFF" then dg_line_t <= dg_line_t + 1; end if;
        if dg_paint_run = '1' and raster_fetch_state = EndOfChargen then
          dg_paint_run <= '0';
          if dg_line_t > dg_cnt(DG_PAINT_MAX) then dg_cnt(DG_PAINT_MAX) <= dg_line_t; end if;
        end if;
        if dg_obj_pend = '1' and raster_fetch_state = PaintDispatch and paint_ready = '1'
           and glyph_goto = '1' and list_in_exp = '1' and list_save_armed = '1' then
          dg_obj_pend <= '0';
          if dg_line_t > dg_cnt(DG_OBJ_MAX) then dg_cnt(DG_OBJ_MAX) <= dg_line_t; end if;
        end if;
      end if;

      -- stage 2: counters
      for n in 0 to 31 loop
        if (n <= DG_START_CP or n = DG_WAIT_BORDER or n = DG_LATE) and n /= DG_EXP_MAX and n /= DG_COPY_MAX
           and n /= DG_FIRST_MAX and dg_ev(n) = '1' then
          if n = DG_PARTS or dg_cnt(n) /= x"FFFF" then
            dg_cnt(n) <= dg_cnt(n) + 1;
          end if;
        end if;
      end loop;
      if dg_ev(DG_COPY_DONE) = '1' then dg_cnt(DG_COPY_Y) <= x"0" & dg_ycounter; end if;
      if dg_ev(DG_EXP_ABORT) = '1' then dg_cnt(DG_ABORT_Y) <= x"0" & dg_ycounter; end if;
      if dg_ev(DG_LATE) = '1' then dg_cnt(DG_LATE_Y) <= x"0" & dg_ycounter; end if;

      dg_clr_s <= dg_clr_s(1 downto 0) & diag_clr;
      if dg_clr_s(2) /= dg_clr_s(1) then
        dg_cnt <= (others => (others => '0'));
      end if;

      dg_sel1 <= diag_sel; dg_sel2 <= dg_sel1;
      diag_val <= dg_cnt(to_integer(dg_sel2));
    end if;
  end process;

  -- colour row buffer: written by the expander, read like colour RAM (one cycle) at the row
  -- index of the painter's colour RAM address; selected for the expanded part of a list row
  process (pixelclock)
    variable d : unsigned(15 downto 0);
  begin
    if rising_edge(pixelclock) then
      if exp_busy = '1' then exp_wpos_d <= exp_wpos; else exp_wpos_d <= (others => '0'); end if;
      if cc_v1 = '1' then
        cbuf(to_integer(cc_i1)) <= colourramdata_ram;   -- the row's own colour bytes (fetch)
      elsif exp_bwe = '1' then
        cbuf(to_integer(exp_baddr)) <= exp_bcolour;
      end if;
      d := colourramaddress - row_col_start;
      cbuf_dout <= cbuf(to_integer(d(10 downto 0)));
      if row_list = '1' and d(15 downto 11) = "00000" then
        cbuf_sel <= '1';
      else
        cbuf_sel <= '0';
      end if;
    end if;
  end process;

  -- Used for main pixel pipeline colour lookup
  paletteram0: entity work.ram32x1024
    port map (
      clka => cpuclock,
      ena => '1',
      wea => palette_we,
      addra => palette_fastio_address,
      dina(31 downto 24) => fastio_wdata,
      dina(23 downto 16) => fastio_wdata,
      dina(15 downto 8) => fastio_wdata,
      dina(7 downto 0) => fastio_wdata,
      douta => palette_fastio_rdata,
      clkb => pixelclock,
      web => (others => '0'),
      addrb => palette_address,
      dinb => (others => '0'),
      doutb => palette_rdata
      );

  -- Used for anti-aliased text colour lookup
  paletteram1: entity work.ram32x1024
    port map (
      clka => cpuclock,
      ena => '1',
      wea => palette_we,
      addra => palette_fastio_address,
      dina(31 downto 24) => fastio_wdata,
      dina(23 downto 16) => fastio_wdata,
      dina(15 downto 8) => fastio_wdata,
      dina(7 downto 0) => fastio_wdata,
      -- douta => palette_fastio_rdata,
      clkb => pixelclock,
      web => (others => '0'),
      addrb => alias_palette_address,
      dinb => (others => '0'),
      doutb => alias_palette_rdata
      );


  charrom1 : entity work.charrom
    port map (Clk => pixelclock,
              address => charaddress,
              cs => '1',  -- active
              data_o => chardata,

              cpuclk => cpuclock,
              cpucs => charrom_cs,
              cpuaddress => unsigned(fastio_addr(11 downto 0)),
              we => fastio_write,
              data_i => fastio_wdata,
              cpu_data_o => charrom_fastio_rdata
              );

  compositeblender: entity work.alpha_blend_top
    port map (clk1x => pixelclock,
              reset => '0',
              hsync_strm0 => '0',
              vsync_strm0 => '0',
              de_strm0 => '1',
              -- RGB of background colour
              r_strm1(9 downto 2) => std_logic_vector(composite_bg_red),
              r_strm1(1 downto 0) => (others => '0'),
              g_strm1(9 downto 2) => std_logic_vector(composite_bg_green),
              g_strm1(1 downto 0) => (others => '0'),
              b_strm1(9 downto 2) => std_logic_vector(composite_bg_blue),
              b_strm1(1 downto 0) => (others => '0'),
              de_strm1 => '1',
              -- XXX: replace RGB and postsprite_pixel_colour values
              -- with appropriately delayed signals
              r_strm0(9 downto 2) => std_logic_vector(composite_red),
              r_strm0(1 downto 0) => (others => '0'),
              g_strm0(9 downto 2) => std_logic_vector(composite_green),
              g_strm0(1 downto 0) => (others => '0'),
              b_strm0(9 downto 2) => std_logic_vector(composite_blue),
              b_strm0(1 downto 0) => (others => '0'),
              de_alpha => '1',
              alpha_strm(9 downto 2) => std_logic_vector(alpha_blend_alpha(7 downto 0)),
              alpha_strm(1 downto 0) => "00",

              alpha_delay => reg_alpha_delay,

              r_blnd => composited_red,
              g_blnd => composited_green,
              b_blnd => composited_blue
              );

  pal_sim0: entity work.pal_simulation
    port map(
      clock => pixelclock,
      shadow_mask_enable => shadow_mask_enable,
      red_in => vga_palin_red,
      green_in => vga_palin_green,
      blue_in => vga_palin_blue,
      red_out => vga_palout_red,
      green_out => vga_palout_green,
      blue_out => vga_palout_blue,
      x_position => xcounter,
      y_position => displayy
      );


  vicii_sprites0: entity work.vicii_sprites
    port map (pixelclock => pixelclock,
              cpuclock => cpuclock,

              sprite_h640 => sprite_h640_delayed,
              sprite_v400s => sprite_v400s_delayed,
              bitplane_h640 => reg_h640_delayed,
              bitplane_h1280 => reg_h1280_delayed,
              bitplane_mode_in => bitplane_mode,
              bitplane_enables_in => bitplane_enables,
              bitplane_complements_in => bitplane_complements,
              bitplanes_y_start => bitplanes_y_start_drive,
              bitplanes_x_start => bitplanes_x_start_drive,
              bitplane_sixteen_colour_mode_flags_in =>
              bitplane_sixteen_colour_mode_flags,

              sprite_datavalid_in => sprite_datavalid,
              sprite_bytenumber_in => sprite_bytenumber,
              sprite_spritenumber_in => sprite_spritenumber,
              sprite_data_in => sprite_data_byte,

              sprite_horizontal_tile_enables => sprite_horizontal_tile_enables,
              sprite_bitplane_enables => sprite_bitplane_enables,
              sprite_extended_width_enables => sprite_extended_width_enables,
              sprite_extended_height_enables => sprite_extended_height_enables,
              sprite_extended_height_size => sprite_extended_height_size,
              sprite_sixteen_colour_enables => sprite_sixteen_colour_enables,

              sprite_number_for_data_in => sprite_number_for_data_tx,
              sprite_data_offset_out => sprite_data_offset_rx,
              sprite_number_for_data_out => sprite_number_for_data_rx,



              is_foreground_in => pixel_is_foreground_in,
              is_background_in => pixel_is_background_in,
              -- VIC-II sprites care only about VIC-II coordinates
              -- XXX 40 and 80 column displays should have the same aspect
              -- ratio for this to really work.
              pipeline_delay => reg_xcounter_delay,
              x320_in => to_xposition(vicii_xcounter_320),
              x640_in => to_xposition(vicii_xcounter_640),
              -- x1280 mode is deprecated
              x1280_in => to_xposition(vicii_xcounter_640),
              y_in => to_yposition(vicii_sprite_ycounter),
              yfine_in => to_yposition(vicii_ycounter_v400),
              border_in => inborder_drive2,
              alt_palette_in => pixel_alt_palette,
              pixel_in => chargen_pixel_colour,
              alpha_in => chargen_alpha_value,
              pixel_out => postsprite_pixel_colour,
              alpha_out => postsprite_alpha_value,
              border_out => postsprite_inborder,
              alt_palette_out => postsprite_alternate_palette,
              is_sprite_out => pixel_is_sprite,
              sprite_number_out => postsprite_sprite_number,
              is_background_out => pixel_is_background_out,
              is_foreground_out => pixel_is_foreground_out,

              -- Get sprite collision info
              sprite_fg_map_final => vicii_sprite_bitmap_collision_map,
              sprite_map_final => vicii_sprite_sprite_collision_map,

              fastio_addr => fastio_addr,
              fastio_write => fastio_write,
              fastio_wdata => fastio_wdata
              );


  chipram_address <= next_ramaddress when safe_to_integer(next_ramaddress) < chipram_size else to_unsigned(0,20);
  ramdata <= chipram_datain;

  process(cpuclock,fastio_addr,fastio_read,chardata,
          sprite_x,sprite_y,vicii_sprite_xmsbs,ycounter,extended_background_mode,
          text_mode,blank,twentyfourlines,vicii_y_smoothscroll,displayy,
          vicii_sprite_enables,multicolour_mode,thirtyeightcolumns,
          vicii_x_smoothscroll,vicii_sprite_y_expand,screen_ram_base,
          character_set_address,irq_collisionspritebitmap,irq_collisionspritesprite,
          irq_raster,mask_collisionspritebitmap,mask_collisionspritesprite,
          mask_raster,vicii_sprite_priority_bits,vicii_sprite_multicolour_bits,
          vicii_sprite_sprite_collisions,vicii_sprite_bitmap_collisions,
          border_colour,screen_colour,multi1_colour,multi2_colour,multi3_colour,
          border_x_left,border_x_right,border_y_top,border_y_bottom,
          x_chargen_start,y_chargen_start,fullcolour_8bitchars,
          fullcolour_extendedchars,sixteenbit_charset,
          cycles_to_next_card,xfrontporch,xbackporch,chargen_active,inborder,
          irq_drive,vicii_sprite_x_expand,sprite_multi0_colour,
          sprite_multi1_colour,sprite_colours,colourram_at_dc00_internal,
          viciii_extended_attributes,virtual_row_width,chargen_x_scale,
          chargen_y_scale,xcounter,chargen_active_soon,card_number,
          colour_ram_base,vicii_sprite_pointer_address,palette_bank_fastio,
          debug_cycles_to_next_card,
          debug_chargen_active,debug_raster_fetch_state,debug_charaddress,
          debug_charrow,palette_fastio_rdata,palette_bank_chargen,
          debug_chargen_active_soon,palette_bank_sprites,
          vicii_ycounter,reg_rom_e000,reg_rom_c000,
          reg_rom_a000,reg_c65_charset,reg_rom_8000,reg_palrom,
          reg_h640,reg_h1280,reg_v400,reg_interlace,xcounter_drive,ycounter_drive,
          horizontal_filter,xfrontporch_drive,chargen_active_drive,
          chargen_active_soon_drive,card_number_drive,
          bitplanes_x_start,bitplanes_y_start,dat_y,dat_x,dat_bitplane_offset,
          bitplane_addresses,vicii_2mhz_internal,viciii_fast_internal,
          bitplane_mode,bitplane_enables,bitplane_addresses,bitplane_complements,
          sprite_bitplane_enables,sprite_horizontal_tile_enables,compositer_enable,
          viciv_fast_internal,pal_simulate,sprite_extended_height_enables,
          sprite_extended_height_size,sprite_extended_width_enables,
          chargen_x_scale_drive,single_side_border,
          sprite_first_x,sprite_sixteen_colour_enables,
          vicii_ntsc,vicii_first_raster,
          palette_bank_chargen_alt,bitplane_sixteen_colour_mode_flags,
          vicii_ycounter_scale_minus_zero,
          hsync_polarity_internal,vsync_polarity_internal,
          vicii_ycounter_minus_one,lightpen_x_latch,lightpen_y_latch,irq_rasterx,irq_lightpen,
          mask_rasterx,mask_lightpen,no_raster_buffer_delay,raster_buffer_double_line,
          vicii_is_raster_source,shadow_mask_enable,sprite_h640,vicii_hot_regs_enable,
          display_row_width,sprite_h640_msbs,glyphs_from_hyperram,fullcolour_mcm,
          reg_xcounter_delay,show_render_activity,test_pattern_enable,vga60_select_internal,
          sprite_y_adjust,reg_alpha_delay,sprite_alpha_blend_value,sprite_alpha_blend_enables,
          sprite_v400s,sprite_v400_msbs,sprite_v400_super_msbs,vicii_raster_compare,
          sprite_continuous_pointer_monitoring,display_row_count,bitplane_bank_select,
          hypervisor_mode,debug_channel_select,hyper_data_counter,debug_pixel_red,
          debug_pixel_green,debug_pixel_blue,debug_x,debug_y,bug_compat_mode,
          reg_mono,upscale_enable_int,enable_raster_delay,reg_char_y16
          ) is
    variable bitplane_number : integer;

    procedure viciv_calculate_modeline_dimensions is
      constant w : integer := 400; -- was 320
    begin

      -- Display is a fixed 600 pixels high, so set Y scaling appropriately
      chargen_y_scale_200 <= to_unsigned(2,8);
      chargen_y_scale_400 <= to_unsigned(1,8);
      text_height_200 <= 400;
      text_height_400 <= 400;

      -- Calculate height of top borders
      top_borders_height_200 <= to_unsigned(safe_to_integer(display_height)
                                            - text_height_200,12);
      single_top_border_200(10 downto 0) <= top_borders_height_200(11 downto 1);
      single_top_border_200(11) <= '0';
      top_borders_height_400 <= to_unsigned(safe_to_integer(display_height)
                                            - text_height_400,12);
      single_top_border_400(10 downto 0) <= top_borders_height_400(11 downto 1);
      single_top_border_400(11) <= '0';
    end procedure;
    procedure viciv_interpret_legacy_mode_registers is
    begin
      -- set x_chargen
      report "LEGACY register update";
      if reg_h640='0' then
        x_chargen_start
          <= to_unsigned(safe_to_integer(frame_h_front)
                          +safe_to_integer(single_side_border)
                          -- VIC-II smooth scrolling is based on H320/400 and real
                          -- pixels are H640/800, so add double
                          +safe_to_integer(vicii_x_smoothscroll)
                          +safe_to_integer(vicii_x_smoothscroll)
                          ,14);
      else
        x_chargen_start
          <= to_unsigned(safe_to_integer(frame_h_front)
                          +safe_to_integer(single_side_border)
                          -- VIC-II smooth scrolling is based on H320/400 and real
                          -- pixels are H640/800, so add double
                          +safe_to_integer(vicii_x_smoothscroll)
                          +safe_to_integer(vicii_x_smoothscroll)
                          -bug_compat_vic_iii_d016_delta
                          ,14);
      end if;

      if reg_h640='0' then
        -- 40 column mode
        virtual_row_width <= to_unsigned(40,16);
        display_row_width <= to_unsigned(40,10);
      elsif reg_h640='1' then
        -- 80 column mode
        virtual_row_width <= to_unsigned(80,16);
        display_row_width <= to_unsigned(80,10);
      end if;

      if reg_v400='0' then
        display_row_count <= to_unsigned(25-1,8);
        chargen_y_scale <= to_unsigned(safe_to_integer(chargen_y_scale_200)-1,8);
        -- set vertical borders based on twentyfourlines
        if twentyfourlines='0' then
          border_y_top <= to_unsigned(
            raster_correction+
            safe_to_integer(single_top_border_200)-safe_to_integer(vicii_first_raster)*2,12);
          border_y_bottom <= to_unsigned(
            raster_correction+
            safe_to_integer(single_top_border_200)-safe_to_integer(vicii_first_raster)*2+
            text_height_200,12);
        else
          border_y_top <= to_unsigned(raster_correction
                                      +safe_to_integer(single_top_border_200)
                                      -safe_to_integer(vicii_first_raster)*2
                                      +(4*2),12);
          border_y_bottom <= to_unsigned(raster_correction
                                         +safe_to_integer(single_top_border_200)
                                         -safe_to_integer(vicii_first_raster)*2
                                         +text_height_200
                                         -(4*2),12);
        end if;
        -- set y_chargen_start based on twentyfourlines
        report "XXX vicii_y_smoothscroll = " & to_string(std_logic_vector(vicii_y_smoothscroll));
        report "XXX raster_correction = " & integer'image(raster_correction);
        report "XXX single_top_border_200 = " & integer'image(safe_to_integer(single_top_border_200));
        report "XXX vicii_first_raster = " & integer'image(safe_to_integer(vicii_first_raster));
        y_chargen_start <= unsigned(to_signed(raster_correction
                                              +safe_to_integer(single_top_border_200)
                                              -safe_to_integer(vicii_first_raster)*2
                                              -(3*2)
                                              -- Display is always V400/600, so pixels
                                              -- are double height
                                              +safe_to_integer(vicii_y_smoothscroll)
                                              +safe_to_integer(vicii_y_smoothscroll)
                                              ,12));

      else
        -- V400 mode : as above, but with the different constants
        display_row_count <= to_unsigned(50-1,8);
        chargen_y_scale <= to_unsigned(safe_to_integer(chargen_y_scale_400)-1,8);
        -- set vertical borders based on twentyfourlines
        if twentyfourlines='0' then
          border_y_top <= to_unsigned(
            raster_correction+
            safe_to_integer(single_top_border_400)
            -safe_to_integer(vicii_first_raster)*2,12);
          border_y_bottom <= to_unsigned(
            raster_correction+
            safe_to_integer(single_top_border_400)-safe_to_integer(vicii_first_raster)*2+
            text_height_400,12);
        else
          border_y_top <= to_unsigned(raster_correction
                                      +safe_to_integer(single_top_border_400)
                                      -safe_to_integer(vicii_first_raster)*2
                                      +(4*2),12);
          border_y_bottom <= to_unsigned(raster_correction
                                      +safe_to_integer(single_top_border_400)
                                      -safe_to_integer(vicii_first_raster)*2
                                      +text_height_400
                                      -(4*2),12);
     end if;
        -- set y_chargen_start based on twentyfourlines
        y_chargen_start <= to_unsigned(raster_correction
                                       +safe_to_integer(single_top_border_400)
                                       -safe_to_integer(vicii_first_raster)*2
                                       -(3*2)
                                       -- Screen is always V400/600, so pixels
                                       -- are 2 physical pixels high
                                       +safe_to_integer(vicii_y_smoothscroll)
                                       +safe_to_integer(vicii_y_smoothscroll)
                                       ,12);
      end if;

      screen_ram_base(27 downto 16) <= (others => '0');
      if reg_h640='1' then
        screen_ram_base(13 downto 11) <= reg_d018_screen_addr(3 downto 1);
        screen_ram_base(10 downto 0) <= (others => '0');
      else
        screen_ram_base(13 downto 10) <= reg_d018_screen_addr;
        screen_ram_base(9 downto 0) <= (others => '0');
      end if;

      -- Sprites fetch from screen ram base + $3F8 (or +$7F8 in VIC-III 80
      -- column mode).
      -- In 80 column mode the screen base must be on a 2K boundary on the
      -- C65, which changes the interpretation of the screen_ram_base.
      -- Note that our interpretation of V400 to double the number of text
      -- rows breaks strict C65 compatibility.
      vicii_sprite_pointer_address(27 downto 16) <= (others => '0');
      -- NOTE: Bits 14 and 15 are still set only by writing to $DD00
      -- or the VIC-IV registers that modify this.
      vicii_sprite_pointer_address(13 downto 10)
        <= reg_d018_screen_addr;
      if reg_h640='1' or reg_v400='1' then
        vicii_sprite_pointer_address(10) <= '1';
      end if;
      vicii_sprite_pointer_address(9 downto 0) <= "1111111000";

      -- Apply VIC-II banks
      screen_ram_base(15 downto 14) <= not last_dd00_bits;
      vicii_sprite_pointer_address(15 downto 14) <= not last_dd00_bits;
      character_set_address(15 downto 14) <= not last_dd00_bits;
      -- NOTE: We DONT reset the character set address with a legacy write,
      -- even if HOTREG are enabled. This makes it easier to use alternate
      -- character sets, and full-colour text mode upgrading of old programmes.

      -- All VIC-II/VIC-III compatibility modes use the first part of the
      -- colour RAM.
      colour_ram_base <= (others => '0');

      -- NOTE: We DONT reset the character set address with a legacy write.
      -- This makes it easier to use alternate character sets, and full-colour
      -- text mode upgrading of old programmes.

    end procedure viciv_interpret_legacy_mode_registers;
    procedure viciv_update_side_border_dimensions is
    begin
      -- set horizontal borders based on 40/38 columns
      report "LEGACY register update";
      if thirtyeightcolumns='0' then
        if reg_h640='0' then
          border_x_left <= to_unsigned(safe_to_integer(frame_h_front)+safe_to_integer(single_side_border),14);
          border_x_right <= to_unsigned(safe_to_integer(frame_h_front)+safe_to_integer(display_width)
                                        -safe_to_integer(single_side_border),14);
        else
          border_x_left <= to_unsigned(safe_to_integer(frame_h_front)+safe_to_integer(single_side_border),14);
          border_x_right <= to_unsigned(safe_to_integer(frame_h_front)+safe_to_integer(display_width)
                                        -safe_to_integer(single_side_border),14);
        end if;
      else
        if reg_h640='0' then
          border_x_left <= to_unsigned(safe_to_integer(frame_h_front)+safe_to_integer(single_side_border)
                                       +(7*2),14);
          border_x_right <= to_unsigned(safe_to_integer(frame_h_front)+safe_to_integer(display_width)
                                        -safe_to_integer(single_side_border)
                                        -(9*2),14);
        else
          border_x_left <= to_unsigned(safe_to_integer(frame_h_front)+safe_to_integer(single_side_border)
                                       +(7*2),14);
          border_x_right <= to_unsigned(safe_to_integer(frame_h_front)+safe_to_integer(display_width)
                                        -safe_to_integer(single_side_border)
                                        -(9*2),14);
        end if;
      end if;
    end procedure viciv_update_side_border_dimensions;


    variable register_bank : unsigned(7 downto 0) := to_unsigned(0,7+1);
    variable register_page : unsigned(3 downto 0) := to_unsigned(0,3+1);
    variable register_num : unsigned(7 downto 0) := to_unsigned(0,7+1);
    variable register_number : unsigned(11 downto 0) := to_unsigned(0,11+1);
  begin
    fastio_rdata <= (others => 'Z');

    chargen_x_scale_drive <= chargen_x_scale;

    bitplanes_x_start_drive <= bitplanes_x_start;
    bitplanes_y_start_drive <= bitplanes_y_start;

    -- Calculate DAT bitplane offset
    -- XXX currently ignores V400 mode
    if reg_v400 = '0' or reg_interlace = '0' then
      if reg_h640 = '0' then
        dat_bitplane_offset <=
          ("00" & dat_y(8 downto 3) & "00000000")
          + ("0000" & dat_y(8 downto 3) & "000000")
          + ("0000000000000" & dat_y(2 downto 0))
          + ("000000" & dat_x & "000");
      else
        dat_bitplane_offset <=
          ("0" & dat_y(8 downto 3) & "000000000")
          + ("000" & dat_y(8 downto 3) & "0000000")
          + ("0000000000000" & dat_y(2 downto 0))
          + ("000000" & dat_x & "000");
      end if;
      dat_even <= '1';
    else
      -- For V400 + Interlace, we need to pick even/odd frame
      -- This must mean that the bottom bit of dat_y indicates
      -- the odd/even frame, and all the other bits of dat_y are
      -- shifted right a bit to exclude it.
      if reg_h640 = '0' then
        dat_bitplane_offset <=
          ("000" & dat_y(8 downto 4) & "00000000")
          + ("0000" & dat_y(8 downto 3) & "000000")
          + ("0000000000000" & dat_y(3 downto 1))
          + ("000000" & dat_x & "000");
      else
        dat_bitplane_offset <=
          ("00" & dat_y(8 downto 4) & "000000000")
          + ("000" & dat_y(8 downto 3) & "0000000")
          + ("0000000000000" & dat_y(3 downto 1))
          + ("000000" & dat_x & "000");
      end if;
      dat_even <= not dat_y(0);
    end if;
    -- Export this and bitplane addresses to the CPU
    dat_offset <= dat_bitplane_offset;
    dat_bitplane_addresses <= bitplane_addresses;

    if true then
      -- Calculate register number asynchronously
      register_number := x"FFF";
      if fastio_addr(19) = '0' or fastio_addr(19) = '1' then
        register_bank := unsigned(fastio_addr(19 downto 12));
        register_page := unsigned(fastio_addr(11 downto 8));
        register_num := unsigned(fastio_addr(7 downto 0));
      else
        -- Give values when inputs are bad to supress warnings cluttering output
        -- when simulating
        register_bank := x"FF";
        register_page := x"F";
        register_num := x"FF";
      end if;

      if register_bank=x"D0" and register_page<4 then
        -- First 1KB of normal C64 IO space maps to r$0 - r$3F
        register_number(5 downto 0) := unsigned(fastio_addr(5 downto 0));
        register_number(11 downto 6) := (others => '0');
        if fastio_addr(11 downto 0) = x"030" then
          -- C128 $D030
          register_number := x"0FF"; -- = 255
        elsif (fastio_addr(11 downto 4) = x"03")
          or (fastio_addr(11 downto 4) = x"07")
        then
          -- $D030-$D03F are otherwise unmapped in VIC-II mode, so that the C65
          -- VIC-III registers there cannot be messed with.
          -- So we set it to a non-existent register
          -- We also have to do the same for $D070-$D07F
          register_number := x"0FE";
        end if;
        report "IO access resolves to video register number "
          & integer'image(safe_to_integer(register_number)) severity note;
      elsif (register_bank = x"D1" or register_bank = x"D2"or register_bank = x"D3") and register_page<4 then
        register_number(11 downto 10) := "00";
        register_number(9 downto 8) := register_page(1 downto 0);
        register_number(7 downto 0) := register_num;
        report "IO access resolves to video register number "
          & integer'image(safe_to_integer(register_number)) severity note;
      end if;

      -- $D800 - $DBFF colour RAM access.
      -- This is a bit fun, because colour RAM is mapped in 3 separate places:
      --   $D800 - $DBFF in the usual IO pages.
      --   $DC00 - $DFFF in the enhanced IO pages when the correct VIC-III
      --   register is set.
      --   $FF80000-$FF8FFFF - All 64KB of colour RAM
      -- The colour RAM has to be dual-port since the video controller needs to
      -- access it as well, so all these have to be mapped on a single port.
      colour_ram_fastio_address <= (others => '1');
      if register_bank = x"D0" or register_bank = x"D1"
        or register_bank = x"D2" or register_Bank=x"D3" then
        if register_page>=8 and register_page<12 then
                                        -- colour ram read $D800 - $DBFF
          colour_ram_fastio_address <= unsigned("000000" & fastio_addr(9 downto 0));
        elsif register_page>=12 and register_page<=15 then
                                        -- colour ram read $DC00 - $DFFF
          colour_ram_fastio_address <= unsigned("000001" & fastio_addr(9 downto 0));
        else
          colour_ram_fastio_address <= (others => '0');
        end if;
      elsif register_bank(7 downto 4)=x"8" then
                                        -- colour RAM all 64KB
        colour_ram_fastio_address <= unsigned(fastio_addr(15 downto 0));
      end if;

      if fastio_read='0' then
        fastio_rdata <= (others => 'Z');
      else
                                        -- report "read from fastio detect in video controller. " &
                                        --  "register number = " & integer'image(safe_to_integer(register_number)) &
                                        --  ", fastio_addr = " & to_hstring(fastio_addr) &
                                        --  ", register_bank = " & to_hstring(register_bank) &
                                        --  ", register_page = " & to_hstring(register_page)
                                        --   severity note;
        if register_number>=0 and register_number<8 then
                                        -- compatibility sprite coordinates
          fastio_rdata <= std_logic_vector(sprite_x(safe_to_integer(register_num(2 downto 0))));
        elsif register_number<16 then
                                        -- compatibility sprite coordinates
          fastio_rdata <= std_logic_vector(sprite_y(safe_to_integer(register_num(2 downto 0))));
        elsif register_number=16 then
                                        -- compatibility sprite x position MSB
          fastio_rdata <= vicii_sprite_xmsbs;
        elsif register_number=17 then             -- $D011
          fastio_rdata(7) <= vicii_ycounter_minus_one(8);  -- MSB of raster
          fastio_rdata(6) <= extended_background_mode;
          fastio_rdata(5) <= not text_mode;
          fastio_rdata(4) <= not blank;
          fastio_rdata(3) <= not twentyfourlines;
          fastio_rdata(2 downto 0) <= std_logic_vector(vicii_y_smoothscroll);
        elsif register_number=18 then          -- $D012 current raster low 8 bits
          fastio_rdata <= std_logic_vector(vicii_ycounter_minus_one(7 downto 0));
        elsif register_number=19 then          -- $D013 lightpen X (coarse rasterX)
          fastio_rdata <= std_logic_vector(lightpen_x_latch);
        elsif register_number=20 then          -- $D014 lightpen Y (coarse rasterY)
          fastio_rdata <= std_logic_vector(lightpen_y_latch);
        elsif register_number=21 then          -- $D015 compatibility sprite enable
          fastio_rdata <= vicii_sprite_enables;
        elsif register_number=22 then          -- $D016
          fastio_rdata(7) <= '1';
          fastio_rdata(6) <= '1';
          fastio_rdata(5) <= '0';       -- no reset support, since no badlines
          fastio_rdata(4) <= multicolour_mode;
          fastio_rdata(3) <= not thirtyeightcolumns;
          fastio_rdata(2 downto 0) <= std_logic_vector(vicii_x_smoothscroll);
        elsif register_number=23 then          -- $D017 compatibility sprite Y
                                               -- expand enable
          fastio_rdata <= vicii_sprite_y_expand;
        elsif register_number=24 then          -- $D018 compatibility RAM addresses
          fastio_rdata <=
            std_logic_vector(screen_ram_base(13 downto 10))
            & std_logic_vector(character_set_address(13 downto 10));
        elsif register_number=25 then          -- $D019 compatibility IRQ bits
          fastio_rdata(7) <= not irq_drive;
          fastio_rdata(6) <= '1';       -- NC
          fastio_rdata(5) <= '1';       -- NC
          fastio_rdata(4) <= irq_rasterx;
          fastio_rdata(3) <= irq_lightpen;
          fastio_rdata(2) <= irq_collisionspritesprite;
          fastio_rdata(1) <= irq_collisionspritebitmap;
          fastio_rdata(0) <= irq_raster;
        elsif register_number=26 then          -- $D01A compatibility IRQ mask bits
          fastio_rdata(7) <= '1';       -- NC
          fastio_rdata(6) <= '1';       -- NC
          fastio_rdata(5) <= '1';       -- NC
          fastio_rdata(4) <= mask_rasterx;
          fastio_rdata(3) <= mask_lightpen;
          fastio_rdata(2) <= mask_collisionspritesprite;
          fastio_rdata(1) <= mask_collisionspritebitmap;
          fastio_rdata(0) <= mask_raster;
        elsif register_number=27 then          -- $D01B sprite background priority
          fastio_rdata <= vicii_sprite_priority_bits;
        elsif register_number=28 then          -- $D01C sprite multicolour
          fastio_rdata <= vicii_sprite_multicolour_bits;
        elsif register_number=29 then          -- $D01D compatibility sprite enable
          fastio_rdata <= vicii_sprite_x_expand;
        elsif register_number=30 then          -- $D01E sprite/sprite collissions
          fastio_rdata <= vicii_sprite_sprite_collisions;
        elsif register_number=31 then          -- $D01F sprite/foreground collissions
          fastio_rdata <= vicii_sprite_bitmap_collisions;
        elsif register_number=32 then
          fastio_rdata <= std_logic_vector(border_colour);
        elsif register_number=33 then
          -- Match C64's VIC-II behaviour of showing only the lower 4 bits of
          -- screen colour, with the upper four bits = $F when in VIC-II IO context
          fastio_rdata(3 downto 0) <= std_logic_vector(screen_colour(3 downto 0));
          if register_bank /= x"D0" then
            fastio_rdata(7 downto 4) <= std_logic_vector(screen_colour(7 downto 4));
          else
            fastio_rdata(7 downto 4) <= x"f";
          end if;
        elsif register_number=34 then
          fastio_rdata <= std_logic_vector(multi1_colour);
        elsif register_number=35 then
          fastio_rdata <= std_logic_vector(multi2_colour);
        elsif register_number=36 then
          fastio_rdata <= std_logic_vector(multi3_colour);
        elsif register_number=37 then
          fastio_rdata <= std_logic_vector(sprite_multi0_colour);
        elsif register_number=38 then
          fastio_rdata <= std_logic_vector(sprite_multi1_colour);
        elsif register_number>=39 and register_number<=46 then
          fastio_rdata <= std_logic_vector(sprite_colours(safe_to_integer(register_number)-39));
        elsif register_number=255 then
          -- C128 $D030 emulation (2MHz mode only)
          fastio_rdata(7 downto 1) <= (others => '0');
          fastio_rdata(0) <= vicii_2mhz_internal;
        elsif register_number=48 then
          -- C65 $D030 emulation
          fastio_rdata <=
            reg_rom_e000        -- ROM @ E000
            & reg_c65_charset   -- character set select (D000 vs 9000)
            & reg_rom_c000      -- ROM @ C000
            & reg_rom_a000      -- ROM @ A000
            & reg_rom_8000      -- ROM @ 8000
            & reg_palrom        -- First sixteen palette entries are fixed
            -- (fetch from palette bank 3 on VIC-IV)
            & "0"                         -- External sync
            & colourram_at_dc00_internal;  -- 2KB colour RAM
        elsif register_number=49 then
          -- Can emulate VIC-III H640, V400 and H1280 by adjusting x and y scale
          -- registers
          fastio_rdata <=
            reg_h640                           -- H640
            & viciii_fast_internal             -- FAST
            & viciii_extended_attributes  -- ATTR (8bit colour RAM features)
            & bitplane_mode                    -- BPM
            & reg_v400                         -- V400
            & reg_h1280                         -- H1280
            & reg_mono                         -- Mono mode for composite output
            & reg_interlace;                   -- INT(erlaced?)


                                        -- Skip $D02F - $D03F to avoid real C65/C128 programs trying to
                                        -- fiddle with registers in this range.
                                        --  For more C65 register info, see:
                                        -- http://www.zimmers.net/cbmpics/cbm/c65/c65manual.txt
        -- @IO:C65 $D032 VIC-III:BPENABLE Bitplane enable bits
        elsif register_number=50 then
          fastio_rdata <= bitplane_enables;
        -- @IO:C65 $D033 - Bitplane 0 address
        -- @IO:C65 $D034 - Bitplane 1 address
        -- @IO:C65 $D035 - Bitplane 2 address
        -- @IO:C65 $D036 - Bitplane 3 address
        -- @IO:C65 $D037 - Bitplane 4 address
        -- @IO:C65 $D038 - Bitplane 5 address
        -- @IO:C65 $D039 - Bitplane 6 address
        -- @IO:C65 $D03A - Bitplane 7 address
        elsif register_number >= 51 and register_number <= 58 then
          -- @IO:C65 $D033-$D03A - VIC-III Bitplane addresses
          bitplane_number := safe_to_integer(register_number(3 downto 0)) - 3;
          fastio_rdata <= std_logic_vector(bitplane_addresses(bitplane_number));
        -- @IO:C65 $D03B - Set bits to NOT bitplane contents
        elsif register_number=59 then
          fastio_rdata <= bitplane_complements;
        -- @IO:C65 $D03C - Bitplane X
        elsif register_number=60 then
          fastio_rdata(6 downto 0) <= std_logic_vector(dat_x(6 downto 0));
          fastio_rdata(7) <= dat_y(8);
        -- @IO:C65 $D03D - Bitplane Y
        elsif register_number=61 then
          fastio_rdata <= std_logic_vector(dat_y(7 downto 0));
        -- @IO:C65 $D03E - Horizontal position (screen verniers?)
        elsif register_number=62 then
          fastio_rdata <= std_logic_vector(bitplanes_x_start);
        -- @IO:C65 $D03F - Vertical position (screen verniers?)
        elsif register_number=63 then
          fastio_rdata <= std_logic_vector(bitplanes_y_start);

        -- $D040 - $D047 DAT memory ports for bitplanes 0 through 7
        -- XXX: Deprecated old addresses for some VIC-IV features currently occupy
        -- these addresses
        elsif register_number=64 then
          -- Unimplemented VIC-III DAC
          fastio_rdata <= x"FF";
        elsif register_number=65 then
          -- Unimplemented VIC-III DAC
          fastio_rdata <= x"FF";
        elsif register_number=66 then
          -- Unimplemented VIC-III DAC
          fastio_rdata <= x"FF";
        elsif register_number=67 then
          -- Unimplemented VIC-III DAC
          fastio_rdata <= x"FF";
        elsif register_number=68 then
          -- Unimplemented VIC-III DAC
          fastio_rdata <= x"FF";
        elsif register_number=69 then
          -- Unimplemented VIC-III DAC
          fastio_rdata <= x"FF";
        elsif register_number=70 then
          -- Unimplemented VIC-III DAC
          fastio_rdata <= x"FF";
        elsif register_number=71 then
          -- Unimplemented VIC-III DAC
          fastio_rdata <= x"FF";
        elsif register_number=72 then
          fastio_rdata <= std_logic_vector(border_y_top(7 downto 0));
        elsif register_number=73 then
          fastio_rdata(7 downto 4) <= sprite_bitplane_enables(3 downto 0);
          fastio_rdata(3 downto 0) <= std_logic_vector(border_y_top(11 downto 8));
        elsif register_number=74 then
          fastio_rdata <= std_logic_vector(border_y_bottom(7 downto 0));
        elsif register_number=75 then
          fastio_rdata(7 downto 4) <= sprite_bitplane_enables(7 downto 4);
          fastio_rdata(3 downto 0) <= std_logic_vector(border_y_bottom(11 downto 8));
        elsif register_number=76 then
          fastio_rdata <= std_logic_vector(x_chargen_start(7 downto 0));
        elsif register_number=77 then
          fastio_rdata(7 downto 4) <= sprite_horizontal_tile_enables(3 downto 0);
          fastio_rdata(3 downto 0) <= std_logic_vector(x_chargen_start(11 downto 8));
        elsif register_number=78 then
          fastio_rdata <= std_logic_vector(y_chargen_start(7 downto 0));
        elsif register_number=79 then
          fastio_rdata(7 downto 4) <= sprite_horizontal_tile_enables(7 downto 4);
          fastio_rdata(3 downto 0) <= std_logic_vector(y_chargen_start(11 downto 8));
        elsif register_number=80 then
          fastio_rdata <= std_logic_vector(xcounter_drive(7 downto 0));
        elsif register_number=81 then
          fastio_rdata(7) <= no_raster_buffer_delay;
          fastio_rdata(6) <= raster_buffer_double_line;
          fastio_rdata(5 downto 0) <= std_logic_vector(xcounter_drive(13 downto 8));
        elsif register_number=82 then
          -- Read physical raster LSB
          fastio_rdata <= std_logic_vector(ycounter_drive(7 downto 0));
        elsif register_number=83 then
          -- Read physical raster MSB and raster compare source flag
          fastio_rdata(7) <= vicii_is_raster_source;
          fastio_rdata(6) <= shadow_mask_enable;
          fastio_rdata(5) <= upscale_enable_int;
          fastio_rdata(4) <= bold_is_alt;
          fastio_rdata(3 downto 0) <= std_logic_vector(ycounter_drive(11 downto 8));
        elsif register_number=84 then
                                        -- $D054 (53332) - New mode control register
          fastio_rdata(7) <= compositer_enable;
          fastio_rdata(6) <= viciv_fast_internal;
          fastio_rdata(5) <= pal_simulate;
          fastio_rdata(4) <= sprite_h640;
          fastio_rdata(3) <= horizontal_filter;
          fastio_rdata(2) <= fullcolour_extendedchars;
          fastio_rdata(1) <= fullcolour_8bitchars;
          fastio_rdata(0) <= sixteenbit_charset;
        elsif register_number=85 then
          fastio_rdata <= sprite_extended_height_enables;
        elsif register_number=86 then
          fastio_rdata <= std_logic_vector(sprite_extended_height_size);
        elsif register_number=87 then
          fastio_rdata <= sprite_extended_width_enables;
        elsif register_number=88 then
          fastio_rdata <= std_logic_vector(virtual_row_width(7 downto 0));
        elsif register_number=89 then
          fastio_rdata <= std_logic_vector(virtual_row_width(15 downto 8));
        elsif register_number=90 then
          fastio_rdata <= std_logic_vector(chargen_x_scale_drive);
        elsif register_number=91 then
          fastio_rdata <= std_logic_vector(chargen_y_scale);
        elsif register_number=92 then
          fastio_rdata <= std_logic_vector(single_side_border(7 downto 0));
        elsif register_number=93 then
          fastio_rdata(7) <= vicii_hot_regs_enable;
          fastio_rdata(6) <= enable_raster_delay;
          fastio_rdata(5 downto 0) <= std_logic_vector(single_side_border(13 downto 8));
        elsif register_number=94 then
          fastio_rdata(7 downto 0)  <= std_logic_vector(display_row_width(7 downto 0));
        elsif register_number=95 then
          fastio_rdata <= std_logic_vector(sprite_h640_msbs);
        elsif register_number=96 then
          fastio_rdata <= std_logic_vector(screen_ram_base(7 downto 0));
        elsif register_number=97 then
          fastio_rdata <= std_logic_vector(screen_ram_base(15 downto 8));
        elsif register_number=98 then
          fastio_rdata <= std_logic_vector(screen_ram_base(23 downto 16));
        elsif register_number=99 then
          fastio_rdata(7) <= glyphs_from_hyperram;
          fastio_rdata(6) <= fullcolour_mcm;
          fastio_rdata(5 downto 4) <= std_logic_vector(display_row_width(9 downto 8));
          fastio_rdata(3 downto 0) <= std_logic_vector(screen_ram_base(27 downto 24));
        elsif register_number=100 then
          fastio_rdata <= std_logic_vector(colour_ram_base(7 downto 0));
        elsif register_number=101 then
          fastio_rdata <= std_logic_vector(colour_ram_base(15 downto 8));
        elsif register_number=102 then -- $D3066 xcounter_pipeline_delayed delay
          fastio_rdata(5 downto 0) <= std_logic_vector(to_unsigned(reg_xcounter_delay,6));
          fastio_rdata(6) <= show_render_activity;
          fastio_rdata(7) <= test_pattern_enable;
        elsif register_number=103 then  -- $D3067
          fastio_rdata <= std_logic_vector(sprite_first_x(7 downto 0));
        elsif register_number=104 then  -- $D068
          fastio_rdata <= std_logic_vector(character_set_address(7 downto 0));
        elsif register_number=105 then
          fastio_rdata <= std_logic_vector(character_set_address(15 downto 8));
        elsif register_number=106 then
          fastio_rdata <= std_logic_vector(character_set_address(23 downto 16));
        elsif register_number=107 then
          fastio_rdata <= std_logic_vector(sprite_sixteen_colour_enables);
        elsif register_number=108 then
          fastio_rdata <= std_logic_vector(vicii_sprite_pointer_address(7 downto 0));
        elsif register_number=109 then
          fastio_rdata <= std_logic_vector(vicii_sprite_pointer_address(15 downto 8));
        elsif register_number=110 then
          fastio_rdata <= std_logic_vector(vicii_sprite_pointer_address(23 downto 16));
        elsif register_number=111 then
          fastio_rdata(7) <= vicii_ntsc;
          fastio_rdata(6) <= vga60_select_internal;
          fastio_rdata(5 downto 0) <= std_logic_vector(vicii_first_raster(5 downto 0));
        elsif register_number=112 then -- $D3070
          fastio_rdata <= palette_bank_fastio & palette_bank_chargen & palette_bank_sprites & palette_bank_chargen_alt;
        elsif register_number=113 then -- $D3071
          fastio_rdata <= bitplane_sixteen_colour_mode_flags;
        elsif register_number=114 then -- $D3072
          fastio_rdata(7 downto 0) <= std_logic_vector(sprite_y_adjust);
        elsif register_number=115 then -- $D3073
          fastio_rdata(3 downto 0) <= std_logic_vector(reg_alpha_delay);
          fastio_rdata(7 downto 4) <= std_logic_vector(vicii_ycounter_scale_minus_zero(3 downto 0));
        elsif register_number=116 then  -- $D3074
          fastio_rdata <= sprite_alpha_blend_enables;
        elsif register_number=117 then  -- $D3075
          fastio_rdata(7 downto 0) <= std_logic_vector(sprite_alpha_blend_value);
        elsif register_number=118 then  -- $D3076 Sprite V400 enables
          fastio_rdata <= std_logic_vector(sprite_v400s);
        elsif register_number=119 then  -- $D3077 Sprite V400 Y position MSBs
	  fastio_rdata <= sprite_v400_msbs;
        elsif register_number=120 then  -- $D3078 Sprite V400 Y position super MSBs
	  fastio_rdata <= sprite_v400_super_msbs;
        elsif register_number=121 then  -- $D3079 Read raster compare LSB
          fastio_rdata <= std_logic_vector(vicii_raster_compare(7 downto 0));
        elsif register_number=122 then  -- $D307A Read raster compare MSB / raster compare source
          fastio_rdata(2 downto 0) <= std_logic_vector(vicii_raster_compare(10 downto 8));
          fastio_rdata(3) <= sprite_continuous_pointer_monitoring;
          fastio_rdata(4) <= reg_char_y16;
          fastio_rdata(5) <= not bug_compat_mode;
          fastio_rdata(6) <= '0';
	  fastio_rdata(7) <= vicii_is_raster_source;
        elsif register_number=123 then  -- $D307B
          fastio_rdata <= std_logic_vector(display_row_count(7 downto 0));
        elsif register_number=124 then  -- $D307C
          -- @IO:GS $D07C.3 RESERVED
          -- fastio_rdata(3 downto 0) <= x"F";
          fastio_rdata(2 downto 0) <= std_logic_vector(bitplane_bank_select);
          fastio_rdata(3) <= not rrb_wraparound_allowed;
          fastio_rdata(4) <= hsync_polarity_internal;
          fastio_rdata(5) <= vsync_polarity_internal;
          fastio_rdata(7 downto 6) <= "11";
        elsif register_number=125 then
          -- fastio_rdata <=
          --  std_logic_vector(to_unsigned(vic_paint_fsm'pos(debug_paint_fsm_state_drive2),8));
          -- fastio_rdata <= std_logic_vector(debug_charaddress_drive2(7 downto 0));
          -- fastio_rdata <= x"FF";
          -- XXX debug: $D07D shows current single top border height
--          fastio_rdata <= std_logic_vector(single_top_border_200(7 downto 0));
          if hypervisor_mode='0' then
            case debug_channel_select is
              when "00" => fastio_rdata <= std_logic_vector(hyper_data_counter(7 downto 0));
              when "01" => fastio_rdata <= std_logic_vector(debug_pixel_red);
              when "10" => fastio_rdata <= std_logic_vector(debug_pixel_green);
              when "11" => fastio_rdata <= std_logic_vector(debug_pixel_blue);
              when others => fastio_rdata <= std_logic_vector(debug_pixel_blue);
            end case;
          else
            -- In hypervisor mode, allow read-back of the debug crosshair positions
            -- so that when we freeze and resume, it isn't put into the wrong place
            fastio_rdata <= std_logic_vector(debug_x(7 downto 0));
          end if;
        elsif register_number=126 then
          -- fastio_rdata <= "0000"
          -- & std_logic_vector(debug_charaddress_drive2(11 downto 8));
--          fastio_rdata <= x"00";
--          fastio_rdata(0) <= external_frame_x_zero_latched;
--          fastio_rdata(1) <= external_pixel_strobe_log(0);
--          fastio_rdata(2) <= vga_in_frame;
--          fastio_rdata(3) <= indisplay_t3;
          if hypervisor_mode='0' then
            fastio_rdata <= std_logic_vector(hyper_data_counter(15 downto 8));
          else
            -- In hypervisor mode, allow read-back of the debug crosshair positions
            -- so that when we freeze and resume, it isn't put into the wrong place
            fastio_rdata <= std_logic_vector(debug_y(7 downto 0));
          end if;
        elsif register_number=127 then
          if hypervisor_mode='0' then
            fastio_rdata <= std_logic_vector(hyper_data_counter(23 downto 16));
          else
            -- In hypervisor mode, allow read-back of the debug crosshair positions
            -- so that when we freeze and resume, it isn't put into the wrong place
            fastio_rdata(3 downto 0) <= std_logic_vector(debug_x(11 downto 8));
            fastio_rdata(7 downto 4) <= std_logic_vector(debug_y(11 downto 8));
          end if;
        elsif register_number<256 then
                                        -- Fill in unused register space
          fastio_rdata <= (others => 'Z');
                                        -- C65 style palette registers
        elsif register_number>=256 and register_number<512 then
          -- red palette
          report "Outputting RED palette read value $" & to_hstring(palette_fastio_rdata(31 downto 24));
          palette_fastio_address <= palette_bank_fastio & std_logic_vector(register_number(7 downto 0));
          fastio_rdata <= palette_fastio_rdata(31 downto 24);
        elsif register_number>=512 and register_number<768 then
          -- green palette
          report "Outputting GREEN palette read value $" & to_hstring(palette_fastio_rdata(23 downto 16));
          palette_fastio_address <= palette_bank_fastio & std_logic_vector(register_number(7 downto 0));
          fastio_rdata <= palette_fastio_rdata(23 downto 16);
        elsif register_number>=768 and register_number<1024 then
          -- blue palette
          report "Outputting BLUE palette read value $" & to_hstring(palette_fastio_rdata(15 downto 8));
          palette_fastio_address <= palette_bank_fastio & std_logic_vector(register_number(7 downto 0));
          fastio_rdata <= palette_fastio_rdata(15 downto 8);
        else
          fastio_rdata <= (others => 'Z');
        end if;
      end if;
    end if;

    if rising_edge(cpuclock) then

      if hw_errata_level /= prev_hw_errata_level then
        prev_hw_errata_level <= hw_errata_level;

        -- Apply variable HW errata level settings
        -- HWERRATA:1 VIC-III D016 Delta
        if to_integer(hw_errata_level) > 0 then
          bug_compat_vic_iii_d016_delta <= 0;
          bug_compat_mode <= '0';
        else
          bug_compat_vic_iii_d016_delta <= 2;
          bug_compat_mode <= '1';
        end if;
      end if;

      upscale_enable <= upscale_enable_int;

      interlace_mode <= reg_interlace;
      mono_mode <= reg_mono;
      v400_mode <= reg_v400;

      last_dd00_bits <= dd00_bits;
      if last_dd00_bits /= dd00_bits then
        viciv_legacy_mode_registers_touched <= '1';
      end if;

      if reset='0' then
        -- Reset sprites to normal behaviour on reset
        sprite_horizontal_tile_enables <= (others => '0');
        sprite_v400s <= (others => '0');
        sprite_v400_super_msbs <= (others => '0');
        sprite_alpha_blend_enables <= (others => '0');
        sprite_bitplane_enables <= (others => '0');
        sprite_extended_width_enables <= (others => '0');
        sprite_extended_height_enables <= (others => '0');
        sprite_sixteen_colour_enables <= (others => '0');
        -- And raster re-write buffer delay also
        no_raster_buffer_delay <= '1';
        raster_buffer_double_line <= '0';
        reg_char_y16 <= '0';
        rrb_wraparound_allowed <= '1';
        rrb_overtime_allowed <= '1';
        bold_is_alt <= '0';        
      end if;

      -- Drive stage for data from hyper RAM and signals out to it
      hyper_data <= hyper_data_in;
      hyper_data_strobe <= hyper_data_strobe_in;
      hyper_addr <= hyper_addr_drive;
      hyper_request_toggle_drive2 <= hyper_request_toggle_drive;
      hyper_request_toggle_drive3 <= hyper_request_toggle_drive2;
      hyper_request_toggle <= hyper_request_toggle_drive3;

      if hyper_data_strobe = '1' then
        hyper_data_counter <= hyper_data_counter + 1;
      end if;

      if vicii_ntsc='1' then
        display_height <= display_height_ntsc;
      else
        display_height <= display_height_pal;
      end if;

      vicii_raster_out(8 downto 0) <= vicii_ycounter_driver;
      vicii_raster_out(11 downto 9) <= "000";

      hsync_polarity <= hsync_polarity_internal;
      vsync_polarity <= vsync_polarity_internal;

      vicii_ycounter_driver <= vicii_ycounter;
      -- We need a delayed version of the VICII ycounter to display in $D011/$D012,
      -- as raster interrupts actually happen one raster line later than expected,
      -- to offset the fact that we have a 1 raster line delay in output of the
      -- video pipeline.
      -- That is, we trigger the interrupt when the raster is actually being DISPLAYED,
      -- and make the contents of $D012/$D011 match this.
      if enable_raster_delay='1' then
        if vicii_ycounter_driver /= 0 then
          vicii_ycounter_minus_one <= vicii_ycounter_driver - 1;
        else
          vicii_ycounter_minus_one <= vicii_max_raster;
        end if;
      else
        vicii_ycounter_minus_one <= vicii_ycounter_driver;
      end if;

      viciv_calculate_modeline_dimensions;

      -- Set IO mode when CPU tells us to.  This is done when entering/exiting
      -- hypervisor mode.
      if iomode_set_toggle /= iomode_set_toggle_last then
        iomode_set_toggle_last <= iomode_set_toggle;
        viciii_iomode <= iomode_set;
      end if;

      viciv_fast <= viciv_fast_internal;
      viciii_fast <= viciii_fast_internal;
      vicii_2mhz <= not vicii_2mhz_internal;

      reset_drive <= reset;
      if reset_drive='0' then
        -- Disable HW errata on reset.
        hw_errata_disable_toggle <= not hw_errata_disable_toggle;

        -- Allow hyppo ROM to be visible on reset.
        rom_at_e000 <= '0';

        -- Enable VIC-II/III registers to force video mode settings when touched
        vicii_hot_regs_enable <= '1';

        -- Set CPU to 40.5MHz
        viciv_fast_internal <= '1';
        viciii_fast_internal <= '1';
        vicii_2mhz_internal <= '0';

        -- Clear all VIC-II/III/IV interrupts on reset
        mask_collisionspritebitmap <= '0';
        mask_collisionspritesprite <= '0';
        mask_raster <= '0';

      -- Also turn sprites off on reset
--        vicii_sprite_enables <= (others => '0');
      end if;

      report "drive led = " & std_logic'image(led)
        & ", drive motor= " & std_logic'image(motor) severity note;

      debug_chargen_active_drive2 <= debug_chargen_active_drive;
      debug_chargen_active_soon_drive2 <= debug_chargen_active_soon_drive;
      debug_raster_fetch_state_drive2 <= debug_raster_fetch_state_drive;
      debug_paint_fsm_state_drive2 <= debug_paint_fsm_state_drive;
      debug_charrow_drive2 <= debug_charrow_drive;
      debug_charaddress_drive2 <= debug_charaddress_drive;
      debug_character_data_from_rom_drive2 <= debug_character_data_from_rom_drive;
      debug_screen_ram_buffer_address_drive2 <= debug_screen_ram_buffer_address_drive;
      debug_raster_buffer_read_address_drive2 <= debug_raster_buffer_read_address_drive;
      debug_raster_buffer_write_address_drive2 <= debug_raster_buffer_write_address_drive;

      chargen_active_soon_drive <= chargen_active_soon;
      cycles_to_next_card_drive <= cycles_to_next_card;
      chargen_active_drive <= chargen_active;
      xcounter_drive <= xcounter;
      ycounter_drive <= ycounter;
      xfrontporch_drive <= xfrontporch;

      if viciv_legacy_mode_registers_touched='1' and vicii_hot_regs_enable='1' then
        viciv_interpret_legacy_mode_registers;
        viciv_update_side_border_dimensions;
        viciv_legacy_mode_registers_touched <= '0';
      end if;
      if viciv_single_side_border_width_touched='1' then
        viciv_update_side_border_dimensions;
        viciv_single_side_border_width_touched <= '0';
      end if;

      ack_lightpen <= '0';
      ack_collisionspritesprite <= '0';
      ack_collisionspritebitmap <= '0';
      ack_raster <= '0';

      palette_we <= (others => '0');

      -- Get VIC-II sprite data offsets
      -- (this can happen on cpuclock, since it should still allow ample time
      --  to synchronise with the sprites before we fetch the data for them).
      -- Save offset delivered by chain
--      report "SPRITE: VIC-II sprite "
--        & integer'image(sprite_number_for_data_rx)
--        & " = " & integer'image(sprite_data_offset_rx);
--      sprite_data_offsets(sprite_number_for_data_rx) <= sprite_data_offset_rx;
--      -- Ask for the next one (8 sprites + 8 C65 bitplanes)
--      if sprite_number_counter = 15 then
--        sprite_number_counter <= 0;
--        sprite_number_for_data_tx <= 0;
--      else
--        sprite_number_counter <= sprite_number_counter + 1;
--        sprite_number_for_data_tx <= sprite_number_for_data_tx + 1;
--      end if;


      -- Reading some registers clears IRQ flags
      clear_collisionspritebitmap_1 <= '0';
      clear_collisionspritesprite_1 <= '0';
      if fastio_read='1' then
        if register_number=30 then
          -- @IO:C64 $D01E sprite/sprite collissions
          clear_collisionspritesprite_1 <= '1';
        elsif register_number=31 then
          -- @IO:C64 $D01F sprite/foreground collissions
          clear_collisionspritebitmap_1 <= '1';
        end if;
      end if;
      -- One cycle delay so that CPU can read these registers with 1 cycle
      -- wait-state without the collision bits disappearing before the CPU
      -- latches the value.
      clear_collisionspritebitmap <= clear_collisionspritebitmap_1;
      clear_collisionspritesprite <= clear_collisionspritesprite_1;

      -- $D000 registers
      if fastio_write='1'
        and (fastio_addr(19) = '0' or fastio_addr(19) = '1') then
        if register_number>=0 and register_number<8 then
          -- compatibility sprite coordinates
          -- @IO:C64 $D000 VIC-II:S0X@SNX sprite N horizontal position
          -- @IO:C64 $D001 VIC-II:S0Y@SNY sprite N vertical position
          -- @IO:C64 $D002 VIC-II:S1X @SNX
          -- @IO:C64 $D003 VIC-II:S1Y @SNY
          -- @IO:C64 $D004 VIC-II:S2X @SNX
          -- @IO:C64 $D005 VIC-II:S2Y @SNY
          -- @IO:C64 $D006 VIC-II:S3X @SNX
          -- @IO:C64 $D007 VIC-II:S3Y @SNY
          sprite_x(safe_to_integer(register_num(2 downto 0))) <= unsigned(fastio_wdata);
        elsif register_number<16 then
          -- @IO:C64 $D008 VIC-II:S4X @SNX
          -- @IO:C64 $D009 VIC-II:S4Y @SNY
          -- @IO:C64 $D00A VIC-II:S5X @SNX
          -- @IO:C64 $D00B VIC-II:S5Y @SNY
          -- @IO:C64 $D00C VIC-II:S6X @SNX
          -- @IO:C64 $D00D VIC-II:S6Y @SNY
          -- @IO:C64 $D00E VIC-II:S7X @SNX
          -- @IO:C64 $D00F VIC-II:S7Y @SNY
          sprite_y(safe_to_integer(register_num(2 downto 0))) <= unsigned(fastio_wdata);
        elsif register_number=16 then
          -- @IO:C64 $D010 VIC-II:SXMSB sprite horizontal position MSBs
          vicii_sprite_xmsbs <= fastio_wdata;
        elsif register_number=17 then             -- $D011
          report "D011 WRITTEN" severity note;
          -- @IO:C64 $D011 VIC-II control register
          -- @IO:C64 $D011.7 VIC-II:RC8 raster compare bit 8
          vicii_raster_compare(10 downto 8) <= "00" & fastio_wdata(7);
          vicii_is_raster_source <= '1';
          -- @IO:C64 $D011.6 VIC-II:ECM extended background mode
          extended_background_mode <= fastio_wdata(6);
          -- @IO:C64 $D011.5 VIC-II:BMM bitmap mode
          text_mode <= not fastio_wdata(5);
          -- @IO:C64 $D011.4 VIC-II:BLNK Enable display: 0 = blank the display, 1 = show the display
          blank <= not fastio_wdata(4);
          -- @IO:C64 $D011.3 VIC-II:RSEL 24/25 row select
          twentyfourlines <= not fastio_wdata(3);
          -- @IO:C64 $D011.2-0 VIC-II:YSCL 24/25 vertical smooth scroll
          vicii_y_smoothscroll <= unsigned(fastio_wdata(2 downto 0));
          viciv_legacy_mode_registers_touched <= '1';

        elsif register_number=18 then
          -- @IO:C64 $D012 VIC-II:RC raster compare bits 0 to 7
          vicii_raster_compare(7 downto 0) <= unsigned(fastio_wdata);
          vicii_is_raster_source <= '1';
        elsif register_number=19 then
        -- @IO:C64 $D013 VIC-II:LPX Coarse horizontal beam position (was lightpen X)
        elsif register_number=20 then
        -- @IO:C64 $D014 VIC-II:LPY Coarse vertical beam position (was lightpen Y)
        elsif register_number=21 then
          -- @IO:C64 $D015 VIC-II:SE sprite enable bits
          vicii_sprite_enables <= fastio_wdata;
        elsif register_number=22 then
          -- @IO:C64 $D016 VIC-II control register
          -- @IO:C64 $D016.5 VIC-II:RST Disables video output on MAX Machine(tm) VIC-II 6566.  Ignored on normal C64s and the MEGA65
          -- @IO:C64 $D016.4 VIC-II:MCM Multi-colour mode
          multicolour_mode <= fastio_wdata(4);
          -- @IO:C64 $D016.3 VIC-II:CSEL 38/40 column select
          thirtyeightcolumns <= not fastio_wdata(3);
          -- @IO:C64 $D016.2-0 VIC-II:XSCL horizontal smooth scroll
          vicii_x_smoothscroll <= unsigned(fastio_wdata(2 downto 0));
          viciv_legacy_mode_registers_touched <= '1';
        elsif register_number=23 then
          -- @IO:C64 $D017 VIC-II:SEXY sprite vertical expansion enable bits
          vicii_sprite_y_expand <= fastio_wdata;
        elsif register_number=24 then
          -- @IO:C64 $D018 VIC-II RAM addresses
          -- Character set source address for user-generated character sets.
          -- @IO:C64 $D018.3-1 VIC-II:CB character set address location ($\times$ 1KiB)
          character_set_address(13 downto 11) <= unsigned(fastio_wdata(3 downto 1));
          character_set_address(10 downto 0) <= (others => '0');
          -- Bits 14 and 15 get set by writing to $DD00, as the VIC-IV sniffs
          -- that CIA register being written on the fastio bus.
          -- Writing here also automatically clears the bank select bits for
          -- the screen RAM address, so that writing to $D018 always works as expected.
          screen_ram_base(19 downto 16) <= "0000";
          -- @IO:C64 $D018.7-4 VIC-II:VS screen address ($\times$ 1KiB)
          reg_d018_screen_addr <= unsigned(fastio_wdata(7 downto 4));
          viciv_legacy_mode_registers_touched <= '1';
        elsif register_number=25 then
          -- @IO:C64 $D019 VIC-II IRQ control
          -- Acknowledge IRQs
          -- (we need to pass this to the dotclock side to avoide multiple drivers)
          -- @IO:C64 $D019.3 VIC-II:ILP light pen indicate or acknowledge
          ack_lightpen <= fastio_wdata(3);
          -- @IO:C64 $D019.2 VIC-II:ISSC sprite:sprite collision indicate or acknowledge
          ack_collisionspritesprite <= fastio_wdata(2);
          -- @IO:C64 $D019.1 VIC-II:ISBC sprite:bitmap collision indicate or acknowledge
          ack_collisionspritebitmap <= fastio_wdata(1);
          -- @IO:C64 $D019.0 VIC-II:RIRQ raster compare indicate or acknowledge
          ack_raster <= fastio_wdata(0);
        elsif register_number=26 then
          -- @IO:C64 $D01A compatibility IRQ mask bits
          -- XXX Enable/disable IRQs
          -- @IO:C64 $D01A.2 VIC-II:MISSC mask sprite:sprite collision IRQ
          mask_collisionspritesprite <= fastio_wdata(2);
          -- @IO:C64 $D01A.1 VIC-II:MISBC mask sprite:bitmap collision IRQ
          mask_collisionspritebitmap <= fastio_wdata(1);
          -- @IO:C64 $D01A.0 VIC-II:MRIRQ mask raster IRQ
          mask_raster <= fastio_wdata(0);
        elsif register_number=27 then
          -- @IO:C64 $D01B VIC-II:BSP sprite background priority bits
          vicii_sprite_priority_bits <= fastio_wdata;
        elsif register_number=28 then
          -- @IO:C64 $D01C VIC-II:SCM sprite multicolour enable bits
          vicii_sprite_multicolour_bits <= fastio_wdata;
        elsif register_number=29 then
          -- @IO:C64 $D01D VIC-II:SEXX sprite horizontal expansion enable bits
          vicii_sprite_x_expand <= fastio_wdata;
        elsif register_number=30 then
        -- @IO:C64 $D01E VIC-II:SSC sprite/sprite collision indicate bits
        -- vicii_sprite_sprite_collisions <= fastio_wdata;
        elsif register_number=31 then
        -- @IO:C64 $D01F VIC-II:SBC sprite/foreground collision indicate bits
        -- vicii_sprite_bitmap_collisions <= fastio_wdata;
        elsif register_number=32 then
          -- @IO:C64 $D020 Border colour
          -- @IO:C64 $D020.3-0 VIC-II:BORDERCOL display border colour (16 colour)
          -- @IO:C65 $D020.7-0 VIC-III:BORDERCOL display border colour (256 colour)
          -- @IO:GS $D020.7-0 VIC-IV:BORDERCOL display border colour (256 colour)
          if register_bank=x"D0" then
            border_colour(3 downto 0) <= unsigned(fastio_wdata(3 downto 0));
          else
            border_colour <= unsigned(fastio_wdata);
          end if;
        elsif register_number=33 then
          -- @IO:C64 $D021 Screen colour
          -- @IO:C64 $D021.3-0 VIC-II:SCREENCOL screen colour (16 colour)
          -- @IO:C65 $D021.7-0 VIC-III:SCREENCOL screen colour (256 colour)
          -- @IO:GS $D021.7-0 VIC-IV:SCREENCOL screen colour (256 colour)
          if register_bank=x"D0" then
            screen_colour(3 downto 0) <= unsigned(fastio_wdata(3 downto 0));
          else
            screen_colour <= unsigned(fastio_wdata);
          end if;
        elsif register_number=34 then
          -- @IO:C64 $D022 VIC-II multi-colour 1
          -- @IO:C64 $D022.3-0 VIC-II:MC1 multi-colour 1 (16 colour)
          -- @IO:C65 $D022.7-0 VIC-III:MC1 multi-colour 1 (256 colour)
          -- @IO:GS $D022.7-0 VIC-IV:MC1 multi-colour 1 (256 colour)
          if register_bank=x"D0" then
            multi1_colour <= unsigned("0000"&fastio_wdata(3 downto 0));
          else
            multi1_colour <= unsigned(fastio_wdata);
          end if;
        elsif register_number=35 then
          -- @IO:C64 $D023 VIC-II multi-colour 2
          -- @IO:C64 $D023.3-0 VIC-II:MC2 multi-colour 2 (16 colour)
          -- @IO:C65 $D023.7-0 VIC-III:MC2 multi-colour 2 (256 colour)
          -- @IO:GS $D023.7-0 VIC-IV:MC2 multi-colour 2 (256 colour)
          if register_bank=x"D0" then
            multi2_colour <= unsigned("0000"&fastio_wdata(3 downto 0));
          else
            multi2_colour <= unsigned(fastio_wdata);
          end if;
        elsif register_number=36 then
          -- @IO:C64 $D024 VIC-II multi-colour 3
          -- @IO:C64 $D024.3-0 VIC-II:MC3 multi-colour 3 (16 colour)
          -- @IO:C65 $D024.7-0 VIC-III:MC3 multi-colour 3 (256 colour)
          -- @IO:GS $D024.7-0 VIC-IV:MC3 multi-colour 3 (256 colour)
          if register_bank=x"D0" then
            multi3_colour <= unsigned("0000"&fastio_wdata(3 downto 0));
          else
            multi3_colour <= unsigned(fastio_wdata);
          end if;
        elsif register_number=37 then
          -- @IO:C64 $D025 VIC-II:SPRMC0 Sprite multi-colour 0
          -- @IO:C65 $D025 VIC-III:SPRMC0 Sprite multi-colour 0 (8-bit for selection of any palette colour)
          -- @IO:GS $D025 VIC-IV:SPRMC0 Sprite multi-colour 0 (8-bit for selection of any palette colour)
          if register_bank=x"D0" then
            sprite_multi0_colour <= unsigned("0000"&fastio_wdata(3 downto 0));
          else
            sprite_multi0_colour <= unsigned(fastio_wdata);
          end if;
        elsif register_number=38 then
          -- @IO:C64 $D026 VIC-II:SPRMC1 Sprite multi-colour 1
          -- @IO:C65 $D026 VIC-III:SPRMC1 Sprite multi-colour 1 (8-bit for selection of any palette colour)
          -- @IO:GS $D026 VIC-IV:SPRMC1 Sprite multi-colour 1 (8-bit for selection of any palette colour)
          if register_bank=x"D0" then
            sprite_multi1_colour <= unsigned("0000"&fastio_wdata(3 downto 0));
          else
            sprite_multi1_colour <= unsigned(fastio_wdata);
          end if;
        elsif register_number>=39 and register_number<=46 then
          -- @IO:C64 $D027 VIC-II:SPR0COL@SPRNCOL sprite N colour / 16-colour sprite transparency colour (lower nybl)
          -- @IO:C64 $D028 VIC-II:SPR1COL @SPRNCOL
          -- @IO:C64 $D029 VIC-II:SPR2COL @SPRNCOL
          -- @IO:C64 $D02A VIC-II:SPR3COL @SPRNCOL
          -- @IO:C64 $D02B VIC-II:SPR4COL @SPRNCOL
          -- @IO:C64 $D02C VIC-II:SPR5COL @SPRNCOL
          -- @IO:C64 $D02D VIC-II:SPR6COL @SPRNCOL
          -- @IO:C64 $D02E VIC-II:SPR7COL @SPRNCOL
          if register_bank=x"D0" then
            sprite_colours(safe_to_integer(register_number)-39)(3 downto 0) <= unsigned(fastio_wdata(3 downto 0));
          else
            sprite_colours(safe_to_integer(register_number)-39) <= unsigned(fastio_wdata);
          end if;
        -- Skip $D02F - $D047 to avoid real C65/C128 programs trying to
        -- fiddle with registers in this range.
        -- NEW VIDEO REGISTERS
        elsif register_number=47 then
          -- @IO:C64 $D02F VIC-II:KEY Write $00 then $00 to enable C64/VIC-II IO registers
          -- this is actually the default when not hitting any of the other keys, but we
          -- promote writing 00, 00 to keep it more transparent for further expansions.
          viciii_iomode <= "00"; -- by default go back to VIC-II mode
          -- @IO:C65 $D02F VIC-III:KEY Write $A5 then $96 to enable C65/VIC-III IO registers
          if reg_key=x"a5" then
            if fastio_wdata=x"96" then
              -- C65 VIC-III mode
              viciii_iomode <= "01";
            end if;
          -- @IO:GS $D02F VIC-IV:KEY Write $47 then $53 to enable MEGA65/VIC-IV IO registers
          elsif reg_key=x"47" then
            if fastio_wdata=x"53" then
              -- MEGA65 VIC-IV mode
              viciii_iomode <= "11";
            end if;
          -- @IO:GS $D02F ETH:KEY Write $45 then $54 to map 45E100 ethernet controller buffers to $D000-$DFFF
          elsif reg_key=x"45" then
            if fastio_wdata=x"54" then
              -- MEGA65 Map ethernet frame buffer mode
              viciii_iomode <= "10";
            end if;
          end if;
          reg_key <= unsigned(fastio_wdata);
        elsif register_number=255 then
          -- @IO:C64 $D030 SUMMARY: C128 2MHz emulation
          -- @IO:C64 $D030.0 VIC-II:C128!FAST 2MHz select (for C128 2MHz emulation)
          vicii_2mhz_internal <= fastio_wdata(0);
        elsif register_number=48 then
          -- @IO:C65 $D030 SUMMARY:VIC-III Control Register A
          -- @IO:C65 $D030.7 VIC-III:ROME Map C65 ROM @ $E000
          rom_at_e000 <= fastio_wdata(7);
          reg_rom_e000 <= fastio_wdata(7);
          -- @IO:C65 $D030.6 VIC-III:CROM9 Select between C64 and C65 charset (not implemented)
          reg_c65_charset <= fastio_wdata(6);
          -- @IO:C65 $D030.5 VIC-III:ROMC Map C65 ROM @ $C000
          rom_at_c000 <= fastio_wdata(5);
          reg_rom_c000 <= fastio_wdata(5);
          -- @IO:C65 $D030.4 VIC-III:ROMA Map C65 ROM @ $A000
          rom_at_a000 <= fastio_wdata(4);
          reg_rom_a000 <= fastio_wdata(4);
          -- @IO:C65 $D030.3 VIC-III:ROM8 Map C65 ROM @ $8000
          rom_at_8000 <= fastio_wdata(3);
          reg_rom_8000 <= fastio_wdata(3);
          -- @IO:C65 $D030.2 VIC-III:PAL Use PALETTE ROM (0) or RAM (1) entries for colours 0 - 15
          reg_palrom <= fastio_wdata(2);
          -- @IO:C65 $D030.1 VIC-III:EXTSYNC Enable external video sync (genlock input)
          -- @IO:C65 $D030.0 VIC-III:CRAM2K Map 2nd KB of colour RAM @ $DC00-$DFFF
          colourram_at_dc00_internal<= fastio_wdata(0);
          colourram_at_dc00<= fastio_wdata(0);
        elsif register_number=49 then
          if d031_writes /= x"FF" then
            d031_writes <= d031_writes + 1;
            d031_written_internal <= not d031_written_internal;
          else
            d031_writes <= x"00";
          end if;
          -- @IO:C65 $D031 SUMMARY:VIC-III Control Register B
          -- @IO:C65 $D031.7 VIC-III:H640 Enable C64 640 horizontal pixels / 80 column mode
          reg_h640 <= fastio_wdata(7);
          -- @IO:C65 $D031.6 VIC-III:FAST Enable C65 FAST mode (~3.5MHz)
          viciii_fast_internal <= fastio_wdata(6);
          -- @IO:C65 $D031.5 VIC-III:ATTR Enable extended attributes and 8 bit colour entries
          viciii_extended_attributes <= fastio_wdata(5);
          -- @IO:C65 $D031.4 VIC-III:BPM Bit-Plane Mode
          bitplane_mode <= fastio_wdata(4);
          -- @IO:C65 $D031.3 VIC-III:V400 Enable 400 vertical pixels (disables PALEMU)
          reg_v400 <= fastio_wdata(3);
          -- @IO:C65 $D031.2 VIC-III:H1280 Enable 1280 horizontal pixels (not implemented, disables PALEMU)
          reg_h1280 <= fastio_wdata(2);
          -- @IO:C65 $D031.1 VIC-III:MONO Enable VIC-III MONO composite video output (colour if disabled)
          reg_mono <= fastio_wdata(1);
          -- @IO:C65 $D031.0 VIC-III:INT Enable VIC-III interlaced mode
          -- Auto-enable interlace mode when selecting V400 (unless in
          -- hypervisor, in which case we want to be able to unfreeze this
          -- register without side-effects)
          -- Note: This has been disabled again as interlace mode was breaking display on some hdmi monitors
          --       We need to come up with a configurable solution for composite once it is ready
          -- if reg_v400='0' and fastio_wdata(3)='1' and hypervisor_mode='0' then
          --   reg_interlace <= '1';
          -- else
          reg_interlace <= fastio_wdata(0);
          -- end if;
          viciv_legacy_mode_registers_touched <= '1';
        elsif register_number=50 then
          bitplane_enables <= fastio_wdata;
        -- @IO:C65 $D033.5-7 VIC-III:B0ADODD@BXADODD Odd rows of even Bitplane X address[15:13] (only used in v400 mode)
        -- @IO:C65 $D033.1-3 VIC-III:B0ADEVN@BXADEVN Even rows of even Bitplane X address[15:13] (for v200, even row drawn twice)
        -- @IO:C65 $D034.5-7 VIC-III:B1ADODD@BYADODD Odd rows of odd Bitplane Y address[15:13] (+64KB) (only used in v400 mode)
        -- @IO:C65 $D034.1-3 VIC-III:B1ADEVN@BYADEVN Even rows of odd Bitplane Y address[15:13] (+64KB) (for v200, even row drawn twice)
        -- @IO:C65 $D035.5-7 VIC-III:B2ADODD @BXADODD
        -- @IO:C65 $D035.1-3 VIC-III:B2ADEVN @BXADEVN
        -- @IO:C65 $D036.5-7 VIC-III:B3ADODD @BYADODD
        -- @IO:C65 $D036.1-3 VIC-III:B3ADEVN @BYADEVN
        -- @IO:C65 $D037.5-7 VIC-III:B4ADODD @BXADODD
        -- @IO:C65 $D037.1-3 VIC-III:B4ADEVN @BXADEVN
        -- @IO:C65 $D038.5-7 VIC-III:B5ADODD @BYADODD
        -- @IO:C65 $D038.1-3 VIC-III:B5ADEVN @BYADEVN
        -- @IO:C65 $D039.5-7 VIC-III:B6ADODD @BXADODD
        -- @IO:C65 $D039.1-3 VIC-III:B6ADEVN @BXADEVN
        -- @IO:C65 $D03A.5-7 VIC-III:B7ADODD @BYADODD
        -- @IO:C65 $D03A.1-3 VIC-III:B7ADEVN @BYADEVN
        elsif register_number >= 51 and register_number <= 58 then
          -- @IO:C65 $D033-$D03A - VIC-III Bitplane addresses
          --bitplane_number := safe_to_integer(register_number(3 downto 0)) - 3;
          bitplane_addresses(safe_to_integer(register_number)-51) <= unsigned(fastio_wdata);
        -- @IO:C65 $D03B VIC-III:BPCOMP Complement bitplane flags
        elsif register_number=59 then
          bitplane_complements <= fastio_wdata;
        -- @IO:C65 $D03C VIC-III:BPX Bitplane X
        elsif register_number=60 then
          dat_x <= unsigned(fastio_wdata(6 downto 0));
          dat_y(8) <= fastio_wdata(7);
        -- @IO:C65 $D03D VIC-III:BPY Bitplane Y
        elsif register_number=61 then
          dat_y(7 downto 0) <= unsigned(fastio_wdata);
        elsif register_number=64 then
        -- @IO:C65 $D03E VIC-III:HPOS Bitplane X Offset
        elsif register_number=62 then
          bitplanes_x_start <= unsigned(fastio_wdata);
        -- @IO:C65 $D03F VIC-III:VPOS Bitplane Y Offset
        elsif register_number=63 then
          bitplanes_y_start <= unsigned(fastio_wdata);
        elsif register_number=64 then
        -- @IO:C65 $D040 VIC-III:B0PIX@BNPIX Display Address Translater (DAT) Bitplane N port
        elsif register_number=65 then
        -- @IO:C65 $D041 VIC-III:B1PIX @BNPIX
        elsif register_number=66 then
        -- @IO:C65 $D042 VIC-III:B2PIX @BNPIX
        elsif register_number=67 then
        -- @IO:C65 $D043 VIC-III:B3PIX @BNPIX
        elsif register_number=68 then
        -- @IO:C65 $D044 VIC-III:B4PIX @BNPIX
        elsif register_number=69 then
        -- @IO:C65 $D045 VIC-III:B5PIX @BNPIX
        elsif register_number=70 then
        -- @IO:C65 $D046 VIC-III:B6PIX @BNPIX
        elsif register_number=71 then
        -- @IO:C65 $D047 VIC-III:B7PIX @BNPIX
        elsif register_number=72 then
          -- @IO:GS $D048 VIC-IV:TBDRPOS top border position
          border_y_top(7 downto 0) <= unsigned(fastio_wdata);
        elsif register_number=73 then
          -- @IO:GS $D049.3-0 VIC-IV:TBDRPOS top border position MSB
          border_y_top(11 downto 8) <= unsigned(fastio_wdata(3 downto 0));
          -- @IO:GS $D049.7-4 VIC-IV:SPRBPMEN Sprite bitplane-modify-mode enables
          sprite_bitplane_enables(3 downto 0) <= fastio_wdata(7 downto 4);
        elsif register_number=74 then
          -- @IO:GS $D04A VIC-IV:BBDRPOS bottom border position
          border_y_bottom(7 downto 0) <= unsigned(fastio_wdata);
        elsif register_number=75 then
          -- @IO:GS $D04B.3-0 VIC-IV:BBDRPOS bottom border position
          border_y_bottom(11 downto 8) <= unsigned(fastio_wdata(3 downto 0));
          -- @IO:GS $D04B.7-4 VIC-IV:SPRBPMEN Sprite bitplane-modify-mode enables
          sprite_bitplane_enables(7 downto 4) <= fastio_wdata(7 downto 4);
        elsif register_number=76 then
          -- @IO:GS $D04C VIC-IV:TEXTXPOS character generator horizontal position
          x_chargen_start(7 downto 0) <= unsigned(fastio_wdata);
        elsif register_number=77 then
          -- @IO:GS $D04D.3-0 VIC-IV:TEXTXPOS character generator horizontal position
          x_chargen_start(11 downto 8) <= unsigned(fastio_wdata(3 downto 0));
          -- @IO:GS $D04D.7-4 VIC-IV:SPRTILEN Sprite horizontal tile enables.
          sprite_horizontal_tile_enables(3 downto 0) <= fastio_wdata(7 downto 4);
        elsif register_number=78 then
          -- @IO:GS $D04E VIC-IV:TEXTYPOS Character generator vertical position
          y_chargen_start(7 downto 0) <= unsigned(fastio_wdata);
        elsif register_number=79 then
          -- @IO:GS $D04F.3-0 VIC-IV:TEXTYPOS Character generator vertical position
          y_chargen_start(11 downto 8) <= unsigned(fastio_wdata(3 downto 0));
          -- @IO:GS $D04F.7-4 VIC-IV:SPRTILEN Sprite 7-4 horizontal tile enables
          sprite_horizontal_tile_enables(7 downto 4) <= fastio_wdata(7 downto 4);
        elsif register_number=80 then
          -- @IO:GS $D050 VIC-IV:XPOSLSB Read horizontal raster scan position LSB
          viciv_rasterx_compare(7 downto 0) <= unsigned(fastio_wdata);
        elsif register_number=81 then
          -- @IO:GS $D051.0-5 VIC-IV:XPOSMSB Read horizontal raster scan position MSB
          viciv_rasterx_compare(13 downto 8) <= unsigned(fastio_wdata(5 downto 0));
          -- @IO:GS $D051.6 VIC-IV:DBLRR When set, the Raster Rewrite Buffer is only updated every 2nd raster line, limiting resolution to V200, but allowing more cycles for Raster-Rewrite actions.
          raster_buffer_double_line <= fastio_wdata(6);
          -- @IO:GS $D051.7 VIC-IV:NORRDEL When clear, raster rewrite double buffering is used
          no_raster_buffer_delay <= fastio_wdata(7);
        elsif register_number=82 then
        -- @IO:GS $D052 VIC-IV:FNRASTERLSB Read physical raster position
        -- Allow setting of fine raster for IRQ (low bits)
        -- vicii_raster_compare(7 downto 0) <= unsigned(fastio_wdata);
--        vicii_is_raster_source <= '0';
        elsif register_number=83 then
        -- @IO:GS $D053.0-3 VIC-IV:FN!RASTER!MSB Read physical raster position
        -- @IO:GS $D053.4 VIC-IV:BOLDISALT When set, the BOLD attribute bit selects the alternate palette, without requiring REVERSE to also be set.
        -- @IO:GS $D053.5 VIC-IV:UPSCALE Enable integrated low-latency (130usec) 720p upscaler
        -- @IO:GS $D053.6 VIC-IV:SHDEMU Enable simulated shadow-mask (PALEMU must also be enabled)
        -- Allow setting of fine raster for IRQ (high bits)
        -- vicii_raster_compare(10 downto 8) <= unsigned(fastio_wdata(2 downto 0));
          -- @IO:GS $D053.7 VIC-IV:FNRST Read raster compare source (0=VIC-IV fine raster, 1=VIC-II raster), provides same value as set in FNRSTCMP
          shadow_mask_enable <= fastio_wdata(6);
          upscale_enable_int <= fastio_wdata(5);
          bold_is_alt <= fastio_wdata(4);
        elsif register_number=84 then
          -- @IO:GS $D054 SUMMARY:VIC-IV Control register C
          -- @IO:GS $D054.7 VIC-IV:ALPHEN Alpha compositor enable
          compositer_enable <= fastio_wdata(7);
          -- @IO:GS $D054.6 VIC-IV:VFAST MEGA65 FAST mode (40.5MHz)
          viciv_fast_internal <= fastio_wdata(6);
          -- @IO:GS $D054.5 VIC-IV:PALEMU Enable PAL CRT-like scan-line emulation (disabled by V400 or H1280)
          pal_simulate <= fastio_wdata(5);
          -- @IO:GS $D054.4 VIC-IV:SPR!H640 Sprite H640 enable
          sprite_h640 <= fastio_wdata(4);
          -- @IO:GS $D054.3 VIC-IV:SMTH video output horizontal smoothing enable
          horizontal_filter <= fastio_wdata(3);
          -- @IO:GS $D054.2 VIC-IV:FCLRHI enable full-colour mode for character numbers >$FF
          fullcolour_extendedchars <= fastio_wdata(2);
          -- @IO:GS $D054.1 VIC-IV:FCLRLO enable full-colour mode for character numbers <=$FF
          fullcolour_8bitchars <= fastio_wdata(1);
          -- @IO:GS $D054.0 VIC-IV:CHR16 enable 16-bit character numbers (two screen bytes per character)
          sixteenbit_charset <= fastio_wdata(0);
        elsif register_number=85 then
          -- @IO:GS $D055 VIC-IV:SPRHGTEN sprite extended height enable (one bit per sprite)
          sprite_extended_height_enables <= fastio_wdata;
        elsif register_number=86 then
          -- @IO:GS $D056 VIC-IV:SPRHGHT Sprite extended height size (sprite pixels high)
          sprite_extended_height_size <= unsigned(fastio_wdata);
        elsif register_number=87 then
          -- @IO:GS $D057 VIC-IV:SPRX64EN Sprite extended width enables (8 bytes per sprite row = 64 pixels wide for normal sprites or 16 pixels wide for 16-colour sprite mode)
          sprite_extended_width_enables <= fastio_wdata;
        elsif register_number=88 then
          -- @IO:GS $D058 VIC-IV:LINESTEPLSB number of bytes to advance between each text row (LSB)
          virtual_row_width(7 downto 0) <= unsigned(fastio_wdata);
        elsif register_number=89 then
          -- @IO:GS $D059 VIC-IV:LINESTEPMSB number of bytes to advance between each text row (MSB)
          virtual_row_width(15 downto 8) <= unsigned(fastio_wdata);
        elsif register_number=90 then
          -- @IO:GS $D05A VIC-IV:CHRXSCL Horizontal hardware scale of text mode (pixel 120ths per pixel)
          chargen_x_scale <= unsigned(fastio_wdata);
        elsif register_number=91 then
          -- @IO:GS $D05B VIC-IV:CHRYSCL Vertical scaling of text mode (number of physical rasters per char text row)
          chargen_y_scale <= unsigned(fastio_wdata);
        elsif register_number=92 then
          -- @IO:GS $D05C VIC-IV:SDBDRWD!LSB Width of single side border (LSB)
          single_side_border(7 downto 0) <= unsigned(fastio_wdata);
          viciv_single_side_border_width_touched <= '1';
        elsif register_number=93 then
          -- @IO:GS $D05D.0-5 VIC-IV:SDBDRWD!MSB side border width (MSB)
          single_side_border(13 downto 8) <= unsigned(fastio_wdata(5 downto 0));
          viciv_single_side_border_width_touched <= '1';
          -- @IO:GS $D05D.6 VIC-IV:RST!DELEN Enable raster delay (delays raster counter and interrupts by one line to match output pipeline latency)
          enable_raster_delay <= fastio_wdata(6);
          -- @IO:GS $D05D.7 VIC-IV:HOTREG Enable VIC-II hot registers. When enabled, touching many VIC-II registers causes the VIC-IV to recalculate display parameters, such as border positions and sizes. Touching registers while this is disabled will trigger a change when reenabling. Setting this to 0 will clear the recalc flag, canceling the recalculation.
          vicii_hot_regs_enable <= fastio_wdata(7);
          if fastio_wdata(7) = '0' then
            viciv_legacy_mode_registers_touched <= '0';
          end if;
        elsif register_number=94 then
          -- @IO:GS $D05E VIC-IV:CHRCOUNT Number of characters to display per row (LSB)
          display_row_width(7 downto 0) <= unsigned(fastio_wdata);
        elsif register_number=95 then
          -- @IO:GS $D05F VIC-IV:SPRXSMSBS Sprite H640 X Super-MSBs
          sprite_h640_msbs <= fastio_wdata;
        elsif register_number=96 then
          -- @IO:GS $D060 VIC-IV:SCRNPTRLSB screen RAM precise base address (bits 7 - 0)
          screen_ram_base(7 downto 0) <= unsigned(fastio_wdata);
        elsif register_number=97 then
          -- @IO:GS $D061 VIC-IV:SCRNPTRMSB screen RAM precise base address (bits 15 - 8)
          screen_ram_base(15 downto 8) <= unsigned(fastio_wdata);
        elsif register_number=98 then
          -- @IO:GS $D062 VIC-IV:SCRNPTRBNK screen RAM precise base address (bits 23 - 16)
          screen_ram_base(23 downto 16) <= unsigned(fastio_wdata);
        elsif register_number=99 then
          -- @IO:GS $D063.0-3 VIC-IV:SCRNPTRMB screen RAM precise base address (bits 27 - 24)
          screen_ram_base(27 downto 24) <= unsigned(fastio_wdata(3 downto 0));
          -- @IO:GS $D063.4-5 VIC-IV:CHRCOUNT Number of characters to display per
          -- row (MSBs)
          display_row_width(9 downto 8) <= unsigned(fastio_wdata(5 downto 4));
          -- @IO:GS $D063.6 VIC-IV:FCOLMCM enable 256 colours in multicolour text mode
          fullcolour_mcm <= fastio_wdata(6);
          -- @IO:GS $D063.7 VIC-IV:EXGLYPH source full-colour character data from expansion RAM
          glyphs_from_hyperram <= fastio_wdata(7);
        elsif register_number=100 then
          -- @IO:GS $D064 VIC-IV:COLPTRLSB colour RAM base address (bits 0 - 7)
          colour_ram_base(7 downto 0) <= unsigned(fastio_wdata);
        elsif register_number=101 then
          -- @IO:GS $D065 VIC-IV:COLPTRMSB colour RAM base address (bits 15 - 8)
          colour_ram_base(15 downto 8) <= unsigned(fastio_wdata);
        elsif register_number=102 then -- $D3066
          -- @IO:GS $D066.0-4 VIC-IV xcounter pipeline delay DEBUG WILL BE REMOVED
          -- @IO:GS $D066.6 VIC-IV render activity display enable DEBUG WILL BE REMOVED
          -- @IO:GS $D066.7 VIC-IV test pattern display enable DEBUG WILL BE REMOVED
          reg_xcounter_delay <= safe_to_integer(unsigned(fastio_wdata(4 downto 0)));
          show_render_activity <= fastio_wdata(6);
          test_pattern_enable <= fastio_wdata(7);
        elsif register_number=103 then  -- $D3067
          -- @IO:GS $D067 DEBUG:SBPDEBUG Sprite/bitplane first X DEBUG WILL BE REMOVED
          sprite_first_x(7 downto 0) <= unsigned(fastio_wdata);
        elsif register_number=104 then
          -- @IO:GS $D068 VIC-IV:CHARPTRLSB Character set precise base address (bits 0 - 7)
          character_set_address(7 downto 0) <= unsigned(fastio_wdata);
        elsif register_number=105 then
          -- @IO:GS $D069 VIC-IV:CHARPTRMSB Character set precise base address (bits 15 - 8)
          character_set_address(15 downto 8) <= unsigned(fastio_wdata);
        elsif register_number=106 then
          -- @IO:GS $D06A VIC-IV:CHARPTRBNK Character set precise base address (bits 23 - 16)
          character_set_address(23 downto 16) <= unsigned(fastio_wdata);
        elsif register_number=107 then
          -- @IO:GS $D06B VIC-IV:SPR16EN sprite 16-colour mode enables
          sprite_sixteen_colour_enables <= fastio_wdata;
        elsif register_number=108 then
          -- @IO:GS $D06C VIC-IV:SPRPTRADRLSB sprite pointer address (bits 7 - 0)
          vicii_sprite_pointer_address(7 downto 0) <= unsigned(fastio_wdata);
        elsif register_number=109 then
          -- @IO:GS $D06D VIC-IV:SPRPTRADRMSB sprite pointer address (bits 15 - 8)
          vicii_sprite_pointer_address(15 downto 8) <= unsigned(fastio_wdata);
        elsif register_number=110 then
          -- @IO:GS $D06E.0-6 VIC-IV:SPRPTRBNK sprite pointer address (bits 23 - 16)
          -- @IO:GS $D06E.7 VIC-IV:SPR!PTR16 16-bit sprite pointer mode (allows sprites to be located on any 64 byte boundary in chip RAM)
          vicii_sprite_pointer_address(23 downto 16) <= unsigned(fastio_wdata);
        elsif register_number=111 then
          -- @IO:GS $D06F.5-0 VIC-IV:RASLINE0 first VIC-II raster line
          vicii_first_raster(5 downto 0) <= unsigned(fastio_wdata(5 downto 0));
          -- @IO:GS $D06F.6 VIC-IV:VGAHDTV Select more VGA-compatible mode if set, instead of HDMI/HDTV VIC-II cycle-exact frame timing. May help to produce a functional display on older VGA monitors.
          -- @IO:GS $D06F.7 VIC-IV:PALNTSC NTSC emulation mode (max raster = 262)
          vicii_ntsc <= fastio_wdata(7);
          pal50_select <= not fastio_wdata(7);
          vga60_select <= fastio_wdata(6);
          vga60_select_internal <= fastio_wdata(6);
          -- Make sure that matrix
          -- mode display isn't jiggly
          if fastio_wdata(7)='1' then
            reg_xcounter_delay <= 1;
            reg_alpha_delay <= x"1";
          else
            reg_xcounter_delay <= 0;
            reg_alpha_delay <= x"1";
          end if;
          report "LEGACY register update & PAL/NTSC mode select";

          -- Recompute screen and border positions
          -- But only if not in hypervisor mode, so that we don't mess up freezing
          if hypervisor_mode='0' then
            viciv_single_side_border_width_touched <= '1';
          end if;

          if vicii_ntsc /= fastio_wdata(7) or vga60_select_internal /= fastio_wdata(6) then
            case fastio_wdata(7 downto 6) is
              when "00" => -- PAL, 720x576 @ 50Hz
                sprite_y_adjust <= to_unsigned(0,8);
                vicii_ycounter_scale_minus_zero <= to_unsigned(2-1,4);
                vicii_max_raster <= pal_max_raster;
                -- VSYNC is negative for 50Hz (required for some monitors)
                hsync_polarity_internal <= '1';
                vsync_polarity_internal <= '0';
                if vicii_ntsc /= fastio_wdata(7) then
                  vicii_first_raster <= to_unsigned(0,9);
                end if;
              when "01" => -- PAL, 720x576 50Hz, NTSC max raster
                sprite_y_adjust <= to_unsigned(0,8);
                vicii_ycounter_scale_minus_zero <= to_unsigned(2-1,4);
                vicii_max_raster <= ntsc_max_raster;
                hsync_polarity_internal <= '1';
                vsync_polarity_internal <= '0';
                if vicii_ntsc /= fastio_wdata(7) then
                  vicii_first_raster <= to_unsigned(0,9);
                end if;
              when "10" => -- NTSC, 720x480 @ 60Hz
                sprite_y_adjust <= to_unsigned(24,8);
                vicii_ycounter_scale_minus_zero <= to_unsigned(2-1,4);
                vicii_max_raster <= ntsc_max_raster;
                hsync_polarity_internal <= '1';
                vsync_polarity_internal <= '0';
                if vicii_ntsc /= fastio_wdata(7) then
                  vicii_first_raster <= to_unsigned(7,9);
                end if;

              when "11" => -- NTSC 720x480 60Hz
                sprite_y_adjust <= to_unsigned(24,8);
                vicii_ycounter_scale_minus_zero <= to_unsigned(2-1,4);
                -- NTSC but with PAL max raster
                vicii_max_raster <= pal_max_raster;
                hsync_polarity_internal <= '1';
                vsync_polarity_internal <= '0';
                if vicii_ntsc /= fastio_wdata(7) then
                  vicii_first_raster <= to_unsigned(7,9);
                end if;
              when others => -- Default to NTSC 800x600 60Hz
                sprite_y_adjust <= to_unsigned(24,8);
                vicii_ycounter_scale_minus_zero <= to_unsigned(2-1,4);
                hsync_polarity_internal <= '1';
                vsync_polarity_internal <= '0';
                if vicii_ntsc /= fastio_wdata(7) then
                  vicii_first_raster <= to_unsigned(7,9);
                end if;
            end case;
          end if;
        elsif register_number=112 then
          -- @IO:GS $D070 NONE:VIC-IV palette bank selection
          -- @IO:GS $D070.7-6 VIC-IV:MAPEDPAL palette bank mapped at $D100-$D3FF
          palette_bank_fastio <= fastio_wdata(7 downto 6);
          -- @IO:GS $D070.5-4 VIC-IV:BTPALSEL bitmap/text palette bank
          palette_bank_chargen <= fastio_wdata(5 downto 4);
          -- @IO:GS $D070.3-2 VIC-IV:SPRPALSEL sprite palette bank
          palette_bank_sprites <= fastio_wdata(3 downto 2);
          -- @IO:GS $D070.1-0 VIC-IV:ABTPALSEL VIC-IV bitmap/text palette bank (alternate palette)
          palette_bank_chargen_alt <= fastio_wdata(1 downto 0);
        elsif register_number=113 then -- $D3071
          -- @IO:GS $D071 VIC-IV:BP16ENS VIC-IV 16-colour bitplane enable flags
          bitplane_sixteen_colour_mode_flags <= fastio_wdata;
        elsif register_number=114 then -- $D3072
          -- @IO:GS $D072 VIC-IV:SPRYADJ Sprite Y position adjustment
          sprite_y_adjust <= unsigned(fastio_wdata);
        elsif register_number=115 then -- $D3073
          -- @IO:GS $D073.0-3 VIC-IV:ALPHADELAY Alpha delay for compositor
          reg_alpha_Delay <= unsigned(fastio_wdata(3 downto 0));
          -- @IO:GS $D073.4-7 VIC-IV:RASTERHEIGHT physical rasters per VIC-II raster (1 to 16)
          vicii_ycounter_scale_minus_zero(3 downto 0) <= unsigned(fastio_wdata(7 downto 4));
        elsif register_number=116 then -- $D3074
          -- @IO:GS $D074 VIC-IV:SPRENALPHA Sprite alpha-blend enable
          sprite_alpha_blend_enables <= fastio_wdata;
        elsif register_number=117 then
          -- @IO:GS $D075 VIC-IV:SPRALPHAVAL Sprite alpha-blend value
          sprite_alpha_blend_value <= unsigned(fastio_wdata);
        elsif register_number=118 then
          -- @IO:GS $D076 VIC-IV:SPRENV400 Sprite V400 enables
          sprite_v400s <= fastio_wdata;
        elsif register_number=119 then  -- $D3077
          -- @IO:GS $D077 VIC-IV:SPRYMSBS Sprite V400 Y position MSBs
          sprite_v400_msbs <= fastio_wdata;
        elsif register_number=120 then  -- $D3078
          -- @IO:GS $D078 VIC-IV:SPRYSMSBS Sprite V400 Y position super MSBs
          sprite_v400_super_msbs <= fastio_wdata;
        elsif register_number=121 then  -- $D3079
          -- @IO:GS $D079 VIC-IV:RASCMP Physical raster compare value to be used if FNRSTCMP is clear
          vicii_raster_compare(7 downto 0) <= unsigned(fastio_wdata);
        elsif register_number=122 then  -- $D307A
          -- @IO:GS $D07A.0-2 VIC-IV:RASCMP!MSB Raster compare value MSB
          -- @IO:GS $D07A.3 VIC-IV:SPTR!CONT Continuously monitor sprite pointer, to allow changing sprite data source while a sprite is being drawn
          -- @IO:GS $D07A.4 VIC-IV:CHARY16 Alternate char ROM bank on alternate raster lines in V200
          -- @IO:GS $D07A.5 VIC-IV:NOBUGCOMPAT *DEPRECATED*, use HWERRATA - Disables VIC-III / C65 Bug Compatibility Mode if set
          -- @IO:GS $D07A.6 VIC-IV:EXTIRQS Enable additional IRQ sources, e.g., raster X position.
          -- @IO:GS $D07A.7 VIC-IV:FNRST!CMP Raster compare is in physical rasters if clear, or VIC-II rasters if set
          irq_extras_enable <= fastio_wdata(6);
          reg_char_y16 <= fastio_wdata(4);
          sprite_continuous_pointer_monitoring <= fastio_wdata(3);
          vicii_raster_compare(10 downto 8) <= unsigned(fastio_wdata(2 downto 0));
          vicii_is_raster_source <= fastio_wdata(7);

          prev_bug_compat_mode <= not fastio_wdata(5);
          if fastio_wdata(5)=prev_bug_compat_mode then
            if fastio_wdata(5)='1' then
              -- Disable compatibility = enable errata
              hw_errata_enable_toggle <= not hw_errata_enable_toggle;
            else
              hw_errata_disable_toggle <= not hw_errata_disable_toggle;
            end if;
          end if;

        elsif register_number=123 then
          -- @IO:GS $D07B VIC-IV:DISP!ROWS Number of text rows to display
          display_row_count <= unsigned(fastio_wdata);
        elsif register_number=124 then
          -- @IO:GS $D07C.0-2 VIC-IV:BIT!PBANK Set which 128KB bank bitplanes
          -- are fetched from.
          bitplane_bank_select <= unsigned(fastio_wdata(2 downto 0));
          dat_bitplane_bank <= unsigned(fastio_wdata(2 downto 0));
          -- @IO:GS $D07C.3 VIC-IV:NORRBWRAP Disables RRB address wrap-around when set.
          rrb_wraparound_allowed <= not fastio_wdata(3);
          rrb_overtime_allowed <= not fastio_wdata(3);
          -- @IO:GS $D07C.4 VIC-IV:HSYNCP hsync polarity
          hsync_polarity_internal <= fastio_wdata(4);
          -- @IO:GS $D07C.5 VIC-IV:VSYNCP vsync polarity
          vsync_polarity_internal <= fastio_wdata(5);
          -- @IO:GS $D07C.6-7 VIC-IV:DEBUGC VIC-IV debug pixel select red(01), green(10) or blue(11) channel visible in $D07D
          debug_channel_select <= fastio_wdata(7 downto 6);
        elsif register_number=125 then
          -- @IO:GS $D07D DEBUG:DEBUGX VIC-IV debug X position (LSB) (write only)
          -- @IO:GS $D07D DEBUG:DEBUGOUT VIC-IV debug value read-back (read only)
          debug_x(7 downto 0) <= unsigned(fastio_wdata);
        elsif register_number=126 then
          -- @IO:GS $D07E DEBUG:DEBUGY VIC-IV debug Y position (LSB)
          debug_y(7 downto 0) <= unsigned(fastio_wdata);
        elsif register_number=127 then
          -- @IO:GS $D07F.0-3 DEBUG:DEBUGX VIC-IV debug X position (MSB)
          -- @IO:GS $D07F.7 DEBUG:DEBUGOOF VIC-IV debug out-of-frame signal enable
          debug_x(11 downto 8) <= unsigned(fastio_wdata(3 downto 0));
          debug_x(13 downto 12) <= "00";
          -- @IO:GS $D07F.4-7 DEBUG:DEBUGY VIC-IV debug Y position (MSB)
          debug_y(11 downto 8) <= unsigned(fastio_wdata(7 downto 4));
        elsif register_number<255 then
          -- reserved register, FDC and RAM expansion controller
          null;
        elsif register_number>=256 and register_number<512 then
          -- @IO:C65 $D100-$D1FF VIC-III:PALRED red palette values (reversed nybl order)
          palette_fastio_address <= palette_bank_fastio & std_logic_vector(register_number(7 downto 0));
          palette_we(3) <= '1';
        elsif register_number>=512 and register_number<768 then
          -- @IO:C65 $D200-$D2FF VIC-III:PALGREEN green palette values (reversed nybl order)
          palette_fastio_address <= palette_bank_fastio & std_logic_vector(register_number(7 downto 0));
          palette_we(2) <= '1';
        elsif register_number>=768 and register_number<1024 then
          -- @IO:C65 $D300-$D3FF VIC-III:PALBLUE blue palette values (reversed nybl order)
          palette_fastio_address <= palette_bank_fastio & std_logic_vector(register_number(7 downto 0));
          palette_we(1) <= '1';
        else
          null;
        end if;
      end if;
    end if;

  end process;

  process(pixelclock,all_pause,reg_h640,ramaddress,this_screen_row_fetch_address,glyph_full_colour,
          inborder,inborder_drive,inborder_drive2) is
    variable indisplay : std_logic := '0';
    variable card_bg_colour : unsigned(7 downto 0) := (others => '0');
    variable card_fg_colour : unsigned(7 downto 0) := (others => '0');
    variable long_address : unsigned(31 downto 0) := (others => '0');
    variable next_glyph_number_temp : std_logic_vector(12 downto 0) := (others => '0');
    variable next_glyph_colour_temp : std_logic_vector(7 downto 0) := (others => '0');
    variable rb_v1, rb_v2 : unsigned(17 downto 0);    -- K325T fast RRB pixels
    variable yf : unsigned(11 downto 0);              -- K325T list mode: fetch side's displayy
    -- K325T fast token path
    variable fs_now, p_last, fast_ok, t_disp_fcm, t_disp_mono : boolean;
    variable fds : fp_dec_t;
    variable fb : unsigned(7 downto 0);
    variable fw : unsigned(63 downto 0);
    variable bgc : unsigned(7 downto 0);
    -- the decoded token becomes the token in flight (what FetchNextCharacter ..
    -- FetchTextCellColourAndSource would have left in the glyph_* registers)
    procedure fp_take is
    begin
      glyph_number <= n_glyph_number; background_colour_select <= n_bg_select;
      glyph_flip_horizontal <= n_flip_h; glyph_flip_vertical <= n_flip_v;
      glyph_with_alpha <= n_alpha; glyph_width_deduct <= n_width_deduct;
      glyph_goto <= n_goto; glyph_4bit <= n_4bit; glyph_full_colour <= n_full_colour;
      if n_list_in_exp = '1' then list_in_exp <= '1'; end if;
      if n_list_line_end = '1' then list_line_end <= '1'; end if;
      -- (K325T list mode: not for the token after a plain row's last one, see FetchTextCell)
      if n_short_line = '1'
        and not (end_of_row = '1' and row_list = '0' and (rl_en_s(1) = '1' or rv2_s(1) = '1')) then
        short_line <= '1'; short_line_length <= n_short_line_length;
      end if;
      draw_mask_blank <= n_draw_mask_blank;
      glyph_data_address <= n_glyph_data_address;
      character_data_from_rom <= n_from_rom;
      glyph_colour_drive <= n_colour_drive;
      glyph_bold_drive <= n_bold_drive; glyph_underline_drive <= n_underline_drive;
      glyph_reverse_drive <= n_reverse_drive; glyph_visible_drive <= n_visible_drive;
      glyph_blink_drive <= n_blink_drive;
      if n_goto = '1' then screenline_draw_mask_drive <= n_draw_mask_drive; end if;
      glyph_bold_and_reverse <= n_bold_and_reverse;
      fp_goto_pend <= n_goto;
      fp_dec <= D0;                              -- the next token (fds below: D0 this cycle)
      fds := D0;
    end procedure;
  begin
    if rising_edge(pixelclock) and all_pause='0' then
      -- K325T fast token path: this cycle's line start, and whether the painter is in the last
      -- pixel cycle of its glyph (fast path only: then it can take the next glyph right away)
      fs_now := is_fetch_start = '1' and last_was_fetch_start = '0';
      t_disp_fcm := false; t_disp_mono := false;
      fds := fp_dec;
      fast_ok := rb_fast_s(1) = '1' and (raster_buffer_write_address(9 downto 0) <= 1020 or rrb_wraparound_allowed = '1');
      case paint_fsm_state is
        when PaintFullColourPixels | Paint4bitColourPixels =>
          p_last := (fast_ok and paint_bits_remaining = 1) or (not fast_ok and paint_bits_remaining = 0)
                    or (fast_ok and paint_bits_remaining = 0);
        when PaintMonoBits =>
          p_last := (fast_ok and paint_bits_remaining = 2) or (paint_bits_remaining <= 1);
        when others =>
          p_last := false;
      end case;
      -- K325T list mode lead (rl_shift, see the signal): the row schedule runs one line ahead
      if rl_shift = '1' then
        yf := displayy_p1;
      elsif rl_shift2 = '1' then
        yf := displayy_p2;
      else
        yf := displayy;
      end if;

      report "ycounter = $" & to_hstring(ycounter) & ", ycounter_driver = $" & to_hstring(ycounter_driver);
      ycounter <= ycounter_driver;
      vgared <= vgared_driver;
      vgagreen <= vgagreen_driver;
      vgablue <= vgablue_driver;

      -- Capture pixel at prescribed position to support automated testing
      -- and display red cross-hairs
      if xcounter=debug_x xor ycounter=debug_y then
        -- Draw cross-hairs at debug coordinates
        vgared <= x"FF";
        vgagreen <= x"00";
        vgablue <= x"00";
      end if;
      if (xcounter=debug_x) and (ycounter=debug_y) then
        debug_pixel_red <= vgared_driver;
        debug_pixel_green <= vgagreen_driver;
        debug_pixel_blue <= vgablue_driver;
      end if;

      sprite_data_offsets(sprite_number_for_data_rx) <= sprite_data_offset_rx;
      -- Ask for the next one (8 sprites + 8 C65 bitplanes)
      if sprite_number_counter = 15 then
        sprite_number_counter <= 0;
        sprite_number_for_data_tx <= 0;
      else
        sprite_number_counter <= sprite_number_counter + 1;
        sprite_number_for_data_tx <= sprite_number_for_data_tx + 1;
      end if;

      pixel_x_640 <= safe_to_integer(xcounter);
      pixel_x_800 <= safe_to_integer(xcounter);
      pixel_y_scale_400 <= chargen_y_scale_400(3 downto 0);
      pixel_y_scale_200 <= chargen_y_scale_200(3 downto 0);

      -- But also export native X position, e.g., for touch panel interface to
      -- match up with visual keyboard

      -- XXX Why do we need these fudge factors to make everything line up?
      -- Subtract 10 for video pipeline depth?
      native_x_640 <= safe_to_integer(vicii_xcounter_640 - 10);
      -- Subtract 34 for some reason?
      native_y_200 <= safe_to_integer(vicii_ycounter - 34);
      native_y_400 <= safe_to_integer(displayy);

      --chardata_drive <= unsigned(chardata);
      --paint_chardata <= chardata_drive;
      paint_chardata <= unsigned(chardata);
      ramdata_drive <= ramdata;
      if row_list = '1' then
        paint_ramdata <= mono_l;                  -- K325T step 5 (see cc_act)
      else
        paint_ramdata <= ramdata_drive;
      end if;

      sprite_fetch_drive <= '0';
      inborder_drive2 <= inborder_drive;
      inborder_drive <= inborder;

      -- Acknowledge IRQs after reading $D019
      irq_raster <= irq_raster and (not ack_raster);
      irq_rasterx <= irq_rasterx and (not ack_rasterx);
      irq_lightpen <= irq_lightpen and (not ack_lightpen);
      irq_collisionspritebitmap <= irq_collisionspritebitmap and (not ack_collisionspritebitmap);
      irq_collisionspritesprite <= irq_collisionspritesprite and (not ack_collisionspritesprite);
      -- Set IRQ line status to CPU
      irq_drive <= not ((irq_raster and mask_raster)
                        or (irq_rasterx and mask_rasterx and irq_extras_enable)
                        or (irq_lightpen and mask_lightpen)
                        or (irq_collisionspritebitmap and mask_collisionspritebitmap)
                        or (irq_collisionspritesprite and mask_collisionspritesprite));

      -- Add new sprite collision bits to the bitmap
      case vicii_sprite_sprite_collision_map is
        when "00000000" | "10000000" | "01000000" | "00100000" | "00010000" |
             "00001000" | "00000100" | "00000010" | "00000001" =>
          vicii_sprite_sprite_collisions <= vicii_sprite_sprite_collisions and (vicii_sprite_sprite_collisions'range => not(clear_collisionspritesprite));
        when others =>
          -- Sprite collision, so add it to the existing map
          vicii_sprite_sprite_collisions
            <= (vicii_sprite_sprite_collisions and (vicii_sprite_sprite_collisions'range => not(clear_collisionspritesprite))) or
               (vicii_sprite_sprite_collision_map and (vicii_sprite_sprite_collision_map'range => not(postsprite_inborder)));
      end case;
      -- Sprite foreground collision is easier: always add it on.
      vicii_sprite_bitmap_collisions
        <= (vicii_sprite_bitmap_collisions and (vicii_sprite_bitmap_collisions'range => not(clear_collisionspritebitmap))) or
           (vicii_sprite_bitmap_collision_map and (vicii_sprite_bitmap_collision_map'range => not(postsprite_inborder)));

      -- Now check if we need to trigger an IRQ due to sprite collisions:
      if vicii_sprite_sprite_collisions /= "00000000" then
        irq_collisionspritesprite <= '1';
      end if;
      if vicii_sprite_bitmap_collisions /= "00000000" then
        irq_collisionspritebitmap <= '1';
      end if;

      -- Detect lightpen event (must appear above irq_lightpen assignment above)
      if touch_active='1' and xcounter_drive(11 downto 0) = touch_x and displayy = touch_y then
        irq_lightpen <= '1';
        lightpen_x_latch <= touch_x(11 downto 4);
        lightpen_y_latch <= touch_y(9 downto 2);
      end if;

      -- reset masks IRQs immediately
      if irq_drive = '0' then
        irq <= '0';
      else
        irq <= 'H';
      end if;

      -- Hsync has trouble meeting timing, so I have spread out the control
      -- over 3 cycles, including one pure drive cycle, which should hopefully
      -- fix it once and for all.
      xcounter_delayed <= xcounter;

      if pixel_newframe_internal='1' then
        -- C65/VIC-III style 1Hz blink attribute clock
        viciii_blink_phase_counter <= viciii_blink_phase_counter + 1;
        if viciii_blink_phase_counter = 30 then
          viciii_blink_phase_counter <= 0;
          viciii_blink_phase <= not viciii_blink_phase;
        end if;

        -- 4Hz 1581 drive LED blink clock
        drive_blink_phase_counter <= drive_blink_phase_counter + 1;
        if drive_blink_phase_counter = 15 then
          drive_blink_phase_counter <= 0;
          drive_blink_phase <= not drive_blink_phase;
        end if;
      end if;

      indisplay :='1';

      -- Make variably delayed xcounter signal, so that we can correct delay
      -- for pipeline depth
      external_pixel_strobe_log(0) <= external_pixel_strobe_in;
      external_pixel_strobe_log(31 downto 1) <= external_pixel_strobe_log(30 downto 0);
      if external_frame_x_zero_latched='0' and external_pixel_strobe_log(reg_xcounter_delay)='1' then
        report "PIXEL xcounter_pipeline_delayed increased";
        xcounter_pipeline_delayed <= xcounter_pipeline_delayed + 1;
      elsif external_frame_x_zero_latched='1' then
        xcounter_pipeline_delayed <= 0;
      end if;

      if external_frame_x_zero_latched='0' and external_pixel_strobe_log(0)='1' and vga_in_frame='1' then
        raster_buffer_read_address(9 downto 0) <= raster_buffer_read_address_next(9 downto 0);
        raster_buffer_read_address_sub <= raster_buffer_read_address_sub_next;
        report "PIXEL pixel strobe edge";
        xcounter <= xcounter + 1;
        -- Allow H640 sprites to begin from far-left
        if (xcounter = sprite_first_x) or (sprite_h640='1') then
          sprite_x_counting <= '1';
        end if;
        if sprite_x_counting = '1' then
          report "sprite_x_counting=1, vicii_xcounter_640 = " & to_hstring(vicii_xcounter_640);
          vicii_xcounter_640 <= vicii_xcounter_640 + 1;
          sprite_x_scale_toggle <= not sprite_x_scale_toggle;
          if sprite_x_scale_toggle = '1' then
            vicii_xcounter_320 <= vicii_xcounter_320 + 1;
          end if;
        end if;
      end if;

      if external_frame_x_zero_latched = '1' then
        -- End of raster reached.
        -- Bump raster number and start next raster.
        report "XZERO: ycounter=" & integer'image(safe_to_integer(ycounter));
        xcounter <= (others => '0');
        sprite_x_counting <= '0';
        sprite_x_scale_toggle <= '0';

        -- Make delayed stopping of chargen rendering take effect
        -- (this has to happen on the following raster, because we determine
        -- end of screen when we pre-compute the next row address)
        if last_external_frame_x_zero_latched = '0' then
          -- K325T list mode lead (see rl_shift): the fetch side's mask of the line ending
          -- now (rl_shift) or of the line before (rl_shift2) masks the line starting now
          rl_mask1 <= before_y_chargen_start and not justbefore_y_chargen_start;
          if rl_shift2 = '1' then
            rl_mask <= rl_mask1;
          else
            rl_mask <= before_y_chargen_start and not justbefore_y_chargen_start;
          end if;
          if stop_chargen_raster_counter /= 0 then
            stop_chargen_raster_counter <= stop_chargen_raster_counter - 1;
          end if;
        end if;
        if stop_chargen_raster_counter = 1 then
          before_y_chargen_start <= '1';
        end if;

        vicii_ycounter_scale <= vicii_ycounter_scale_minus_zero;
        report "LEGACY vicii_ycounter_scale = " & integer'image(safe_to_integer(vicii_ycounter_scale))
          & ", vicii_ycounter_max_phase = " & integer'image(safe_to_integer(vicii_ycounter_max_phase))
          & ", text_mode=" & std_logic'image(text_mode)
          & ", screen_ram_base=$" & to_hstring(screen_ram_base)
          & ", character_set_base=$" & to_hstring(character_set_address)
          & ", screen_ram_buffer_read_address=" & integer'image(safe_to_integer(screen_ram_buffer_read_address))
          & ", first_card_of_row=" & integer'image(safe_to_integer(first_card_of_row))
          & ", chargen_y=" & integer'image(safe_to_integer(chargen_y))
          & ", chargen_y_sub = " & integer'image(safe_to_integer(chargen_y_sub))
          ;
        vicii_xcounter_320 <= to_unsigned(0,9);
        vicii_xcounter_640 <= to_unsigned(0,10);

        chargen_active <= '0';
        chargen_active_soon <= '0';

        -- Make VIC-II triggered raster interrupts edge triggered, since one
        -- emulated VIC-II raster is ~63*48 = ~3,000 cycles, and many C64
        -- raster routines may finish in that time, and might get confused if
        -- a raster interrupt gets retriggered too soon.  This will also cause
        -- some problems for software that really expects multiple interrupts
        -- on the same raster line, but that should be really quite rare.
        -- We could allow multiple triggerings per raster when CPU is at <= 3.5MHz,
        -- and only edge trigger it when at full speed?
        -- As we have a one raster line delay in display, we delay the raster
        -- interrupt by one line also, so that it better matches what we see on
        -- a VIC-II.
        if enable_raster_delay='1' then
          vicii_raster_compare_plus_one <= vicii_raster_compare + 1;
        else
          vicii_raster_compare_plus_one <= vicii_raster_compare;
        end if;
        if (xcounter_drive = viciv_rasterx_compare) then
          irq_rasterx <= '1';
        end if;
        if (vicii_is_raster_source='1') and (vicii_ycounter = vicii_raster_compare_plus_one(8 downto 0)) and last_vicii_ycounter /= vicii_ycounter then
          irq_raster <= '1';
        end if;
        last_vicii_ycounter <= vicii_ycounter;
        -- Make VIC-IV raster interrupts edge triggered, as well, to avoid re-triggering
        -- of the raster interrupt at the end of the raster line (eg. if the raster
        -- interrupt has already been acknowledged before the raster line reaches the end).
        -- Retriggering would happen once external_frame_x_zero_latched = '1' but ycounter
        -- not yet updated (it will get updated two clock cycles later).
        if (vicii_is_raster_source='0') and (ycounter = vicii_raster_compare_plus_one) and last_ycounter /= ycounter then
          irq_raster <= '1';
        end if;
        last_ycounter <= ycounter;

        if last_external_frame_x_zero_latched='0' then
          -- ... update Y position, even during VSYNC, since frame timing is
          -- now exact.
          report "XZERO: incrementing ycounter from " & integer'image(safe_to_integer(ycounter));
          ycounter_driver <= ycounter_driver + 1;

          displaycolumn0 <= '1';
          displayy <= displayy + 1;
          displayy_p1 <= displayy_p1 + 1;               -- K325T list mode lead
          displayy_p2 <= displayy_p2 + 1;
          if displayy(4)='1' then
            displayline0 <= '0';
          end if;

          if vicii_ycounter_phase = vicii_ycounter_max_phase then
            if safe_to_integer(vicii_ycounter) /= vicii_max_raster then
              vicii_ycounter <= vicii_ycounter + 1;
              -- Indicate fixed point on the frame
              -- (used by CPU to time entry into freeze routine for proper synchronisation.
              --  Also helps thumbnails to not have tears in them).
              if vicii_ycounter = to_unsigned(255,9) then
                viciv_frame_indicate <= '1';
              else
                viciv_frame_indicate <= '0';
              end if;
              -- We update V400 position in this case, bug also in the
              -- alternate case below
              vicii_ycounter_v400 <= vicii_ycounter_v400 + 1;
            end if;
            vicii_ycounter_continuous <= vicii_ycounter_continuous + 1;

            if vicii_ycounter_max_phase = 0 then
              -- Calculate raster number for sprites.
              if vicii_ycounter = (safe_to_integer(vicii_max_raster) + 2 - safe_to_integer(sprite_y_adjust)) then
                vicii_sprite_ycounter <= to_unsigned(0,9);
              else
                vicii_sprite_ycounter <= vicii_ycounter_continuous - 2  + safe_to_integer(sprite_y_adjust);
              end if;
            end if;

            vicii_ycounter_phase <= (others => '0');
            -- All visible rasters are now equal height
            -- (we take up the slack using vertical_flyback fast raster stepping,
            -- and allow arbitrary setting of first raster of the VGA frame).
            vicii_ycounter_max_phase <= vicii_ycounter_scale;
          else
            -- In the middle of a VIC-II logical raster, so just increase phase.
            vicii_ycounter_phase <= vicii_ycounter_phase + 1;
            -- But also bump V400 raster if required
            if safe_to_integer(vicii_ycounter_phase) =  safe_to_integer(vicii_ycounter_max_phase(3 downto 1)) then
              vicii_ycounter_v400 <= vicii_ycounter_v400 + 1;
            end if;

            -- Calculate raster number for sprites.
            -- The -2 is an adjustment factor to make the sprites line up correctly
            -- on the screen.
            -- This is done on an "off" line, so that the sprites line up properly
            if vicii_ycounter = (safe_to_integer(vicii_max_raster) + 2 - safe_to_integer(sprite_y_adjust)) then
              vicii_sprite_ycounter <= to_unsigned(0,9);
            else
              vicii_sprite_ycounter <= vicii_ycounter_continuous - 2 + safe_to_integer(sprite_y_adjust);
            end if;

          end if;
        end if;
      end if;

      -- If we got far along the last line to make it look real, and ...
      last_external_frame_y_zero <= external_frame_y_zero;
      -- K325T list mode v2: snapshot the object table once per frame (top of the frame, far
      -- from the first text row), unless the program holds it
      rv2_s <= rv2_s(0) & rrb_v2_en;
      hold_s <= hold_s(0) & obj_hold;
      exp_copy_start <= '0';
      if external_frame_y_zero = '0' and last_external_frame_y_zero='1'
         and rv2_s(1) = '1' and hold_s(1) = '0' then
        exp_copy_start <= '1';
      end if;
      -- v2 collisions: a pass per frame (after the copy; with HOLD on the held snapshot)
      exp_col_tick <= '0';
      if external_frame_y_zero = '0' and last_external_frame_y_zero='1' and rv2_s(1) = '1' then
        exp_col_tick <= '1';
      end if;
      if external_frame_y_zero = '0' and last_external_frame_y_zero='1' then
        -- Start of next frame
        report "Starting new frame. ycounter_driver <= 0";

        ycounter_driver <= (others =>'0');
        report "LEGACY: chargen_y_sub = 0, first_card_of_row = 0 due to start of frame";
        chargen_y_sub <= (others => '0');
        first_card_of_row <= (others => '0');

        displayy <= (others => '0');
        displayy_p1 <= to_unsigned(1,12);               -- K325T list mode lead
        displayy_p2 <= to_unsigned(2,12);
        -- K325T list mode lead: on or off for the whole frame (NORRDEL = 0 already double
        -- buffers; DBLRR fetches every other line only: both keep their own timing)
        rl_shift <= (rl_en_s(1) or rv2_s(1)) and no_raster_buffer_delay and not raster_buffer_double_line;
        rl_shift2 <= (rl_en_s(1) or rv2_s(1)) and no_raster_buffer_delay and raster_buffer_double_line;
        displayline0 <= '1';
        indisplay := '0';
        report "clearing indisplay because xcounter=0" severity note;
        screen_row_address <= screen_ram_base(19 downto 0);
        display_row_number <= to_unsigned(0,8);

        -- Reset VIC-II raster counter to first raster for top of frame
        -- (the preceeding rasters occur during vertical flyback, in case they
        -- have interrupts triggered on them).
        vicii_ycounter_phase <= to_unsigned(1,4);
        vicii_ycounter <= vicii_first_raster;
        vicii_ycounter_continuous <= vicii_first_raster;
        vicii_ycounter_v400 <= (others =>'0');
        vicii_ycounter_phase_v400 <= to_unsigned(1,4);

      end if;

      if xcounter<frame_h_front then
        xfrontporch <= '1';
      else
        xfrontporch <= '0';
      end if;
      if external_frame_x_zero_latched='1' then
        -- tell frame grabber about each new raster
        pixel_newraster <= '1';
      else
        pixel_newraster <= '0';
      end if;

      -- Work out when the horizonal back porch starts.
      -- The edge is used to trigger drawing of the next raster into the raster
      -- buffer.
      -- We actually want to trigger this as early as possible, so that sprite
      -- fetching doesn't run over into the next raster line.
      -- 30MHz pixel clock @ 50Hz display means we will catch up 3.3 pixels
      -- per pixel, so we can't start before (display_width - (display_width/3.3)).

      if xcounter=0 then
        report "stopping drawing at start of next raster";
        chargen_active <= '0';
        chargen_active_soon <= '0';
        raster_buffer_read_address(10) <= raster_buffer_half_toggle;
        raster_buffer_max_write_address_prev <= raster_buffer_max_write_address_hold;
        report "setting raster_buffer_max_write_address_prev to $" & to_hstring(raster_buffer_max_write_address_hold);
      end if;
      if raster_buffer_read_address_next(9 downto 0) > raster_buffer_max_write_address_prev
         and cu_s(1) = '0' then                  -- (K325T XCTL bit 3: the full text width)
        report "stopping character generator due to buffer exhaustion"
          severity note;
        chargen_active <= '0';
        chargen_active_soon <= '0';
      end if;

      -- Work out where in the current character we seem to be
      -- (and allowing for smooth scrolling etc during drawing of the frame)
      -- (K325T list mode lead: yf = displayy, or displayy + 1 with rl_shift)
      if reg_v400='1' then
        if y_chargen_start > yf then
          pixels_since_last_char <= "000";
        else
          pixels_since_last_char <= to_unsigned(safe_to_integer(yf) - safe_to_integer(y_chargen_start),3) + 1;
        end if;
      else
        if y_chargen_start > yf(11 downto 1) then
          pixels_since_last_char <= "000";
        else
          pixels_since_last_char <= to_unsigned(safe_to_integer(yf(11 downto 1)) - safe_to_integer(y_chargen_start),3)
                                    -- Magic fudge factor to get everything
                                    -- lining up correctly
                                    + to_unsigned(safe_to_integer(y_chargen_start(3 downto 1)) + 1,3);
        end if;
      end if;

      last_was_fetch_start <= is_fetch_start;
      is_fetch_start <= '0';
      if raster_buffer_double_line='0' or ycounter(0)='0' then
        if no_raster_buffer_delay='0' then
          if xcounter=(safe_to_integer(frame_h_front)+display_fetch_start) then
            is_fetch_start <= '1';
          end if;
        else
          if xcounter=(safe_to_integer(frame_h_front)+display_fetch_start) then
            is_fetch_start <= '1';
          end if;
        end if;
      end if;
      if is_fetch_start='1' and last_was_fetch_start='0' then
        -- Start of filling raster buffer.
        -- We don't need to double-buffer, as we start filling from the back
        -- porch of the previous line, hundreds of cycles before the start of
        -- the next line of display.
        report "RASTER FETCH: start of fetch in preparation for the next raster";

        report "ZEROing screen_ram_buffer_read_address" severity note;
        screen_ram_buffer_read_address <= to_unsigned(0,11);

        -- Some house keeping first:
        -- Reset write address in raster buffer
        -- Set write address to all 1's, so that it wraps to zero at the start
        raster_buffer_write_address(9 downto 0) <= (others => '1');
        -- Make sure we read and write to opposite halves of the raster buffer
        -- (K325T list mode lead: double buffered as with NORRDEL = 0)
        raster_buffer_write_address(10) <= raster_buffer_half_toggle xor (no_raster_buffer_delay and not rl_shift and not rl_shift2);
        raster_buffer_half_toggle <= not raster_buffer_half_toggle;
        if list_saved_max > raster_buffer_max_write_address then      -- K325T list mode
          raster_buffer_max_write_address_hold <= list_saved_max;
        else
          raster_buffer_max_write_address_hold <= raster_buffer_max_write_address;
        end if;
        report "setting raster_buffer_max_write_address_hold to $" & to_hstring(raster_buffer_max_write_address);

        -- K325T fast token path: off until this line's FetchFirstCharacter
        fp_line <= '0'; fp_dec <= DIdle; fp_goto_pend <= '0';
        -- K325T XCTL bit 3: clear the new write half's valid bits in 4 cycles
        cu_clr_cnt <= 4;

        -- Reset glyph Y offset each raster line
        glyph_y_offset <= 0;

        -- Reset glyph using nve y offset
        glyph_nve_y_offset <= '0';

        -- Hold chargen_y for entire fetch, so that we don't get glitching when
        -- chargen_y increases part way through resulting in characters on
        -- right of display shifting up one physical pixel.
        chargen_y_hold <= chargen_y;

        if chargen_y_hold = chargen_y then
          charrow_repeated <= '1';
        else
          charrow_repeated <= '0';
        end if;

        -- Work out colour ram address
        report "COLOURRAM: Setting colourramaddress via first_card_of_row."
          & " text_mode=" & std_logic'image(text_mode)
          & ", sixteenbit_charset=" & std_logic'image(sixteenbit_charset);
        colourramaddress <= colour_ram_base + first_card_of_row;
        -- Work out the screen ram address.  We only need to re-fetch screen
        -- RAM if first_card_of_row is different to last time.
        prev_first_card_of_row <= first_card_of_row;

        -- Set all signals for both eventuality, since none are shared between
        -- the two paths.  This helps keep the logic shallow.

        -- Delay application of screen_ram_base address changes by one raster line
        -- so match behaviour of VIC-II
        if (text_mode='0') and (sixteenbit_charset='1') then
          -- bitmap mode in sixteen bit char mode uses 2 screen RAM bytes per
          -- card, but not two bitmap bytes, so we have to increment double
          screen_row_current_address
            <= to_unsigned(safe_to_integer(screen_ram_base(19 downto 0))
                           + safe_to_integer(first_card_of_row) + safe_to_integer(first_card_of_row),20);
        else
          screen_row_current_address
            <= to_unsigned(safe_to_integer(screen_ram_base(19 downto 0))
                           + safe_to_integer(first_card_of_row),20);
        end if;
        card_of_row <= (others =>'0');
        screen_ram_buffer_write_address <= to_unsigned(0,11);
        short_line <= '0';
        report "ZEROing screen_ram_buffer_write_address" severity note;
        -- Finally decide which way we should go
        if safe_to_integer(first_card_of_row) /= safe_to_integer(prev_first_card_of_row) then
          raster_fetch_state_init <= FetchScreenRamLine;
          raster_fetch_state <= FetchScreenRamLine;
          -- From Section 3.5 of http://www.zimmers.net/cbmpics/cbm/c64/vic-ii.txt
          -- (but has problems for some reason)
          if (blank = '0') and ((vertical_border='0') or justbefore_y_chargen_start='1') and (vicii_ycounter<248) and (vicii_ycounter>=40) then
            badline_toggle_internal <= not badline_toggle_internal;
            badline_toggle <= not badline_toggle_internal;
            report "BADLINE @ y = " & integer'image(safe_to_integer(displayy)) severity note;
            report "BADLINE first_card_of_row = %" & to_string(std_logic_vector(first_card_of_row)) severity note;
            report "BADLINE prev_first_card_of_row = %" & to_string(std_logic_vector(prev_first_card_of_row)) severity note;
          else
            report "BADLINE in vertical border suppressed @ y = " & integer'image(safe_to_integer(displayy)) severity note;
          end if;
        else
          report "noBADLINE" severity note;
          raster_fetch_state_init <= FetchFirstCharacter;
          raster_fetch_state <= FetchFirstCharacter;
        end if;
        raster_fetch_restart <= '1';

        -- Now check if we have tipped over from one logical pixel row to another.
        chargen_y <= chargen_y_next;
        if chargen_y_sub=chargen_y_scale then
          chargen_y_next <= chargen_y_next + 1;
          if chargen_y_scale /= 0 then
            if chargen_y_next = "111" then
              report "bumping chargen_y to " & integer'image(safe_to_integer(chargen_y)) severity note;
              bump_screen_row_address<='1';
            end if;
            if pixels_since_last_char = "111" then
              chargen_y_next <= "000";
            end if;
          else
            if chargen_y_next = "111" then
              report "LEGACY: Bumping screen row address one raster early for V400";
              bump_screen_row_address<='1';
            end if;
            if pixels_since_last_char = "110" then
              chargen_y_next <= "000";
            end if;
          end if;
          if (chargen_y_scale=x"02") and (chargen_y(0)='1') then
            chargen_y_sub <= "00001";
          else
            report "LEGACY: chargen_y_sub = 0 due increment of chargen_y";
            chargen_y_sub <= (others => '0');
          end if;
        else
          report "LEGACY: chargen_y_sub incremented";
          chargen_y_sub <= chargen_y_sub + 1;
        end if;

        if bump_screen_row_address='1' then
          bump_screen_row_address <= '0';

          -- Compute the address for the screen row.
          if (text_mode='0') and (sixteenbit_charset='1') then
            -- 16bit charset mode + bitmap mode = 2 bytes screen memory per card,
            -- so that we can pick foreground and background colours from full
            -- 256-colour palette.
            screen_row_address <= screen_ram_base(19 downto 0) + first_card_of_row;
          else
            screen_row_address <= screen_ram_base(19 downto 0) + first_card_of_row;
          end if;

          if before_y_chargen_start='0' then
            -- Increment card number every "bad line"
            report "LEGACY: Advancing first_card_of_row due to end of character";
            first_card_of_row <= to_unsigned(safe_to_integer(first_card_of_row) + row_advance,16);
            display_row_number <= display_row_number + 1;
            if display_row_number = display_row_count then
              -- Stop chargen on next raster
              stop_chargen_raster_counter <= stop_chargen_delay;
            end if;
          else
            report "LEGACY: NOT advancing first_card_of_row due to end of character (before_y_chargen_start=1)";
          end if;
        end if;

      end if;

      if xcounter<(safe_to_integer(frame_h_front)+display_width) then
        xbackporch <= '0';
        xbackporch_edge <= '0';
      else
        xbackporch <= '1';
        xbackporch_edge <= not xbackporch;
      end if;

      -- Work out if the border is active
      if displayy=border_y_bottom then
        vertical_border <= '1';
      end if;
      if displayy=border_y_top then
        vertical_border <= '0';
      end if;

      if xcounter<border_x_left or xcounter>=border_x_right or
        vertical_border='1' then
        inborder<='1';
        viciv_flyback <= '1';
      else
        inborder<=blank;
        viciv_flyback <= '0';
      end if;

      if vga_in_frame = '0' then
        indisplay := '0';
        report "clearing indisplay because of horizontal porch" severity note;
      end if;

      -- Calculate vertical flyback and related signals
      if ycounter=frame_v_front then
        vert_in_frame <= '1';
      elsif ycounter=0 then
        -- Start of vertical flyback
        indisplay := '0';
        report "clearing indisplay because of vertical porch";

        vert_in_frame <= '0';
        -- Send a 1 cycle pulse at the end of each frame for
        -- streaming display module to synchronise on.
        if vert_in_frame = '1' then
          pixel_frame_toggle <= not pixel_frame_toggle;
          pixel_newframe <= '1';
          pixel_newframe_internal <= '1';
        else
          pixel_newframe <= '0';
          pixel_newframe_internal <= '0';
        end if;

      end if;

      -- Generate pixel clock based on x640 clock
      last_vicii_xcounter_640 <= vicii_xcounter_640;
      if vicii_xcounter_640 /= last_vicii_xcounter_640 then
        lcd_pixel_strobe <= indisplay;
        report "lcd_pixel_strobe = " & std_logic'image(indisplay);
      else
        lcd_pixel_strobe <= '0';
        report "lcd_pixel_strobe = 0";
      end if;

      report "chargen_active=" & std_logic'image(chargen_active)
        & ", xcounter = " & to_string(std_logic_vector(xcounter))
        & ", x_chargen_start = " & to_string(std_logic_vector(x_chargen_start)) severity note;
      if xcounter=border_x_right then
        -- Stop character generator as soon as we hit the right border
        -- so that we can switch to fetching sprite data for the next raster.
        report "Masking chargen_active based on xcounter<border_x_right" severity note;
        chargen_active <= '0';
        chargen_active_soon <= '0';
      end if;
      x_chargen_start_minus1 <= x_chargen_start - 1;
      if xcounter = x_chargen_start_minus1 then
        -- trigger next card at start of chargen row
        chargen_x <= (others => '0');
        report "reset chargen_x" severity note;
      end if;
      if xcounter = x_chargen_start then
        -- Gets masked to 0 below if displayy is above y_chargen_start
        chargen_active <= '1';
        report "Setting chargen_active based on xcounter = x_chargen_start" severity note;
        chargen_active_soon <= '0';
      end if;
      y_chargen_start_minus_one <= y_chargen_start-1;
      -- (K325T list mode lead: yf, the fetch side's line; the frame top reset stays on displayy)
      if yf = (y_chargen_start_minus_one) then
        justbefore_y_chargen_start <= '1';
      else
        justbefore_y_chargen_start <= '0';
      end if;
      if displayy = "000000000000" then
        before_y_chargen_start <= '1';
      elsif yf = y_chargen_start then
        before_y_chargen_start <= '0';
      end if;
      -- Allow y_chargen_start to be shifted down mid-frame to allow
      -- multiple character displays per screen, e.g., for fixed vs scrolling.
      if yf < y_chargen_start_minus_one then
        before_y_chargen_start <= '1';
      end if;
      if before_y_chargen_start = '1' and justbefore_y_chargen_start='0' then
        -- We have to reset the chargen Y value pipeline.
        -- So chargen_y goes to zero, but we then need to make sure we don't
        -- accidentally double print the top line of pixels, so we pre-advance
        -- chargen_y_sub or chargen_y_next as appropriate.
        chargen_y <= "000";
        if chargen_y_scale = 0 then
          chargen_y_next <= "001";
          chargen_y_sub <= "00000";
        else
          chargen_y_next <= "000";
          chargen_y_sub <= "00001";
        end if;
        if chargen_y_sub /= 0 then
          report "LEGACY: Reseting chargen_y_sub";
        end if;
        if rl_shift = '0' and rl_shift2 = '0' then  -- K325T list mode lead: rl_mask below
          chargen_active <= '0';
          chargen_active_soon <= '0';
        end if;
        -- Force badline so that moving chargen down results in fresh loading
        -- of the first line of text.
        prev_first_card_of_row <= (others => '1');
        report "Masking chargen_active based on displayy<y_chargen_start" severity note;

      end if;
      -- K325T list mode lead: the text-area mask of the line shown now is the fetch side's mask
      -- of the line before (which, one line ahead, is the original mask of this line)
      if (rl_shift = '1' or rl_shift2 = '1') and rl_mask = '1' then
        chargen_active <= '0';
        chargen_active_soon <= '0';
      end if;

      if xcounter(5)='1' and xcounter(4)='1' then
        displaycolumn0 <= '0';
      end if;
      if xcounter = 0 then
        report "ycounter = " & integer'image(safe_to_integer(ycounter))
          & ", before_y_chargen_start = " & std_logic'image(before_y_chargen_start)
          & ", chargen_y = " & integer'image(safe_to_integer(chargen_y))
          & ", chargen_y_sub = " & integer'image(safe_to_integer(chargen_y_sub))
          & ", chargen_active = " & std_logic'image(chargen_active)
          ;

      end if;

      if short_line='1' then
        row_advance <= short_line_length;
      else
        row_advance <= safe_to_integer(virtual_row_width);
      end if;

      viciv_outofframe <= (not indisplay_t3);

--      if indisplay_t3='1' then
      if inborder='1' or (bitplane_mode='1' and viciv_bitplane_chargen_on='0') then
        pixel_colour <= border_colour;
        pixel_alpha <= x"FF";
        report "VICIV: Drawing border" severity note;
      elsif chargen_active='0' then
        pixel_colour <= screen_colour;
        report "VICIV: no character pixel data as chargen_active=0" severity note;
      else
        -- Otherwise read pixel data from raster buffer
        if raster_buffer_read_address(9 downto 0) = to_unsigned(0,10) then
          report "LEGACY: Painting pixels from raster buffer";
        end if;
        report "VICIV: raster buffer reading next from = $" & to_hstring(raster_buffer_read_address)
          & "/$" & to_hstring(raster_buffer_max_write_address_prev)
          & ", pixel_colour = $" & to_hstring(raster_buffer_read_data(7 downto 0))
          & ", pixel_alpha = $" & to_hstring(raster_buffer_read_data(16 downto 9))
          & ", pixel_is_foreground = " & std_logic'image(raster_buffer_read_data(8))
          severity note;
        pixel_colour <= raster_buffer_read_data(7 downto 0);
        pixel_alpha <= raster_buffer_read_data(16 downto 9);
        -- 18th bit indicates to use primary or alternate palette
        pixel_alt_palette <= raster_buffer_read_data(17);
        -- 9th bit indicates foreground for sprite collission handling
        pixel_is_background <= not raster_buffer_read_data(8);
        pixel_is_foreground <= raster_buffer_read_data(8);
        -- K325T XCTL bit 3: a pixel this painting did not write is a background pixel (what a
        -- painted background pixel of the screen colour shows)
        if cu_s(1) = '1' and cu_vq = '0' then
          pixel_colour <= screen_colour;
          pixel_alpha <= x"FF";
          pixel_alt_palette <= '0';
          pixel_is_background <= '1';
          pixel_is_foreground <= '0';
        end if;
      end if;

      -- Make delayed versions of card number and x position so that we have time
      -- to fetch character row data.
      chargen_x_t1 <= chargen_x;
      chargen_x_t2 <= chargen_x_t1;
      chargen_x_t3 <= chargen_x_t2;
      charrow_t1 <= charrow;
      charrow_t2 <= charrow_t1;
      card_number_t1 <= card_number(7 downto 0);
      card_number_t2 <= card_number_t1;
      card_number_t3 <= card_number_t2;
      indisplay_t1 <= indisplay;
      indisplay_t2 <= indisplay_t1;
      indisplay_t3 <= indisplay_t2;

      -- We use a drive stage for these lines to preserve CPU timing.
      debug_cycles_to_next_card_drive <= debug_cycles_to_next_card;
      debug_chargen_active_drive <= debug_chargen_active;
      debug_chargen_active_soon_drive <= debug_chargen_active_soon;
      debug_raster_fetch_state_drive <= debug_raster_fetch_state;
      debug_paint_fsm_state_drive <= debug_paint_fsm_state;
      debug_charrow_drive <= debug_charrow;
      debug_charaddress_drive <= debug_charaddress;
      debug_character_data_from_rom_drive <= debug_character_data_from_rom;
      debug_screen_ram_buffer_address_drive <= debug_screen_ram_buffer_address;
      debug_raster_buffer_read_address_drive <= debug_raster_buffer_read_address;
      debug_raster_buffer_write_address_drive <= debug_raster_buffer_write_address;

      -- Actually, we use two drive stages since the video timing is so pernickety.
      -- The 2nd drive stage is driven by the cpuclock. Search for _drive2 to
      -- find it.

      if xcounter=debug_x and ycounter=debug_y then
        debug_cycles_to_next_card <= cycles_to_next_card;
        debug_chargen_active <= chargen_active;
        debug_chargen_active_soon <= chargen_active_soon;
        debug_raster_fetch_state <= raster_fetch_state;
        debug_paint_fsm_state <= paint_fsm_state;
        debug_charrow <= charrow;
--        debug_charaddress <= charaddress;
        debug_character_data_from_rom <= character_data_from_rom;
        debug_screen_ram_buffer_address <= screen_ram_buffer_read_address(9 downto 0);
        debug_raster_buffer_read_address <= raster_buffer_read_address(7 downto 0);
        debug_raster_buffer_write_address <= raster_buffer_write_address(7 downto 0);
      end if;

      -- Pixels have a two cycle pipeline to help keep timing contraints:

      report "PIXEL (" & integer'image(safe_to_integer(xcounter)) & "," & integer'image(safe_to_integer(displayy)) & ") : colour =\ $"
        & to_hstring(postsprite_pixel_colour)
        & ", RGBA = $" &to_hstring(palette_rdata)
        & ", alpha = $" & to_hstring(postsprite_alpha_value)
        & ", vga_in_frame = " & std_logic'image(vga_in_frame)
        & ", external_pixel_strobe = " & std_logic'image(external_pixel_strobe_in)
        severity note;

      -- 1. From pixel colour lookup RGB

      -- Feed pixel into sprite pipeline
      report "Feeding pixel+alpha to pipeline: pixel_colour=$" & to_hstring(pixel_colour)
        & ", pixel_alpha=$" & to_hstring(pixel_alpha);
      chargen_pixel_colour <= pixel_colour;
      chargen_alpha_value <= pixel_alpha;
      pixel_is_foreground_in <= pixel_is_foreground;
      pixel_is_background_in <= pixel_is_background;

      --report "SPRITE: pre_pixel_colour = $" & to_hstring(pixel_colour)
      --  & ", postsprite_pixel_colour = $" & to_hstring(postsprite_pixel_colour);

      -- One pixel delay required for alternate palette selection
      postsprite_alternate_palette_delayed <= postsprite_alternate_palette;

      -- Use palette bank 3 for "palette ROM" colours (C64 default colours
      -- should be placed there for C65 compatibility).
      if postsprite_pixel_colour(7 downto 4) = x"0" and reg_palrom='0' then
        -- Get pixel colour (which may be foreground or background)
        palette_address <= "11" & std_logic_vector(postsprite_pixel_colour);
        -- Get the colour of the background for doing the alpha blending
        alias_palette_address <= "11" & std_logic_vector(paint_background);
        if pixel_is_sprite='0' or sprite_alpha_blend_enables(postsprite_sprite_number)='0' then
          alpha_blend_alpha <= postsprite_alpha_value;
        else
          alpha_blend_alpha <= sprite_alpha_blend_value;
        end if;
      else
        palette_address(7 downto 0) <= std_logic_vector(postsprite_pixel_colour);
        alias_palette_address(7 downto 0) <= std_logic_vector(paint_background);
        if pixel_is_sprite='0' then
          if postsprite_alternate_palette_delayed='1' then
            palette_address(9 downto 8) <= palette_bank_chargen_alt;
            alias_palette_address(9 downto 8) <= palette_bank_chargen_alt;
          else
            palette_address(9 downto 8) <= palette_bank_chargen;
            alias_palette_address(9 downto 8) <= palette_bank_chargen_alt;
          end if;
          alpha_blend_alpha <= postsprite_alpha_value;
        else
          -- If the pixel is a sprite pixel, then apply the sprite alpha value.
          -- XXX The video pipeline currently doesn't tell us WHICH sprite the
          -- pixel belongs to, and we need to know this to be able to decide if
          -- we should alpha blend the sprite pixel to whatever is behind it.
          -- XXX We should blend to the non-sprite palette, so that sprites can
          -- have their own colours, but still fade into any background colour.
          palette_address(9 downto 8) <= palette_bank_sprites;
          alias_palette_address(9 downto 8) <= palette_bank_sprites;
          if sprite_alpha_blend_enables(postsprite_sprite_number)='0' then
            alpha_blend_alpha <= postsprite_alpha_value;
          else
            alpha_blend_alpha <= sprite_alpha_blend_value;
          end if;
        end if;
      end if;

      if xray_mode='1' then
        -- Debug mode enabled using switch 1 to show whether we think pixels
        -- are foreground, background, sprite and/or border.
        palette_address(9 downto 6) <= (others => '0');
        palette_address(5) <= postsprite_pixel_colour(0);
        palette_address(4) <= paint_background(0);
        -- background was always set due to bug with passing in foreground flag
        -- to background flag in sprite module.
        -- sprite + text = $7 (foreground, sprites and background!)
        -- text = $E (foreground and background, and not alpha sprite pixel)
        -- sprite white fg (=+$20) on blue bg (= no +$10) = $21, as expected
        if pixel_is_sprite='0' or sprite_alpha_blend_enables(postsprite_sprite_number)='0' then
          palette_address(3) <= '1';
        else
          palette_address(3) <= postsprite_inborder;
        end if;
        palette_address(2) <= pixel_is_foreground_out;
        palette_address(1) <= pixel_is_background_out;
        palette_address(0) <= pixel_is_sprite;
      end if;

      -- VIC-III palette RGB values have only the high bits in the low nybl, and
      -- the high-nybl is reserved.
      -- VIC-IV puts the low nybl in those reserved high-nybl bits
      vga_buffer_red(7 downto 4) <= unsigned(palette_rdata(27 downto 24));
      vga_buffer_red(3 downto 0) <= unsigned(palette_rdata(31 downto 28));
      vga_buffer_green(7 downto 4) <= unsigned(palette_rdata(19 downto 16));
      vga_buffer_green(3 downto 0) <= unsigned(palette_rdata(23 downto 20));
      vga_buffer_blue(7 downto 4) <= unsigned(palette_rdata(11 downto 8));
      vga_buffer_blue(3 downto 0) <= unsigned(palette_rdata(15 downto 12));

      --vga_buffer_red <= unsigned(postsprite_pixel_colour);
      --vga_buffer_green <= unsigned(postsprite_pixel_colour);
      --vga_buffer_blue <= unsigned(postsprite_pixel_colour);

      --vga_buffer_red <= unsigned(postsprite_pixel_colour);
      --vga_buffer_green <= unsigned(postsprite_pixel_colour);
      --vga_buffer_blue <= unsigned(postsprite_pixel_colour);

      -- The nybls have not been switched around for the alpha palette, so we
      -- have to do that here
      composite_bg_red(7 downto 4) <= unsigned(alias_palette_rdata(27 downto 24));
      composite_bg_red(3 downto 0) <= unsigned(alias_palette_rdata(31 downto 28));
      composite_bg_green(7 downto 4) <= unsigned(alias_palette_rdata(19 downto 16));
      composite_bg_green(3 downto 0) <= unsigned(alias_palette_rdata(23 downto 20));
      composite_bg_blue(7 downto 4) <= unsigned(alias_palette_rdata(11 downto 8));
      composite_bg_blue(3 downto 0) <= unsigned(alias_palette_rdata(15 downto 12));

      composite_red <= vga_buffer_red;
      composite_green <= vga_buffer_green;
      composite_blue <= vga_buffer_blue;

      report "Palette read address = $" & to_hstring(palette_address)
        & ", alpha palette read address = $" & to_hstring(alias_palette_address)
        & ", rdata=$" & to_hstring(palette_rdata)
        & ", alias rdata=$" & to_hstring(alias_palette_rdata);
      report "compositing background "
        & "R=$" & to_hstring(alias_palette_rdata(31 downto 24))
        & ", G=$" & to_hstring(alias_palette_rdata(23 downto 16))
        & ", B=$" & to_hstring(alias_palette_rdata(15 downto 8))
        &" with foreground "
        & "R=$" & to_hstring(vga_buffer_red)
        & ", G=$" & to_hstring(vga_buffer_green)
        & ", B=$" & to_hstring(vga_buffer_blue)
        & ", alpha=$" & to_hstring(raster_buffer_read_data(16 downto 9));

      report "alpha composited"
        & " red=$" & to_hstring(composited_red(9 downto 2))
        & ", green=$" & to_hstring(composited_green(9 downto 2))
        & ", blue=$" & to_hstring(composited_blue(9 downto 2));

      if compositer_enable='1' then
        vga_buffer2_red <= unsigned(composited_red(9 downto 2));
        vga_buffer2_green <= unsigned(composited_green(9 downto 2));
        vga_buffer2_blue <= unsigned(composited_blue(9 downto 2));
      else
        vga_buffer2_red <= vga_buffer_red;
        vga_buffer2_green <= vga_buffer_green;
        vga_buffer2_blue <= vga_buffer_blue;
      end if;

      vga_buffer3_red <= vga_buffer2_red;
      vga_buffer3_green <= vga_buffer2_green;
      vga_buffer3_blue <= vga_buffer2_blue;

      vga_buffer4_red <= vga_buffer3_red;
      vga_buffer4_green <= vga_buffer3_green;
      vga_buffer4_blue <= vga_buffer3_blue;

      vga_buffer5_red <= vga_buffer4_red;
      vga_buffer5_green <= vga_buffer4_green;
      vga_buffer5_blue <= vga_buffer4_blue;

      vga_filtered_red <= to_unsigned(safe_to_integer(vga_buffer5_red)
                                      +safe_to_integer(vga_buffer4_red)
                                      +safe_to_integer(vga_buffer3_red)
                                      +safe_to_integer(vga_buffer2_red),10);
      vga_filtered_green <= to_unsigned(safe_to_integer(vga_buffer5_green)
                                        +safe_to_integer(vga_buffer4_green)
                                        +safe_to_integer(vga_buffer3_green)
                                        +safe_to_integer(vga_buffer2_green),10);
      vga_filtered_blue <= to_unsigned(safe_to_integer(vga_buffer5_blue)
                                       +safe_to_integer(vga_buffer4_blue)
                                       +safe_to_integer(vga_buffer3_blue)
                                       +safe_to_integer(vga_buffer2_blue),10);

      if horizontal_filter='0' or reg_h1280='1' then
        vga_palin_red <= vga_buffer3_red;
        vga_palin_green <= vga_buffer3_green;
        vga_palin_blue <= vga_buffer3_blue;
      else
        vga_palin_red <= vga_filtered_red(9 downto 2);
        vga_palin_green <= vga_filtered_green(9 downto 2);
        vga_palin_blue <= vga_filtered_blue(9 downto 2);
      end if;

      if pal_simulate='1' and reg_h1280 = '0' and (reg_v400 = '0' or (reg_v400 = '1' and raster_buffer_double_line = '1')) then
        vga_out_red <= vga_palout_red;
        vga_out_green <= vga_palout_green;
        vga_out_blue <= vga_palout_blue;
      else
        vga_out_red <= vga_palin_red;
        vga_out_green <= vga_palin_green;
        vga_out_blue <= vga_palin_blue;
      end if;

      -- Also use pixel colour to produce RLE compressed video stream for
      -- pushing over ethernet on ff10::6565:6565:6565 IPv6 transient
      -- multi-cast address or via serial console.  However we do it, we first
      -- need to compress the video as much as possible, and to do that, we need
      -- the pixel stream.

      -- Announce each raster line.  Can also be used to identify start of frame.
      if xcounter=safe_to_integer(display_width) then
        report "FRAMEPACKER: end of raster announcement";
        pixel_newraster <= '1';
        pixel_strobe_out <= '0';
        pixel_y <= displayy;
      else
        -- output pixels as packed RGB instead of palette colours
        -- (this 8bpp format is what VNC uses anyway, so there is no functional
        -- loss of colour resolution).
        pixel_stream_out(7 downto 5) <= vga_buffer3_red(7 downto 5);
        pixel_stream_out(4 downto 2) <= vga_buffer3_green(7 downto 5);
        pixel_stream_out(1 downto 0) <= vga_buffer3_blue(7 downto 6);
        -- And also output full 24bit RGB, that the new frame packer uses
        pixel_red_out <= vga_buffer3_red;
        pixel_green_out <= vga_buffer3_green;
        pixel_blue_out <= vga_buffer3_blue;
        xcounter_last <= xcounter;
        if xcounter /= xcounter_last then
          -- XXX pixel_strobe_in should be fed through the pipeline and delayed
          -- to match, so that the correct pixels get latched.
          report "pixel = " & std_logic'image(indisplay)
            & ", xcounter = " & integer'image(safe_to_integer(xcounter));
          pixel_strobe_out <= indisplay;
          pixel_x_out <= safe_to_integer(xcounter);
        else
          pixel_strobe_out <= '0';
        end if;
        pixel_newraster <= '0';
      end if;

      -- 2. From RGB, push out to pins (also draw border)
      if (displayline0 ='1') and (displaycolumn0='1')
        and (((led='1') and (drive_blink_phase='1'))
             or (motor='1')) then
        report "drawing drive led OSD" severity note;
        drive_led_out <= '1';
        vgared_driver <= x"FF";
        vgagreen_driver <= x"00";
        vgablue_driver <= x"00";
      else
        drive_led_out <= '0';
        if show_render_activity='1' then
          vgared_driver <= (others => render_activity(0));
          vgagreen_driver <= (others => render_activity(1));
          vgablue_driver <= (others => render_activity(2));
        else
          vgared_driver <= vga_out_red(7 downto 0);
          vgagreen_driver <= vga_out_green(7 downto 0);
          vgablue_driver <= vga_out_blue(7 downto 0);
        end if;
      end if;

      --------------------------------------------------------------------------
      --------------------------------------------------------------------------
      --------------------------------------------------------------------------
      -- Character/bitmap data preparation
      --------------------------------------------------------------------------
      --------------------------------------------------------------------------
      --------------------------------------------------------------------------

      -- Do chipram read based on fetch scheduled in previous cycle
      this_ramaccess_is_screen_row_fetch <= next_ramaccess_is_screen_row_fetch;
      this_ramaccess_is_glyph_data_fetch <= next_ramaccess_is_glyph_data_fetch;
      this_ramaccess_is_sprite_data_fetch <= next_ramaccess_is_sprite_data_fetch;
      this_ramaccess_screen_row_buffer_address
        <= next_ramaccess_screen_row_buffer_address;
      this_screen_row_fetch_address <= next_screen_row_fetch_address;
      last_ramaccess_is_screen_row_fetch <= this_ramaccess_is_screen_row_fetch;
      last_ramaccess_is_glyph_data_fetch <= this_ramaccess_is_glyph_data_fetch;
      last_ramaccess_is_sprite_data_fetch <= this_ramaccess_is_sprite_data_fetch;
      last_ramaccess_screen_row_buffer_address
        <= this_ramaccess_screen_row_buffer_address;
      last_screen_row_fetch_address <= this_screen_row_fetch_address;
      final_ramdata <= ramdata;
      final_ramaccess_is_screen_row_fetch <= last_ramaccess_is_screen_row_fetch;
      final_ramaccess_is_glyph_data_fetch <= last_ramaccess_is_glyph_data_fetch;
      final_ramaccess_is_sprite_data_fetch <= last_ramaccess_is_sprite_data_fetch;
      final_ramaccess_screen_row_buffer_address
        <= last_ramaccess_screen_row_buffer_address;
      final_screen_row_fetch_address <= last_screen_row_fetch_address;

      if final_ramaccess_is_screen_row_fetch='1' then
        report "buffering screen ram byte $" & to_hstring(final_ramdata) & " to address $" & to_hstring(to_unsigned(safe_to_integer(final_ramaccess_screen_row_buffer_address),16));
      end if;
      screen_ram_buffer_write <= final_ramaccess_is_screen_row_fetch;
      screen_ram_buffer_write_address <= '0' & final_ramaccess_screen_row_buffer_address;
      screen_ram_buffer_din <= final_ramdata;
      -- K325T list mode
      rl_en_s <= rl_en_s(0) & rrb_list_en;
      exp_start <= '0';
      exp_start_scan <= '0';
      exp_abort <= '0';
      if exp_done = '1' then
        expanding <= '0';
      end if;
      if exp_bwe = '1' then
        screen_ram_buffer_write <= '1';
        screen_ram_buffer_write_address <= exp_baddr;
        screen_ram_buffer_din <= exp_bscreen;
      end if;
      if final_ramaccess_is_screen_row_fetch = '1' and row_end_pos(10) = '0' then
        -- v2: after the row; sticky at 1024 if the row fills (or wraps) the 1 KB buffer
        row_end_pos <= ('0' & final_ramaccess_screen_row_buffer_address) + 1;
      end if;
      -- the row's first LIST token ($FFFC) or end of row ($FFFF), whichever comes first: nothing
      -- after an end of row counts (a later LIST token neither)
      if final_ramaccess_is_screen_row_fetch = '1' and list_found = '0' and row_ff = '0' then
        if final_ramaccess_screen_row_buffer_address(0) = '0' then
          if final_ramdata = x"FC" then list_lo_fc <= '1'; else list_lo_fc <= '0'; end if;
          if final_ramdata = x"FF" then list_lo_ff <= '1'; else list_lo_ff <= '0'; end if;
        elsif list_lo_fc = '1' and final_ramdata = x"FF" then
          list_found <= '1';
          list_pos <= ('0' & final_ramaccess_screen_row_buffer_address) - 1;
        elsif list_lo_ff = '1' and final_ramdata = x"FF" then
          row_ff <= '1';                          -- v2: the objects replace this $FFFF
          list_pos <= ('0' & final_ramaccess_screen_row_buffer_address) - 1;
        end if;
      end if;
      -- Collect last token for processing
      screen_line_last_token(15 downto 8) <= final_ramdata;
      screen_line_last_token(7 downto 0) <= screen_line_last_token(15 downto 8);

      if raster_fetch_state /= Idle or paint_fsm_state /= Idle then
        report "raster_fetch_state=" & vic_chargen_fsm'image(raster_fetch_state) & ", "
          & "paint_fsm_state=" & vic_paint_fsm'image(paint_fsm_state)
          & ", rb_w_addr=$" & to_hstring(raster_buffer_write_address) severity note;
      end if;

      -- Pre-calculate some expressions to flatten logic in critical path
      -- Note we use prev_first_card_of_row, so that we don't show the last pixel
      -- row from the next char card row down the screen.
      if reg_h640='1' then
        bitmap_glyph_data_address
          <= (character_set_address(19 downto 14)&"00000000000000")
          + (safe_to_integer(screen_ram_buffer_read_address)+safe_to_integer(prev_first_card_of_row))*8+safe_to_integer(chargen_y_hold);
      else
        bitmap_glyph_data_address
          <= (character_set_address(19 downto 13)&"0000000000000")
          + (safe_to_integer(screen_ram_buffer_read_address)+safe_to_integer(prev_first_card_of_row))*8+safe_to_integer(chargen_y_hold);
      end if;
      if xcounter = 0 then
        report "LEGACY: bitmap_glyph_data_address = $"
          & to_hstring(
            to_unsigned(safe_to_integer(character_set_address(19 downto 13))*8192
                        + safe_to_integer(screen_ram_buffer_read_address)
                        +safe_to_integer(first_card_of_row)*8
                        +safe_to_integer(chargen_y_hold)
                        ,17)
            );
      end if;
      display_row_width_minus1 <= display_row_width - 1;

      ramaddress <= next_ramaddress;

      report "raster_fetch_state = " & vic_chargen_fsm'image(raster_fetch_state);
      case raster_fetch_state is
        when Idle => null;
                     -- Show what we are doing in debug display mode
                     render_activity <= "000";
        when FetchScreenRamLine =>
          -- Make sure that painting is not in progress
          if bitplane_mode='1' then
            paint_fsm_state <= Idle;
            raster_fetch_state <= EndOfCharGen;
          elsif paint_ready='1' then
            -- Set FSM state so that no painting occurs, and so that we
            -- continue to fetch the screen row.  Note that here we just
            -- schedule the memory reads.  The data is written elsewhere.  This
            -- helps to simplify the logic in terms of number of states in the
            -- machine, as well as for accepting the data when it has been read.
            paint_fsm_state <= Idle;
            raster_fetch_state <= FetchScreenRamLine2;
            -- Show what we are doing in debug display mode
            render_activity <= "001";

            -- Reset screen row (bad line) state
            character_number <= to_unsigned(1,11);
            end_of_row_16 <= '0'; end_of_row <= '0';
            report "COLOURRAM: Setting colourramaddress via first_card_of_row."
              & " text_mode=" & std_logic'image(text_mode)
              & ", sixteenbit_charset=" & std_logic'image(sixteenbit_charset);
            colourramaddress <= to_unsigned(safe_to_integer(colour_ram_base) + safe_to_integer(first_card_of_row),16);
            -- K325T step 5: copy the row's colour bytes into cbuf while the row is fetched
            if (rl_en_s(1) = '1' or rv2_s(1) = '1') and sixteenbit_charset = '1' then
              cc_act <= '1'; cc_idx <= (others => '0');
              cc_addr <= to_unsigned(safe_to_integer(colour_ram_base) + safe_to_integer(first_card_of_row),16);
              cc_n <= display_row_width & '0';
            end if;
            -- K325T list mode: a new row, no LIST token seen yet
            list_found <= '0'; list_lo_fc <= '0'; row_list <= '0';
            list_lo_ff <= '0'; row_ff <= '0'; row_short <= '0'; row_end_pos <= (others => '0');
            row_scr_base <= screen_row_current_address;
            exp_row <= display_row_number;            -- v2: character row of this fetch

            -- Now ask for the first byte.  We indicate all details of this
            -- read so that it can be committed by the receiving side of the logic.
            next_ramaccess_is_screen_row_fetch <= '1';
            next_ramaccess_is_glyph_data_fetch <= '0';
            next_ramaccess_is_sprite_data_fetch <= '0';
            next_ramaccess_screen_row_buffer_address <= to_unsigned(0,10);
            next_screen_row_fetch_address <= screen_row_current_address;

            -- Set pipeline delay countdown for investigating the 16-bit tokens
            -- to see if they indicate programmatic instructions, rather than
            -- ordinary characte data.
            badlineprog_countdown <= 5;

            report "BADLINE, colour_ram_base=$" & to_hstring(colour_ram_base) severity note;

            report "LEGACY: Badline fetch: "
              & "screen_row_current_address = $" & to_hstring(screen_row_current_address)
              ;
          end if;
        when FetchScreenRamLine2 =>
          -- Ask for the next byte.  We indicate all details of this
          -- read so that it can be committed by the receiving side of the logic.
          -- Otherwise, if we are at the end of the row, then stop.

          -- XXX check the last stored token to see if it is a GOTO, GOSUB or RETURN.
          -- If it is, rewind, and redirect accordingly.
          -- Part of the challenge here is that the bytes here are delayed by
          -- several cycles, so we have to take that into account.
          if sixteenbit_charset='1' then
            if badlineprog_countdown = 0 then
              report "BADLINEPROG: last_token=$" & to_hstring(screen_line_last_token);
              if next_token_is_goto='1' then
                -- Set screen RAM fetch to the value of this token (shifted
                -- left one bit).
                -- XXX goto tokens can only point to first 128KB of RAM.
                next_screen_row_fetch_address(19 downto 17) <= "000";
                next_screen_row_fetch_address(16 downto 1) <= screen_line_last_token;
                next_screen_row_fetch_address(0) <= '0';
                -- Flush screen row buffer fetch pipeline while waiting for
                -- branch to complete
                badlineprog_inhibit_screen_row_buffer_write_counter <= 4;
                -- Clear next token is branch flag
                next_token_is_goto <= '0';
              else
                case screen_line_last_token is
                  when x"FFFF" =>
                    -- End of line / RETURN token
                    -- If nothing on the stack, this is the last token to fetch.
                    null;
                  when x"FFFE" =>
                    -- GOTO: Next token is address to goto (shifted left one bit)
                    null;
                  when x"FFFD" =>
                    -- GOSUB: Next token is address to goto (shifted left one bit)
                    -- (Same as GOTO, except that we push the write offset to be
                    --  retrieved on return.)
                    null;
                  when others =>
                    null;
                end case;
              end if;
              -- We need two bytes before we have next token, so set count down
              badlineprog_countdown <= 1;
            else
              badlineprog_countdown <= badlineprog_countdown - 1;
            end if;
          end if;

          -- Is this the last character in the row?
          -- (Only used when screen lines have only one character?)
          if character_number = display_row_width_minus1&'1' then
            end_of_row_16 <= '1';
          else
            end_of_row_16 <= '0';
          end if;
          if character_number = '0'&display_row_width_minus1 then
            end_of_row <= '1';
          else
            end_of_row <= '0';
          end if;

          -- Work out if we need to fetch any more
          if (sixteenbit_charset='1' and end_of_row_16='1')
            or (sixteenbit_charset='0' and end_of_row='1') then
            -- All done, move to actual row fetch
            if (rl_en_s(1) = '1' or rv2_s(1) = '1') and sixteenbit_charset = '1' then
              raster_fetch_state <= ListWait;         -- K325T list mode
              list_wait <= 5;
            else
              raster_fetch_state <= FetchFirstCharacter;
            end if;
            next_ramaccess_is_screen_row_fetch <= '0';
            next_ramaccess_is_glyph_data_fetch <= '0';
            next_ramaccess_is_sprite_data_fetch <= '0';
          else
            -- More to fetch, so keep scheduling the reads
            if screenline_return_stack_count = 0 then
              -- Only advance fetched character counter if we are not in a
              -- GOSUB in the screen row data.
              character_number <= character_number + 1;
            end if;
            next_ramaccess_is_screen_row_fetch <= '1';
            report "Scheduling read of $" & to_hstring(next_screen_row_fetch_address)
              & " for screen row read.";
            next_ramaccess_is_glyph_data_fetch <= '0';
            next_ramaccess_is_sprite_data_fetch <= '0';
            if next_token_is_goto='0' then
              next_ramaccess_screen_row_buffer_address <= next_ramaccess_screen_row_buffer_address + 1;
              next_screen_row_fetch_address <= next_screen_row_fetch_address + 1;
            end if;
          end if;
        when ListWait =>
          -- K325T list mode: let the last row bytes land in the buffer (LIST detection), then
          -- expand the lists or go straight to painting
          -- v2: rows without a LIST token get the global objects at their first $FFFF (which
          -- the objects' GOTOX overwrites; the expansion ends with its own $FFFF) or else after
          -- their last token; with v1 off a LIST token only marks where they go.  No append
          -- point beyond LIMIT - 2 (a full row is painted plainly).
          -- While the table copy runs (top of the frame), the expander cannot start.  Every
          -- line above the text area is a forced badline whose buffer the next line fetches
          -- again: paint it plainly at once (painting and the sprite fetches keep their time; the
          -- copy uses the Idle time after them).  The fetch that is kept for the first text row
          -- (from the line just before it on) waits here for the copy, which gets the chip RAM
          -- port in this state (exp_mfree).  If the copy is not done by the next raster line, the
          -- line start takes the FSM out of this state (no assignment here) and the row is
          -- painted plainly.
          if list_wait /= 0 then
            list_wait <= list_wait - 1;
          elsif exp_copying = '1' and before_y_chargen_start = '1' and justbefore_y_chargen_start = '0' then
            raster_fetch_state <= FetchFirstCharacter;
          elsif exp_copying = '1' then
            null;
          elsif list_found = '1' and (rl_en_s(1) = '1' or rv2_s(1) = '1') then
            exp_start <= '1'; expanding <= '1'; row_list <= '1';
            exp_start_scan <= not rl_en_s(1);
            raster_fetch_state <= FetchFirstCharacter;   -- (K325T step 5: painting overlaps)
          elsif rv2_s(1) = '1' and row_ff = '1' and list_pos <= to_unsigned(RRB_LIST_LIMIT - 2, 11) then
            row_short <= '1';                     -- keep the short row's row advance
            exp_start <= '1'; exp_start_scan <= '1'; expanding <= '1'; row_list <= '1';
            raster_fetch_state <= FetchFirstCharacter;   -- (K325T step 5: painting overlaps)
          elsif rv2_s(1) = '1' and row_ff = '0' and row_end_pos(10) = '0'
                and row_end_pos <= to_unsigned(RRB_LIST_LIMIT - 2, 11) then
            -- (row_end_pos(10): the row filled or wrapped the fetch's 1 KB: no append point)
            list_pos <= row_end_pos;
            exp_start <= '1'; exp_start_scan <= '1'; expanding <= '1'; row_list <= '1';
            raster_fetch_state <= FetchFirstCharacter;   -- (K325T step 5: painting overlaps)
          else
            raster_fetch_state <= FetchFirstCharacter;
          end if;
        when ListRun =>
          if exp_done = '1' then
            expanding <= '0';
            raster_fetch_state <= FetchFirstCharacter;
          end if;
        when FetchFirstCharacter =>
          -- Show what we are doing in debug display mode
          render_activity <= "010";
          list_line_end <= '0';
          -- K325T list mode: the colour address painting starts from (whichever of the line
          -- start / badline set it) is index 0 of the row
          row_col_start <= colourramaddress;
          list_in_exp <= '0'; list_save_armed <= row_list; list_saved_max <= (others => '0');

          next_ramaccess_is_screen_row_fetch <= '0';
          next_ramaccess_is_glyph_data_fetch <= '0';
          next_ramaccess_is_sprite_data_fetch <= '0';

          -- By default glyphs do paint the background when required.
          -- (This can be turned off for the rest of a line by using a tab-stop
          -- token).
          glyph_paint_background <= '1';

          -- And don't invert palettes by default
          glyph_alternate_palette_invert <= '0';

          -- By default, characters are drawn in the foreground.
          -- If force_chars_background is set, then chars are forced into the background.
          -- If force_chars_foreground is set, then chars are forced into the foreground
          -- (ignoreing if a particular colour bit would normally be required
          -- to achieve this).
          force_chars_foreground <= '1';
          force_chars_background <= '0';

          -- By default, draw all pixel rows of each character
          screenline_draw_mask <= (others => '1');
          report "DRAWMASK: Reset drawmask to $ff";

          report "ZEROing screen_ram_buffer_read_address" severity note;
          screen_ram_buffer_read_address <= to_unsigned(0,11);

          character_number <= (others => '0');
          card_of_row <= (others => '0');
          if bitplane_mode='0' or viciv_bitplane_chargen_on='1' then
            raster_fetch_state <= FetchNextCharacter;
            if not rd_ok(to_unsigned(0, 11), expanding, list_pos, exp_busy, exp_wpos) then
              raster_fetch_state <= FrontWait;    -- K325T step 5 (a row without own tokens)
            end if;
          else
            raster_fetch_state <= EndOfCharGen;
          end if;
          -- K325T fast token path for CHR16 text lines: the decoder starts with token 0 (the
          -- screen buffer read address is 0 from the next cycle on)
          fp_line <= '0'; fp_dec <= DIdle; fp_goto_pend <= '0';
          if fp_s(1) = '1' and rb_fast_s(1) = '1' and text_mode = '1' and sixteenbit_charset = '1'
             and bitplane_mode = '0' and (glyphs_from_hyperram = '0' or not hyper_installed) then
            fp_line <= '1'; fp_dec <= D0;
            raster_fetch_state <= TurboWait;
          end if;
        when FetchNextCharacter =>
          -- Fetch next character
          -- All we can expect here is that character_number is correctly set.

          report "screen_ram byte read from buffer as $" & to_hstring(screen_ram_buffer_dout) severity note;

          -- XXX: Timing to be fixed.
          -- (Ideally we would take only 8 cycles to fetch a character so that
          -- we use as little raster time as possible, especially for true 1920
          -- pixel modes.  However, for now, the emphasis is on making it work.
          -- In particular, we should pipeline reading of the next character
          -- number and resolving relevant information about it with the fetching
          -- of the data for the current character. That would basically fix it.)

          -- Based on either the card number (for bitmap modes) or
          -- character_number (for text modes), work out the address where the
          -- data lives.

          -- Work out exactly what mode we are in so that we can be a bit more
          -- efficient in the next cycle
          if screen_ram_buffer_read_address = to_unsigned(0,10) then
            report "LEGACY: Char/bitmap data fetch: "
              & "chargen_y_hold = $" & to_hstring(chargen_y_hold)
              & ", chargen_y = $" & to_hstring(chargen_y)
              & ", chargen_y_next = $" & to_hstring(chargen_y_next)
              ;
          end if;
          if text_mode='1' then
            -- Read 8 or 16 bit screen RAM data for character number information
            -- (the address was put on the bus for us already).
            -- Handle extended background colour mode here if required.
            glyph_number(12 downto 8) <= "00000";
            glyph_number(5 downto 0) <= screen_ram_buffer_dout(5 downto 0);
            if extended_background_mode='1' then
              background_colour_select <= screen_ram_buffer_dout(7 downto 6);
            else
              background_colour_select <= "00";
              glyph_number(7 downto 6) <= screen_ram_buffer_dout(7 downto 6);
            end if;
          else
            -- Read 8 or 16 bits of colour information for bitmap modes.
            -- In 16 bit charset mode we allow 8 bits for fore and back-ground
            -- colours.
            if sixteenbit_charset='1' then
              bitmap_colour_foreground <= screen_ram_buffer_dout;
            else
              bitmap_colour_foreground <= x"0" & screen_ram_buffer_dout(7 downto 4);
              bitmap_colour_background <= x"0" & screen_ram_buffer_dout(3 downto 0);
            end if;
          end if;

          -- calculate data address for bitmap mode in case we need it
          -- bitmap area is always on an 8KB boundary
          glyph_data_address <= bitmap_glyph_data_address;
          report "bitmap srba="& integer'image(safe_to_integer(screen_ram_buffer_read_address))
            & ", fcor="& integer'image(safe_to_integer(first_card_of_row))
            severity note;

          screen_ram_buffer_read_address <= srb_next(screen_ram_buffer_read_address, row_list);
          report "INCREMENTing screen_ram_buffer_read_address to " & integer'image(safe_to_integer(screen_ram_buffer_read_address)+1) severity note;

          -- Clear 16-bit character attributes in case we are reading 8-bits only.
          glyph_flip_horizontal <= '0';
          glyph_flip_vertical <= '0';
          glyph_with_alpha <= '0';
          glyph_width_deduct <= to_unsigned(0,4);
          glyph_goto <= '0';
          glyph_4bit <= '0';

          screen_ram_is_ff <= '0';
          screen_ram_high_is_ff <= '0';

          if sixteenbit_charset='1' then
            if screen_ram_buffer_dout = x"ff" then
              screen_ram_is_ff <= '1';
            end if;
            raster_fetch_state <= FetchCharHighByte;
          else
            -- 8 bit character set / colour info mode
            glyph_full_colour <= fullcolour_8bitchars;
            if text_mode='1' then
              raster_fetch_state <= FetchTextCell;
            else
              raster_fetch_state <= FetchBitmapCell;
            end if;
          end if;
        when FetchCharHighByte =>

          -- In 16-bit character mode we also need to read the 2nd colour byte,
          -- which are doing now, so we need to advance colourramaddress ready
          -- to read the low colour byte of the next character.
          report "COLOURRAM: Incrementing colourramaddress";
          colourramaddress <= colourramaddress + 1;
          report "reading high colour byte";

          -- Work out if character is full colour (ignored for bitmap mode but
          -- calculated outside of if test to flatten logic).
          if screen_ram_buffer_dout(4 downto 0) = "00000" then
            glyph_full_colour <= fullcolour_8bitchars;
          else
            glyph_full_colour <= fullcolour_extendedchars;
          end if;
          if text_mode='1' then
            -- We only allow 8192 characters in extended mode.
            -- The spare bits are used to provide some (hopefully useful)
            -- extended attributes.

            -- FCM/NCM + CHARY16 causes interlacing of two consecutive glyphs #902
            if reg_char_y16='1' and charrow_repeated='1' and ((fullcolour_extendedchars='1' and screen_ram_buffer_dout(4 downto 0) /= "00000") or fullcolour_8bitchars='1') and colourramdata(4)='0' then
              glyph_number(7 downto 0) <= glyph_number(7 downto 0) + 1;
              if glyph_number(7 downto 0) = x"ff" then
                glyph_number(12 downto 8) <= screen_ram_buffer_dout(4 downto 0) + 1;
              else
                glyph_number(12 downto 8) <= screen_ram_buffer_dout(4 downto 0);
              end if;
            else
              glyph_number(12 downto 8) <= screen_ram_buffer_dout(4 downto 0);
            end if;

            glyph_width_deduct(2 downto 0) <= screen_ram_buffer_dout(7 downto 5);
            glyph_width_deduct(3) <= '0';
            if screen_ram_buffer_dout = x"ff" then
              screen_ram_high_is_ff <= '1';
            end if;

            -- First colour RAM byte has vertical controls
            glyph_flip_vertical <= colourramdata(7);
            glyph_flip_horizontal <= colourramdata(6);
            glyph_with_alpha <= colourramdata(5);
            -- bit 4 indicates glyph number is actually a GOTO pixel number
            -- (allows over-rendering and skipping)
            glyph_goto <= colourramdata(4);

            -- Enables chars to be 16x8, with 4 bits each using
            -- full-colour painting pipeline
            glyph_4bit <= colourramdata(3);
            report "DRAWMASK: Reading glyph_4bit from bit 3 of $" & to_hstring(colourramdata);
            if colourramdata(3)='1' then
              glyph_full_colour <= '1';
            end if;
            -- Because the glyphs are 16 pixels wide, we need to have an extra
            -- bit for width trimming
            glyph_width_deduct(3) <= colourramdata(2);


            -- XXX colour ram bits 0 - 1 of byte 1 were for trimming top or bottom
            -- of rows of glyphs, but have since been reclaimed.


            raster_fetch_State <= FetchTextCell;
          else
            bitmap_colour_background <= screen_ram_buffer_dout;
            raster_fetch_state <= FetchBitmapCell;
          end if;

          -- calculate data address for bitmap mode in case we need it
          -- bitmap area is always on an 8KB boundary
          glyph_data_address <= bitmap_glyph_data_address;
          report "bitmap srba="& integer'image(safe_to_integer(screen_ram_buffer_read_address))
            & ", fcor="& integer'image(safe_to_integer(first_card_of_row))
            severity note;

          screen_ram_buffer_read_address <= srb_next(screen_ram_buffer_read_address, row_list);
          report "INCREMENTing screen_ram_buffer_read_address to " & integer'image(safe_to_integer(screen_ram_buffer_read_address)+1) severity note;
        when FetchBitmapCell =>
          report "LEGACY: from bitmap layout, we get glyph_data_address = $" & to_hstring("000"&glyph_data_address) severity note;
          raster_fetch_state <= FetchBitmapData;
        when FetchTextCell =>
          if row_list = '1' and screen_ram_buffer_read_address > list_pos then
            list_in_exp <= '1';                   -- this token is part of the expanded lists
          end if;
          if screen_ram_is_ff='1' and screen_ram_high_is_ff='1' then
            if row_list = '1' and screen_ram_buffer_read_address > list_pos then
              -- K325T list mode: end of the expanded row (the row advance stays LINESTEP, or
              -- for a short row whose $FFFF the v2 objects replaced: as without them)
              list_line_end <= '1';
              if row_short = '1' then
                short_line <= '1';
                short_line_length <= safe_to_integer(list_pos) + 2;
              end if;
            elsif end_of_row = '1' and row_list = '0' and (rl_en_s(1) = '1' or rv2_s(1) = '1') then
              -- K325T list mode: this is the token after a plain row's last one (fetched, never
              -- painted).  Its bytes are whatever the 2 KB buffer holds there, e.g. the $FFFF an
              -- earlier v2 expansion wrote: it must not shorten the row advance
              null;
            else
            -- 16-bit Character is $FFFF, which is end of line marker.
            -- So remember that this line is short, and don't add the virtual
            -- row width, and abort drawing this line.
            short_line <= '1';
            short_line_length <= safe_to_integer(screen_ram_buffer_read_address);
            end if;
          end if;

          report "LEGACY: from screen_ram we get glyph_number = $" & to_hstring(to_unsigned(safe_to_integer(glyph_number),16)) severity note;
          -- We now know the character number, and whether it is full-colour or
          -- normal, and whether we are flipping in either axis, and so can
          -- work out the address to fetch data from.
          if glyph_with_alpha='1' then
            report "glyph is alpha blended";
          end if;

          -- Work out if we are drawing this line of this char
          draw_mask_blank <= not screenline_draw_mask(to_integer(chargen_y_hold));
          report "DRAWMASK: Y = " & integer'image(to_integer(chargen_y_hold))
            & ": Setting draw_mask_blank to " & std_logic'image(not screenline_draw_mask(to_integer(chargen_y_hold)))
            & ", glyph_4bit = " & std_logic'image(glyph_4bit)
            & ", screenline_draw_mask = $" & to_hstring(screenline_draw_mask);

          if glyph_full_colour='1' then
            report "glyph is full colour";
            -- Full colour glyphs come from 64*(glyph_number) in RAM, never
            -- from character ROM.  As we only have 2^16 positions, the glyphs
            -- must be in only the first 512KB of chipram.
            glyph_data_address(19) <= '0';

            -- if vertical flip bit is set fetch the char data with 7 - chargen_y
            if glyph_flip_vertical='1' then
              -- Allow setting an offset in the glyph address for easier
              -- free vertical positioning of RRB soft-sprites
              if glyph_nve_y_offset='1' then
                -- -ve offset visibly moves the char data down the screen
                glyph_data_address(18 downto 3) <= (glyph_number(12 downto 0) & not chargen_y_hold) - glyph_y_offset;
              else
                -- +ve offset visibly moves the char data up the screen
                glyph_data_address(18 downto 3) <= (glyph_number(12 downto 0) & not chargen_y_hold) + glyph_y_offset;
              end if;
            else
              -- Allow setting an offset in the glyph address for easier
              -- free vertical positioning of RRB soft-sprites
              if glyph_nve_y_offset='1' then
                -- -ve offset visibly moves the char data down the screen
                glyph_data_address(18 downto 3) <= (glyph_number(12 downto 0) & chargen_y_hold) - glyph_y_offset;
              else
                -- +ve offset visibly moves the char data up the screen
                glyph_data_address(18 downto 3) <= (glyph_number(12 downto 0) & chargen_y_hold) + glyph_y_offset;
              end if;
            end if;

            if glyph_flip_horizontal='1' then
              glyph_data_address(2 downto 0) <= "111";
            else
              glyph_data_address(2 downto 0) <= "000";
            end if;

            character_data_from_rom <= '0';
          else
            -- Normal character glyph fetched relative to character_set_address.
            -- Again, we take into account if we are flipping vertically.
            if glyph_flip_vertical='0' then
              glyph_data_address
                <= character_set_address(19 downto 0)
                + safe_to_integer(glyph_number)*8+safe_to_integer(chargen_y_hold);
            else
              glyph_data_address
                <= character_set_address(19 downto 0)
                + safe_to_integer(glyph_number)*8+7-safe_to_integer(chargen_y_hold);
            end if;
            -- Mark as possibly coming from ROM
            character_data_from_rom <= '1';
          end if;

          raster_fetch_state <= FetchTextCellColourAndSource;
        when FetchBitmapData =>
          -- Show what we are doing in debug display mode
          render_activity <= "011";

          if character_data_from_rom = '1' then
            if glyph_data_address(19 downto 12) = "0000"&x"1"
              or glyph_data_address(19 downto 12) = "0000"&x"9" then
              report "reading from rom: glyph_data_address=$" & to_hstring(glyph_data_address(15 downto 0))
                & "chargen_y_hold=" & to_string(std_logic_vector(chargen_y_hold)) severity note;
              character_data_from_rom <= '1';
            else
              character_data_from_rom <= '0';
            end if;
          end if;

          -- Schedule next colour ram byte
          report "COLOURRAM: Incrementing colourramaddress";
          colourramaddress <= colourramaddress + 1;

          if viciii_extended_attributes='1' or glyph_full_colour='1' then
            -- 8-bit colour RAM in VIC-III/IV mode for bitmap mode, or for
            -- full-colour text mode
            glyph_colour_drive <= colourramdata;
          else
            -- 16 colours only in VIC-II mode
            glyph_colour_drive(7 downto 4) <= x"0";
            glyph_colour_drive(3 downto 0) <= colourramdata(3 downto 0);
          end if;

          -- Why on earth do we do this? This carries these flags between glyphs?
          glyph_visible_drive <= glyph_visible;
          glyph_reverse_drive <= glyph_reverse;
          glyph_underline_drive <= glyph_underline;
          glyph_bold_drive <= glyph_bold;

          raster_fetch_state <= PaintMemWait;
        when FetchTextCellColourAndSource =>
          -- Finally determine whether source is from RAM or CHARROM
          if character_data_from_rom = '1' then
            if glyph_data_address(19 downto 12) = "0000"&x"1"
              or glyph_data_address(19 downto 12) = "0000"&x"9" then
              report "reading from rom: glyph_data_address=$" & to_hstring(glyph_data_address(15 downto 0))
                & "chargen_y=" & to_string(std_logic_vector(chargen_y_hold)) severity note;
              character_data_from_rom <= '1';
            else
              character_data_from_rom <= '0';
            end if;
          end if;
          -- Record colour and attribute information from colour RAM
          -- XXX We do this even in bitmap mode!
          if glyph_full_colour='1' and viciii_extended_attributes='0' then
            glyph_colour_drive <= colourramdata;
          else
            glyph_colour_drive(7 downto 4) <= "0000";
            glyph_colour_drive(3 downto 0) <= colourramdata(3 downto 0);
          end if;
          glyph_bold_drive <= '0';
          glyph_underline_drive <= '0';
          glyph_reverse_drive <= '0';
          glyph_visible_drive <= '1';
          glyph_blink_drive <= '0';

          report "DRAWMASK: goto=" & std_logic'image(glyph_goto);
          if glyph_goto='1' then
            -- Also hold the 2nd colour RAM byte for use as the draw mask,
            -- if its a GOTOX token with the appropriate bit set
            screenline_draw_mask_drive <= colourramdata;
            report "DRAWMASK: Loading screenline_draw_mask_drive with $" & to_hstring(colourramdata)
              & ", glyph_4bit = " & std_logic'image(glyph_4bit);
          end if;

          -- Get bold + reverse combination, even if not in VIC-III extended attribute
          -- mode, so that we can check for it in GOTOX tokens.
          glyph_bold_and_reverse <= colourramdata(5) and colourramdata(6);

          report "Reading high-byte of colour RAM (value $" & to_hstring(colourramdata)&")";
          if multicolour_mode='1' then
            -- Multicolour + full colour mode + 16-bit char mode = simple 256 colour foreground
            -- colour selection from 2nd byte of colour RAM data
            glyph_colour_drive(7 downto 4) <= colourramdata(7 downto 4);
          else
            if viciii_extended_attributes='1' then
              -- VIC-III character attributes
              if colourramdata(4)='1' then    -- IF BLINK==1
                -- Blinking glyph
                glyph_blink_drive <= '1';
                if colourramdata(5)='1'            -- IF REVERSE==1
                  or colourramdata(6)='1'          --    OR BOLD==1
                  or colourramdata(7)='1' then     --    OR UNDERLINE==1
                  -- Blinking attributes
                  if viciii_blink_phase='1' then
                    glyph_reverse_drive <= colourramdata(5);
                    glyph_bold_drive <= colourramdata(6);
                    if bold_is_alt='0' then
                      glyph_colour_drive(4) <= colourramdata(6);
                    end if;
                    if chargen_y_hold="111" then
                      glyph_underline_drive <= colourramdata(7);
                    end if;
                  end if;
                else
                  -- Just plain blinking character
                  glyph_visible_drive <= viciii_blink_phase;
                end if;
              else 
                -- Non-blinking attributes
                glyph_visible_drive <= '1';
                glyph_reverse_drive <= colourramdata(5);
                glyph_bold_drive <= colourramdata(6);
                if bold_is_alt='0' then
                  glyph_colour_drive(4) <= colourramdata(6);
                end if;
                if chargen_y_hold="111" then
                  glyph_underline_drive <= colourramdata(7);
                end if;
              end if;
            end if;
          end if;

          -- Schedule next colour ram byte
          report "COLOURRAM: Incrementing colourramaddress";
          colourramaddress <= colourramaddress + 1;

          raster_fetch_state <= PaintMemWait;
        when PaintMemWait =>
          -- This is the time that the 2nd colour byte will be available if we
          -- are in 16-bit text mode, so copy out the value.
          -- Allow for 2 cycle delay to get data in paint_ramdata
          -- In this cycle chardata and ramdata will have the requested value
          glyph_visible <= glyph_visible_drive;
          glyph_reverse <= glyph_reverse_drive;
          glyph_underline <= glyph_underline_drive;
          glyph_bold <= glyph_bold_drive;
          glyph_colour_drive2 <= glyph_colour_drive;

          raster_fetch_state <= PaintMemWait2;
        when PaintMemWait2 =>
          mono_l <= ramdata;                      -- K325T step 5: the glyph byte (port at PaintMemWait)
          -- Alpha blend mode glyphs invert pixel values (=intensities)
          -- for reverse video mode.
          -- (But FCM reverse just changes transparent pixel colours, and
          --  is handled by paint_background_with_any_reverse).
          if glyph_with_alpha='1' then
            glyph_xor <= glyph_reverse;
          else
            glyph_xor <= '0';
          end if;         

          glyph_colour <= glyph_colour_drive2;
          if glyph_4bit='0' then
            glyph_width <= 8 - safe_to_integer(glyph_width_deduct(2 downto 0));
          else
            glyph_width <= 16 - safe_to_integer(glyph_width_deduct(3 downto 0));
          end if;

          if glyph_full_colour = '1' then
            if glyphs_from_hyperram='0' or (not hyper_installed) then
              -- Fetch full-colour glyph data from chip ram
              if glyph_flip_horizontal = '0' then
                glyph_data_address(2 downto 0) <= glyph_data_address(2 downto 0) + 1;
              else
                glyph_data_address(2 downto 0) <= glyph_data_address(2 downto 0) - 1;
              end if;
              full_colour_fetch_count <= 0;
              raster_fetch_state <= PaintFullColourFetch;
            else
              -- Fetch glyph data from ATTIC/CELLAR ram (hyperram)
              report "HYPERRAM: Request for $" & to_hstring(glyph_data_address(18 downto 3)&"000")
                & " dispatched.";
              full_colour_fetch_count <= 0;
              hyper_addr_drive(18 downto 3) <= glyph_data_address(18 downto 3);
              hyper_request_toggle_drive <= not last_hyper_request_toggle;
              last_hyper_request_toggle <= not last_hyper_request_toggle;
              raster_fetch_state <= PaintFullColourHyperRAMFetch;
            end if;
          else
            raster_fetch_state <= PaintMemWait3;
          end if;
          -- K325T fast token path: the first word of a full-colour row arrives now (requested in
          -- PaintMemWait), the second next cycle; a GOTOX needs no glyph data
          if fp_line = '1' then
            fcm_w0 <= chipram_datain32;
            if glyph_goto = '1' then
              raster_fetch_state <= PaintMemWait3;
            elsif glyph_full_colour = '1' then
              raster_fetch_state <= TurboFetch32;
            end if;
          end if;
        when FrontWait =>
          -- K325T step 5: the next token is not written by the expander yet
          if rd_ok(screen_ram_buffer_read_address, expanding, list_pos, exp_busy, exp_wpos) then
            raster_fetch_state <= FetchNextCharacter;
          end if;
        when TurboWait =>
          -- K325T fast token path: the first token of the line (or one decoded late)
          if fp_dec = DFull then
            fp_take;
            raster_fetch_state <= PaintMemWait;
          end if;
        when TurboFetch32 =>
          -- K325T fast token path: the 8 bytes of a full-colour row (two words, byte n of a word
          -- is address 4w + n) as PaintFullColourFetch would have assembled them, then
          -- PaintMemWait3's work
          for i in 0 to 7 loop
            if glyph_flip_horizontal = '0' then
              if i < 4 then fb := fcm_w0(8 * i + 7 downto 8 * i);
              else fb := chipram_datain32(8 * (i - 4) + 7 downto 8 * (i - 4)); end if;
            else
              if i < 4 then fb := chipram_datain32(8 * (3 - i) + 7 downto 8 * (3 - i));
              else fb := fcm_w0(8 * (7 - i) + 7 downto 8 * (7 - i)); end if;
            end if;
            if glyph_4bit = '1' and glyph_flip_horizontal = '1' then
              fb := fb(3 downto 0) & fb(7 downto 4);    -- flip the nybl order
            end if;
            if glyph_visible = '0' or draw_mask_blank = '1' then
              fw(8 * i + 7 downto 8 * i) := x"00";
            else
              fw(8 * i + 7 downto 8 * i) := fb;
            end if;
            if glyph_xor = '1' then
              fw(8 * i + 7 downto 8 * i) := fb xor x"FF";
            end if;
            if glyph_underline = '1' then
              fw(8 * i + 7 downto 8 * i) := x"FF";
            end if;
          end loop;
          full_colour_data <= fw;
          character_number <= character_number + 1;
          if character_number(10 downto 0) = display_row_width_minus1 then
            end_of_row_16 <= '1';
          else
            end_of_row_16 <= '0';
          end if;
          if character_number = '0'&display_row_width_minus1 then
            end_of_row <= '1';
          else
            end_of_row <= '0';
          end if;
          if (end_of_row = '1' and row_list = '0') or (short_line='1') or (list_line_end = '1') then
            raster_fetch_state <= EndOfChargen;
          else
            raster_fetch_state <= PaintDispatch;
          end if;
        when PaintFullColourHyperRAMFetch =>
          -- Read data from dedicated hyperram interface (a bit like the VRAM
          -- that was originally planned for the Amiga Ranger chipset that was
          -- never released.
          if hyper_data_strobe='1' then
            report "VIC: Receiving hyperram byte $" & to_hstring(hyper_data)
              & ", full_colour_fetch_count = " & integer'image(full_colour_fetch_count);
            if glyph_flip_horizontal='0' then
              if glyph_visible='0' or draw_mask_blank='1' then
                full_colour_data(63 downto 56) <= "00000000";
              elsif glyph_underline='1' then
                full_colour_data(63 downto 56) <= "11111111";
              elsif glyph_xor='1' then
                full_colour_data(63 downto 56) <= hyper_data xor "11111111";
              else
                full_colour_data(63 downto 56) <= hyper_data;
              end if;
              full_colour_data(55 downto 0) <= full_colour_data(63 downto 8);
            else
              if glyph_visible='0' or draw_mask_blank='1' then
                full_colour_data(7 downto 0) <= "00000000";
              elsif glyph_underline='1' then
                full_colour_data(7 downto 0) <= "11111111";
              elsif glyph_xor='1' then
                full_colour_data(7 downto 0) <= hyper_data xor "11111111";
              else
                full_colour_data(7 downto 0) <= hyper_data;
              end if;
              full_colour_data(63 downto 8) <= full_colour_data(55 downto 0);
            end if;

            if full_colour_fetch_count < 7 then
              raster_fetch_state <= PaintFullColourHyperRAMFetch;
              full_colour_fetch_count <= full_colour_fetch_count + 1;
            else
              report "VIC: Received all bytes from HyperRAM. Resuming";
              raster_fetch_state <= PaintMemWait3;
            end if;

          end if;
        when PaintFullColourFetch =>
          -- Show what we are doing in debug display mode
          render_activity <= "100";

          -- Read and store the 8 bytes of data we need for a full-colour character
          report "LEGACY: glyph reading full-colour pixel value $" & to_hstring(ramdata);
          if glyph_4bit='0' or glyph_flip_horizontal='0' then
            -- Don't flip byte nybl order
            full_colour_data(63 downto 56) <= ramdata;
          else
            -- Do flip byte nybl order
            full_colour_data(63 downto 60) <= ramdata(3 downto 0);
            full_colour_data(59 downto 56) <= ramdata(7 downto 4);
          end if;
          full_colour_data(55 downto 0) <= full_colour_data(63 downto 8);
          if glyph_flip_horizontal = '0' then
            glyph_data_address(2 downto 0) <= glyph_data_address(2 downto 0) + 1;
          else
            glyph_data_address(2 downto 0) <= glyph_data_address(2 downto 0) - 1;
          end if;
          if glyph_visible='0' or draw_mask_blank='1' then
            full_colour_data(63 downto 56) <= "00000000";
          end if;
          if glyph_xor='1' then
            if glyph_4bit='0' or glyph_flip_horizontal='0' then
              -- Don't flip byte nybl order
              full_colour_data(63 downto 56) <= ramdata xor "11111111";
            else
              -- Do flip byte nybl order
              full_colour_data(63 downto 60) <= ramdata(3 downto 0) xor "1111";
              full_colour_data(59 downto 56) <= ramdata(7 downto 4) xor "1111";
            end if;
          end if;
          if glyph_underline='1' then
            full_colour_data(63 downto 56) <= "11111111";
          end if;
          if full_colour_fetch_count < 7 then
            full_colour_fetch_count <= full_colour_fetch_count + 1;
            raster_fetch_state <= PaintFullColourFetch;
          else
            raster_fetch_state <= PaintMemWait3;
          end if;
        when PaintMemWait3 =>
          -- In this cycle paint_chardata and and paint_ramdata should have the
          -- requested value
          -- Abort if we have already drawn enough characters.
          character_number <= character_number + 1;
          -- We are counting the number characters, not the number of bytes, so
          -- no need multiply row width by two for 16-bit character mode
          -- if character_number = virtual_row_width_minus1(7 downto 0)&'0' then
          if character_number(10 downto 0) = display_row_width_minus1 then
            end_of_row_16 <= '1';
          else
            end_of_row_16 <= '0';
          end if;
          if character_number = '0'&display_row_width_minus1 then
            end_of_row <= '1';
          else
            end_of_row <= '0';
          end if;
          if (end_of_row = '1' and row_list = '0') or (short_line='1') or (list_line_end = '1') then
            raster_fetch_state <= EndOfChargen;
          else
            raster_fetch_state <= PaintDispatch;
          end if;
        when PaintDispatch =>
          -- Dispatch this card for painting.

          -- Hold from dispatching if painting the previous card is not yet finished.
          -- (K325T fast token path: a full-colour or plain mono glyph may go in the painter's
          -- last pixel cycle; a GOTOX waits for the painter to be idle, as before)
          if paint_ready='1'
             or (fp_line = '1' and p_last and glyph_goto = '0'
                 and (glyph_full_colour = '1'
                      or (multicolour_mode = '0' and extended_background_mode = '0'))) then
            paint_from_charrom <= character_data_from_rom;
            report "character rom address set to $" & to_hstring(glyph_data_address(11 downto 0)) severity note;
            -- Tell painter whether to flip horizontally or not.
            paint_flip_horizontal <= glyph_flip_horizontal;
            paint_glyph_width <= glyph_width;
            paint_blink <= glyph_blink;
            paint_glyph_4bit <= glyph_4bit;
            paint_with_alpha <= glyph_with_alpha;

            if bold_is_alt = '1' then
              paint_alternate_palette <= glyph_bold;
            else
              -- Normal VIC-III interpretation
              paint_alternate_palette <= glyph_reverse and glyph_bold;
            end if;

            if glyph_goto='1' then

              report "DRAWMASK: PAINTING: is GOTOX";

              -- Glyph is tab-stop glyph
              -- Set screen ram buffer write address to 10 bit
              -- offset indicated by glyph number bits
              raster_buffer_write_address(9 downto 0) <= glyph_number(9 downto 0) - 1;
              -- K325T list mode: the first GOTOX of the expanded part -- everything before it is
              -- painted (dispatch waits for paint_ready): remember where the ordinary row ends
              if list_in_exp = '1' and list_save_armed = '1' then
                list_saved_max <= raster_buffer_max_write_address;
                list_save_armed <= '0';
              end if;

              -- for GOTOX chars glyph_4bit is the ROWMASK enable bit
              if glyph_4bit='1' then
                screenline_draw_mask <= screenline_draw_mask_drive;
                report "DRAWMASK: PAINTING: Setting screenline_draw_mask to $" & to_hstring(screenline_draw_mask_drive);
              else
                screenline_draw_mask <= (others => '1');
                report "DRAWMASK: PAINTING: Ignoring drawmask. Using $ff (glyph_4bit not set)";

                -- Allow bold + reverse on a GOTOX token to switch
                -- primary/alternate palette selection for all chars that follow
                -- Note: Moved here to fix a bug where ROWMASK would still be able to select the alternate palette
                glyph_alternate_palette_invert <= glyph_bold_and_reverse;
              end if;

              -- Allow setting of the glyph y offset in GOTO tokens
              glyph_y_offset <= to_integer(glyph_width_deduct(2 downto 0));

              -- Allow setting of y offset to be -ve instead of the default +pve
              glyph_nve_y_offset <= glyph_number(12);

              -- Also note whether the glyph painting should now not paint
              -- background pixels, to allow masked over writing
              glyph_paint_background <= not glyph_flip_vertical;

              -- Also allow forcing of the following characters to be
              -- background or foreground
              force_chars_foreground <= glyph_width_deduct(3);
              force_chars_background <= glyph_flip_horizontal;

            -- ... and don't paint anything, because it is just
            -- a tab stop.
            elsif glyph_full_colour='1' then
              -- Now work out exactly how we are painting
              -- Paint full-colour glyph
              report "LEGACY: Dispatching to PaintFullColour due to glyph_full_colour = 1";
              -- We set background colour to screen colour in full-colour mode
              -- for transparent pixels, and for alpha blending of anti-aliased
              -- text.  We do also support ECM mode.
              case background_colour_select is
                when "00" => paint_background <= screen_colour;
                when "01" => paint_background <= multi1_colour;
                when "10" => paint_background <= multi2_colour;
                when "11" => paint_background <= multi3_colour;
                when others => paint_background <= screen_colour;
              end case;
              -- For alpha-blended pixels, we need to make sure that we set
              -- paint_foreground from glyph_colour, which allows us to have
              -- 32 colours of anti-aliased text (using VIC-III bold attribute
              -- to provide the 5th bit), as well as the option of reversed
              -- text, which should invert the alpha-values).
              paint_foreground <= glyph_colour;
              paint_fsm_state <= PaintFullColour;
            else
              report "LEGACY: Dispatching normal due to glyph_full_colour = 0"
                & ", paint_ready=" & std_logic'image(paint_ready);
              if multicolour_mode='0' and extended_background_mode='0' then
                -- Mono mode
                if text_mode='1' then
                  paint_foreground <= glyph_colour;
                  paint_background <= screen_colour;
                else
                  paint_foreground <= bitmap_colour_foreground;
                  paint_background <= bitmap_colour_background;
                end if;
                paint_fsm_state <= PaintMono;
              elsif multicolour_mode='1' then
                -- Multicolour mode
                paint_background <= screen_colour;
                if text_mode='1' then
                  if extended_background_mode='1' then
                    -- Illegal video mode that shows all black
                    paint_background <= x"00";
                    paint_mc1 <= x"00";
                    paint_mc2 <= x"00";
                    paint_foreground <= x"00";
                  else
                    if fullcolour_mcm='1' then
                      -- multi-colour text mode with full-colour VIC III/IV feature
                      -- See #571 for more discussion on this
					  paint_foreground <= glyph_colour;
                    else
                      -- multi-colour text mode masks bit 3 of the foreground
                      -- colour to select whether the character is multi-colour or
                      -- not.
                      paint_foreground <= "00000"&glyph_colour(2 downto 0);
                    end if;
                    paint_mc1 <= multi2_colour;
                    paint_mc2 <= multi1_colour;
                  end if;
                else
                  if extended_background_mode='1' then
                    -- Illegal video mode that shows all black
                    paint_background <= x"00";
                    paint_mc1 <= x"00";
                    paint_mc2 <= x"00";
                    paint_foreground <= x"00";
                  else
                    paint_mc2 <= bitmap_colour_foreground;
                    paint_mc1 <= bitmap_colour_background;
                    paint_foreground <= glyph_colour;
                  end if;
                end if;
                if text_mode='1' and glyph_colour(3)='0' then
                  -- Multi-colour text mode only applies to colours 8-15,
                  -- so draw this glyph in mono
                  paint_fsm_state <= PaintMono;
                else
                  -- Really do low-res multi-colour
                  paint_fsm_state <= PaintMultiColour;
                end if;
              elsif extended_background_mode='1' then
                -- ECM (extended colour mode)
                if text_mode='1' then
                  paint_foreground <= glyph_colour;
                  case background_colour_select is
                    when "00" => paint_background <= screen_colour;
                    when "01" => paint_background <= multi1_colour;
                    when "10" => paint_background <= multi2_colour;
                    when "11" => paint_background <= multi3_colour;
                    when others => paint_background <= screen_colour;
                  end case;
                else
                  -- ECM + bitmap mode is illegal
                  paint_foreground <= x"00";
                  paint_background <= x"00";
                end if;
                paint_fsm_state <= PaintMono;
              end if;
            end if;
            -- Fetch next character
            raster_fetch_state <= FetchNextCharacter;
            if not rd_ok(screen_ram_buffer_read_address, expanding, list_pos, exp_busy, exp_wpos) then
              raster_fetch_state <= FrontWait;    -- K325T step 5
            end if;
            -- K325T fast token path: the next token is decoded already (or TurboWait waits for
            -- it); the painter's state is set after the painter's own case (below)
            if fp_line = '1' then
              if glyph_goto = '1' then
                fp_goto_pend <= '0';
              elsif glyph_full_colour = '1' then
                t_disp_fcm := true;
              elsif paint_ready = '0' then
                t_disp_mono := true;                 -- dispatched in the painter's last cycle
              end if;
              if fp_dec = DFull then
                fp_take;
                raster_fetch_state <= PaintMemWait;
              else
                raster_fetch_state <= TurboWait;
              end if;
            end if;
          end if;
        when EndOfChargen =>
          fp_line <= '0';                         -- K325T fast token path: decoder off

          -- Idle the painter, and then start drawing VIC-II sprites
          if paint_ready='1' then
            paint_fsm_state <= Idle;
          end if;
          if paint_fsm_state = Idle then
            report "SPRITE: begin data fetch for raster";
            raster_fetch_state <= SpritePointerFetch;
            sprite_fetch_sprite_number <= 0;
            sprite_fetch_byte_number <= 0;
          end if;
        when SpritePointerFetch =>
          -- Show what we are doing in debug display mode
          render_activity <= "101";

          sprite_pointer_address(19 downto 17) <= "000";

          sprite_datavalid <= '0';
          if sprite_fetch_sprite_number = 16 or (sprite_fetch_sprite_number = 8 and bitplane_mode = '0') then
            -- Done fetching sprites
            raster_fetch_state <= Idle;
          elsif sprite_fetch_sprite_number < 8 then
            -- Fetch sprites
            max_sprite_fetch_byte_number <= 7;
            if vicii_sprite_pointer_address(23)='0' then
              -- Normal 8-bit sprite pointers
              sprite_pointer_address(19 downto 3) <= vicii_sprite_pointer_address(19 downto 3);
              sprite_pointer_address(2 downto 0) <=  to_unsigned(sprite_fetch_sprite_number,3);
              report "SPRITE: will fetch pointer value from $" &
                to_hstring(vicii_sprite_pointer_address(19 downto 0) + sprite_fetch_sprite_number);
            else
              -- 16-bit sprite pointers, allowing sprites to be sourced from
              -- anywhere in first 64K x 64 = 4MB of chip RAM (of which we
              -- currently have only 128KB :)
              sprite_pointer_address(19 downto 4) <= vicii_sprite_pointer_address(19 downto 4);
              sprite_pointer_address(3 downto 1) <=  to_unsigned(sprite_fetch_sprite_number,3);
              sprite_pointer_address(0) <= '0';
              report "SPRITE: will fetch pointer LSB from $" &
                to_hstring(vicii_sprite_pointer_address(19 downto 0) + sprite_fetch_sprite_number*2);
            end if;
            raster_fetch_state <= SpritePointerFetch2;
          else
            -- Fetch VIC-III bitplanes
            -- Bitplanes for odd raster lines
            if (reg_h640='0' and reg_h1280='0') then
              if bitplane_sixteen_colour_mode_flags(sprite_fetch_sprite_number mod 8)='0'
              then
                -- 320px, mono bitplane = 40 bytes for 320 pixels
                max_sprite_fetch_byte_number <= 39;
              else
                -- 320px, 16-colour bitplane = 160 bytes for 320 pixels
                max_sprite_fetch_byte_number <= 159;
              end if;
            end if;
            if (reg_h640='1' and reg_h1280='0') then
              if bitplane_sixteen_colour_mode_flags(sprite_fetch_sprite_number mod 8)='0'
              then
                -- 640px, mono bitplane = 80 bytes for 640 pixels
                max_sprite_fetch_byte_number <= 79;
              else
                -- 640px, 16-colour bitplane = 320 bytes for 640 pixels
                max_sprite_fetch_byte_number <= 319;
              end if;
            end if;
            -- Don't waste time fetching bitplanes that are disabled.
            if (bitplane_enables(sprite_fetch_sprite_number mod 8)='0')
              or (bitplane_mode='0') then
              max_sprite_fetch_byte_number <= 1;
            end if;

            -- Odd bitplanes come from 2nd 64KB RAM, even bitplanes from first.
            -- But also allow shifting bitplanes higher in memory
            sprite_pointer_address(19 downto 17) <= bitplane_bank_select;
            if (sprite_fetch_sprite_number mod 2) = 0 then
              sprite_pointer_address(16) <= '0';
            else
              sprite_pointer_address(16) <= '1';
            end if;
            -- Interlacing selects which of two bitplane address register
            -- fields to use
            if (reg_v400='1') and (vicii_ycounter_v400(0)='0') then
              -- Use odd scan set
              sprite_pointer_address(15 downto 13)
                <= bitplane_addresses(sprite_fetch_sprite_number mod 8)
                (7 downto 5);
            else
              -- Use even scan set
              sprite_pointer_address(15 downto 13)
                <= bitplane_addresses(sprite_fetch_sprite_number mod 8)
                (3 downto 1);
            end if;
            -- XXX: VIC-IV should allow setting of the lower bits of the bitplane
            -- address
            sprite_pointer_address(12 downto 0) <= (others => '0');
            if bitplane_enables(sprite_fetch_sprite_number mod 8)='0' then
              -- Don't waste fetch cycles on bitplanes that are turned off
              sprite_fetch_byte_number <= 0;
              sprite_fetch_sprite_number <= sprite_fetch_sprite_number + 1;
              raster_fetch_state <= SpritePointerFetch;
            else
              --sprite_data_address <= sprite_pointer_address;
              --sprite_data_address(12 downto 0) <= to_unsigned(sprite_data_offsets(sprite_fetch_sprite_number),13);

              raster_fetch_state <= SpritePointerCompute;
            --raster_fetch_state <= SpritePointerFetch2;
            end if;
          end if;
        when SpritePointerFetch2 =>
          raster_fetch_state <= SpritePointerCompute1;
          if vicii_sprite_pointer_address(23)='1' then
            -- 16-bit sprite pointers, allowing sprites to be sourced from
            -- anywhere in first 64K x 64 = 4MB of chip RAM (of which we
            -- currently have only 384KB :)
            sprite_pointer_address(19 downto 4) <= vicii_sprite_pointer_address(19 downto 4);
            sprite_pointer_address(3 downto 1) <=  to_unsigned(sprite_fetch_sprite_number,3);
            sprite_pointer_address(0) <= '1';
            report "SPRITE: will fetch pointer MSB from $" &
              to_hstring(vicii_sprite_pointer_address(19 downto 0) + sprite_fetch_sprite_number*2);
          end if;
        when SpritePointerCompute1 =>
          -- Drive stage for ram data to improve timing closure
          raster_fetch_state <= SpritePointerCompute;
        when SpritePointerCompute =>
          -- Sprite data address is 64*pointer value, plus the 16KB bank
          -- from $DD00.  Then we need to add the data offset for this sprite.
          -- 64-pixel wide and upto 255-pixel heigh extended size sprites means
          -- we need to allow the address computation to add the sprite number
          -- from the ram data to be added to the upper bits of the
          -- sprite_data_offsets() value for the sprite
          sprite_data_address(19 downto 16) <= "0000";
          if sprite_fetch_sprite_number < 8 then
            -- But only accept the new sprite data address at the start of
            -- display of a sprite
            if sprite_continuous_pointer_monitoring='1' then
              sprite_data_address(16) <= '0';
              sprite_data_address(15) <= sprite_pointer_address(15);
              sprite_data_address(14) <= sprite_pointer_address(14);
              sprite_data_address(13 downto 0) <= (ramdata_drive&"000000") + to_unsigned(sprite_data_offsets(sprite_fetch_sprite_number),14);

              sprite_data_addresses(sprite_fetch_sprite_number)(19 downto 17) <= "000";
              sprite_data_addresses(sprite_fetch_sprite_number)(16) <= '0';
              sprite_data_addresses(sprite_fetch_sprite_number)(15) <= sprite_pointer_address(15);
              sprite_data_addresses(sprite_fetch_sprite_number)(14) <= sprite_pointer_address(14);
              sprite_data_addresses(sprite_fetch_sprite_number)(13 downto 0) <= (ramdata_drive&"000000");
            else
              if sprite_data_offsets(sprite_fetch_sprite_number) /= 0 then
                sprite_data_address <= sprite_data_addresses(sprite_fetch_sprite_number) + to_unsigned(sprite_data_offsets(sprite_fetch_sprite_number),14);
              else
                sprite_data_addresses(sprite_fetch_sprite_number)(19 downto 16) <= "0000";
                sprite_data_addresses(sprite_fetch_sprite_number)(16) <= '0';
                sprite_data_addresses(sprite_fetch_sprite_number)(15) <= sprite_pointer_address(15);
                sprite_data_addresses(sprite_fetch_sprite_number)(14) <= sprite_pointer_address(14);
                sprite_data_addresses(sprite_fetch_sprite_number)(13 downto 0) <= (ramdata_drive&"000000");

                sprite_data_address(19 downto 16) <= "0000";
                sprite_data_address(16) <= '0';
                sprite_data_address(15) <= sprite_pointer_address(15);
                sprite_data_address(14) <= sprite_pointer_address(14);
                sprite_data_address(13 downto 0) <= (ramdata_drive&"000000");
              end if;
            end if;
            -- sprite_data_address(5 downto 0) <= to_unsigned(sprite_data_offsets(sprite_fetch_sprite_number),6);
            report "SPRITE: sprite #"
              & integer'image(sprite_fetch_sprite_number)
              & " pointer value = $" & to_hstring(ramdata_drive);
          else
            -- Bitplane fetches happen here

            --sprite_data_address <= sprite_pointer_address;
            --sprite_data_address(12 downto 0) <= to_unsigned(sprite_data_offsets(sprite_fetch_sprite_number),13);
            --  sprite_data_address(16) <= '0';
            --  sprite_data_address(15) <= sprite_pointer_address(15);
            --  sprite_data_address(14) <= sprite_pointer_address(14);
            --  sprite_data_address(13 downto 0) <= (ramdata_drive&"000000") + to_unsigned(sprite_data_offsets(sprite_fetch_sprite_number),14);
            if (reg_h640='1' or reg_h1280='1') then
              sprite_data_address(19 downto 14) <= sprite_pointer_address(19 downto 14);
              sprite_data_address(13 downto 0) <= to_unsigned(sprite_data_offsets(sprite_fetch_sprite_number),14);
            else
              sprite_data_address(19 downto 13) <= sprite_pointer_address(19 downto 13);
              sprite_data_address(12 downto 0) <= to_unsigned(sprite_data_offsets(sprite_fetch_sprite_number),13);
            end if;
          end if;
          -- Get MSB if we are using 16-bit sprite pointers
          if vicii_sprite_pointer_address(23)='1' then
            raster_fetch_state <= SpritePointerComputeMSB;
          else
            raster_fetch_state <= SpriteDataFetch;
          end if;
        when SpritePointerComputeMSB =>
          -- Copy in MSB bits for sprite data address
          -- XXX It would be nice to use bit 7 to indicate to source from
          -- colour RAM, but for now we just clip to the 1MB chip RAM range
          report "SPRITE: setting upper bits of sprite data address to $" & to_hstring(ramdata_drive);
          if sprite_continuous_pointer_monitoring='1' then
            sprite_data_address <= (ramdata_drive(5 downto 0)&sprite_data_addresses(sprite_fetch_sprite_number)(13 downto 0))
                                   + to_unsigned(sprite_data_offsets(sprite_fetch_sprite_number),14);
          else
            if sprite_data_offsets(sprite_fetch_sprite_number) /= 0 then
              sprite_data_address <= sprite_data_addresses(sprite_fetch_sprite_number) + to_unsigned(sprite_data_offsets(sprite_fetch_sprite_number),14);
            else
              sprite_data_address <= sprite_data_addresses(sprite_fetch_sprite_number);
              sprite_data_address(19 downto 14) <= ramdata_drive(5 downto 0);
              sprite_data_address(13 downto 0) <= sprite_data_address(13 downto 0);
              sprite_data_addresses(sprite_fetch_sprite_number)(19 downto 14) <= ramdata_drive(5 downto 0);
              sprite_data_addresses(sprite_fetch_sprite_number)(13 downto 0) <= sprite_data_address(13 downto 0);
            end if;
          end if;
          raster_fetch_state <= SpriteDataFetch;
        when SpriteDataFetch =>
          -- Show what we are doing in debug display mode
          render_activity <= "110";

          report "SPRITE: fetching sprite #"
            & integer'image(sprite_fetch_sprite_number)
            & " data from $" & to_hstring(sprite_data_address(19 downto 0));

          if sprite_fetch_sprite_number < 8 then
            sprite_data_address(19 downto 0) <= sprite_data_address(19 downto 0) + 1;
          else
            sprite_data_address(19 downto 0) <= sprite_data_address(19 downto 0) + 8;
          end if;
          raster_fetch_state <= SpriteDataFetch2;
        when SpriteDataFetch2 =>
          report "SPRITE: fetching sprite #"
            & integer'image(sprite_fetch_sprite_number)
            & " data = $" &
            to_hstring(ramdata)
            & " from $" & to_hstring(sprite_data_address(19 downto 0))
            & " for byte number " & integer'image(sprite_fetch_byte_number);
          if sprite_fetch_sprite_number < 8 then
            sprite_data_address(19 downto 0) <= sprite_data_address(19 downto 0) + 1;
          else
            sprite_data_address(19 downto 0) <= sprite_data_address(19 downto 0) + 8;
          end if;

          -- Schedule pushing fetched sprite/bitplane byte to next cycle when
          -- the data will be available in ramdata_drive
          sprite_fetch_drive <= '1';

          sprite_fetch_byte_number_drive <= sprite_fetch_byte_number;
          sprite_fetch_sprite_number_drive <= sprite_fetch_sprite_number;

          sprite_fetch_byte_number <= sprite_fetch_byte_number + 1;


          -- XXX - always fetches 8 bytes of sprite data instead of 3, even if
          -- sprite is not set to 64 pixels wide mode. This wastes a little
          -- raster time.
          -- Bitplanes are also fetched using the sprite fetch pipeline, so we fetch
          -- more bytes for those, according to the bitplane width.
          --if ((sprite_fetch_byte_number = 7) and (sprite_fetch_sprite_number < 8))
          if (sprite_fetch_byte_number = max_sprite_fetch_byte_number)
          then
            sprite_fetch_byte_number <= 0;
            sprite_fetch_sprite_number <= sprite_fetch_sprite_number + 1;
            raster_fetch_state <= SpritePointerFetch;
          end if;
        when others => null;
      end case;

      -- K325T fast token path: the decoder (see fp_line).  The same work as FetchNextCharacter,
      -- FetchCharHighByte, FetchTextCell and FetchTextCellColourAndSource for CHR16 text, into
      -- the n_* registers, one token ahead; not in a line-start cycle (the line start owns the
      -- screen buffer and colour RAM addresses then).
      if fds = D0 and not rd_ok(screen_ram_buffer_read_address, expanding, list_pos, exp_busy, exp_wpos_d) then
        fds := DIdle;                             -- K325T step 5: wait for the expander
      end if;
      if fp_line = '1' and not fs_now then
        case fds is
          when D0 =>
            n_glyph_number(12 downto 8) <= "00000";
            n_glyph_number(5 downto 0) <= screen_ram_buffer_dout(5 downto 0);
            if extended_background_mode='1' then
              n_bg_select <= screen_ram_buffer_dout(7 downto 6);
            else
              n_bg_select <= "00";
              n_glyph_number(7 downto 6) <= screen_ram_buffer_dout(7 downto 6);
            end if;
            screen_ram_buffer_read_address <= srb_next(screen_ram_buffer_read_address, row_list);
            n_flip_h <= '0'; n_flip_v <= '0'; n_alpha <= '0'; n_goto <= '0'; n_4bit <= '0';
            n_width_deduct <= (others => '0');
            if screen_ram_buffer_dout = x"ff" then n_is_ff <= '1'; else n_is_ff <= '0'; end if;
            n_high_is_ff <= '0';
            n_list_in_exp <= '0'; n_list_line_end <= '0'; n_short_line <= '0';
            fp_dec <= D1;
          when D1 =>
            colourramaddress <= colourramaddress + 1;
            if screen_ram_buffer_dout(4 downto 0) = "00000" then
              n_full_colour <= fullcolour_8bitchars;
            else
              n_full_colour <= fullcolour_extendedchars;
            end if;
            if reg_char_y16='1' and charrow_repeated='1' and ((fullcolour_extendedchars='1' and screen_ram_buffer_dout(4 downto 0) /= "00000") or fullcolour_8bitchars='1') and colourramdata(4)='0' then
              n_glyph_number(7 downto 0) <= n_glyph_number(7 downto 0) + 1;
              if n_glyph_number(7 downto 0) = x"ff" then
                n_glyph_number(12 downto 8) <= screen_ram_buffer_dout(4 downto 0) + 1;
              else
                n_glyph_number(12 downto 8) <= screen_ram_buffer_dout(4 downto 0);
              end if;
            else
              n_glyph_number(12 downto 8) <= screen_ram_buffer_dout(4 downto 0);
            end if;
            n_width_deduct(2 downto 0) <= screen_ram_buffer_dout(7 downto 5);
            n_width_deduct(3) <= colourramdata(2);
            if screen_ram_buffer_dout = x"ff" then n_high_is_ff <= '1'; end if;
            n_flip_v <= colourramdata(7);
            n_flip_h <= colourramdata(6);
            n_alpha <= colourramdata(5);
            n_goto <= colourramdata(4);
            n_4bit <= colourramdata(3);
            if colourramdata(3)='1' then n_full_colour <= '1'; end if;
            screen_ram_buffer_read_address <= srb_next(screen_ram_buffer_read_address, row_list);
            fp_dec <= D2;
          when D2 =>
            -- waits while a GOTOX before this token is not dispatched (draw mask, Y offset)
            if fp_goto_pend = '0' then
              if row_list = '1' and screen_ram_buffer_read_address > list_pos then
                n_list_in_exp <= '1';
              end if;
              if n_is_ff = '1' and n_high_is_ff = '1' then
                if row_list = '1' and screen_ram_buffer_read_address > list_pos then
                  n_list_line_end <= '1';
                  if row_short = '1' then
                    n_short_line <= '1';
                    n_short_line_length <= safe_to_integer(list_pos) + 2;
                  end if;
                else
                  n_short_line <= '1';
                  n_short_line_length <= safe_to_integer(screen_ram_buffer_read_address);
                end if;
              end if;
              n_draw_mask_blank <= not screenline_draw_mask(to_integer(chargen_y_hold));
              if n_full_colour = '1' then
                n_glyph_data_address(19) <= '0';
                if n_flip_v = '1' then
                  if glyph_nve_y_offset = '1' then
                    n_glyph_data_address(18 downto 3) <= (n_glyph_number(12 downto 0) & not chargen_y_hold) - glyph_y_offset;
                  else
                    n_glyph_data_address(18 downto 3) <= (n_glyph_number(12 downto 0) & not chargen_y_hold) + glyph_y_offset;
                  end if;
                else
                  if glyph_nve_y_offset = '1' then
                    n_glyph_data_address(18 downto 3) <= (n_glyph_number(12 downto 0) & chargen_y_hold) - glyph_y_offset;
                  else
                    n_glyph_data_address(18 downto 3) <= (n_glyph_number(12 downto 0) & chargen_y_hold) + glyph_y_offset;
                  end if;
                end if;
                if n_flip_h = '1' then
                  n_glyph_data_address(2 downto 0) <= "111";
                else
                  n_glyph_data_address(2 downto 0) <= "000";
                end if;
                n_from_rom <= '0';
              else
                if n_flip_v = '0' then
                  n_glyph_data_address <= character_set_address(19 downto 0)
                    + safe_to_integer(n_glyph_number)*8+safe_to_integer(chargen_y_hold);
                else
                  n_glyph_data_address <= character_set_address(19 downto 0)
                    + safe_to_integer(n_glyph_number)*8+7-safe_to_integer(chargen_y_hold);
                end if;
                n_from_rom <= '1';
              end if;
              fp_dec <= D3;
            end if;
          when D3 =>
            if n_from_rom = '1' then
              if n_glyph_data_address(19 downto 12) = "0000"&x"1"
                or n_glyph_data_address(19 downto 12) = "0000"&x"9" then
                n_from_rom <= '1';
              else
                n_from_rom <= '0';
              end if;
            end if;
            if n_full_colour='1' and viciii_extended_attributes='0' then
              n_colour_drive <= colourramdata;
            else
              n_colour_drive(7 downto 4) <= "0000";
              n_colour_drive(3 downto 0) <= colourramdata(3 downto 0);
            end if;
            n_bold_drive <= '0';
            n_underline_drive <= '0';
            n_reverse_drive <= '0';
            n_visible_drive <= '1';
            n_blink_drive <= '0';
            if n_goto = '1' then
              n_draw_mask_drive <= colourramdata;
            end if;
            n_bold_and_reverse <= colourramdata(5) and colourramdata(6);
            if multicolour_mode='1' then
              n_colour_drive(7 downto 4) <= colourramdata(7 downto 4);
            else
              if viciii_extended_attributes='1' then
                if colourramdata(4)='1' then
                  n_blink_drive <= '1';
                  if colourramdata(5)='1' or colourramdata(6)='1' or colourramdata(7)='1' then
                    if viciii_blink_phase='1' then
                      n_reverse_drive <= colourramdata(5);
                      n_bold_drive <= colourramdata(6);
                      if bold_is_alt='0' then
                        n_colour_drive(4) <= colourramdata(6);
                      end if;
                      if chargen_y_hold="111" then
                        n_underline_drive <= colourramdata(7);
                      end if;
                    end if;
                  else
                    n_visible_drive <= viciii_blink_phase;
                  end if;
                else
                  n_visible_drive <= '1';
                  n_reverse_drive <= colourramdata(5);
                  n_bold_drive <= colourramdata(6);
                  if bold_is_alt='0' then
                    n_colour_drive(4) <= colourramdata(6);
                  end if;
                  if chargen_y_hold="111" then
                    n_underline_drive <= colourramdata(7);
                  end if;
                end if;
              end if;
            end if;
            colourramaddress <= colourramaddress + 1;
            fp_dec <= DFull;
          when others => null;
        end case;
      end if;

      -- Force abort of existing RRB line render if we've run out of cycles.
      if raster_fetch_restart='1' and rrb_overtime_allowed='0' then        
        raster_fetch_state <= raster_fetch_state_init;
        raster_fetch_restart <= '0';
        -- K325T list mode: an expansion still running at the next raster line is cut off;
        -- the row is then painted as a plain row (never leave the colour port redirected)
        if expanding = '1' then
          exp_abort <= '1'; expanding <= '0'; row_list <= '0';
        end if;
      end if;
      -- K325T list mode: with RRB overtime allowed (the default) the line start above also takes
      -- the FSM out of ListRun (ListRun assigns no state until exp_done), but without the abort:
      -- cut the expansion off here too, so the expander never reads chip RAM in the next
      -- line's fetch states
      if is_fetch_start='1' and last_was_fetch_start='0' and expanding = '1' and exp_done = '0' then
        exp_abort <= '1'; expanding <= '0'; row_list <= '0';
      end if;
      
      -- Push sprite data out in a drive cycle to improve timing closure.
      if sprite_fetch_drive = '1' then
        sprite_datavalid <= '1';
        sprite_spritenumber <= sprite_fetch_sprite_number_drive;
        sprite_bytenumber <= sprite_fetch_byte_number_drive;
        sprite_data_byte <= ramdata_drive;
      end if;

      raster_buffer_write <= '0';

      -- Always write if we are using the primary or alternate palette
      raster_buffer_write_data(17) <= paint_alternate_palette xor glyph_alternate_palette_invert;

      rb_fast_s <= rb_fast_s(0) & fast_rrb_en;   -- K325T fast RRB
      fp_s <= fp_s(0) & fast_token_en;           -- K325T fast token path
      cu_s <= cu_s(0) & clear_unpainted_en;      -- K325T XCTL bit 3
      -- K325T step 5: the colour copy (one byte per cycle; data one cycle after the address)
      cc_v1 <= '0';
      if cc_act = '1' then
        if cc_idx = cc_n then
          cc_act <= '0';
        else
          cc_v1 <= '1'; cc_i1 <= cc_idx;
          cc_idx <= cc_idx + 1; cc_addr <= cc_addr + 1;
        end if;
      end if;
      cu_clr <= '0';
      if cu_clr_cnt /= 0 then
        cu_clr_cnt <= cu_clr_cnt - 1;
        if cu_clr_cnt = 1 then
          cu_clr <= '1'; cu_clr_half <= raster_buffer_write_address(10);
        end if;
      end if;
      rb_double <= '0';
      raster_buffer_write2 <= '0';
      case paint_fsm_state is
        when Idle =>
          if paint_ready /= '1' then
            paint_ready <= '1';
            report "LEGACY: asserting paint_ready" severity note;
          end if;
        when PaintFullColour =>
          -- Draw 8 pixels using a byte at a time from full_colour_data
          paint_ready <= '0';
          report "LEGACY: clearing paint_ready. full_colour_data=$" & to_hstring(full_colour_data);
          paint_full_colour_data <= full_colour_data;
          paint_bits_remaining <= paint_glyph_width - 1;
          -- Reverse video mode for FCM/NCM changes whether foreground or
          -- background colour is visible through transparent pixels.
          if glyph_reverse='1' and (glyph_bold='0' or bold_is_alt='1') and glyph_with_alpha='0' then
            paint_background_with_any_reverse <= paint_foreground;
            transparent_pixel_will_come_from_primary_palette <= '1';
          else
            paint_background_with_any_reverse <= paint_background;
            transparent_pixel_will_come_from_primary_palette <= '0';
          end if;      
          if paint_glyph_4bit='1' then
            paint_fsm_state <= Paint4bitColourPixels;
          else
            paint_fsm_state <= PaintFullColourPixels;
          end if;
        when Paint4bitColourPixels =>
          if rb_fast_s(1) = '1' and paint_bits_remaining >= 1 and (raster_buffer_write_address(9 downto 0) <= 1020 or rrb_wraparound_allowed = '1') then
            -- K325T fast RRB: two nybls per cycle
            rb_v1 := rb_nib_px(paint_full_colour_data(3 downto 0), paint_with_alpha, force_chars_foreground,
                               force_chars_background, paint_foreground, paint_background_with_any_reverse,
                               raster_buffer_write_data(17));
            rb_v2 := rb_nib_px(paint_full_colour_data(7 downto 4), paint_with_alpha, force_chars_foreground,
                               force_chars_background, paint_foreground, paint_background_with_any_reverse, rb_v1(17));
            raster_buffer_write_data <= rb_v1;
            raster_buffer_write_data2 <= rb_v2;
            if paint_full_colour_data(3 downto 0) /= x"0" or glyph_paint_background = '1' then
              raster_buffer_write <= '1'; else raster_buffer_write <= '0'; end if;
            if paint_full_colour_data(7 downto 4) /= x"0" or glyph_paint_background = '1' then
              raster_buffer_write2 <= '1'; else raster_buffer_write2 <= '0'; end if;
            paint_full_colour_data(55 downto 0) <= paint_full_colour_data(63 downto 8);
            raster_buffer_write_address(9 downto 0) <= raster_buffer_write_address(9 downto 0) + 2;
            raster_buffer_max_write_address <= raster_buffer_write_address(9 downto 0) + 2;
            rb_double <= '1';
            if paint_bits_remaining = 1 then
              paint_fsm_state <= Idle;
            else
              paint_bits_remaining <= paint_bits_remaining - 2;
            end if;
          else
            if paint_full_colour_data(3 downto 0) = x"0" then
              -- background pixel
              raster_buffer_write_data(16 downto 9) <= x"FF";  -- solid alpha
              raster_buffer_write_data(8) <= force_chars_foreground;
              raster_buffer_write_data(7 downto 0) <= paint_background_with_any_reverse;
            else
              -- foreground pixel
              if paint_with_alpha='0' then
                report "LEGACY: full-colour glyph painting pixel $" & to_hstring(paint_full_colour_data(7 downto 0))
                  & " into buffer @ $" & to_hstring(raster_buffer_write_address);
                raster_buffer_write_data(16 downto 9) <= x"FF";  -- solid alpha
                --
                raster_buffer_write_data(8) <= not force_chars_background;

                if paint_full_colour_data(3 downto 0) /= x"F" then
                  -- Lower four bits of colour come from the nybl
                  raster_buffer_write_data(3 downto 0) <= paint_full_colour_data(3 downto 0);
                  -- Upper four from the foreground colour from screen RAM.
                  -- This makes it much more useful for paralax layers etc
                  raster_buffer_write_data(7 downto 4) <= paint_foreground(7 downto 4);
                else
                  raster_buffer_write_data(7 downto 0) <= paint_foreground;
                end if;
              else
                -- XXX Add alternate alpha mode where alhpa value is picked by
                -- colour RAM, allowing full colour chars to be faded in and out
                -- from background?
                report "LEGACY: full-colour glyph painting alpha pixel $"
                  & to_hstring(paint_foreground)
                  & " with alpha value $" & to_hstring(paint_full_colour_data(3 downto 0)) & "F"
                  & " : raster_buffer_write_address=$" & to_hstring(raster_buffer_write_address)
                  & " ( + 1 ?)";
                -- 8-bit pixel values provide the alpha
                raster_buffer_write_data(16 downto 13) <= paint_full_colour_data(3 downto 0);
                raster_buffer_write_data(12 downto 9) <= (others => paint_full_colour_data(0));
                raster_buffer_write_data(8) <= (paint_full_colour_data(3) or force_chars_foreground) and (not force_chars_background);
                -- colour RAM colour provides the foreground
                raster_buffer_write_data(7 downto 0) <= paint_foreground;
              end if;
            end if;
            paint_full_colour_data(59 downto 0) <= paint_full_colour_data(63 downto 4);
            if (raster_buffer_write_address(9 downto 0) /= "1111111110") or rrb_wraparound_allowed='1' then
              raster_buffer_write_address(9 downto 0) <= raster_buffer_write_address(9 downto 0) + 1;
              raster_buffer_max_write_address <= raster_buffer_write_address(9 downto 0) + 1;
            else
              raster_buffer_max_write_address <= "1111111110";
            end if;
            if paint_full_colour_data(3 downto 0) /= x"0" or glyph_paint_background='1' then
              raster_buffer_write <= '1';
            else
              raster_buffer_write <= '0';
            end if;
            report "LEGACY: full colour glyph paint_bits_remaining=" & integer'image(paint_bits_remaining) severity note;
            if paint_bits_remaining > 0 then
              paint_bits_remaining <= paint_bits_remaining - 1;
            else
              -- All done
              paint_fsm_state <= Idle;
            end if;
          end if;
        when PaintFullColourPixels =>
          if rb_fast_s(1) = '1' and paint_bits_remaining >= 1 and (raster_buffer_write_address(9 downto 0) <= 1020 or rrb_wraparound_allowed = '1') then
            -- K325T fast RRB: two bytes per cycle
            rb_v1 := rb_fcm_px(paint_full_colour_data(7 downto 0), paint_with_alpha, force_chars_foreground,
                               force_chars_background, transparent_pixel_will_come_from_primary_palette,
                               paint_foreground, paint_background_with_any_reverse, raster_buffer_write_data(17));
            rb_v2 := rb_fcm_px(paint_full_colour_data(15 downto 8), paint_with_alpha, force_chars_foreground,
                               force_chars_background, transparent_pixel_will_come_from_primary_palette,
                               paint_foreground, paint_background_with_any_reverse, rb_v1(17));
            raster_buffer_write_data <= rb_v1;
            raster_buffer_write_data2 <= rb_v2;
            if paint_full_colour_data(7 downto 0) /= x"00" or glyph_paint_background = '1' then
              raster_buffer_write <= '1'; else raster_buffer_write <= '0'; end if;
            if paint_full_colour_data(15 downto 8) /= x"00" or glyph_paint_background = '1' then
              raster_buffer_write2 <= '1'; else raster_buffer_write2 <= '0'; end if;
            paint_full_colour_data(47 downto 0) <= paint_full_colour_data(63 downto 16);
            raster_buffer_write_address(9 downto 0) <= raster_buffer_write_address(9 downto 0) + 2;
            raster_buffer_max_write_address <= raster_buffer_write_address(9 downto 0) + 2;
            rb_double <= '1';
            if paint_bits_remaining = 1 then
              paint_fsm_state <= Idle;
            else
              paint_bits_remaining <= paint_bits_remaining - 2;
            end if;
          else
            if paint_full_colour_data(7 downto 0) = x"00" then
              -- background pixel
              raster_buffer_write_data(16 downto 9) <= x"FF";  -- solid alpha
              raster_buffer_write_data(8) <= force_chars_foreground;
              raster_buffer_write_data(7 downto 0) <= paint_background_with_any_reverse;
              if transparent_pixel_will_come_from_primary_palette = '1' then
                -- Overwrites default ALT palette selection logic
                raster_buffer_write_data(17) <= '0';
              end if;            
            else
              -- foreground pixel
              if paint_with_alpha='0' then
                report "LEGACY: full-colour glyph painting pixel $" & to_hstring(paint_full_colour_data(7 downto 0))
                  & " into buffer @ $" & to_hstring(raster_buffer_write_address);
                raster_buffer_write_data(16 downto 9) <= x"FF";  -- solid alpha
                raster_buffer_write_data(8) <= not force_chars_background;
                if paint_full_colour_data(7 downto 0) /= x"FF" then
                  raster_buffer_write_data(7 downto 0) <= paint_full_colour_data(7 downto 0);
                else
                  raster_buffer_write_data(7 downto 0) <= paint_foreground;
                end if;
              else
                -- XXX Add alternate alpha mode where alhpa value is picked by
                -- colour RAM, allowing full colour chars to be faded in and out
                -- from background?
                report "LEGACY: full-colour glyph painting alpha pixel $"
                  & to_hstring(paint_foreground)
                  & " with alpha value $" & to_hstring(paint_full_colour_data(7 downto 0))
                  & " : raster_buffer_write_address=$" & to_hstring(raster_buffer_write_address)
                  & " ( + 1 ?)";
                -- 8-bit pixel values provide the alpha
                raster_buffer_write_data(16 downto 9) <= paint_full_colour_data(7 downto 0);
                raster_buffer_write_data(8) <= (paint_full_colour_data(7) or force_chars_foreground) and (not force_chars_background);
                -- colour RAM colour provides the foreground
                raster_buffer_write_data(7 downto 0) <= paint_foreground;
              end if;
            end if;
            paint_full_colour_data(55 downto 0) <= paint_full_colour_data(63 downto 8);
            if (raster_buffer_write_address(9 downto 0) /= "1111111110") or rrb_wraparound_allowed='1' then
              raster_buffer_write_address(9 downto 0) <= raster_buffer_write_address(9 downto 0) + 1;
              raster_buffer_max_write_address <= raster_buffer_write_address(9 downto 0) + 1;
            else
              raster_buffer_max_write_address <= "1111111110";
            end if;
            if glyph_paint_background='1' or paint_full_colour_data(7 downto 0) /= x"00" then
              raster_buffer_write <= '1';
            else
              raster_buffer_write <= '0';
            end if;
            report "LEGACY: full colour glyph paint_bits_remaining=" & integer'image(paint_bits_remaining) severity note;
            if paint_bits_remaining > 0 then
              paint_bits_remaining <= paint_bits_remaining - 1;
            else
              paint_fsm_state <= PaintFullColourDone;
            end if;
            if paint_bits_remaining = 0 then
              -- All done
              paint_fsm_state <= Idle;
            end if;
          end if;
        when PaintFullColourDone =>
          null;
        when PaintMono =>
          -- Drive stage costs us another cycle per glyph, but seems necessary
          -- to meet timing.
          report "LEGACY: Painting mono card";
          -- Delay of paint_alternate_palette for mono is correct
          if bold_is_alt='1' then
            paint_alternate_palette <= glyph_bold;
          else
            paint_alternate_palette <= glyph_reverse and glyph_bold;
          end if;
          if glyph_reverse='1' and (glyph_bold='0' or bold_is_alt='1') then
            paint_buffer_hflip_chardata <= not paint_chardata;
            paint_buffer_noflip_chardata <= not (
              paint_chardata(0)&paint_chardata(1)
              &paint_chardata(2)&paint_chardata(3)
              &paint_chardata(4)&paint_chardata(5)
              &paint_chardata(6)&paint_chardata(7));
            paint_buffer_hflip_ramdata <= not paint_ramdata;
            paint_buffer_noflip_ramdata <= not (
              paint_ramdata(0)&paint_ramdata(1)
              &paint_ramdata(2)&paint_ramdata(3)
              &paint_ramdata(4)&paint_ramdata(5)
              &paint_ramdata(6)&paint_ramdata(7));
          else
            paint_buffer_hflip_chardata <= paint_chardata;
            paint_buffer_noflip_chardata <=
              paint_chardata(0)&paint_chardata(1)
              &paint_chardata(2)&paint_chardata(3)
              &paint_chardata(4)&paint_chardata(5)
              &paint_chardata(6)&paint_chardata(7);
            paint_buffer_hflip_ramdata <= paint_ramdata;
            paint_buffer_noflip_ramdata <=
              paint_ramdata(0)&paint_ramdata(1)
              &paint_ramdata(2)&paint_ramdata(3)
              &paint_ramdata(4)&paint_ramdata(5)
              &paint_ramdata(6)&paint_ramdata(7);
          end if;
          if glyph_visible='0' or draw_mask_blank='1' then
            paint_buffer_noflip_ramdata <= "00000000";
            paint_buffer_hflip_ramdata <= "00000000";
            paint_buffer_noflip_chardata <= "00000000";
            paint_buffer_hflip_chardata <= "00000000";
          end if;
          if glyph_underline='1' then
            paint_buffer_noflip_ramdata <= "11111111";
            paint_buffer_hflip_ramdata <= "11111111";
            paint_buffer_noflip_chardata <= "11111111";
            paint_buffer_hflip_chardata <= "11111111";
          end if;
          paint_fsm_state <= PaintMonoDrive;
        when PaintMonoDrive =>
          -- Paint 8 mono bits from ramdata or chardata
          -- Paint from a buffer to meet timing, even though it means we spend
          -- 9 cycles per char to paint, instead of the ideal 8.
          report "paint_flip_horizontal="&std_logic'image(paint_flip_horizontal)
            & ", paint_from_charrom=" & std_logic'image(paint_from_charrom) severity note;
          report "LEGACY: painting either $ " & to_hstring(paint_ramdata) & " or $" & to_hstring(paint_chardata) severity note;
          report "  painting from direct memory would have $ " & to_hstring(ramdata) & " or $" & to_hstring(chardata) severity note;
          if paint_flip_horizontal='1' and paint_from_charrom='1' then
            paint_buffer <= paint_buffer_hflip_chardata;
          elsif paint_flip_horizontal='0' and paint_from_charrom='1' then
            paint_buffer <= paint_buffer_noflip_chardata;
          elsif paint_flip_horizontal='1' and paint_from_charrom='0' then
            paint_buffer <= paint_buffer_hflip_ramdata;
            if paint_ramdata(0)='1' then
              raster_buffer_write_data(16 downto 9) <= x"FF";  -- solid alpha
              raster_buffer_write_data(8) <= not force_chars_background;
              raster_buffer_write_data(7 downto 0) <= paint_foreground;
            else
              raster_buffer_write_data(16 downto 9) <= x"FF";  -- solid alpha
              raster_buffer_write_data(8) <= not force_chars_foreground;
              raster_buffer_write_data(7 downto 0) <= paint_background;
            end if;
          elsif paint_flip_horizontal='0' and paint_from_charrom='0' then
            paint_buffer <= paint_buffer_noflip_ramdata;
          end if;
          paint_bits_remaining <= paint_glyph_width;
          paint_ready <= '0';
          raster_buffer_write <= '0';
          report "LEGACY: clearing paint_ready";
          paint_fsm_state <= PaintMonoBits;
        when PaintMonoBits =>
          if rb_fast_s(1) = '1' and paint_bits_remaining >= 2 and (raster_buffer_write_address(9 downto 0) <= 1020 or rrb_wraparound_allowed = '1') then
            -- K325T fast RRB: two bits per cycle
            rb_v1 := rb_mono_px(paint_buffer(0), force_chars_foreground, force_chars_background,
                                paint_foreground, paint_background, raster_buffer_write_data(17));
            rb_v2 := rb_mono_px(paint_buffer(1), force_chars_foreground, force_chars_background,
                                paint_foreground, paint_background, raster_buffer_write_data(17));
            raster_buffer_write_data <= rb_v1;
            raster_buffer_write_data2 <= rb_v2;
            raster_buffer_write <= paint_buffer(0) or glyph_paint_background;
            raster_buffer_write2 <= paint_buffer(1) or glyph_paint_background;
            paint_buffer <= "00" & paint_buffer(7 downto 2);
            raster_buffer_write_address(9 downto 0) <= raster_buffer_write_address(9 downto 0) + 2;
            raster_buffer_max_write_address <= raster_buffer_write_address(9 downto 0) + 2;
            rb_double <= '1';
            paint_bits_remaining <= paint_bits_remaining - 2;
            if paint_bits_remaining = 2 then
              paint_fsm_state <= Idle;
            end if;
          else
            if paint_bits_remaining = paint_glyph_width then
              report "painting card using data $" & to_hstring(paint_buffer) severity note;
            end if;
            if paint_bits_remaining /= 0 then
              report "LEGACY: Painting mono char pixel @ $" & to_hstring(raster_buffer_write_address)
                & " (" & integer'image(paint_bits_remaining) & " pixels remaining in card.)";
              paint_buffer<= '0'&paint_buffer(7 downto 1);
              raster_buffer_write_data(16 downto 9) <= x"FF";  -- solid alpha
              if paint_buffer(0)='1' then
                raster_buffer_write_data(8) <= not force_chars_background;
                raster_buffer_write_data(7 downto 0) <= paint_foreground;
                report "Painting foreground pixel in colour $" & to_hstring(paint_foreground) severity note;
              else
                raster_buffer_write_data(8) <= not force_chars_foreground;
                raster_buffer_write_data(7 downto 0) <= paint_background;
                report "Painting background pixel in colour $" & to_hstring(paint_background) severity note;
              end if;
              if (raster_buffer_write_address(9 downto 0) /= "1111111110") or rrb_wraparound_allowed='1' then
                raster_buffer_write_address(9 downto 0) <= raster_buffer_write_address(9 downto 0) + 1;
                raster_buffer_max_write_address <= raster_buffer_write_address(9 downto 0) + 1;
              else
                raster_buffer_max_write_address <= "1111111110";
              end if;
              if paint_buffer(0)='1' or glyph_paint_background='1' then
                raster_buffer_write <= '1';
              else
                raster_buffer_write <= '0';
              end if;
              report "paint_bits_remaining=" & integer'image(paint_bits_remaining) severity note;
              paint_bits_remaining <= paint_bits_remaining - 1;
            end if;
            if paint_bits_remaining = 1 or paint_bits_remaining = 0 then
              paint_fsm_state <= Idle;
            end if;
          end if;
        when PaintMultiColour =>
          -- Drive stage costs us another cycle per glyph, but seems necessary
          -- to meet timing.
          -- Paint_alternate_palette seems to not work in multi-colour mode
          if bold_is_alt='1' then
            paint_alternate_palette <= glyph_bold;
          else
            paint_alternate_palette <= glyph_reverse and glyph_bold;
          end if;
          if glyph_reverse='1' and (glyph_bold='0' or bold_is_alt='1') then
            paint_buffer_hflip_chardata <= not paint_chardata;
            paint_buffer_noflip_chardata <= not (
              paint_chardata(0)&paint_chardata(1)
              &paint_chardata(2)&paint_chardata(3)
              &paint_chardata(4)&paint_chardata(5)
              &paint_chardata(6)&paint_chardata(7));
            paint_buffer_hflip_ramdata <= not paint_ramdata;
            paint_buffer_noflip_ramdata <= not (
              paint_ramdata(0)&paint_ramdata(1)
              &paint_ramdata(2)&paint_ramdata(3)
              &paint_ramdata(4)&paint_ramdata(5)
              &paint_ramdata(6)&paint_ramdata(7));
          else
            paint_buffer_hflip_chardata <= paint_chardata;
            paint_buffer_noflip_chardata <=
              paint_chardata(0)&paint_chardata(1)
              &paint_chardata(2)&paint_chardata(3)
              &paint_chardata(4)&paint_chardata(5)
              &paint_chardata(6)&paint_chardata(7);
            paint_buffer_hflip_ramdata <= paint_ramdata;
            paint_buffer_noflip_ramdata <=
              paint_ramdata(0)&paint_ramdata(1)
              &paint_ramdata(2)&paint_ramdata(3)
              &paint_ramdata(4)&paint_ramdata(5)
              &paint_ramdata(6)&paint_ramdata(7);
          end if;
          if glyph_visible='0' or draw_mask_blank='1' then
            paint_buffer_noflip_ramdata <= "00000000";
            paint_buffer_hflip_ramdata <= "00000000";
            paint_buffer_noflip_chardata <= "00000000";
            paint_buffer_hflip_chardata <= "00000000";
          end if;
          if glyph_underline='1' then
            paint_buffer_noflip_ramdata <= "11111111";
            paint_buffer_hflip_ramdata <= "11111111";
            paint_buffer_noflip_chardata <= "11111111";
            paint_buffer_hflip_chardata <= "11111111";
          end if;

          paint_fsm_state <= PaintMultiColourDrive;
        when PaintMultiColourDrive =>
          -- Paint 4 multi-colour half-nybls from ramdata or chardata
          -- Paint from a buffer to meet timing, even though it means we spend
          -- 5 cycles per char to paint, instead of the ideal 4.
          report "paint_flip_horizontal="&std_logic'image(paint_flip_horizontal)
            & ", paint_from_charrom=" & std_logic'image(paint_from_charrom) severity note;
          if raster_buffer_write_address(9 downto 0) = 0 then
            report "painting either $ " & to_hstring(paint_ramdata) & " or $" & to_hstring(paint_chardata) severity note;
            report "  painting from direct memory would have $ " & to_hstring(ramdata) & " or $" & to_hstring(chardata) severity note;
          end if;
          if paint_flip_horizontal='1' and paint_from_charrom='1' then
            paint_buffer <= paint_buffer_hflip_chardata;
          elsif paint_flip_horizontal='0' and paint_from_charrom='1' then
            paint_buffer <= paint_buffer_noflip_chardata;
          elsif paint_flip_horizontal='1' and paint_from_charrom='0' then
            paint_buffer <= paint_buffer_hflip_ramdata;
            raster_buffer_write_data(16 downto 9) <= x"FF";  -- solid alpha
            if paint_ramdata(0)='1' then
              raster_buffer_write_data(8) <= not force_chars_background;
              raster_buffer_write_data(7 downto 0) <= paint_foreground;
            else
              raster_buffer_write_data(8) <= not force_chars_foreground;
              raster_buffer_write_data(7 downto 0) <= paint_background;
            end if;
          elsif paint_flip_horizontal='0' and paint_from_charrom='0' then
            paint_buffer <= paint_buffer_noflip_ramdata;
          end if;
          paint_bits_remaining <= (paint_glyph_width / 2);
          paint_ready <= '0';
          report "LEGACY: clearing paint_ready";
          paint_fsm_state <= PaintMultiColourBits;
        when PaintMultiColourBits =>
          if rb_fast_s(1) = '1' and paint_bits_remaining /= 0 and (raster_buffer_write_address(9 downto 0) <= 1020 or rrb_wraparound_allowed = '1') then
            -- K325T fast RRB: one double-wide multicolour pixel per cycle (no Hold state)
            rb_v1 := rb_mc_px(paint_buffer(1 downto 0), force_chars_foreground, force_chars_background,
                              paint_foreground, paint_background, paint_mc1, paint_mc2,
                              raster_buffer_write_data(17));
            raster_buffer_write_data <= rb_v1;
            raster_buffer_write_data2 <= rb_v1;
            if paint_buffer(1 downto 0) /= "00" or glyph_paint_background = '1' then
              raster_buffer_write <= '1'; raster_buffer_write2 <= '1';
            else
              raster_buffer_write <= '0'; raster_buffer_write2 <= '0';
            end if;
            paint_buffer <= "00" & paint_buffer(7 downto 2);
            raster_buffer_write_address(9 downto 0) <= raster_buffer_write_address(9 downto 0) + 2;
            raster_buffer_max_write_address <= raster_buffer_write_address(9 downto 0) + 2;
            rb_double <= '1';
            paint_bits_remaining <= paint_bits_remaining - 1;
            if paint_bits_remaining = 1 then
              paint_fsm_state <= Idle;
            end if;
          else
            if paint_bits_remaining = (paint_glyph_width / 2) then
              report "painting card using data $" & to_hstring(paint_buffer) severity note;
            end if;
            if paint_bits_remaining /= 0 then
              paint_buffer<= "00"&paint_buffer(7 downto 2);
              raster_buffer_write_data(16 downto 9) <= x"FF";  -- solid alpha
              case paint_buffer(1 downto 0) is
                when "00" =>
                  raster_buffer_write_data(8) <= not force_chars_foreground;
                  raster_buffer_write_data(7 downto 0) <= paint_background;
                  report "Painting background pixel in colour $" & to_hstring(paint_background) severity note;
                when "01" =>
                  raster_buffer_write_data(8) <= not force_chars_background;
                  raster_buffer_write_data(7 downto 0) <= paint_mc1;
                  report "Painting multi-colour 2 pixel in colour $" & to_hstring(paint_mc1) severity note;
                when "10" =>
                  raster_buffer_write_data(8) <= not force_chars_background;
                  raster_buffer_write_data(7 downto 0) <= paint_mc2;
                  report "Painting multi-colour 3 pixel in colour $" & to_hstring(paint_mc2) severity note;
                when "11" =>
                  raster_buffer_write_data(8) <= not force_chars_background;
                  raster_buffer_write_data(7 downto 0) <= paint_foreground;
                  report "Painting foreground pixel in colour $" & to_hstring(paint_foreground) severity note;
                when others =>
                  null;
              end case;
              if (raster_buffer_write_address(9 downto 0) /= "1111111110") or rrb_wraparound_allowed='1' then
                raster_buffer_write_address(9 downto 0) <= raster_buffer_write_address(9 downto 0) + 1;
                raster_buffer_max_write_address <= raster_buffer_write_address(9 downto 0) + 1;
              else
                raster_buffer_max_write_address <= "1111111110";
              end if;
              if paint_buffer(1 downto 0) /= "00" or glyph_paint_background='1' then
                raster_buffer_write <= '1';
              else
                raster_buffer_write <= '0';
              end if;
              report "paint_bits_remaining=" & integer'image(paint_bits_remaining) severity note;
              paint_bits_remaining <= paint_bits_remaining - 1;
            end if;
            -- Stretch multi-colour pixels to be double width
            paint_fsm_state <= PaintMultiColourHold;
          end if;
        when PaintMultiColourHold =>
          if (raster_buffer_write_address(9 downto 0) /= "1111111110") or rrb_wraparound_allowed='1' then
            raster_buffer_write_address(9 downto 0) <= raster_buffer_write_address(9 downto 0) + 1;
            raster_buffer_max_write_address <= raster_buffer_write_address(9 downto 0) + 1;
          else
            raster_buffer_max_write_address <= "1111111110";
          end if;
          if paint_buffer(1 downto 0) /= "00" or glyph_paint_background='1' then
            raster_buffer_write <= '1';
          else
            raster_buffer_write <= '0';
          end if;
          if paint_bits_remaining = 0 then
            paint_fsm_state <= Idle;
          else
            paint_fsm_state <= PaintMultiColourBits;
          end if;
        when others =>
          -- If we don't know what to do, just smile and nod and say we are
          -- ready again.
          paint_fsm_state <= Idle;
      end case;

      -- K325T fast token path: a glyph dispatched this cycle (PaintDispatch) -- possibly in the
      -- painter's last pixel cycle, so after the painter's own assignments.  Full colour / NCM:
      -- PaintFullColour's set-up done here, straight to the pixels; mono: to PaintMono.
      if t_disp_fcm then
        paint_ready <= '0';
        paint_full_colour_data <= full_colour_data;
        paint_bits_remaining <= glyph_width - 1;
        case background_colour_select is
          when "01" => bgc := multi1_colour;
          when "10" => bgc := multi2_colour;
          when "11" => bgc := multi3_colour;
          when others => bgc := screen_colour;
        end case;
        if glyph_reverse='1' and (glyph_bold='0' or bold_is_alt='1') and glyph_with_alpha='0' then
          paint_background_with_any_reverse <= glyph_colour;
          transparent_pixel_will_come_from_primary_palette <= '1';
        else
          paint_background_with_any_reverse <= bgc;
          transparent_pixel_will_come_from_primary_palette <= '0';
        end if;
        if glyph_4bit = '1' then
          paint_fsm_state <= Paint4bitColourPixels;
        else
          paint_fsm_state <= PaintFullColourPixels;
        end if;
      elsif t_disp_mono then
        paint_fsm_state <= PaintMono;
      end if;

      if raster_fetch_state /= Idle or paint_fsm_state /= Idle then
        report "raster_fetch_state=" & vic_chargen_fsm'image(raster_fetch_state) & ", "
          & "paint_fsm_state=" & vic_paint_fsm'image(paint_fsm_state)
          & ", rb_w_addr=$" & to_hstring(raster_buffer_write_address) severity note;
      end if;
    end if;
  end process;

  -- charaddress generation
  process(raster_fetch_state,glyph_data_address,reg_char_y16,charrow_repeated)
  begin
    if reg_char_y16 = '0' then
      charaddress <= safe_to_integer(glyph_data_address(11 downto 0));
    else
      if charrow_repeated='0' then
        charaddress <= safe_to_integer(glyph_data_address(10 downto 0));
      else
        charaddress <= 2048 + safe_to_integer(glyph_data_address(10 downto 0));
      end if;
    end if;
  --charaddress <= to_unsigned(0,12);
  --case raster_fetch_state is
  --  when FetchBitmapData =>
  --    report "setting charaddress to " & integer'image(safe_to_integer(glyph_data_address(10 downto 0)))
  --      & " for painting glyph $" & to_hstring(to_unsigned(safe_to_integer(glyph_number),16)) severity note;
  --    charaddress <= safe_to_integer(glyph_data_address(11 downto 0));
  --  when FetchTextCellColourAndSource =>
  --    -- upper bit of charrom address is set by $D018, only 258*8 = 2K
  --    -- range of address is controlled here by character number.
  --    report "setting charaddress to " & integer'image(safe_to_integer(glyph_data_address(10 downto 0)))
  --        & " for painting glyph $" & to_hstring(to_unsigned(safe_to_integer(glyph_number),16)) severity note;
  --    charaddress <= safe_to_integer(glyph_data_address(11 downto 0));
  --  when others => null;
  -- end case;
  end process;

  -- raster buffer read address/sub calculations
  -- pulled out so "next" value can be fed directly to raster buffer ram read address.
  process(raster_buffer_read_address,raster_buffer_read_address_sub,chargen_x_scale_drive,xcounter,x_chargen_start_minus1,
          reg_h640)
  begin
    raster_buffer_read_address_next <= raster_buffer_read_address;
    if xcounter = x_chargen_start_minus1 then
      -- Request first byte of pre-rendered character data
      report "raster fetch raster_buffer_read_address reset to zero at start of chargen";
      raster_buffer_read_address_next(9 downto 0) <= (others => '0');
      raster_buffer_read_address_sub_next(9 downto 0) <= (others => '0');
    else
      if reg_h640='1' then
        -- 640 wide characters use x scale directly
        if raster_buffer_read_address_sub >= 240 then
          raster_buffer_read_address_sub_next <= raster_buffer_read_address_sub - 240 + chargen_x_scale_drive;
          raster_buffer_read_address_next(9 downto 0) <= raster_buffer_read_address(9 downto 0) + 2;
        elsif raster_buffer_read_address_sub >= 120 then
          raster_buffer_read_address_sub_next <= raster_buffer_read_address_sub - 120 + chargen_x_scale_drive;
          raster_buffer_read_address_next(9 downto 0) <= raster_buffer_read_address(9 downto 0) + 1;
        else
          raster_buffer_read_address_sub_next <= raster_buffer_read_address_sub + chargen_x_scale_drive;
        end if;
      else
        -- 320 wide / 40 column text is 2x as wide, i.e., we halve the x scale
        -- factor.
        if raster_buffer_read_address_sub >= 240 then
          raster_buffer_read_address_sub_next <= raster_buffer_read_address_sub - 240 + chargen_x_scale_drive(7 downto 1);
          raster_buffer_read_address_next(9 downto 0) <= raster_buffer_read_address(9 downto 0) + 2;
        elsif raster_buffer_read_address_sub >= 120 then
          raster_buffer_read_address_sub_next <= raster_buffer_read_address_sub - 120 + chargen_x_scale_drive(7 downto 1);
          raster_buffer_read_address_next(9 downto 0) <= raster_buffer_read_address(9 downto 0) + 1;
        else
          raster_buffer_read_address_sub_next <= raster_buffer_read_address_sub + chargen_x_scale_drive(7 downto 1);
        end if;
      end if;
    end if;
  end process;

  -- K325T list mode v2: the table copy may use the chip RAM port in a cycle t only if
  -- exp_mfree(t) = '1'.  Proof that its read can never meet a VIC-IV read: the expander's
  -- mreq/maddr are registered, so a copy read decided at t is on next_ramaddress (= the port,
  -- chipram_address) in cycle t+1.  The VIC-IV reads in cycle c only if
  --   (a) this_ramaccess_is_screen_row_fetch(c) = '1' (the row fetch), or
  --   (b) raster_fetch_state(c) is one of the states listed in the mux below (glyphs: FetchBitmapData,
  --       FetchTextCellColourAndSource, PaintMemWait/2, PaintFullColourFetch; sprites/bitplanes:
  --       SpritePointerFetch2, SpritePointerCompute1, SpriteDataFetch/2); every other state
  --       leaves the address alone and consumes no data addressed in an mfree state.
  -- (a) this_ramaccess_is_screen_row_fetch(t+1) = next_ramaccess_is_screen_row_fetch(t), which
  --     exp_mfree(t) requires to be '0'.
  -- (b) exp_mfree(t) requires raster_fetch_state(t) in {Idle, ListWait, ListRun}.  The only
  --     successors in one cycle: Idle -> Idle (its case arm assigns nothing); ListWait ->
  --     ListWait, ListRun, FetchFirstCharacter; ListRun -> ListRun, FetchFirstCharacter; and from
  --     any state the line start / restart -> raster_fetch_state_init in {FetchScreenRamLine,
  --     FetchFirstCharacter}.  None of these is a reading state, so state(t+1) issues no read.
  --     (Their first reads come later: FetchScreenRamLine sets next_ at t+1 -> this_ at t+3;
  --     FetchFirstCharacter needs 4 more states before FetchTextCellColourAndSource.)
  -- The expander's own entry/object reads are decided in ListRun (the VIC-IV starts it only from
  -- ListWait and leaves ListRun only on exp_done or a line start, which aborts it in the same
  -- edge: its last read is then on the port in the first cycle of FetchScreenRamLine or
  -- FetchFirstCharacter, not a reading state either).
  -- K325T step 5: the expander's reads while painting overlaps: only in states whose successor
  -- (in one cycle) is never a VIC-IV reading state, so a read decided now and on the port in the
  -- next cycle meets no VIC-IV read (FetchNextCharacter -> FetchCharHighByte -> FetchTextCell;
  -- PaintMemWait3 / TurboFetch32 -> PaintDispatch / EndOfChargen; the old path's PaintDispatch ->
  -- FetchNextCharacter / FrontWait; PaintMemWait2 -> PaintMemWait3 / TurboFetch32 except the old
  -- path's full-colour fetch; TurboWait while it does not take a token).  The mono glyph byte is
  -- latched in PaintMemWait2, so the held port address is not needed after it.
  exp_ofree <= '1' when next_ramaccess_is_screen_row_fetch = '0'
                        and (raster_fetch_state = Idle or raster_fetch_state = ListWait
                             or raster_fetch_state = ListRun or raster_fetch_state = FrontWait
                             or raster_fetch_state = FetchNextCharacter
                             or raster_fetch_state = FetchCharHighByte
                             or raster_fetch_state = PaintMemWait3
                             or raster_fetch_state = TurboFetch32
                             or raster_fetch_state = EndOfChargen
                             or (raster_fetch_state = PaintDispatch and fp_line = '0')
                             or (raster_fetch_state = TurboWait and fp_dec /= DFull)
                             or (raster_fetch_state = PaintMemWait2
                                 and (glyph_full_colour = '0' or fp_line = '1')))
               else '0';
  exp_mfree <= '1' when (raster_fetch_state = Idle or raster_fetch_state = ListWait
                         or raster_fetch_state = ListRun)
                        and next_ramaccess_is_screen_row_fetch = '0' else '0';

  -- ramaddress mux
  -- This is pulled out into a combinatorial section so that ramaddress changes as soon as the raster_fetch_state
  -- value changes so that it can be driven into the block ram and sampled at the next clock cycle, thus providing the
  -- expected data on the next clock as well.
  process(raster_fetch_state,this_ramaccess_is_screen_row_fetch,glyph_data_address,sprite_pointer_address,sprite_data_address,
          ramaddress,this_screen_row_fetch_address,glyph_full_colour,exp_mreq,exp_maddr,fp_line,glyph_goto)
  begin
    next_ramaddress <= ramaddress;

    if this_ramaccess_is_screen_row_fetch='1' then
      report "chipram fetch for screen row data from $" & to_hstring(to_unsigned(safe_to_integer(this_screen_row_fetch_address),16));
      next_ramaddress <= this_screen_row_fetch_address;
    end if;

    case raster_fetch_state is
      when FetchBitmapData =>
        -- Ask for first byte of data so that paint can commence immediately.
        report "setting ramaddress to $" & to_hstring("000"&glyph_data_address) & " for glyph painting." severity note;
        next_ramaddress <= glyph_data_address;
      when FetchTextCellColourAndSource =>
        -- Ask for first byte of data so that paint can commence immediately.
        report "setting ramaddress to $" & to_hstring("000"&glyph_data_address) & " for glyph painting." severity note;
        next_ramaddress <= glyph_data_address;
      when PaintMemWait =>
        if glyph_full_colour = '1' then
          report "setting ramaddress to $" & to_hstring(glyph_data_address) & " for full-colour glyph drawing";
          next_ramaddress <= glyph_data_address;
        end if;
        -- K325T fast token path: the glyph's address (FetchTextCellColourAndSource put it out
        -- before); a full-colour row as its first 32-bit word
        if fp_line = '1' then
          next_ramaddress <= glyph_data_address;
          if glyph_full_colour = '1' then
            next_ramaddress(2 downto 0) <= "000";
          end if;
        end if;
      when PaintMemWait2 =>
        if glyph_full_colour = '1' then
          report "LEGACY: setting ramaddress to $" & to_hstring(glyph_data_address) & " for full-colour glyph drawing";
          next_ramaddress <= glyph_data_address;
          if fp_line = '1' then                 -- K325T fast token path: the second word
            next_ramaddress(2 downto 0) <= "100";
          end if;
        end if;
      when PaintFullColourFetch =>
        report "setting ramaddress to $" & to_hstring(glyph_data_address) & " for full-colour glyph drawing";
        next_ramaddress <= glyph_data_address;
      when SpritePointerFetch2 =>
        next_ramaddress <= sprite_pointer_address;
      when SpritePointerCompute1 =>
        next_ramaddress <= sprite_pointer_address;
      when SpriteDataFetch =>
        next_ramaddress <= sprite_data_address;
      when SpriteDataFetch2 =>
        next_ramaddress <= sprite_data_address;
      when others => null;
    end case;
    -- K325T RRB list mode: the expander reads entries and object data (ListRun only)
    if exp_mreq = '1' then
      next_ramaddress <= exp_maddr;
    end if;
  end process;

  process (pixelclock) is
  begin
    if rising_edge(pixelclock) then

      -- XXX Export $D031 mystery writes debug signal
      d031_written <= d031_written_internal;

      --Route out position counters for compositor
      --But delay them for the video pipeline depth.
      --1 pixel stage + 8 sprite + 8 bitplane = 17 cycles
      xcounter_out <= xcounter_pipeline_delayed;

      report "VICIV: xcounter=" & integer'image(to_integer(xcounter))
        & ", ycounter=" & integer'image(to_integer(ycounter));

      sprite_h640_delayed <= sprite_h640;
      sprite_v400s_delayed <= sprite_v400s;
      reg_h640_delayed <= reg_h640;
      reg_h1280_delayed <= reg_h1280;
      external_frame_x_zero_latched <= external_frame_x_zero;
      last_external_frame_x_zero_latched <= external_frame_x_zero_latched;

    -- ycounter we can watch for changes and count down, instead of having to have
    -- 17 copies of it
--      if ycounter /= ycounter_last then
--        ycounter_export_countdown <= 17;
--      else
--        if ycounter_export_countdown /= 0 then
--          ycounter_export_countdown <= ycounter_export_countdown - 1;
--          ycounter_out <= safe_to_integer(ycounter_last);
--          ycounter_out <= safe_to_integer(ycounter);
--        else
--        end if;
--      end if;
    end if;
  end process;

  ycounter_out <= safe_to_integer(ycounter);

end Behavioral;
