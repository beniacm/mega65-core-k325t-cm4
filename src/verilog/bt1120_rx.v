// From the QMTech K325T bring-up (tm_fpga/rtl/bt1120_rx.v, BT1120 -> HDMI, verified on the board
// 2026-07-10, sim: tb_bt1120_video BIT-EXACT).  Used by linux_fb.vhdl for the Rockchip's picture.
// bt1120_rx.v — BT.1120 16-bit receiver front-end (pixel-clock domain).
//
// Repurposes the RK3566 VOP's BT1120 video output as a fast RK->FPGA data pipe
// (see tm_fpga/FAST_COMM.md). BT1120 carries sync in-band via Timing Reference
// Signals (TRS): a 4-word run  FF, 00, 00, XY  where XY = {1,F,V,H,P3..P0}:
//   H=1 -> EAV (end active video),  H=0 -> SAV (start active video)
//   V=1 -> vertical blanking,  F = field
// Between an SAV and the next EAV the words are ACTIVE VIDEO = our payload.
//
// IMPORTANT (transport constraint): BT.656/1120 RESERVES byte codes 0x00 and
// 0xFF for TRS, so active video may only use 0x01..0xFE per byte. The host
// therefore cannot blit arbitrary bytes — it must encode payload to avoid
// 0x00/0xFF (see FAST_COMM.md). Given that, the luma byte == 0xFF unambiguously
// marks the start of a TRS, which is how this decoder locks:
//   normal --(luma==FF)--> consume 00,00,XY (decode XY) --> normal
//
// Output: valid/data stream + start-of-frame (F edge) / start-of-line (SAV)
// strobes, all in the dclk domain. CDC + DDR packing live in bt1120_ddr_loader.v.

`default_nettype none
module bt1120_rx (
    input  wire        dclk,        // BT1120 pixel clock (GPIO3_A6)
    input  wire        rst_n,       // async assert, sync deassert to dclk
    input  wire [15:0] d,           // BT1120 16-bit data bus

    output reg         dv,          // active-video word valid this cycle
    output reg  [15:0] dout,        // 16-bit payload word (valid when dv)
    output reg         sof,         // 1-cyc: SAV of a new frame (field bit flipped)
    output reg         sol,         // 1-cyc: SAV of a new line
    // extras for the video (BT1120->HDMI) consumer; loader ignores them
    output reg         sav,         // 1-cyc: ANY SAV, including blanking lines
    output reg         vbl,         // V bit of the most recent SAV (1 = v-blank)
    output wire        active       // between SAV and EAV (blanking-fill detect)
);
    // TRS state: 0 = normal video; 3/2/1 = consuming the 00,00,XY after an FF.
    reg [1:0] trs;
    reg       in_active;            // between SAV and EAV
    reg       field_q;              // last field bit (for frame-start edge)
    assign active = in_active;

    always @(posedge dclk or negedge rst_n) begin
        if (!rst_n) begin
            trs <= 2'd0; in_active <= 1'b0; field_q <= 1'b0;
            dv <= 1'b0; dout <= 16'h0; sof <= 1'b0; sol <= 1'b0;
            sav <= 1'b0; vbl <= 1'b1;
        end else begin
            dv <= 1'b0; sof <= 1'b0; sol <= 1'b0; sav <= 1'b0;

            if (trs != 2'd0) begin
                // inside a TRS: words are 00, 00, XY (XY when trs==1)
                if (trs == 2'd1) begin
                    // d = XY status word
                    if (d[4]) begin
                        in_active <= 1'b0;                 // EAV
                    end else begin
                        sav <= 1'b1;                       // SAV (any line)
                        vbl <= d[5];
                        if (!d[5]) begin
                            in_active <= 1'b1;             // SAV, non-blank line
                            sol <= 1'b1;
                            if (d[6] != field_q) sof <= 1'b1;  // field edge = new frame
                            field_q <= d[6];
                        end
                    end
                end
                trs <= trs - 2'd1;
            end else if (d[7:0] == 8'hFF) begin
                trs <= 2'd3;                                // FF -> start of TRS
            end else if (in_active) begin
                dv   <= 1'b1;                               // ordinary active word
                dout <= d;
            end
        end
    end
endmodule
`default_nettype wire
