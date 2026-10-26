`timescale 1ns/1ps

// Load-time scaler of the advert player.
//
// The BMP reader streams an advert poster of any size (src_w x src_h, bottom
// row first). This module scales it to fit 1280x720 with its aspect ratio
// kept - bilinear interpolation, centred, black borders - and emits the whole
// 1280x720 frame in the same bottom-up order, so the normal frame-buffer write
// path stores it like any other picture.
//
// Geometry: at level 0 the longer side (relative to 16:9) fills the screen;
// levels 1..5 shrink the picture to 72/80 .. 40/80 of that, always centred.
// step is the source distance between output pixels in Q16, the larger of
//     src_w / 1280 = src_w * 51.2   and   src_h / 720 = src_h * 91.02,
// times 80/k for level k = 80 - 8 * level. Both axes are centred: output
// pixel x samples source column
//     u = (x - 639.5) * step + (src_w - 1) / 2,
// output row j samples v = (j - 359.5) * step + (src_h - 1) / 2. A pixel
// shows the picture when -0.5 <= u < src_w - 0.5 and -0.5 <= v < src_h - 0.5;
// elsewhere it is black. Positions outside the outermost pixel centres repeat
// the edge pixel.
//
// Source rows go into one 4 x 1024 line RAM (RGB565): row t at (t mod 4) *
// 1024, so the two rows an output row interpolates between stay intact while
// the next two arrive. Each output pixel takes eight clocks: two RAM reads
// (top and bottom row, both columns at once), two horizontal interpolations
// and the vertical one, all on one shared, pipelined set of multipliers.
// Source pixels are written in the phases without a read. The source is held
// until the black rows above the picture are out (source_go), so it never
// runs ahead of the first rows it fills. The TF card needs more than 46k
// clocks for a source row (144 clocks a pixel, 320 pixels or more); even at
// the largest enlargement (4x) one source row feeds 4 output rows of 10k
// clocks, less than the two rows the writer may run ahead. Pixels outside the
// picture are black whatever their (wrapped) source position.
module advert_fit_scaler #(
    parameter integer START_DELAY = 1024        // let the write FIFO leave reset
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        start,                   // src_w / src_h / level valid, new poster
    input  wire [2:0]  level,                   // 0 full size .. 5 half size
    input  wire        abort,
    input  wire [10:0] src_w,                   // 320..1024
    input  wire [10:0] src_h,                   // 180..1024
    input  wire        in_valid,                // at most one pixel every 3 clocks
    input  wire [23:0] in_rgb,                  // {R, G, B}
    output wire        out_valid,
    output wire [31:0] out_data,                // {R, G, B, 8'h00}
    output wire        busy,
    // The source may stream from here on: the black rows above the picture
    // are out, so no source row is needed before it can be stored.
    output reg         source_go
);
    localparam [3:0] S_IDLE   = 4'd0;
    localparam [3:0] S_CMP    = 4'd1;
    localparam [3:0] S_M1     = 4'd2;
    localparam [3:0] S_M2     = 4'd3;
    localparam [3:0] S_M3     = 4'd4;
    localparam [3:0] S_M4     = 4'd5;
    localparam [3:0] S_DELAY  = 4'd6;
    localparam [3:0] S_ROW    = 4'd7;
    localparam [3:0] S_ROWSET = 4'd8;
    localparam [3:0] S_WAIT   = 4'd9;
    localparam [3:0] S_PIXEL  = 4'd10;
    localparam [3:0] S_LEVEL  = 4'd11;
    localparam [3:0] S_ROWPRE = 4'd12;
    localparam [3:0] S_MW     = 4'd13;     // two clocks for the registered product
    localparam [3:0] S_MW2    = 4'd14;

    reg [3:0]  state;
    reg [10:0] w, h;
    reg [11:0] w2m1, h2m1;              // 2w - 1, 2h - 1: limits in half pixels
    reg [10:0] hm1;                     // h - 1, the last source row
    reg [17:0] step;                    // Q16, 0.25 .. 2.86
    reg [2:0]  lvl;
    reg signed [28:0] u_start, u_acc, v_acc;
    reg [12:0] delay;

    // One shared multiplier for the setup: step, the level, then 1279 and 719 steps.
    reg [17:0] mul_x;
    reg [14:0] mul_y;
    wire [32:0] mul_p = mul_x * mul_y;
    reg  [32:0] mul_p1, mul_q;          // product, twice registered
    reg  [3:0]  mul_ret;                // setup state after S_MW / S_MW2
    always @(posedge clk) begin
        mul_p1 <= mul_p;
        mul_q <= mul_p1;
    end
    // 80 / k in Q13 for k = 80, 72, 64, 56, 48, 40.
    wire [14:0] level_ratio = (lvl == 3'd1) ? 15'd9102 : (lvl == 3'd2) ? 15'd10240 :
                              (lvl == 3'd3) ? 15'd11703 : (lvl == 3'd4) ? 15'd13653 :
                              (lvl == 3'd5) ? 15'd16384 : 15'd8192;

    // ------------------------------------------------------------ line RAM
    reg [2:0]  phase;
    reg [9:0]  wx;
    reg [10:0] rows_done;
    reg        wr_pending;
    reg        accepting;               // source rows still expected
    reg [9:0]  w_m1;
    reg [10:0] h_m1;
    reg [11:0] wr_addr;
    reg [15:0] wr_data;
    reg [11:0] rd_addr_a, rd_addr_b;
    // Port A reads in phases 1 and 2 (the RAM samples the address at their end);
    // read_slot marks them one clock ahead.
    reg        read_slot;
    wire       wr_now = wr_pending && !read_slot;
    wire [15:0] dout_a, dout_b;

    advert_line_ram u_line_ram (
        .clk(clk), .we_a(wr_now), .addr_a(wr_now ? wr_addr : rd_addr_a), .din_a(wr_data),
        .dout_a(dout_a), .addr_b(rd_addr_b), .dout_b(dout_b));

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            wx <= 10'd0;
            rows_done <= 11'd0;
            wr_pending <= 1'b0;
            accepting <= 1'b0;
            w_m1 <= 10'd0;
            h_m1 <= 11'd0;
            wr_addr <= 12'd0;
            wr_data <= 16'd0;
        end else if (start || abort) begin
            wx <= 10'd0;
            rows_done <= 11'd0;
            wr_pending <= 1'b0;
            accepting <= start && !abort;
            w_m1 <= src_w[9:0] - 10'd1;
            h_m1 <= src_h - 11'd1;
        end else begin
            if (wr_now)
                wr_pending <= 1'b0;
            if (in_valid && accepting) begin
                wr_pending <= 1'b1;
                wr_addr <= {rows_done[1:0], wx};
                wr_data <= {in_rgb[23:19], in_rgb[15:10], in_rgb[7:3]};
                if (wx == w_m1) begin
                    wx <= 10'd0;
                    rows_done <= rows_done + 11'd1;
                    if (rows_done == h_m1)
                        accepting <= 1'b0;
                end else begin
                    wx <= wx + 10'd1;
                end
            end
        end
    end

    // ------------------------------------------------------------ emission
    reg [9:0]  j;                       // output row, bottom row first
    reg [10:0] x;
    reg [9:0]  col_a, col_b;
    reg [1:0]  b0, b1;
    reg [10:0] r1;
    reg [4:0]  fy, fx;
    reg        row_image, px_image;
    reg [15:0] p00, p10, p01, p11;      // top-left, top-right, bottom-left, bottom-right
    reg [15:0] top, lerp_q;

    wire signed [13:0] u_half = u_acc[28:15];
    wire signed [13:0] v_half = v_acc[28:15];
    wire        u_inside = u_half >= -14'sd1 && u_half < $signed({2'b00, w2m1});
    wire        v_inside = v_half >= -14'sd1 && v_half < $signed({2'b00, h2m1});
    wire [10:0] u_int = u_acc[26:16];
    wire [10:0] v_int = v_acc[26:16];
    reg         v_in_q, v_end_q;            // v_inside and v_int >= h - 1, one clock late
    always @(posedge clk) begin
        v_in_q <= v_inside;
        v_end_q <= v_int >= hm1;
    end

    // Interpolator a + (b - a) * f / 32 per channel in two stages: A forms
    // the products, B adds a. A takes the top row in phase 3, the bottom row
    // in phase 4 and the vertical step (top against the bottom result) in
    // phase 6; each result leaves B one phase later.
    wire [15:0] ia = (phase == 3'd3) ? p00 : (phase == 3'd4) ? p01 : top;
    wire [15:0] ib = (phase == 3'd3) ? p10 : (phase == 3'd4) ? p11 : lerp_q;
    wire [4:0]  i_f = (phase == 3'd6) ? fy : fx;
    reg signed [12:0] pr_q, pg_q, pb_q;
    reg [15:0] a_q;

    function signed [12:0] prod;
        input [5:0] a;
        input [5:0] b;
        input [4:0] f;
        reg signed [6:0] d;
        begin
            d = $signed({1'b0, b}) - $signed({1'b0, a});
            prod = d * $signed({1'b0, f});
        end
    endfunction

    function [5:0] add_back;
        input [5:0] a;
        input signed [12:0] p;
        reg signed [7:0] s;
        begin
            s = $signed({2'b00, a}) + (p >>> 5);
            add_back = s[5:0];
        end
    endfunction

    wire [5:0]  sum_r = add_back({1'b0, a_q[15:11]}, pr_q);
    wire [5:0]  sum_g = add_back(a_q[10:5], pg_q);
    wire [5:0]  sum_b = add_back({1'b0, a_q[4:0]}, pb_q);
    wire [15:0] lerp_565 = {sum_r[4:0], sum_g, sum_b[4:0]};

    // Source columns of the pixel at u_acc (edge pixels repeat).
    wire        col_low = u_acc[28];
    wire        col_high = !u_acc[28] && u_int >= w - 11'd1;
    wire [9:0]  col_a_now = col_low ? 10'd0 : col_high ? w[9:0] - 10'd1 : u_int[9:0];
    wire [9:0]  col_b_now = col_low ? 10'd1 : col_high ? w[9:0] - 10'd1 : u_int[9:0] + 10'd1;

    assign busy = state != S_IDLE;
    // One output pixel in the last phase.
    assign out_valid = state == S_PIXEL && phase == 3'd7;
    assign out_data = px_image ?
                      {lerp_565[15:11], lerp_565[15:13], lerp_565[10:5], lerp_565[10:9],
                       lerp_565[4:0], lerp_565[4:2], 8'h00} : 32'd0;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state <= S_IDLE;
            w <= 11'd1024; h <= 11'd576; w2m1 <= 12'd2047; h2m1 <= 12'd1151; hm1 <= 11'd575;
            step <= 18'd65536; lvl <= 3'd0; u_start <= 29'sd0; u_acc <= 29'sd0; v_acc <= 29'sd0;
            mul_x <= 18'd0; mul_y <= 15'd0; mul_ret <= S_IDLE;
            delay <= 13'd0;
            j <= 10'd0; x <= 11'd0; phase <= 3'd0;
            col_a <= 10'd0; col_b <= 10'd0; b0 <= 2'd0; b1 <= 2'd0; r1 <= 11'd0;
            fy <= 5'd0; fx <= 5'd0; row_image <= 1'b0; px_image <= 1'b0;
            p00 <= 16'd0; p10 <= 16'd0; p01 <= 16'd0; p11 <= 16'd0; top <= 16'd0; lerp_q <= 16'd0;
            pr_q <= 13'sd0; pg_q <= 13'sd0; pb_q <= 13'sd0; a_q <= 16'd0;
            rd_addr_a <= 12'd0; rd_addr_b <= 12'd0;
            read_slot <= 1'b0;
            source_go <= 1'b0;
        end else begin
            read_slot <= state == S_PIXEL && (phase == 3'd0 || phase == 3'd1);
            pr_q <= prod({1'b0, ia[15:11]}, {1'b0, ib[15:11]}, i_f);
            pg_q <= prod(ia[10:5], ib[10:5], i_f);
            pb_q <= prod({1'b0, ia[4:0]}, {1'b0, ib[4:0]}, i_f);
            a_q <= ia;
            lerp_q <= lerp_565;
            if (abort) begin
                state <= S_IDLE;
                source_go <= 1'b0;
            end else if (start) begin
                source_go <= 1'b0;
                w <= src_w;
                h <= src_h;
                w2m1 <= {src_w, 1'b0} - 12'd1;
                h2m1 <= {src_h, 1'b0} - 12'd1;
                hm1 <= src_h - 11'd1;
                lvl <= (level > 3'd5) ? 3'd5 : level;
                state <= S_CMP;
            end else begin
                case (state)
                S_IDLE: ;
                // Wider than 16:9 fits the width, otherwise the height.
                S_CMP: begin
                    mul_x <= {7'd0, w};
                    mul_y <= 15'd13107;                     // 51.2 in Q8
                    mul_ret <= S_M1; state <= S_MW;
                end
                S_M1: begin
                    step <= {1'b0, mul_q[24:8]};
                    mul_x <= {7'd0, h};
                    mul_y <= 15'd23302;                     // 91.02 in Q8
                    mul_ret <= S_M2; state <= S_MW;
                end
                S_M2: begin
                    mul_x <= ({1'b0, mul_q[24:8]} > step) ? {1'b0, mul_q[24:8]} : step;
                    mul_y <= level_ratio;
                    mul_ret <= S_LEVEL; state <= S_MW;
                end
                S_LEVEL: begin
                    step <= mul_q[30:13];
                    mul_x <= mul_q[30:13];
                    mul_y <= 15'd1279;
                    mul_ret <= S_M3; state <= S_MW;
                end
                S_M3: begin
                    u_start <= $signed({3'b000, w - 11'd1, 15'd0}) - $signed({1'b0, mul_q[28:1]});
                    mul_y <= 15'd719;
                    mul_ret <= S_M4; state <= S_MW;
                end
                S_M4: begin
                    v_acc <= $signed({3'b000, h - 11'd1, 15'd0}) - $signed({1'b0, mul_q[28:1]});
                    delay <= START_DELAY[12:0];
                    j <= 10'd0;
                    state <= S_DELAY;
                end
                S_DELAY: begin
                    if (delay != 13'd0)
                        delay <= delay - 13'd1;
                    else
                        state <= S_ROW;
                end
                // Output row j interpolates source rows v_int and v_int + 1.
                S_ROW: begin
                    row_image <= v_in_q;
                    if (v_acc[28]) begin
                        b0 <= 2'd0; b1 <= 2'd1; r1 <= 11'd1; fy <= 5'd0;
                    end else if (v_end_q) begin
                        b0 <= hm1[1:0]; b1 <= hm1[1:0]; r1 <= hm1; fy <= 5'd0;
                    end else begin
                        b0 <= v_int[1:0]; b1 <= v_int[1:0] + 2'd1; r1 <= v_int + 11'd1;
                        fy <= v_acc[15:11];
                    end
                    state <= S_ROWSET;
                end
                S_ROWSET: begin
                    x <= 11'd0;
                    phase <= 3'd0;
                    u_acc <= u_start;
                    if (row_image)
                        source_go <= 1'b1;
                    state <= row_image ? S_WAIT : S_PIXEL;
                end
                S_WAIT: if (rows_done > r1) state <= S_PIXEL;
                S_PIXEL: begin
                    phase <= phase + 3'd1;
                    case (phase)
                    3'd0: begin
                        px_image <= row_image && u_inside;
                        col_a <= col_a_now;
                        col_b <= col_b_now;
                        fx <= (col_low || col_high) ? 5'd0 : u_acc[15:11];
                        rd_addr_a <= {b0, col_a_now};
                        rd_addr_b <= {b0, col_b_now};
                        u_acc <= u_acc + $signed({11'd0, step});
                    end
                    3'd1: begin rd_addr_a <= {b1, col_a}; rd_addr_b <= {b1, col_b}; end
                    3'd2: begin p00 <= dout_a; p10 <= dout_b; end
                    3'd3: begin p01 <= dout_a; p11 <= dout_b; end
                    3'd5: top <= lerp_q;
                    3'd4, 3'd6: ;
                    default: begin
                        if (x == 11'd1279) begin
                            v_acc <= v_acc + $signed({11'd0, step});
                            if (j == 10'd719) begin
                                state <= S_IDLE;
                            end else begin
                                j <= j + 10'd1;
                                state <= S_ROWPRE;
                            end
                        end else begin
                            x <= x + 11'd1;
                        end
                    end
                    endcase
                end
                S_ROWPRE: state <= S_ROW;
                S_MW: state <= S_MW2;
                S_MW2: state <= mul_ret;
                default: state <= S_IDLE;
                endcase
            end
        end
    end
endmodule

// 4 x 1024 x 16 line RAM: port A writes or reads, port B reads.
module advert_line_ram (
    input  wire        clk,
    input  wire        we_a,
    input  wire [11:0] addr_a,
    input  wire [15:0] din_a,
    output wire [15:0] dout_a,
    input  wire [11:0] addr_b,
    output wire [15:0] dout_b
);
`ifdef ORDER_UI_SIMULATION
reg [15:0] mem [0:4095];
reg [15:0] qa, qb;
always @(posedge clk) begin
    if (we_a) mem[addr_a] <= din_a;
    qa <= mem[addr_a];
    qb <= mem[addr_b];
end
assign dout_a = qa;
assign dout_b = qb;
`else
EG_LOGIC_BRAM #(
    .DATA_WIDTH_A(16), .ADDR_WIDTH_A(12), .DATA_DEPTH_A(4096),
    .DATA_WIDTH_B(16), .ADDR_WIDTH_B(12), .DATA_DEPTH_B(4096),
    .MODE("DP"), .REGMODE_A("NOREG"), .REGMODE_B("NOREG"),
    .WRITEMODE_A("NORMAL"), .WRITEMODE_B("NORMAL"), .IMPLEMENT("9K"),
    .DEBUGGABLE("NO"), .PACKABLE("NO"), .FILL_ALL("NONE")
) u_bram (
    .dia(din_a), .dib(16'd0), .addra(addr_a), .addrb(addr_b),
    .cea(1'b1), .ceb(1'b1), .ocea(1'b0), .oceb(1'b0),
    .clka(clk), .clkb(clk), .wea(we_a), .web(1'b0),
    .bea(1'b0), .beb(1'b0), .rsta(1'b0), .rstb(1'b0),
    .doa(dout_a), .dob(dout_b)
);
`endif
endmodule
