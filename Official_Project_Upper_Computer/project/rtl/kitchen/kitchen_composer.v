`timescale 1ns/1ps

// Display-list processor. At every frame start it swaps in the buffer it
// composed during the previous frame, then rebuilds the requested page into
// the other buffer by executing that page's command list (see
// tools/build_kitchen_assets.py). Every tile is read, modified and written
// back, so later commands only change the fields they own.
//
// Tile word:
//   [31] glyph present  [30] CJK  [29] right half  [28:27] vertical place
//   (0 normal, 1 upper half of a 16 px lowered glyph, 2 its lower half)
//   [26:19] code  [18:15] fg  [14:11] bg  [10:7] decoration  [6:0] element
module kitchen_composer (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        frame_start,
    input  wire [2:0]  page,
    output reg         front,          // buffer shown by the display
    output reg         frame_ready,    // the buffer about to be shown is complete
    // Variable bus: var_value may take two clocks after var_id changes.
    output wire [5:0]  var_id,
    input  wire [15:0] var_value,
    // Tile RAM port A.
    output reg  [11:0] ram_addr,
    output reg         ram_we,
    output reg  [31:0] ram_wdata,
    input  wire [31:0] ram_rdata,
    // Display list and phrase ROMs (one clock of latency).
    output wire [10:0] dl_addr,
    input  wire [63:0] dl_data,
    output wire [9:0]  ph_addr,
    input  wire [8:0]  ph_data
);
`include "kitchen_ui_defs.vh"

    localparam [3:0] OP_END = 4'd0, OP_FILL = 4'd1, OP_TEXT = 4'd2, OP_NUM = 4'd3,
                     OP_BAR = 4'd4, OP_IF = 4'd5;

    localparam [4:0] S_IDLE = 5'd0, S_WAIT = 5'd1, S_DECODE = 5'd2, S_EXEC = 5'd3,
                     S_FILL = 5'd4, S_TXT_WAIT = 5'd5, S_TXT_CHAR = 5'd6,
                     S_NUM_CONV = 5'd7, S_NUM_EMIT = 5'd8, S_BAR = 5'd9,
                     S_RD = 5'd10, S_RD_WAIT = 5'd11, S_WR = 5'd12, S_EMIT = 5'd13,
                     S_VAR = 5'd14, S_VAR0 = 5'd15;

    // Kinds of tile writes.
    localparam [1:0] W_ATTR = 2'd0, W_GLYPH = 2'd1, W_SEG = 2'd2;

    reg [4:0]  state;
    reg [4:0]  ret_state;        // where S_WR returns to
    reg        target;           // buffer being composed
    reg [10:0] pc;
    reg [63:0] cmd;

    wire [3:0]  cmd_op    = cmd[63:60];
    wire [4:0]  cmd_row   = cmd[59:55];
    wire [6:0]  cmd_col   = cmd[54:48];
    wire [11:0] cmd_skip  = cmd[59:48];
    wire [3:0]  cmd_fg    = cmd[47:44];
    wire [3:0]  cmd_bg    = cmd[43:40];
    wire [3:0]  cmd_deco  = cmd[39:36];
    wire [6:0]  cmd_elem  = cmd[35:29];
    wire        f_set_fg  = cmd[28];
    wire        f_set_bg  = cmd[27];
    wire        f_set_deco = cmd[26];
    wire        f_set_elem = cmd[25];
    wire        f_clear   = cmd[24];
    wire        f_drop    = cmd[23];
    wire        f_hi      = cmd[22];
    wire        f_zero    = cmd[21];
    wire        f_group   = cmd[20];      // TEXT; IF: invert
    wire [6:0]  fill_w    = cmd[19:13];
    wire [4:0]  fill_h    = cmd[12:8];
    wire [11:0] text_addr = cmd[19:8];
    wire [3:0]  text_group = cmd[19:16];
    wire [2:0]  num_digits = cmd[19:17];
    wire [4:0]  bar_total = cmd[19:15];
    wire [1:0]  if_cmp    = cmd[13:12];
    wire [3:0]  if_const  = cmd[11:8];

    assign var_id = (cmd_op == OP_IF) ? cmd[19:14] : cmd[13:8];
    reg  [15:0] var_q;              // var_value registered once per command
    wire [15:0] var_field = f_hi ? {12'd0, var_q[7:4]} : var_q;
    wire [11:0] group_addr = group_phrase(text_group, var_field[3:0]);

    assign dl_addr = pc;

    // Tile write request.
    reg [4:0]  tile_row;
    reg [6:0]  tile_col;
    reg [1:0]  w_kind;
    reg        w_cjk, w_half, w_seg_on;
    reg [1:0]  w_vpos;
    reg [7:0]  w_code;
    wire [10:0] tile_lin = {tile_row, 6'd0} + {2'd0, tile_row, 4'd0} + {4'd0, tile_col};
    wire        tile_ok = tile_row < 5'd23 && tile_col < 7'd80;

    // FILL / BAR iteration.
    reg [4:0]  row0, row_end;
    reg [6:0]  col0, col_end;
    reg [4:0]  bar_count;
    reg [15:0] bar_value;

    // Text / number emission.
    reg [9:0]  ph_ptr;
    assign ph_addr = ph_ptr;
    reg [8:0]  ch;
    reg [1:0]  ch_step;          // which of the up to four tiles of the character
    reg        ch_from_num;
    reg [6:0]  text_col;
    reg [15:0] num_work;
    reg [2:0]  num_place;        // 4..0 during conversion
    reg [3:0]  num_digit [0:4];
    reg [2:0]  num_pos;          // digit position being emitted
    reg        num_leading;

    function [15:0] pow10;
        input [2:0] place;
        begin
            case (place)
                3'd4: pow10 = 16'd10000;
                3'd3: pow10 = 16'd1000;
                3'd2: pow10 = 16'd100;
                3'd1: pow10 = 16'd10;
                default: pow10 = 16'd1;
            endcase
        end
    endfunction

    reg cond;
    always @* begin
        case (if_cmp)
            2'd0: cond = var_q == {12'd0, if_const};
            2'd1: cond = var_q != {12'd0, if_const};
            2'd2: cond = var_q < {12'd0, if_const};
            default: cond = var_q[if_const];
        endcase
        cond = cond ^ f_group;
    end

    // New tile value from the old one.
    reg [31:0] new_tile;
    always @* begin
        new_tile = ram_rdata;
        case (w_kind)
            W_ATTR: begin
                if (f_clear)    new_tile[31:19] = 13'd0;
                if (f_set_fg)   new_tile[18:15] = cmd_fg;
                if (f_set_bg)   new_tile[14:11] = cmd_bg;
                if (f_set_deco) new_tile[10:7]  = cmd_deco;
                if (f_set_elem) new_tile[6:0]   = cmd_elem;
            end
            W_GLYPH: begin
                new_tile[31:19] = (w_code == 8'd32 && !w_cjk) ? 13'd0 :
                                  {1'b1, w_cjk, w_half, w_vpos, w_code};
                new_tile[18:15] = cmd_fg;
            end
            default: begin
                // No glyph; [28:27] places the segment like a lowered glyph.
                new_tile[31:19] = {2'b00, 1'b0, w_vpos, 8'd0};
                new_tile[18:15] = cmd_fg;
                new_tile[10:7]  = w_seg_on ? DECO_SEG_ON : DECO_SEG_OFF;
            end
        endcase
    end

    // Character tiles: 0 (row, col), 1 (row, col+1) for CJK, 2/3 the row below
    // when the text is lowered by 16 px.
    wire ch_cjk = ch[8];
    wire [1:0] ch_last = f_drop ? (ch_cjk ? 2'd3 : 2'd2) : (ch_cjk ? 2'd1 : 2'd0);

    // step[0]: right half of a CJK glyph; step[1]: the row below (lowered text).
    task start_char_tile;
        input [1:0] step;
        begin
            w_kind   <= W_GLYPH;
            w_cjk    <= ch_cjk;
            w_code   <= ch[7:0];
            w_half   <= ch_cjk & step[0];
            tile_col <= text_col + {6'd0, ch_cjk & step[0]};
            tile_row <= cmd_row + {4'd0, step[1]};
            w_vpos   <= !f_drop ? 2'd0 : (step[1] ? 2'd2 : 2'd1);
        end
    endtask

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            ret_state <= S_IDLE;
            front <= 1'b0;
            target <= 1'b1;
            frame_ready <= 1'b0;
            pc <= 11'd0;
            cmd <= 64'd0;
            var_q <= 16'd0;
            ram_addr <= 12'd0;
            ram_we <= 1'b0;
            ram_wdata <= 32'd0;
            tile_row <= 5'd0;
            tile_col <= 7'd0;
            w_kind <= W_ATTR;
            w_cjk <= 1'b0;
            w_half <= 1'b0;
            w_seg_on <= 1'b0;
            w_vpos <= 2'd0;
            w_code <= 8'd0;
            row0 <= 5'd0; row_end <= 5'd0; col0 <= 7'd0; col_end <= 7'd0;
            bar_count <= 5'd0; bar_value <= 16'd0;
            ph_ptr <= 10'd0; ch <= 9'd0; ch_step <= 2'd0; ch_from_num <= 1'b0;
            text_col <= 7'd0; num_work <= 16'd0; num_place <= 3'd0;
            num_pos <= 3'd0; num_leading <= 1'b0;
            num_digit[0] <= 4'd0; num_digit[1] <= 4'd0; num_digit[2] <= 4'd0;
            num_digit[3] <= 4'd0; num_digit[4] <= 4'd0;
        end else begin
            ram_we <= 1'b0;
            if (frame_start) begin
                // Show what was composed during the last frame.
                if (frame_ready)
                    front <= ~front;
                frame_ready <= 1'b0;
            end
            case (state)
                S_IDLE: if (frame_start) begin
                    target <= frame_ready ? front : ~front;
                    pc <= page_base(page);
                    state <= S_WAIT;
                end
                S_WAIT: state <= S_DECODE;          // ROM latency
                S_DECODE: begin
                    cmd <= dl_data;
                    state <= S_VAR0;
                end
                S_VAR0: state <= S_VAR;             // var_value settles
                S_VAR: begin
                    var_q <= var_value;              // var_id follows cmd
                    state <= S_EXEC;
                end
                S_EXEC: begin
                    case (cmd_op)
                        OP_FILL: begin
                            row0 <= cmd_row; col0 <= cmd_col;
                            row_end <= cmd_row + fill_h; col_end <= cmd_col + fill_w;
                            tile_row <= cmd_row; tile_col <= cmd_col;
                            w_kind <= W_ATTR;
                            state <= (fill_w == 0 || fill_h == 0) ? S_WAIT : S_RD;
                            ret_state <= S_FILL;
                            if (fill_w == 0 || fill_h == 0) pc <= pc + 1'b1;
                        end
                        OP_TEXT: begin
                            ph_ptr <= f_group ? group_addr[9:0] : text_addr[9:0];
                            text_col <= cmd_col;
                            ch_from_num <= 1'b0;
                            state <= S_TXT_WAIT;
                        end
                        OP_NUM: begin
                            num_work <= var_field;
                            num_place <= 3'd4;
                            num_digit[0] <= 4'd0; num_digit[1] <= 4'd0; num_digit[2] <= 4'd0;
                            num_digit[3] <= 4'd0; num_digit[4] <= 4'd0;
                            text_col <= cmd_col;
                            state <= S_NUM_CONV;
                        end
                        OP_BAR: begin
                            bar_value <= var_q;
                            bar_count <= 5'd0;
                            tile_row <= cmd_row;
                            tile_col <= cmd_col;
                            state <= (bar_total == 0) ? S_WAIT : S_BAR;
                            if (bar_total == 0) pc <= pc + 1'b1;
                        end
                        OP_IF: begin
                            pc <= cond ? pc + 1'b1 : pc + 1'b1 + cmd_skip;
                            state <= S_WAIT;
                        end
                        default: begin                      // END
                            state <= S_IDLE;
                            frame_ready <= 1'b1;
                        end
                    endcase
                end

                // ---- FILL: one tile per pass through S_RD/S_WR.
                S_FILL: begin
                    if (tile_col + 1'b1 < col_end) begin
                        tile_col <= tile_col + 1'b1;
                        state <= S_RD;
                    end else if (tile_row + 1'b1 < row_end) begin
                        tile_col <= col0;
                        tile_row <= tile_row + 1'b1;
                        state <= S_RD;
                    end else begin
                        pc <= pc + 1'b1;
                        state <= S_WAIT;
                    end
                end

                // ---- BAR: segments on below the value, off above it.
                S_BAR: begin
                    if (bar_count < bar_total) begin
                        w_kind <= W_SEG;
                        w_seg_on <= {11'd0, bar_count} < bar_value;
                        w_vpos <= f_drop ? 2'd1 : f_zero ? 2'd2 : 2'd0;
                        tile_col <= cmd_col + bar_count;
                        tile_row <= cmd_row;
                        bar_count <= bar_count + 1'b1;
                        ret_state <= S_BAR;
                        state <= S_RD;
                    end else begin
                        pc <= pc + 1'b1;
                        state <= S_WAIT;
                    end
                end

                // ---- TEXT: phrase characters until 0x1FF.
                S_TXT_WAIT: state <= S_TXT_CHAR;   // phrase ROM latency
                S_TXT_CHAR: begin
                    if (ph_data == 9'h1FF) begin
                        pc <= pc + 1'b1;
                        state <= S_WAIT;
                    end else begin
                        ch <= ph_data;
                        ch_step <= 2'd0;
                        state <= S_EMIT;
                    end
                end

                // ---- NUM: binary to decimal by repeated subtraction.
                S_NUM_CONV: begin
                    if (num_work >= pow10(num_place)) begin
                        num_work <= num_work - pow10(num_place);
                        num_digit[num_place] <= num_digit[num_place] + 1'b1;
                    end else if (num_place != 0) begin
                        num_place <= num_place - 1'b1;
                    end else begin
                        num_pos <= num_digits - 1'b1;
                        num_leading <= 1'b1;
                        ch_from_num <= 1'b1;
                        state <= S_NUM_EMIT;
                    end
                end
                S_NUM_EMIT: begin
                    // Leading zeros become spaces unless asked for; the last
                    // digit is always shown.
                    if (num_leading && !f_zero && num_pos != 0 && num_digit[num_pos] == 0)
                        ch <= 9'd32;
                    else begin
                        ch <= {5'd3, num_digit[num_pos]};      // '0' + digit
                        num_leading <= 1'b0;
                    end
                    ch_step <= 2'd0;
                    state <= S_EMIT;
                end

                // ---- Write the tiles of one character.
                S_EMIT: begin
                    start_char_tile(ch_step);
                    ret_state <= S_EMIT;
                    state <= S_RD;
                    if (ch_step == ch_last) begin
                        ret_state <= ch_from_num ? S_NUM_EMIT : S_TXT_WAIT;
                    end
                end

                // ---- Read, modify, write one tile.
                S_RD: begin
                    if (tile_ok) begin
                        ram_addr <= {target, tile_lin};
                        state <= S_RD_WAIT;
                    end else begin
                        state <= S_WR;
                    end
                end
                S_RD_WAIT: state <= S_WR;
                S_WR: begin
                    if (tile_ok) begin
                        ram_we <= 1'b1;
                        ram_wdata <= new_tile;
                    end
                    state <= ret_state;
                    if (ret_state == S_EMIT) begin
                        // Next tile of the same character; ASCII skips step 1.
                        ch_step <= (!ch_cjk && ch_step == 2'd0) ? 2'd2 : ch_step + 1'b1;
                    end else if (ret_state == S_TXT_WAIT) begin
                        text_col <= text_col + (ch_cjk ? 7'd2 : 7'd1);
                        ph_ptr <= ph_ptr + 1'b1;
                    end else if (ret_state == S_NUM_EMIT) begin
                        text_col <= text_col + 1'b1;
                        if (num_pos == 0) begin
                            pc <= pc + 1'b1;
                            state <= S_WAIT;
                        end else begin
                            num_pos <= num_pos - 1'b1;
                        end
                    end
                end
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
