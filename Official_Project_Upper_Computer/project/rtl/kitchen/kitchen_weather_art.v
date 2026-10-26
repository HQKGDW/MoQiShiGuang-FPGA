`timescale 1ns/1ps

// Animated weather picture of the kitchen weather page, drawn over the left
// card (x 176..591, y 96..447). Six scenes:
//   0 晴天  a sun with a breathing glow and twinkling rays
//   1 多云  a smaller sun behind a drifting cloud
//   2 阴天  a grey back cloud and a light front cloud drifting apart
//   3 小雨  a cloud and slanted rain streaks
//   4 大雨  a darker cloud and dense, faster rain
//   5 雪天  a cloud and falling, swaying snowflakes
//
// Shapes are circles (six slots: 0-2 front cloud, 3-5 back cloud, slot 5 is
// the sun when there is one) plus a flat-bottomed rectangle per cloud. The
// squared distances are kept incrementally - (d+1)^2 = d^2 + 2d + 1 along a
// line and down the lines - from start values computed once per frame by a
// serial squarer in the vertical blank, so the picture needs no multiplier
// (the device's DSPs are all used) and no memory. Latency: four clocks.
module kitchen_weather_art (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        enable,          // the weather page is on screen
    input  wire [2:0]  kind,
    input  wire        in_vs,
    input  wire        in_de,
    input  wire [23:0] rgb_in,
    output reg         out_vs,
    output reg         out_de,
    output reg  [23:0] rgb_out
);
    localparam [10:0] X0 = 11'd176;
    localparam [9:0]  Y0 = 10'd96;
    localparam [10:0] W = 11'd416;
    localparam [9:0]  H = 10'd352;
    localparam integer N_SQ = 25;

    // ------------------------------------------------------------ raster
    reg        vs_q, de_q;
    reg [10:0] x_cnt;
    reg [9:0]  y_cnt;
    wire       frame_start = in_vs && !vs_q;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vs_q <= 1'b0; de_q <= 1'b0; x_cnt <= 11'd0; y_cnt <= 10'd0;
        end else begin
            vs_q <= in_vs;
            de_q <= in_de;
            x_cnt <= in_de ? x_cnt + 1'b1 : 11'd0;
            if (in_vs)
                y_cnt <= 10'd0;
            else if (de_q && !in_de)
                y_cnt <= y_cnt + 1'b1;
        end
    end

    // ------------------------------------------------------------ frame geometry
    reg [9:0]  t;                        // frame counter
    reg [2:0]  k;                        // scene of this frame
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            t <= 10'd0; k <= 3'd0;
        end else if (frame_start) begin
            t <= t + 1'b1;
            k <= (kind > 3'd5) ? 3'd0 : kind;
        end
    end
    wire [7:0] tri8 = t[8] ? ~t[7:0] : t[7:0];          // 0..255..0, 8.5 s
    wire [5:0] tri6 = t[6] ? ~t[5:0] : t[5:0];          // 0..63..0, 2.1 s
    wire signed [10:0] drift = $signed({3'd0, tri8[7:3]}) - 11'sd16;   // -16..15
    wire       has_sun = k <= 3'd1;
    wire       has_back = k == 3'd2;
    // Front cloud centre, back cloud centre, sun centre and radius (local).
    reg signed [10:0] fcx, fcy, bcx, bcy, scx, scy;
    reg [6:0]  sun_r;
    always @* begin
        case (k)
            3'd1:    begin fcx = 11'sd236 + drift; fcy = 11'sd206; end
            3'd2:    begin fcx = 11'sd248 + drift; fcy = 11'sd214; end
            default: begin fcx = 11'sd208 + (drift >>> 1); fcy = 11'sd118; end
        endcase
        bcx = 11'sd150 - drift;
        bcy = 11'sd132;
        scx = (k == 3'd0) ? 11'sd208 : 11'sd150;
        scy = (k == 3'd0) ? 11'sd176 : 11'sd122;
        sun_r = (k == 3'd0) ? 7'd62 : 7'd46;
    end
    // Circles: centre and radius per slot (radius 0 = unused).
    reg signed [10:0] ccx [0:5];
    reg signed [10:0] ccy [0:5];
    reg [6:0]  crad [0:5];
    always @* begin
        ccx[0] = fcx - 11'sd62; ccy[0] = fcy + 11'sd18; crad[0] = (k == 3'd0) ? 7'd0 : 7'd46;
        ccx[1] = fcx + 11'sd2;  ccy[1] = fcy - 11'sd14; crad[1] = (k == 3'd0) ? 7'd0 : 7'd64;
        ccx[2] = fcx + 11'sd64; ccy[2] = fcy + 11'sd22; crad[2] = (k == 3'd0) ? 7'd0 : 7'd40;
        ccx[3] = bcx - 11'sd44; ccy[3] = bcy + 11'sd13; crad[3] = has_back ? 7'd34 : 7'd0;
        ccx[4] = bcx + 11'sd2;  ccy[4] = bcy - 11'sd10; crad[4] = has_back ? 7'd46 : 7'd0;
        if (has_sun) begin
            ccx[5] = scx; ccy[5] = scy; crad[5] = sun_r;
        end else begin
            ccx[5] = bcx + 11'sd46; ccy[5] = bcy + 11'sd16; crad[5] = has_back ? 7'd30 : 7'd0;
        end
    end
    // Sun radii: in_core core, glow bands (breathing), ray span (breathing).
    wire [7:0] glow = 8'd10 + tri6[5:2];
    wire [7:0] ray_len = 8'd18 + tri6[5:2] + tri6[5:3];
    wire [7:0] r_in   = {1'b0, sun_r} - {3'd0, sun_r[6:2]} - {4'd0, sun_r[6:3]};   // ~0.62 r
    wire [7:0] r_g1   = {1'b0, sun_r} + (glow >> 2);
    wire [7:0] r_g2   = {1'b0, sun_r} + (glow >> 1);
    wire [7:0] r_g3   = {1'b0, sun_r} + glow;
    wire [7:0] r_ray0 = {1'b0, sun_r} + 8'd14;
    wire [7:0] r_ray1 = {1'b0, sun_r} + 8'd14 + ray_len;

    // Serial squarer: 25 values, 12 clocks each, after the vertical sync.
    reg [4:0]  sq_k;
    reg [3:0]  sq_bit;
    reg        sq_busy, geo_ready;
    reg [19:0] sq_acc;
    reg [19:0] sq [0:N_SQ-1];
    reg [10:0] sq_v;                  // operand of value sq_k (combinational)
    reg [10:0] sq_op;                 // ... registered, while its bits are summed
    always @* begin
        case (sq_k)
            5'd0:  sq_v = ccx[0][10] ? -ccx[0] : ccx[0];
            5'd1:  sq_v = ccx[1][10] ? -ccx[1] : ccx[1];
            5'd2:  sq_v = ccx[2][10] ? -ccx[2] : ccx[2];
            5'd3:  sq_v = ccx[3][10] ? -ccx[3] : ccx[3];
            5'd4:  sq_v = ccx[4][10] ? -ccx[4] : ccx[4];
            5'd5:  sq_v = ccx[5][10] ? -ccx[5] : ccx[5];
            5'd6:  sq_v = ccy[0][10] ? -ccy[0] : ccy[0];
            5'd7:  sq_v = ccy[1][10] ? -ccy[1] : ccy[1];
            5'd8:  sq_v = ccy[2][10] ? -ccy[2] : ccy[2];
            5'd9:  sq_v = ccy[3][10] ? -ccy[3] : ccy[3];
            5'd10: sq_v = ccy[4][10] ? -ccy[4] : ccy[4];
            5'd11: sq_v = ccy[5][10] ? -ccy[5] : ccy[5];
            5'd12: sq_v = {4'd0, crad[0]};
            5'd13: sq_v = {4'd0, crad[1]};
            5'd14: sq_v = {4'd0, crad[2]};
            5'd15: sq_v = {4'd0, crad[3]};
            5'd16: sq_v = {4'd0, crad[4]};
            5'd17: sq_v = {4'd0, crad[5]};
            5'd18: sq_v = {3'd0, r_in};
            5'd19: sq_v = {3'd0, r_g1};
            5'd20: sq_v = {3'd0, r_g2};
            5'd21: sq_v = {3'd0, r_g3};
            5'd22: sq_v = {3'd0, r_ray0};
            5'd23: sq_v = {3'd0, r_ray1};
            default: sq_v = 11'd0;
        endcase
    end
    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sq_k <= 5'd0; sq_bit <= 4'd15; sq_busy <= 1'b0; geo_ready <= 1'b0; sq_acc <= 20'd0; sq_op <= 11'd0;
            for (i = 0; i < N_SQ; i = i + 1) sq[i] <= 20'd0;
        end else begin
            geo_ready <= 1'b0;
            if (vs_q && !in_vs) begin                  // end of vertical sync: geometry is stable
                sq_busy <= 1'b1; sq_k <= 5'd0; sq_bit <= 4'd15; sq_acc <= 20'd0;
            end else if (sq_busy) begin
                if (sq_bit == 4'd15) begin
                    // Load the operand, then sum its 11 shifted bits.
                    sq_op <= sq_v;
                    sq_acc <= 20'd0;
                    sq_bit <= 4'd0;
                end else begin
                    if (sq_op[sq_bit])
                        sq_acc <= sq_acc + ({9'd0, sq_op} << sq_bit);
                    if (sq_bit == 4'd10) begin
                        sq[sq_k] <= sq_acc + (sq_op[10] ? {9'd0, sq_op} << 10 : 20'd0);
                        sq_bit <= 4'd15;
                        if (sq_k == N_SQ - 1) begin
                            sq_busy <= 1'b0;
                            geo_ready <= 1'b1;
                        end else begin
                            sq_k <= sq_k + 1'b1;
                        end
                    end else begin
                        sq_bit <= sq_bit + 1'b1;
                    end
                end
            end
        end
    end

    // ------------------------------------------------------------ incremental distances
    reg signed [11:0] dx [0:5];
    reg signed [11:0] dy [0:5];
    // 18 bits hold every square inside the art window (|dx| < 330, |dy| < 260);
    // outside it the sums may wrap, but nothing is drawn there.
    reg [17:0] dx2 [0:5];
    reg [17:0] dy2 [0:5];
    wire line_start = in_de && x_cnt == X0 - 1'b1;
    wire line_end = de_q && !in_de && y_cnt >= Y0 && y_cnt < Y0 + H;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < 6; i = i + 1) begin
                dx[i] <= 12'sd0; dy[i] <= 12'sd0; dx2[i] <= 18'd0; dy2[i] <= 18'd0;
            end
        end else begin
            for (i = 0; i < 6; i = i + 1) begin
                if (line_start) begin
                    dx[i] <= -{ccx[i][10], ccx[i]};
                    dx2[i] <= sq[i][17:0];
                end else if (in_de) begin
                    dx[i] <= dx[i] + 12'sd1;
                    dx2[i] <= dx2[i] + {{5{dx[i][11]}}, dx[i], 1'b1};
                end
                if (geo_ready) begin
                    dy[i] <= -{ccy[i][10], ccy[i]};
                    dy2[i] <= sq[6 + i][17:0];
                end else if (line_end) begin
                    dy[i] <= dy[i] + 12'sd1;
                    dy2[i] <= dy2[i] + {{5{dy[i][11]}}, dy[i], 1'b1};
                end
            end
        end
    end

    // ------------------------------------------------------------ s1: coverage
    wire [10:0] lx = x_cnt - X0;
    wire [9:0]  ly = y_cnt - Y0;
    wire        in_art = enable && in_de && x_cnt >= X0 && x_cnt < X0 + W &&
                         y_cnt >= Y0 && y_cnt < Y0 + H;
    reg  [17:0] d2 [0:5];
    reg  [5:0]  in_circ;
    always @* begin
        for (i = 0; i < 6; i = i + 1) begin
            d2[i] = dx2[i] + dy2[i];
            in_circ[i] = crad[i] != 7'd0 && d2[i] < sq[12 + i][17:0];
        end
    end
    // Flat-bottomed cloud bodies.
    wire signed [11:0] slx = {1'b0, lx};
    wire signed [11:0] sly = {2'b00, ly};
    wire front_rect = k != 3'd0 && slx >= fcx - 12'sd62 && slx <= fcx + 12'sd64 &&
                      sly >= fcy + 12'sd18 && sly < fcy + 12'sd64;
    wire back_rect = has_back && slx >= bcx - 12'sd44 && slx <= bcx + 12'sd46 &&
                     sly >= bcy + 12'sd13 && sly < bcy + 12'sd46;
    wire front_cloud = (in_circ[0] || in_circ[1] || in_circ[2] || front_rect) && sly < fcy + 12'sd64;
    wire front_solid = front_cloud;
    wire back_cloud = has_back && (in_circ[3] || in_circ[4] || in_circ[5] || back_rect) && sly < bcy + 12'sd46;
    wire front_shade = sly > fcy + 12'sd30;
    // Sun: core, rim, glow bands and rays.
    wire sun_core = has_sun && in_circ[5];
    wire sun_solid = sun_core;
    wire sun_hot = has_sun && d2[5] < sq[18][17:0];
    wire [1:0] sun_glow = !has_sun ? 2'd0 : d2[5] < sq[19][17:0] ? 2'd3 :
                          d2[5] < sq[20][17:0] ? 2'd2 : d2[5] < sq[21][17:0] ? 2'd1 : 2'd0;
    wire [11:0] ax = dx[5][11] ? -dx[5] : dx[5];
    wire [11:0] ay = dy[5][11] ? -dy[5] : dy[5];
    wire in_ray_span = has_sun && d2[5] >= sq[22][17:0] && d2[5] < sq[23][17:0];
    // Rain: slanted streaks under the cloud.
    wire [10:0] u = lx + {3'd0, ly[9:2]};
    wire        heavy = k == 3'd4;
    wire [5:0]  rcol = heavy ? u[9:4] : {1'b0, u[9:5]};
    wire [4:0]  rphase = heavy ? {1'b0, u[3:0]} : u[4:0];
    wire [4:0]  rhash = {rcol[0], rcol[3], rcol[1], rcol[4] ^ rcol[5], rcol[2]};
    wire [9:0]  fall = heavy ? {t[7:0], 2'b00} + t : {t[8:0], 1'b0} + t;   // 5 or 3 px per frame
    wire [9:0]  rv = ly - fall + {rhash, 3'd0} + {1'b0, rhash, 2'd0};       // + 12 x column hash
    wire        rain_zone = (k == 3'd3 || k == 3'd4) && lx >= 11'd40 && lx < 11'd376 &&
                            sly > fcy + 12'sd70;
    wire        rain = rain_zone && rphase < 5'd2 &&
                       (heavy ? rv[4:0] < 5'd18 : rv[5:0] < 6'd14);
    // Snow: one flake in half of the 32x32 cells, falling and swaying.
    wire signed [11:0] sway = $signed({6'd0, tri6[5:3]}) - 12'sd4;
    wire [10:0] snx = lx + sway[10:0];
    wire [9:0]  sny = ly - t;
    wire [4:0]  scell_x = snx[9:5];
    wire [4:0]  scell_y = sny[9:5];
    wire [4:0]  sh = {scell_x[1:0], 3'd0} + scell_x + {scell_y[2:0], 1'b0} + scell_y;   // 9x + 3y
    wire [4:0]  fx = 5'd8 + {1'b0, sh[3:0]};
    wire [4:0]  fy = 5'd8 + {1'b0, sh[4:1]};
    wire [4:0]  sdx = snx[4:0] > fx ? snx[4:0] - fx : fx - snx[4:0];
    wire [4:0]  sdy = sny[4:0] > fy ? sny[4:0] - fy : fy - sny[4:0];
    wire        flake_shape = (sdy == 5'd0 && sdx <= 5'd4) || (sdx == 5'd0 && sdy <= 5'd4) ||
                              (sdx == sdy && sdx <= 5'd3);
    wire        snow = k == 3'd5 && lx >= 11'd24 && lx < 11'd392 && sly > fcy + 12'sd60 &&
                       sh[0] && flake_shape;

    // s0: coverage registered; the rays need one more stage.
    reg        vs0, de0, art0, fc0, fs0, fsh0, bc0, sc0, ss0, shot0, span0, rain0, snow0;
    reg [1:0]  glow0;
    reg [23:0] rgb0;
    reg [11:0] ax0, ay0;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vs0 <= 1'b0; de0 <= 1'b0; art0 <= 1'b0; fc0 <= 1'b0; fs0 <= 1'b0; fsh0 <= 1'b0;
            bc0 <= 1'b0; sc0 <= 1'b0; ss0 <= 1'b0; shot0 <= 1'b0; span0 <= 1'b0; rain0 <= 1'b0;
            snow0 <= 1'b0; glow0 <= 2'd0; rgb0 <= 24'd0; ax0 <= 12'd0; ay0 <= 12'd0;
        end else begin
            vs0 <= in_vs; de0 <= in_de; rgb0 <= rgb_in; art0 <= in_art;
            fc0 <= front_cloud; fs0 <= front_solid; fsh0 <= front_shade; bc0 <= back_cloud;
            sc0 <= sun_core; ss0 <= sun_solid; shot0 <= sun_hot; span0 <= in_ray_span;
            glow0 <= sun_glow; rain0 <= rain; snow0 <= snow;
            ax0 <= dx[5][11] ? -dx[5] : dx[5];
            ay0 <= dy[5][11] ? -dy[5] : dy[5];
        end
    end
    // Rays: horizontal, vertical and diagonal, or the set in between (twinkle).
    wire [11:0] axs = (ax0 >> 2) + (ax0 >> 3) + (ax0 >> 5) + (ax0 >> 7);    // ~0.414 |dx|
    wire [11:0] ays = (ay0 >> 2) + (ay0 >> 3) + (ay0 >> 5) + (ay0 >> 7);
    wire [11:0] adiff = ax0 > ay0 ? ax0 - ay0 : ay0 - ax0;
    wire ray_set_a = ay0 < 12'd4 || ax0 < 12'd4 || adiff < 12'd6;
    wire ray_set_b = (ay0 > axs ? ay0 - axs : axs - ay0) < 12'd4 ||
                     (ax0 > ays ? ax0 - ays : ays - ax0) < 12'd4;
    wire sun_ray = span0 && (t[5] ? ray_set_b : ray_set_a);

    reg        vs1, de1, art1, fc1, fs1, fsh1, bc1, sc1, ss1, shot1, sray1, rain1, snow1;
    reg [1:0]  glow1;
    reg [2:0]  k1;
    reg [23:0] rgb1;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vs1 <= 1'b0; de1 <= 1'b0; art1 <= 1'b0; fc1 <= 1'b0; fs1 <= 1'b0; fsh1 <= 1'b0;
            bc1 <= 1'b0; sc1 <= 1'b0; ss1 <= 1'b0; shot1 <= 1'b0; sray1 <= 1'b0; rain1 <= 1'b0;
            snow1 <= 1'b0; glow1 <= 2'd0; k1 <= 3'd0; rgb1 <= 24'd0;
        end else begin
            vs1 <= vs0; de1 <= de0; rgb1 <= rgb0; k1 <= k;
            art1 <= art0;
            fc1 <= fc0; fs1 <= fs0; fsh1 <= fsh0; bc1 <= bc0;
            sc1 <= sc0; ss1 <= ss0; shot1 <= shot0; sray1 <= sun_ray;
            glow1 <= glow0; rain1 <= rain0; snow1 <= snow0;
        end
    end

    // ------------------------------------------------------------ s2: colour
    function [7:0] mix4;                 // (4 - w) / 4 a + w / 4 b
        input [7:0] a;
        input [7:0] b;
        input [1:0] w;
        begin
            case (w)
                2'd0: mix4 = a;
                2'd1: mix4 = (a >> 1) + (a >> 2) + (b >> 2);
                2'd2: mix4 = (a >> 1) + (b >> 1);
                default: mix4 = (a >> 2) + (b >> 1) + (b >> 2);
            endcase
        end
    endfunction
    function [23:0] mix;
        input [23:0] a;
        input [23:0] b;
        input [1:0] w;
        begin
            mix = {mix4(a[23:16], b[23:16], w), mix4(a[15:8], b[15:8], w), mix4(a[7:0], b[7:0], w)};
        end
    endfunction
    wire [23:0] cloud_rgb = (k1 == 3'd4) ? (fsh1 ? 24'h8995a6 : 24'ha9b4c2) :
                            (k1 == 3'd3) ? (fsh1 ? 24'hb8c3d1 : 24'hd5dde7) :
                            fsh1 ? 24'hd3dce6 : 24'hf1f5f9;
    // One layer per pixel, front to back; it is blended with the card
    // background only (the layers barely overlap).
    reg [23:0] colour2, rgb2;
    reg [1:0]  weight2;                  // quarters of the layer colour
    reg        vs2, de2;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            colour2 <= 24'd0; rgb2 <= 24'd0; weight2 <= 2'd0; vs2 <= 1'b0; de2 <= 1'b0;
        end else begin
            vs2 <= vs1;
            de2 <= de1;
            rgb2 <= rgb1;
            weight2 <= 2'd0;
            colour2 <= 24'd0;
            if (art1) begin
                if (snow1) begin
                    colour2 <= 24'hf4f8ff; weight2 <= 2'd3;
                end else if (rain1) begin
                    colour2 <= (k1 == 3'd4) ? 24'h5aa8ff : 24'h7cc6ff; weight2 <= 2'd3;
                end else if (fc1) begin
                    colour2 <= cloud_rgb; weight2 <= fs1 ? 2'd3 : 2'd2;
                end else if (bc1) begin
                    colour2 <= 24'h76838f; weight2 <= 2'd3;
                end else if (sc1) begin
                    colour2 <= ss1 && shot1 ? 24'hfff3c4 : 24'hffd24d; weight2 <= ss1 ? 2'd3 : 2'd2;
                end else if (sray1) begin
                    colour2 <= 24'hffc94d; weight2 <= 2'd3;
                end else if (glow1 != 2'd0) begin
                    colour2 <= 24'hffb020; weight2 <= glow1 == 2'd3 ? 2'd2 : 2'd1;
                end
            end
        end
    end
    // Weight 3 means the layer colour itself (a solid shape).
    wire [23:0] blended = (weight2 == 2'd3) ? colour2 : mix(rgb2, colour2, weight2);

    // ------------------------------------------------------------ s3: output
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_vs <= 1'b0; out_de <= 1'b0; rgb_out <= 24'd0;
        end else begin
            out_vs <= vs2; out_de <= de2; rgb_out <= blended;
        end
    end
endmodule
