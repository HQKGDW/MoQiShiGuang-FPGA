`timescale 1ns/1ps

// Spectrum bars of the kitchen console in tile row 20, above the ticker
// (x 160..1279, y 640..671): 28 bars, 40 px apart, that jump with the sound.
//
// Analysis: for every 48 kHz sample one sequential engine runs 28 band-pass
// filters (Chamberlin state-variable filters, two passes per sample, i.e.
// 96 kHz, centres 50 Hz .. 12 kHz on a log scale, damping 3/8) with a single
// shared multiplier, and follows the peak of each band output (decay
// 2^-10 per sample). The peak becomes a code of two steps per octave (3 dB).
// Every frame the code minus a per-band offset (calibrated on the six tracks
// of AUDIO.PCM, see tools/spectrum_model.py) gives the bar height 0..10:
// bars rise at once and fall one segment per frame; a light cap marks the
// recent peak, holds 24 frames and then falls.
//
// Drawing: each bar is 32 px wide with 10 LED segments of 2 px (1 px gaps)
// above a baseline, coloured in the accent colour (mode 0110), dimmer at the
// bottom; unlit segments stay faintly visible. Latency: four clocks for vs,
// de and rgb.
module kitchen_spectrum (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               enable,          // draw the band (console pages)
    input  wire signed [15:0] sample,          // mixed output, after the volume
    input  wire               sample_valid,
    input  wire [23:0]        accent,
    input  wire               in_vs,
    input  wire               in_de,
    input  wire [23:0]        rgb_in,
    output reg                out_vs,
    output reg                out_de,
    output reg  [23:0]        rgb_out
);
    localparam integer NB = 28;
    localparam [10:0] X0 = 11'd160;
    localparam [9:0]  Y0 = 10'd640;
    localparam signed [21:0] SMAX = 22'sh1fffff;
    localparam signed [21:0] SMIN = -22'sh200000;

    // f = 2 sin(pi fc / 96 kHz) in Q16.
    function [15:0] coef;
        input [4:0] k;
        begin
            case (k)
                5'd0:  coef = 16'd214;   5'd1:  coef = 16'd263;   5'd2:  coef = 16'd322;
                5'd3:  coef = 16'd394;   5'd4:  coef = 16'd483;   5'd5:  coef = 16'd592;
                5'd6:  coef = 16'd725;   5'd7:  coef = 16'd888;   5'd8:  coef = 16'd1088;
                5'd9:  coef = 16'd1333;  5'd10: coef = 16'd1633;  5'd11: coef = 16'd2000;
                5'd12: coef = 16'd2450;  5'd13: coef = 16'd3002;  5'd14: coef = 16'd3677;
                5'd15: coef = 16'd4504;  5'd16: coef = 16'd5517;  5'd17: coef = 16'd6758;
                5'd18: coef = 16'd8277;  5'd19: coef = 16'd10137; 5'd20: coef = 16'd12412;
                5'd21: coef = 16'd15193; 5'd22: coef = 16'd18592; 5'd23: coef = 16'd22738;
                5'd24: coef = 16'd27784; 5'd25: coef = 16'd33907; 5'd26: coef = 16'd41300;
                default: coef = 16'd50159;
            endcase
        end
    endfunction

    // Code at which a bar starts to light, per band.
    function [5:0] base;
        input [4:0] k;
        begin
            case (k)
                5'd0:  base = 6'd23; 5'd1:  base = 6'd24; 5'd2:  base = 6'd24; 5'd3:  base = 6'd24;
                5'd4:  base = 6'd25; 5'd5:  base = 6'd25; 5'd6:  base = 6'd25; 5'd7:  base = 6'd25;
                5'd8:  base = 6'd25; 5'd9:  base = 6'd25; 5'd10: base = 6'd25; 5'd11: base = 6'd25;
                5'd12: base = 6'd25; 5'd13: base = 6'd24; 5'd14: base = 6'd23; 5'd15: base = 6'd23;
                5'd16: base = 6'd22; 5'd17: base = 6'd22; 5'd18: base = 6'd21; 5'd19: base = 6'd20;
                5'd20: base = 6'd20; 5'd21: base = 6'd19; 5'd22: base = 6'd18; 5'd23: base = 6'd18;
                5'd24: base = 6'd17; 5'd25: base = 6'd17; 5'd26: base = 6'd16;
                default: base = 6'd15;
            endcase
        end
    endfunction

    function signed [21:0] sat22;
        input signed [23:0] v;
        begin
            sat22 = (v > $signed({{2{SMAX[21]}}, SMAX})) ? SMAX :
                    (v < $signed({{2{SMIN[21]}}, SMIN})) ? SMIN : v[21:0];
        end
    endfunction

    // Two codes per octave: {msb position, next bit}.
    function [5:0] level_code;
        input [21:0] v;
        reg [5:0] c;
        integer i;
        begin
            c = 6'd0;
            for (i = 1; i < 22; i = i + 1)
                if (v[i])
                    c = {i[4:0], 1'b0} + v[i - 1];
            level_code = c;
        end
    endfunction

    // ------------------------------------------------------------ filter engine
    localparam [3:0] E_CLEAR = 4'd0, E_IDLE = 4'd1, E_READ = 4'd2, E_LOAD = 4'd3,
                     E_M1 = 4'd4, E_A1 = 4'd5, E_A2 = 4'd6, E_M2 = 4'd7, E_C = 4'd8,
                     E_E1 = 4'd9, E_E2 = 4'd10, E_E3 = 4'd11;
    reg  [3:0]  est;
    reg  [4:0]  k;
    reg         pass;
    reg  signed [21:0] x, lo, bp, hp, qbp;
    reg  [21:0] env, absb, dec, envr;
    reg  signed [38:0] prod;
    reg  signed [21:0] mul_b;
    wire signed [16:0] mul_a = {1'b0, coef(k)};

    // Band states {env, band, low}, read one clock after the address.
    reg  [65:0] state_mem [0:31];
    reg  [65:0] state_q;
    reg  [4:0]  raddr;
    reg         we;
    reg  [4:0]  waddr;
    reg  [65:0] wdata;
    always @(posedge clk) begin
        if (we)
            state_mem[waddr] <= wdata;
        state_q <= state_mem[raddr];
    end

    reg  [5:0]  cur_code [0:NB-1];
    integer i;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            est <= E_CLEAR; k <= 5'd0; pass <= 1'b0;
            x <= 22'sd0; lo <= 22'sd0; bp <= 22'sd0; hp <= 22'sd0; qbp <= 22'sd0;
            absb <= 22'sd0; dec <= 22'sd0; envr <= 22'sd0; env <= 22'd0;
            prod <= 39'sd0; mul_b <= 22'sd0;
            raddr <= 5'd0; we <= 1'b0; waddr <= 5'd0; wdata <= 66'd0;
            for (i = 0; i < NB; i = i + 1)
                cur_code[i] <= 6'd0;
        end else begin
            we <= 1'b0;
            prod <= mul_a * mul_b;
            case (est)
                // Zero every band state once after reset.
                E_CLEAR: begin
                    we <= 1'b1;
                    waddr <= k;
                    wdata <= 66'd0;
                    k <= k + 1'b1;
                    if (k == 5'd31)
                        est <= E_IDLE;
                end
                E_IDLE: if (sample_valid) begin
                    x <= {{2{sample[15]}}, sample, 4'd0};
                    k <= 5'd0;
                    raddr <= 5'd0;
                    est <= E_READ;
                end
                E_READ: est <= E_LOAD;
                E_LOAD: begin
                    lo <= state_q[21:0];
                    bp <= state_q[43:22];
                    env <= state_q[65:44];
                    mul_b <= state_q[43:22];
                    pass <= 1'b0;
                    est <= E_M1;
                end
                E_M1: est <= E_A1;                     // prod = f * band
                E_A1: begin
                    lo <= sat22(lo + (prod >>> 16));
                    qbp <= (bp >>> 2) + (bp >>> 3);      // damping 3/8
                    est <= E_A2;
                end
                E_A2: begin
                    hp <= sat22(x - lo - qbp);
                    mul_b <= sat22(x - lo - qbp);
                    est <= E_M2;
                end
                E_M2: est <= E_C;                      // prod = f * high
                E_C: begin
                    bp <= sat22(bp + (prod >>> 16));
                    mul_b <= sat22(bp + (prod >>> 16));
                    if (!pass) begin
                        pass <= 1'b1;
                        est <= E_M1;
                    end else begin
                        est <= E_E1;
                    end
                end
                E_E1: begin
                    absb <= bp[21] ? -bp : bp;
                    dec <= env - (env >> 10);
                    est <= E_E2;
                end
                E_E2: begin
                    envr <= (absb > dec) ? absb : dec;
                    we <= 1'b1;
                    waddr <= k;
                    wdata <= {((absb > dec) ? absb : dec), bp, lo};
                    est <= E_E3;
                end
                E_E3: begin
                    cur_code[k] <= level_code(envr);
                    if (k == NB - 1) begin
                        est <= E_IDLE;
                    end else begin
                        k <= k + 1'b1;
                        raddr <= k + 1'b1;
                        est <= E_READ;
                    end
                end
                default: est <= E_IDLE;
            endcase
        end
    end

    // ------------------------------------------------------------ bar heights, per frame
    reg        vs_q, de_q;
    reg [3:0]  disp [0:NB-1];
    reg [3:0]  peak [0:NB-1];
    reg [4:0]  hold [0:NB-1];
    reg [1:0]  frame_phase;
    wire       frame_start = in_vs && !vs_q;
    // One band per clock after the frame start (29 clocks in the blanking):
    // band uk is read into registers, band wk written from them.
    reg [4:0]  uk, wk;
    reg        updating, writing;
    reg [3:0]  h_q, d_q, p_q;
    reg [4:0]  hold_q;
    wire [5:0] cc = cur_code[uk];
    wire [5:0] bb = base(uk);
    wire [5:0] diff = cc - bb;
    wire [3:0] h = (cc <= bb) ? 4'd0 : (diff >= 6'd10) ? 4'd10 : diff[3:0];
    wire [3:0] d_old = disp[uk];
    wire [3:0] p_old = peak[uk];
    wire [4:0] h_old = hold[uk];
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            frame_phase <= 2'd0; uk <= 5'd0; wk <= 5'd0; updating <= 1'b0; writing <= 1'b0;
            h_q <= 4'd0; d_q <= 4'd0; p_q <= 4'd0; hold_q <= 5'd0;
            for (i = 0; i < NB; i = i + 1) begin
                disp[i] <= 4'd0; peak[i] <= 4'd0; hold[i] <= 5'd0;
            end
        end else begin
            writing <= updating;
            wk <= uk;
            h_q <= h; d_q <= d_old; p_q <= p_old; hold_q <= h_old;
            if (frame_start) begin
                frame_phase <= frame_phase + 1'b1;
                uk <= 5'd0;
                updating <= 1'b1;
            end else if (updating) begin
                if (uk == NB - 1)
                    updating <= 1'b0;
                uk <= uk + 1'b1;
            end
            if (writing) begin
                disp[wk] <= (h_q >= d_q) ? h_q : d_q - 1'b1;
                if (h_q >= p_q) begin
                    peak[wk] <= h_q;
                    hold[wk] <= 5'd24;
                end else if (hold_q != 0) begin
                    hold[wk] <= hold_q - 1'b1;
                end else if (frame_phase[0] && p_q != 0) begin
                    peak[wk] <= p_q - 1'b1;
                end
            end
        end
    end

    // ------------------------------------------------------------ raster
    reg [10:0] x_cnt;
    reg [9:0]  y_cnt;
    reg [5:0]  bx;                  // pixel within the 40 px bar slot
    reg [4:0]  bar;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vs_q <= 1'b0; de_q <= 1'b0; x_cnt <= 11'd0; y_cnt <= 10'd0;
            bx <= 6'd0; bar <= 5'd0;
        end else begin
            vs_q <= in_vs;
            de_q <= in_de;
            x_cnt <= in_de ? x_cnt + 1'b1 : 11'd0;
            if (in_vs)
                y_cnt <= 10'd0;
            else if (de_q && !in_de)
                y_cnt <= y_cnt + 1'b1;
            // (bar, bx) describe the next pixel.
            if (!in_de || x_cnt == X0 - 1) begin
                bx <= 6'd0;
                bar <= 5'd0;
            end else if (bx == 6'd39) begin
                bx <= 6'd0;
                bar <= bar + 1'b1;
            end else begin
                bx <= bx + 1'b1;
            end
        end
    end
    wire [4:0] r = ~y_cnt[4:0];     // 0 at the bottom row (671)
    wire       in_band = enable && in_de && x_cnt >= X0 && y_cnt >= Y0 && y_cnt < Y0 + 10'd32;
    // Segment s = (r - 1) / 3 for r = 1..30; its third row is the gap.
    reg [3:0]  seg;
    reg        seg_on;
    always @* begin
        seg = 4'd0;
        seg_on = 1'b0;
        if (r >= 5'd1 && r <= 5'd30) begin
            seg = (r - 5'd1) / 5'd3;
            seg_on = ((r - 5'd1) % 5'd3) != 5'd2;
        end
    end

    // ------------------------------------------------------------ s1
    reg        vs1, de1, band1, col1, base1, on1;
    reg [23:0] rgb1;
    reg [3:0]  seg1, disp1, peak1;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vs1 <= 1'b0; de1 <= 1'b0; band1 <= 1'b0; col1 <= 1'b0; base1 <= 1'b0; on1 <= 1'b0;
            rgb1 <= 24'd0; seg1 <= 4'd0; disp1 <= 4'd0; peak1 <= 4'd0;
        end else begin
            vs1 <= in_vs;
            de1 <= in_de;
            rgb1 <= rgb_in;
            band1 <= in_band;
            col1 <= bx >= 6'd4 && bx < 6'd36 && bar < NB;
            base1 <= r == 5'd0;
            on1 <= seg_on;
            seg1 <= seg;
            disp1 <= (bar < NB) ? disp[bar] : 4'd0;
            peak1 <= (bar < NB) ? peak[bar] : 4'd0;
        end
    end

    // ------------------------------------------------------------ s2: what to draw
    localparam [1:0] K_NONE = 2'd0, K_BAR = 2'd1, K_CAP = 2'd2;
    reg        vs2, de2, draw2;
    reg [23:0] rgb2;
    reg [1:0]  kind2;
    reg [4:0]  weight2;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vs2 <= 1'b0; de2 <= 1'b0; draw2 <= 1'b0; rgb2 <= 24'd0; kind2 <= K_NONE; weight2 <= 5'd0;
        end else begin
            vs2 <= vs1;
            de2 <= de1;
            rgb2 <= rgb1;
            draw2 <= band1 && col1 && (base1 || on1);
            if (base1) begin
                kind2 <= K_BAR;  weight2 <= 5'd4;               // baseline
            end else if (seg1 < disp1) begin
                kind2 <= K_BAR;  weight2 <= 5'd7 + {1'b0, seg1}; // lit, brighter upwards
            end else if (peak1 > disp1 && seg1 == peak1 - 1'b1) begin
                kind2 <= K_CAP;  weight2 <= 5'd16;              // peak cap
            end else begin
                kind2 <= K_BAR;  weight2 <= 5'd2;               // unlit segment
            end
        end
    end

    function [7:0] mix8;
        input [7:0] a;      // weight 16 - w
        input [7:0] b;      // weight w
        input [4:0] w;
        reg [12:0] s;
        begin
            s = a * (5'd16 - w) + b * w;
            mix8 = s[11:4];
        end
    endfunction

    // ------------------------------------------------------------ s3: colour
    wire [23:0] cap_rgb = {1'b1, accent[23:17], 1'b1, accent[15:9], 1'b1, accent[7:1]};
    reg        vs3, de3, draw3;
    reg [23:0] rgb3, colour3;
    reg [4:0]  weight3;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vs3 <= 1'b0; de3 <= 1'b0; draw3 <= 1'b0; rgb3 <= 24'd0; colour3 <= 24'd0; weight3 <= 5'd0;
        end else begin
            vs3 <= vs2;
            de3 <= de2;
            draw3 <= draw2;
            rgb3 <= rgb2;
            colour3 <= (kind2 == K_CAP) ? cap_rgb : accent;
            weight3 <= (weight2 > 5'd16) ? 5'd16 : weight2;
        end
    end

    // ------------------------------------------------------------ s4: blend
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_vs <= 1'b0; out_de <= 1'b0; rgb_out <= 24'd0;
        end else begin
            out_vs <= vs3;
            out_de <= de3;
            rgb_out <= draw3 ?
                       {mix8(rgb3[23:16], colour3[23:16], weight3), mix8(rgb3[15:8], colour3[15:8], weight3),
                        mix8(rgb3[7:0], colour3[7:0], weight3)} : rgb3;
        end
    end
endmodule
