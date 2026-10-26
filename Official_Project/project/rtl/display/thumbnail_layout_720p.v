`timescale 1ns/1ps

module thumbnail_layout_720p #(
    parameter integer ADDR_WIDTH = 21,
    parameter integer FRAME_WIDTH = 1280,
    parameter integer FRAME_HEIGHT = 720,
    parameter integer FRAME_WORDS = 460800,
    parameter integer BORDER_WIDTH = 4
) (
    input  wire [10:0] pixel_x,
    input  wire [9:0]  pixel_y,
    input  wire [2:0]  focus_index,
    input  wire [3:0]  image_complete,
    input  wire [2:0]  bank_owner0,
    input  wire [2:0]  bank_owner1,
    input  wire [2:0]  bank_owner2,
    input  wire [2:0]  bank_owner3,
    input  wire [7:0]  category_cache_status,
    output reg         thumb_de,
    output reg  [1:0]  source_index,
    output reg  [ADDR_WIDTH-1:0] source_word_addr,
    output reg         focus_border
);
    localparam integer THUMB_WIDTH = FRAME_WIDTH / 2;
    localparam integer THUMB_HEIGHT = FRAME_HEIGHT / 2;

    integer local_x;
    integer local_y;
    integer source_offset;
    reg [2:0] owner_for_bank;

    always @* begin
        thumb_de = 1'b0;
        source_index = 2'd0;
        source_word_addr = {ADDR_WIDTH{1'b0}};
        focus_border = 1'b0;
        local_x = 0;
        local_y = 0;
        source_offset = 0;
        owner_for_bank = 3'd0;

        if (pixel_x < FRAME_WIDTH && pixel_y < FRAME_HEIGHT) begin
            source_index = {pixel_y >= THUMB_HEIGHT,
                            pixel_x >= THUMB_WIDTH};
            local_x = (pixel_x >= THUMB_WIDTH) ?
                      pixel_x - THUMB_WIDTH : pixel_x;
            local_y = (pixel_y >= THUMB_HEIGHT) ?
                      pixel_y - THUMB_HEIGHT : pixel_y;
            source_offset = local_y * FRAME_WIDTH + local_x;
            source_word_addr = source_index * FRAME_WORDS + source_offset;
            case (source_index)
                2'd0: owner_for_bank = bank_owner0;
                2'd1: owner_for_bank = bank_owner1;
                2'd2: owner_for_bank = bank_owner2;
                default: owner_for_bank = bank_owner3;
            endcase
            thumb_de = image_complete[source_index];
            focus_border = image_complete[source_index] &&
                           category_cache_status[focus_index] &&
                           owner_for_bank == focus_index &&
                           (local_x < BORDER_WIDTH ||
                            local_y < BORDER_WIDTH ||
                            local_x >= THUMB_WIDTH - BORDER_WIDTH ||
                            local_y >= THUMB_HEIGHT - BORDER_WIDTH);
        end
    end
endmodule

module thumbnail_overlay_720p (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        vs,
    input  wire        de,
    input  wire [23:0] rgb_in,
    input  wire        thumbnail_mode,
    input  wire [2:0]  focus_index,
    input  wire [3:0]  image_complete,
    input  wire [2:0]  bank_owner0,
    input  wire [2:0]  bank_owner1,
    input  wire [2:0]  bank_owner2,
    input  wire [2:0]  bank_owner3,
    input  wire [7:0]  category_cache_status,
    output reg         vs_out,
    output reg         de_out,
    output reg  [23:0] rgb_out
);
    reg [10:0] pixel_x;
    reg [9:0] line_y;
    reg de_q;
    wire thumb_de;
    wire [1:0] source_index;
    wire [20:0] source_word_addr;
    wire focus_border;

    thumbnail_layout_720p u_layout (
        .pixel_x(pixel_x),
        .pixel_y(line_y),
        .focus_index(focus_index),
        .image_complete(image_complete),
        .bank_owner0(bank_owner0),
        .bank_owner1(bank_owner1),
        .bank_owner2(bank_owner2),
        .bank_owner3(bank_owner3),
        .category_cache_status(category_cache_status),
        .thumb_de(thumb_de),
        .source_index(source_index),
        .source_word_addr(source_word_addr),
        .focus_border(focus_border)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pixel_x <= 11'd0;
            line_y <= 10'd0;
            de_q <= 1'b0;
            vs_out <= 1'b0;
            de_out <= 1'b0;
            rgb_out <= 24'd0;
        end else begin
            de_q <= de;
            vs_out <= vs;
            de_out <= de;

            if (!de)
                pixel_x <= 11'd0;
            else if (!de_q)
                pixel_x <= 11'd1;
            else
                pixel_x <= pixel_x + 1'b1;

            if (vs)
                line_y <= 10'd0;
            else if (de_q && !de)
                line_y <= line_y + 1'b1;

            if (!thumbnail_mode)
                rgb_out <= rgb_in;
            else if (!thumb_de)
                rgb_out <= 24'h000000;
            else if (focus_border)
                rgb_out <= 24'h35d0d8;
            else
                rgb_out <= rgb_in;
        end
    end
endmodule
