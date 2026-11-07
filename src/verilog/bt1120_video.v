// From the QMTech K325T bring-up (tm_fpga/rtl/bt1120_video.v, BT1120 -> HDMI, verified on the board
// 2026-07-10, sim: tb_bt1120_video BIT-EXACT).  Used by linux_fb.vhdl for the Rockchip's picture.
// bt1120_video.v — BT.1120 16-bit in -> RGB888 + display syncs (pixel domain).
//
//   bt1120_rx -> YC-lane auto-detect -> 4:2:2->4:4:4 -> YCbCr->RGB (BT.601 ltd)
//              -> rgb888/de/hsync/vsync, everything aligned in the dclk domain.
//
// * YC lanes: which byte of bt_d carries luma is a VOP wiring detail we can't
//   know up front.  BT.1120 blanking fill is Y=0x10 C=0x80, so during horizontal
//   blanking (not active, not TRS) the word is either {C,Y}=0x8010 or 0x1080 —
//   sampled continuously to steer a swap mux (default: Y = high byte).
// * Chroma upsample is sample-and-hold per Cb/Cr pair (4:2:2 nearest), pixel k
//   uses (Y_k, Cb_2m, Cr_2m+1) of its pair m — 2-beat latency, continuous.
// * Timing: DE comes from the decoder's dv (exact active window).  hsync/vsync
//   are synthesized at fixed offsets from SAV / the vblank edge with VESA-ish
//   positions for 640x480@60 (sinks lock on period + DE, exact porch split is
//   not critical).  All syncs ride the same delay line as the video pipeline.
`default_nettype none
module bt1120_video #(
    parameter [10:0] VS_START = 11'd490,   // vsync at line 490/491 (640x480@60)
    parameter [10:0] VS_END   = 11'd492,
    parameter [11:0] HS_START = 12'd657,   // hsync ~[657,753) after SAV @ h=0
    parameter [11:0] HS_END   = 12'd753,
    parameter        POS_SYNC = 1'b0       // 0: negative (VESA 480p), 1: positive (CEA 720p)
)(
    input  wire        pclk,        // recovered BT1120 pixel clock (MMCM output)
    input  wire        rst_n,
    input  wire [15:0] bt_d,        // registered input word

    output wire [23:0] rgb,         // {R,G,B}
    output wire        de,
    output wire        hsync,       // negative polarity
    output wire        vsync,       // negative polarity
    output wire        locked,      // saw a frame edge (vblank 1->0) recently
    output wire        yc_swapped   // debug: 1 = luma found on LOW byte
);
    // ---------------- front-end decoder ----------------
    wire        dv, sof, sol, sav, vbl, act;
    wire [15:0] dout;
    bt1120_rx u_rx (
        .dclk(pclk), .rst_n(rst_n), .d(bt_d),
        .dv(dv), .dout(dout), .sof(sof), .sol(sol),
        .sav(sav), .vbl(vbl), .active(act)
    );

    // ---------------- YC-lane auto-detect ----------------
    // In blanking fill (outside active video; TRS bytes are FF/00 so they can
    // never alias), the word is Y=0x10 C=0x80 on whichever lanes carry them:
    //   bt_d == 0x8010  ->  high byte 0x80 = CHROMA  ->  Y on LOW  byte (swap=1)
    //   bt_d == 0x1080  ->  high byte 0x10 = LUMA    ->  Y on HIGH byte (swap=0)
    reg swap = 1'b0;                 // 0: Y=dout[15:8] (default), 1: Y=dout[7:0]
    always @(posedge pclk) begin
        if (!act) begin
            if      (bt_d == 16'h8010) swap <= 1'b1;   // Y on low byte
            else if (bt_d == 16'h1080) swap <= 1'b0;   // Y on high byte
        end
    end
    assign yc_swapped = swap;

    wire [7:0] y8 = swap ? dout[7:0]  : dout[15:8];
    wire [7:0] c8 = swap ? dout[15:8] : dout[7:0];

    // ---------------- timing regeneration ----------------
    reg [11:0] h = 12'd0;            // 0 at SAV
    reg [10:0] v = 11'd0;            // 0 at first active line of a frame
    reg        vbl_q = 1'b1;
    reg [7:0]  lock_cnt = 8'd0;      // frames seen (saturating) -> locked
    always @(posedge pclk) begin
        if (!rst_n) begin
            h <= 12'd0; v <= 11'd0; vbl_q <= 1'b1; lock_cnt <= 8'd0;
        end else begin
            h <= sav ? 12'd0 : h + 12'd1;
            if (sav) begin
                vbl_q <= vbl;
                if (!vbl && vbl_q) begin
                    v <= 11'd0;                      // first active line
                    if (lock_cnt != 8'hFF) lock_cnt <= lock_cnt + 8'd1;
                end else begin
                    v <= v + 11'd1;
                end
            end
        end
    end
    assign locked = (lock_cnt >= 8'd2);
    wire hs_in = (h >= HS_START) && (h < HS_END);
    wire vs_in = (v >= VS_START) && (v < VS_END);
    wire hs_raw = POS_SYNC ? hs_in : ~hs_in;
    wire vs_raw = POS_SYNC ? vs_in : ~vs_in;

    // ---------------- 4:2:2 -> 4:4:4 (2-beat latency) ----------------
    reg        par = 1'b0;           // parity of the CURRENT dv beat
    reg [7:0]  y_d1, y_d2, cb_h, cb_p, cr_p;
    reg        dv_d1 = 1'b0, dv_d2 = 1'b0;
    always @(posedge pclk) begin
        if (sol)      par <= 1'b0;
        else if (dv)  par <= ~par;
        if (dv) begin
            y_d1 <= y8;
            if (!par) cb_h <= c8;                   // even beat: hold Cb
            else begin cb_p <= cb_h; cr_p <= c8; end // odd beat: commit pair
        end
        if (dv | dv_d1 | dv_d2) y_d2 <= y_d1;       // advance while draining
        dv_d1 <= dv; dv_d2 <= dv_d1;
    end

    // ---------------- CSC: BT.601 limited YCbCr -> RGB (x256 coeffs) --------
    //   R = 1.164(Y-16) + 1.596(Cr-128)
    //   G = 1.164(Y-16) - 0.392(Cb-128) - 0.813(Cr-128)
    //   B = 1.164(Y-16) + 2.017(Cb-128)
    // stage A: center;  stage B: multiply;  stage C: sum + round + clip.
    reg  signed [9:0]  yc, cbc, crc;
    reg                deA, hsA, vsA;
    always @(posedge pclk) begin
        yc  <= $signed({2'b00, y_d2}) - 10'sd16;
        cbc <= $signed({2'b00, cb_p}) - 10'sd128;
        crc <= $signed({2'b00, cr_p}) - 10'sd128;
        deA <= dv_d2; hsA <= hs_raw; vsA <= vs_raw;
    end
    // coefficients need 11-bit signed: 516 would wrap to -508 in 10 bits
    reg signed [21:0] my, mrcr, mgcb, mgcr, mbcb;
    reg               deB, hsB, vsB;
    always @(posedge pclk) begin
        my   <= yc  * 11'sd298;
        mrcr <= crc * 11'sd409;
        mgcb <= cbc * 11'sd100;
        mgcr <= crc * 11'sd208;
        mbcb <= cbc * 11'sd516;
        deB <= deA; hsB <= hsA; vsB <= vsA;
    end
    wire signed [22:0] rs = my + mrcr + 23'sd128;
    wire signed [22:0] gs = my - mgcb - mgcr + 23'sd128;
    wire signed [22:0] bs = my + mbcb + 23'sd128;
    function [7:0] clip8(input signed [22:0] x);
        reg signed [14:0] s;
        begin
            s = x >>> 8;
            clip8 = (s < 0) ? 8'd0 : (s > 15'sd255) ? 8'd255 : s[7:0];
        end
    endfunction
    reg [23:0] rgbC; reg deC, hsC, vsC;
    always @(posedge pclk) begin
        rgbC <= {clip8(rs), clip8(gs), clip8(bs)};
        deC <= deB; hsC <= hsB; vsC <= vsB;
    end

    assign rgb   = deC ? rgbC : 24'h000000;
    assign de    = deC;
    assign hsync = hsC;
    assign vsync = vsC;
endmodule
`default_nettype wire
