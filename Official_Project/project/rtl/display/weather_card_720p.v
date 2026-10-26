`timescale 1ns/1ps

// Weather card on the advert screen: a translucent panel at the bottom
// centre (x 396..883, y 628..703) with the weather icon, weather,
// temperature, feel and the dishes the kitchen recommends for it.
//
// The card is 32 glyph cells of 28x28 pixels in a 1024 x 28 RAM ({cell,
// row}), written by the board link like the ticker (front_link, frame type 4).
// Its power-on content is weather_card.mif, the kitchen's default weather,
// so the first advert already shows a card. Cells 0, 1, 16, 17 are the four
// quarters of a 56x56 icon drawn without gaps; cells 3-15 and 19-31 are two
// text lines on a 32 px pitch. Latency: three clocks for vs, de and rgb.
module weather_card_720p #(
    parameter integer H_ACTIVE = 1280,
    parameter integer PANEL_X = 396,
    parameter integer PANEL_Y = 628,
    parameter integer PANEL_W = 488,
    parameter integer PANEL_H = 76
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        enable,             // an advert is on screen
    input  wire        vs,
    input  wire        de,
    input  wire [23:0] rgb_in,
    input  wire [23:0] weather_rgb,        // panel line and icon colour (by weather)
    input  wire        card_wclk,
    input  wire        card_we,
    input  wire [9:0]  card_waddr,
    input  wire [27:0] card_wdata,
    output reg         vs_out,
    output reg         de_out,
    output reg  [23:0] rgb_out
);
    localparam integer ICON_X = PANEL_X + 16;     // 56x56, vertically centred
    localparam integer ICON_Y = PANEL_Y + 10;
    localparam integer TEXT_X = PANEL_X + 88;     // text column 0 = cell 3 / 19
    localparam integer TEXT_Y0 = PANEL_Y + 8;
    localparam integer TEXT_Y1 = PANEL_Y + 40;

    // ------------------------------------------------------------ raster
    reg [10:0] x;
    reg [9:0]  y;
    reg        de_q, vs_q;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x <= 11'd0; y <= 10'd0; de_q <= 1'b0; vs_q <= 1'b0;
        end else begin
            de_q <= de;
            vs_q <= vs;
            x <= de ? x + 1'b1 : 11'd0;
            if (vs)
                y <= 10'd0;
            else if (de_q && !de)
                y <= y + 1'b1;
        end
    end

    // ------------------------------------------------------------ s0: cell and row
    wire        in_panel = enable && de && x >= PANEL_X && x < PANEL_X + PANEL_W &&
                           y >= PANEL_Y && y < PANEL_Y + PANEL_H;
    wire        edge_line = y == PANEL_Y || y == PANEL_Y + 1;
    wire [10:0] ix = x - ICON_X;
    wire [9:0]  iy = y - ICON_Y;
    wire        in_icon = x >= ICON_X && x < ICON_X + 56 && y >= ICON_Y && y < ICON_Y + 56;
    wire [10:0] tx = x - TEXT_X;
    wire        text_line1 = y >= TEXT_Y1;
    wire [9:0]  ty = y - (text_line1 ? TEXT_Y1 : TEXT_Y0);
    wire        in_text = x >= TEXT_X && tx[10:5] < 6'd13 && tx[4:0] < 5'd28 &&
                          ((y >= TEXT_Y0 && y < TEXT_Y0 + 28) || (y >= TEXT_Y1 && y < TEXT_Y1 + 28));
    // Icon quarter rows 0..27: subtract 28 for the lower / right half.
    wire        icon_right = ix >= 11'd28;
    wire        icon_low = iy >= 10'd28;
    wire [4:0]  icon_col = icon_right ? ix - 11'd28 : ix[4:0];
    wire [4:0]  icon_row = icon_low ? iy - 10'd28 : iy[4:0];
    wire [4:0]  text_cell = {text_line1, 4'd0} + 5'd3 + tx[9:5];
    reg  [9:0]  rd_addr;
    reg  [4:0]  col1;
    reg         panel1, edge1, glyph1, icon1, rec1;
    reg         vs1, de1;
    reg  [23:0] rgb1;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_addr <= 10'd0; col1 <= 5'd0; panel1 <= 1'b0; edge1 <= 1'b0; glyph1 <= 1'b0;
            icon1 <= 1'b0; rec1 <= 1'b0; vs1 <= 1'b0; de1 <= 1'b0; rgb1 <= 24'd0;
        end else begin
            vs1 <= vs; de1 <= de; rgb1 <= rgb_in;
            panel1 <= in_panel;
            edge1 <= in_panel && edge_line;
            glyph1 <= in_panel && (in_icon || in_text);
            icon1 <= in_icon;
            // Line 1 cells 19-20 are the "推荐" label, drawn muted.
            rec1 <= in_text && text_line1 && tx[9:5] < 4'd2;
            if (in_icon) begin
                rd_addr <= {icon_low, 3'd0, icon_right, icon_row};
                col1 <= icon_col;
            end else begin
                rd_addr <= {text_cell, ty[4:0]};
                col1 <= tx[4:0];
            end
        end
    end

    // ------------------------------------------------------------ s1: RAM
    wire [27:0] bits;
    weather_card_ram u_ram (
        .clk(clk), .address(rd_addr), .bits(bits),
        .wclk(card_wclk), .we(card_we), .waddr(card_waddr), .wdata(card_wdata));
    reg  [4:0]  col2;
    reg         panel2, edge2, glyph2, icon2, rec2, vs2, de2;
    reg  [23:0] rgb2;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            col2 <= 5'd0; panel2 <= 1'b0; edge2 <= 1'b0; glyph2 <= 1'b0; icon2 <= 1'b0;
            rec2 <= 1'b0; vs2 <= 1'b0; de2 <= 1'b0; rgb2 <= 24'd0;
        end else begin
            col2 <= col1; panel2 <= panel1; edge2 <= edge1; glyph2 <= glyph1; icon2 <= icon1;
            rec2 <= rec1; vs2 <= vs1; de2 <= de1; rgb2 <= rgb1;
        end
    end

    // ------------------------------------------------------------ s2: colour
    // Panel: the advert darkened to a quarter with a blue tint; a two-line
    // rule on top; glyphs in white, the icon and the rule in the colour of
    // the weather (gold sun, blue rain, ...).
    wire        on = glyph2 && bits[5'd27 - col2];
    wire [23:0] dim = {2'b00, rgb2[23:18], 2'b00, rgb2[15:10], 2'b00, rgb2[7:2]} + 24'h0a1420;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vs_out <= 1'b0; de_out <= 1'b0; rgb_out <= 24'd0;
        end else begin
            vs_out <= vs2;
            de_out <= de2;
            rgb_out <= !panel2 ? rgb2 :
                       edge2 ? weather_rgb :
                       on ? (icon2 ? weather_rgb : rec2 ? 24'h9fb4c4 : 24'hf4f7fb) : dim;
        end
    end
endmodule

// 1024 x 28 dual-port RAM (four BRAM9K; the BRAM32K are all used): port A reads for the display, port B is
// written by the board link.
module weather_card_ram (
    input wire clk, input wire [9:0] address, output wire [27:0] bits,
    input wire wclk, input wire we, input wire [9:0] waddr, input wire [27:0] wdata
);
`ifdef ORDER_UI_SIMULATION
reg [27:0] simulation_ram [0:1023];
reg [27:0] simulation_bits;
initial $readmemh("../../project/rtl/display/weather_card.dath", simulation_ram);
always @(posedge clk) simulation_bits <= simulation_ram[address];
always @(posedge wclk) if (we) simulation_ram[waddr] <= wdata;
assign bits = simulation_bits;
`else
EG_LOGIC_BRAM #(
    .DATA_WIDTH_A(28), .ADDR_WIDTH_A(10), .DATA_DEPTH_A(1024),
    .DATA_WIDTH_B(28), .ADDR_WIDTH_B(10), .DATA_DEPTH_B(1024),
    .MODE("DP"), .REGMODE_A("NOREG"), .REGMODE_B("NOREG"),
    .WRITEMODE_A("NORMAL"), .WRITEMODE_B("NORMAL"), .IMPLEMENT("9K"),
    .DEBUGGABLE("NO"), .PACKABLE("NO"),
    .INIT_FILE("weather_card.mif"), .FILL_ALL("NONE")
) u_bram (
    .dia(28'd0), .dib(wdata), .addra(address), .addrb(waddr),
    .cea(1'b1), .ceb(1'b1), .ocea(1'b0), .oceb(1'b0),
    .clka(clk), .clkb(wclk), .wea(1'b0), .web(we),
    .bea(1'b0), .beb(1'b0), .rsta(1'b0), .rstb(1'b0),
    .doa(bits), .dob()
);
`endif
endmodule
