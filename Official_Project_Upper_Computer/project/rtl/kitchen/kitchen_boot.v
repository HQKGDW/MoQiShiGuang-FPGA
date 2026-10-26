`timescale 1ns/1ps

// Boot sequence of the kitchen console (frames at 60 Hz):
//
//      0- 17  black (the boot animation itself is silent)
//     18-229  scene A: an amber line ignites from the centre and opens into a
//             frame, 默契食光 is revealed by a scan line, KITCHEN CONSOLE is
//             typed letter by letter
//    230-261  shutter: scene A splits at the centre and slides apart,
//             revealing the self-check page (tile layer); first transition
//             sound
//    262-399  self-check rows complete one by one, the progress bar fills
//        400  the console opens from the centre into the order board;
//             second transition sound
module kitchen_boot_sequencer #(
    parameter integer SHUTTER_START = 230,
    parameter integer SHUTTER_END = 262,
    parameter integer EXIT_FRAME = 400
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       frame_start,
    output reg  [9:0] boot_t,
    output wire       layer_on,       // scene A or shutter
    output wire       page_b,         // the tile layer shows the self-check page
    output reg  [3:0] boot_step,
    output reg  [4:0] boot_progress,
    output reg        exit_req,       // one clock: open into the console
    output reg        chime_boot,     // one clock: transition sound into the self-check
    output reg        chime_ready     // one clock: transition sound into the console
);
    assign layer_on = boot_t < SHUTTER_END;
    assign page_b = boot_t >= SHUTTER_START - 4;
    wire [9:0] progress_t = boot_t - SHUTTER_END;
    wire [16:0] progress_scaled = progress_t * 7'd77;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            boot_t <= 10'd0;
            boot_step <= 4'd0;
            boot_progress <= 5'd0;
            exit_req <= 1'b0;
            chime_boot <= 1'b0;
            chime_ready <= 1'b0;
        end else begin
            exit_req <= 1'b0;
            chime_boot <= 1'b0;
            chime_ready <= 1'b0;
            if (frame_start) begin
                if (!(&boot_t))
                    boot_t <= boot_t + 1'b1;
                chime_boot <= boot_t == SHUTTER_START;
                chime_ready <= boot_t == EXIT_FRAME;
                exit_req <= boot_t == EXIT_FRAME;
                boot_step <= (boot_t >= 365) ? 4'd6 : (boot_t >= 350) ? 4'd5 :
                             (boot_t >= 330) ? 4'd4 : (boot_t >= 310) ? 4'd3 :
                             (boot_t >= 290) ? 4'd2 : (boot_t >= 270) ? 4'd1 : 4'd0;
                boot_progress <= (boot_t < SHUTTER_END) ? 5'd0 :
                                 (progress_scaled[16:8] >= 9'd30) ? 5'd30 : progress_scaled[12:8];
            end
        end
    end
endmodule

// Scene A and the shutter. x / y are the pipeline's stage-1 coordinates;
// on / rgb come out seven clocks later, aligned with the display's stage 8.
module kitchen_boot_layer (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [9:0]  boot_t,
    input  wire        layer_on,
    input  wire [10:0] x,
    input  wire [9:0]  y,
    output reg         on,
    output reg  [23:0] rgb
);
    localparam [23:0] BG       = 24'h0c1016;
    localparam [23:0] GRID     = 24'h17202b;
    localparam [23:0] AMBER    = 24'hffb020;
    localparam [23:0] AMBER_LO = 24'h6b4a14;
    localparam [23:0] GLOW     = 24'h3a2a0e;
    localparam [23:0] WHITE    = 24'hf4f6f8;
    localparam integer TITLE_X = 444, TITLE_Y = 282;     // 4 glyphs, 104 px advance
    localparam integer LATIN_X = 415, LATIN_Y = 392;     // 15 cells, 30 px advance
    localparam integer BOX_L = 180, BOX_R = 1100, BOX_T = 250, BOX_B = 470;

    function [7:0] mix8;
        input [7:0] a;
        input [7:0] b;
        input [4:0] w;
        reg signed [9:0] diff;
        reg signed [15:0] scaled;
        begin
            diff = $signed({2'b00, b}) - $signed({2'b00, a});
            scaled = diff * $signed({1'b0, w});
            mix8 = a + scaled[11:4];
        end
    endfunction
    function [23:0] mix24;
        input [23:0] a;
        input [23:0] b;
        input [4:0] w;
        begin
            mix24 = {mix8(a[23:16], b[23:16], w), mix8(a[15:8], b[15:8], w), mix8(a[7:0], b[7:0], w)};
        end
    endfunction
    function [4:0] coverage_weight;
        input [1:0] c;
        begin
            case (c)
                2'd0: coverage_weight = 5'd0;
                2'd1: coverage_weight = 5'd6;
                2'd2: coverage_weight = 5'd11;
                default: coverage_weight = 5'd16;
            endcase
        end
    endfunction
    // KITCHEN CONSOLE -> glyphs of "KITCHENOSL"; 15 = blank.
    function [3:0] latin_code;
        input [3:0] n;
        begin
            case (n)
                4'd0: latin_code = 4'd0;   4'd1: latin_code = 4'd1;   4'd2: latin_code = 4'd2;
                4'd3: latin_code = 4'd3;   4'd4: latin_code = 4'd4;   4'd5: latin_code = 4'd5;
                4'd6: latin_code = 4'd6;   4'd8: latin_code = 4'd3;   4'd9: latin_code = 4'd7;
                4'd10: latin_code = 4'd6;  4'd11: latin_code = 4'd8;  4'd12: latin_code = 4'd7;
                4'd13: latin_code = 4'd9;  4'd14: latin_code = 4'd5;
                default: latin_code = 4'd15;
            endcase
        end
    endfunction

    // ---------------------------------------------------- frame values
    reg [9:0]  shutter_h;        // half opening of the shutter
    reg        shutter;
    reg [9:0]  line_len;         // ignition half length
    reg [6:0]  split_d;          // distance of the split lines from the centre
    reg [5:0]  bracket_len;
    reg [10:0] scan_x;
    reg [4:0]  letters;          // Latin letters shown
    reg        cursor_on;
    reg [4:0]  fade;
    wire [9:0] t_split = boot_t - 10'd50;      // split: 4 px per frame
    wire [9:0] t_bracket = boot_t - 10'd78;    // brackets: 5 px per frame
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            shutter_h <= 10'd0; shutter <= 1'b0; line_len <= 10'd0; split_d <= 7'd0;
            bracket_len <= 6'd0; scan_x <= 11'd0; letters <= 5'd0; cursor_on <= 1'b0; fade <= 5'd0;
        end else begin
            shutter <= boot_t >= 10'd230;
            shutter_h <= (boot_t >= 10'd230) ? {boot_t - 10'd230, 3'b000} + {boot_t - 10'd230, 2'b00} : 10'd0;
            line_len <= (boot_t < 10'd20) ? 10'd0 :
                        (boot_t >= 10'd49) ? 10'd460 : {boot_t - 10'd20, 4'b0000};
            split_d <= (boot_t < 10'd50) ? 7'd0 :
                       (boot_t >= 10'd77) ? 7'd110 : {t_split[4:0], 2'b00};
            bracket_len <= (boot_t < 10'd78) ? 6'd0 :
                           (boot_t >= 10'd88) ? 6'd48 : {t_bracket[3:0], 2'b00} + t_bracket[3:0];
            scan_x <= (boot_t < 10'd80) ? TITLE_X : (boot_t >= 10'd130) ? 11'd2047 :
                      TITLE_X + {boot_t - 10'd80, 3'b000};
            letters <= (boot_t < 10'd130) ? 5'd0 : (boot_t >= 10'd186) ? 5'd15 :
                       ((boot_t - 10'd130) >> 2) + 1'b1;
            cursor_on <= boot_t >= 10'd126 && boot_t < 10'd214 && !boot_t[3];
            fade <= (boot_t < 10'd18) ? 5'd0 : (boot_t >= 10'd42) ? 5'd16 :
                    (((boot_t - 10'd18) * 4'd11) >> 4);
        end
    end

    // ---------------------------------------------------- stage A (x, y in)
    wire [9:0]  dy_centre = (y >= 10'd360) ? y - 10'd360 : 10'd360 - y;
    wire        open_now = shutter && dy_centre < shutter_h;
    wire        edge_now = shutter && dy_centre >= shutter_h && dy_centre < shutter_h + 10'd3;
    wire [10:0] ya_now = !shutter ? {1'b0, y} : (y < 10'd360) ? {1'b0, y} + shutter_h :
                         {1'b0, y} - shutter_h;      // may wrap: then outside everything
    // Latin cell of x: 30 px cells, n = rel / 30 via a multiply by 2185 / 65536.
    wire [10:0] latin_rel_now = x - LATIN_X;
    wire [22:0] latin_mul_now = latin_rel_now * 12'd2185;
    wire [3:0]  latin_n_now = latin_mul_now[19:16];
    reg  [10:0] xa, ya;
    reg  [10:0] latin_rel_a;
    reg  [3:0]  latin_n_a;
    reg         open_a, edge_a;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            xa <= 11'd0; ya <= 11'd0; open_a <= 1'b0; edge_a <= 1'b0;
            latin_rel_a <= 11'd0; latin_n_a <= 4'd0;
        end else begin
            xa <= x; ya <= ya_now; open_a <= open_now; edge_a <= edge_now;
            latin_rel_a <= latin_rel_now; latin_n_a <= latin_n_now;
        end
    end

    // ---------------------------------------------------- stage B: geometry, ROM addresses
    wire [10:0] title_rel = xa - TITLE_X;
    wire [10:0] title_row = ya - TITLE_Y;
    wire [1:0]  title_g = (title_rel >= 11'd312) ? 2'd3 : (title_rel >= 11'd208) ? 2'd2 :
                          (title_rel >= 11'd104) ? 2'd1 : 2'd0;
    wire [10:0] title_lx = title_rel - {title_g, 6'd0} - {title_g, 5'd0} - {title_g, 3'd0};
    wire        in_title = title_rel < 11'd392 && title_row < 11'd80 && title_lx < 11'd80;
    wire [10:0] latin_rel = latin_rel_a;
    wire [10:0] latin_row = ya - LATIN_Y;
    wire [3:0]  latin_n = latin_n_a;
    wire [10:0] latin_lx = latin_rel - {latin_n, 4'd0} - {latin_n, 3'd0} - {latin_n, 2'd0} - {latin_n, 1'b0};
    wire [3:0]  latin_c = latin_code(latin_n);
    wire        in_latin = latin_rel < 11'd450 && latin_row < 11'd40 && latin_lx < 11'd30 &&
                           latin_c != 4'd15 && {1'b0, latin_n} < letters;
    wire [10:0] dxc = (xa >= 11'd640) ? xa - 11'd640 : 11'd640 - xa;
    wire [10:0] dyc = (ya >= 11'd360) ? ya - 11'd360 : 11'd360 - ya;
    wire        ignite_core = split_d == 0 && line_len != 0 && dxc < {1'b0, line_len} && dyc <= 11'd1;
    wire        ignite_glow = split_d == 0 && line_len != 0 && dxc < {1'b0, line_len} &&
                              dyc >= 11'd2 && dyc <= 11'd5;
    wire        split_line = split_d != 0 && dxc < 11'd460 &&
                             (dyc == {4'd0, split_d} || dyc + 11'd1 == {4'd0, split_d});
    wire [10:0] bx = (xa < 11'd640) ? xa - BOX_L : BOX_R - xa;      // distance from the side
    wire [10:0] by = (ya < 11'd360) ? ya - BOX_T : BOX_B - ya;
    wire        bracket = bracket_len != 0 &&
                          ((by <= 11'd2 && bx < {5'd0, bracket_len}) ||
                           (bx <= 11'd2 && by < {5'd0, bracket_len}));
    wire        scan_line = scan_x != 11'd2047 && xa >= scan_x && xa < scan_x + 11'd3 &&
                            ya >= 11'd270 && ya < 11'd374;
    wire [10:0] scan_gap = scan_x - xa;
    wire [10:0] cursor_x = LATIN_X + {letters, 4'd0} + {letters, 3'd0} + {letters, 2'd0} + {letters, 1'b0};
    wire        cursor = cursor_on && xa >= cursor_x && xa < cursor_x + 11'd20 &&
                         ya >= 11'd428 && ya < 11'd432;
    wire        grid = xa[4:0] == 5'd16 && ya[4:0] == 5'd16;

    reg [11:0] big_addr;
    reg [9:0]  latin_addr;
    reg [3:0]  big_px, latin_px;
    reg        in_title_b, title_shown_b, in_latin_b, open_b, edge_b;
    reg        core_b, glow_b, split_b, bracket_b, scan_b, cursor_b, grid_b;
    reg [5:0]  tint_b;              // amber tint near the scan front (0..32)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            big_addr <= 12'd0; latin_addr <= 10'd0; big_px <= 4'd0; latin_px <= 4'd0;
            in_title_b <= 1'b0; title_shown_b <= 1'b0; in_latin_b <= 1'b0; open_b <= 1'b0;
            edge_b <= 1'b0; core_b <= 1'b0; glow_b <= 1'b0; split_b <= 1'b0; bracket_b <= 1'b0;
            scan_b <= 1'b0; cursor_b <= 1'b0; grid_b <= 1'b0; tint_b <= 6'd0;
        end else begin
            // 400 words per big glyph (5 per row); 80 per Latin glyph (2 per row).
            big_addr <= {title_g, 8'd0} + {title_g, 7'd0} + {title_g, 4'd0} +
                        {title_row[6:0], 2'd0} + title_row[6:0] + title_lx[6:4];
            latin_addr <= {latin_c, 6'd0} + {latin_c, 4'd0} + {latin_row[5:0], 1'b0} + latin_lx[4];
            big_px <= title_lx[3:0];
            latin_px <= latin_lx[3:0];
            in_title_b <= in_title;
            title_shown_b <= xa < scan_x;
            in_latin_b <= in_latin;
            open_b <= open_a;
            edge_b <= edge_a;
            core_b <= ignite_core;
            glow_b <= ignite_glow;
            split_b <= split_line;
            bracket_b <= bracket;
            scan_b <= scan_line;
            cursor_b <= cursor;
            grid_b <= grid;
            tint_b <= (scan_x == 11'd2047 || scan_gap >= 11'd32) ? 6'd0 : 6'd32 - scan_gap[5:0];
        end
    end

    // ---------------------------------------------------- stage C: ROMs
    wire [31:0] big_word, latin_word;
    // 4 glyphs x 400 words; the address width must match the depth.
    kitchen_rom #(.WIDTH(32), .DEPTH(2048), .ADDR_W(11), .FILE("kitchen_boot_big"),
                  .IMPLEMENT("32K")) u_big (.clk(clk), .addr(big_addr[10:0]), .data(big_word));
    kitchen_rom #(.WIDTH(32), .DEPTH(1024), .ADDR_W(10), .FILE("kitchen_boot_latin"),
                  .IMPLEMENT("32K")) u_latin (.clk(clk), .addr(latin_addr), .data(latin_word));
    reg [3:0] big_px_c, latin_px_c;
    reg       in_title_c, title_shown_c, in_latin_c, open_c, edge_c;
    reg       core_c, glow_c, split_c, bracket_c, scan_c, cursor_c, grid_c;
    reg [5:0] tint_c;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            big_px_c <= 4'd0; latin_px_c <= 4'd0; in_title_c <= 1'b0; title_shown_c <= 1'b0;
            in_latin_c <= 1'b0; open_c <= 1'b0; edge_c <= 1'b0; core_c <= 1'b0; glow_c <= 1'b0;
            split_c <= 1'b0; bracket_c <= 1'b0; scan_c <= 1'b0; cursor_c <= 1'b0; grid_c <= 1'b0;
            tint_c <= 6'd0;
        end else begin
            big_px_c <= big_px; latin_px_c <= latin_px; in_title_c <= in_title_b;
            title_shown_c <= title_shown_b; in_latin_c <= in_latin_b; open_c <= open_b;
            edge_c <= edge_b; core_c <= core_b; glow_c <= glow_b; split_c <= split_b;
            bracket_c <= bracket_b; scan_c <= scan_b; cursor_c <= cursor_b; grid_c <= grid_b;
            tint_c <= tint_b;
        end
    end

    // ---------------------------------------------------- stage D0: coverage, base colour
    wire [31:0] big_shift = big_word << {big_px_c, 1'b0};
    wire [31:0] latin_shift = latin_word << {latin_px_c, 1'b0};
    reg  [23:0] base_c;
    always @* begin
        base_c = grid_c ? GRID : BG;
        if (glow_c) base_c = GLOW;
        if (split_c) base_c = AMBER_LO;
        if (core_c || bracket_c) base_c = AMBER;
    end
    reg [23:0] base_d0;
    reg [4:0]  big_w_d0, latin_w_d0, tint_d0;
    reg        scan_d0, cursor_d0, edge_d0, on_d0;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            base_d0 <= 24'd0; big_w_d0 <= 5'd0; latin_w_d0 <= 5'd0; tint_d0 <= 5'd0;
            scan_d0 <= 1'b0; cursor_d0 <= 1'b0; edge_d0 <= 1'b0; on_d0 <= 1'b0;
        end else begin
            base_d0 <= base_c;
            big_w_d0 <= (in_title_c && title_shown_c) ? coverage_weight(big_shift[31:30]) : 5'd0;
            latin_w_d0 <= in_latin_c ? coverage_weight(latin_shift[31:30]) : 5'd0;
            tint_d0 <= tint_c[5:1];
            scan_d0 <= scan_c; cursor_d0 <= cursor_c; edge_d0 <= edge_c;
            on_d0 <= layer_on && !open_c;
        end
    end

    // ---------------------------------------------------- stage D1: title ink
    reg [23:0] title_d1, base_d1;
    reg [4:0]  big_w_d1, latin_w_d1;
    reg        scan_d1, cursor_d1, edge_d1, on_d1;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            title_d1 <= 24'd0; base_d1 <= 24'd0; big_w_d1 <= 5'd0; latin_w_d1 <= 5'd0;
            scan_d1 <= 1'b0; cursor_d1 <= 1'b0; edge_d1 <= 1'b0; on_d1 <= 1'b0;
        end else begin
            title_d1 <= mix24(WHITE, AMBER, tint_d0);
            base_d1 <= base_d0; big_w_d1 <= big_w_d0; latin_w_d1 <= latin_w_d0;
            scan_d1 <= scan_d0; cursor_d1 <= cursor_d0; edge_d1 <= edge_d0; on_d1 <= on_d0;
        end
    end

    // ---------------------------------------------------- stage D2: title, Latin text
    reg [23:0] colour_d2;
    reg [4:0]  latin_w_d2;
    reg        cursor_d2, edge_d2, on_d2;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            colour_d2 <= 24'd0; latin_w_d2 <= 5'd0; cursor_d2 <= 1'b0; edge_d2 <= 1'b0; on_d2 <= 1'b0;
        end else begin
            colour_d2 <= scan_d1 ? AMBER : mix24(base_d1, title_d1, big_w_d1);
            latin_w_d2 <= latin_w_d1; cursor_d2 <= cursor_d1; edge_d2 <= edge_d1; on_d2 <= on_d1;
        end
    end
    reg [23:0] colour_d3;
    reg        on_d3;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            colour_d3 <= 24'd0; on_d3 <= 1'b0;
        end else begin
            colour_d3 <= (cursor_d2 || edge_d2) ? AMBER : mix24(colour_d2, AMBER, latin_w_d2);
            on_d3 <= on_d2;
        end
    end

    // ---------------------------------------------------- output: fade in from black
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            on <= 1'b0;
            rgb <= 24'd0;
        end else begin
            on <= on_d3;
            rgb <= mix24(24'h000000, colour_d3, fade);
        end
    end
endmodule
