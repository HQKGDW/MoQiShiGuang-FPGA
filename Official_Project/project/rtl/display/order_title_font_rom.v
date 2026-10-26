`timescale 1ns/1ps

module order_title_font_rom (
    input wire clk, input wire [4:0] phrase, input wire [2:0] character,
    input wire [5:0] row, output wire [39:0] bits
);
reg [4:0] glyph;

always @* begin
    glyph = 5'h1f;
    case (phrase)
        5'd0: case (character)
            default: glyph = 5'h1f;
        endcase
        5'd1: case (character)
            3'd0: glyph = 5'd5;
            3'd1: glyph = 5'd11;
            3'd2: glyph = 5'd12;
            3'd3: glyph = 5'd18;
            3'd4: glyph = 5'd26;
            default: glyph = 5'h1f;
        endcase
        5'd2: case (character)
            3'd0: glyph = 5'd14;
            3'd1: glyph = 5'd19;
            3'd2: glyph = 5'd29;
            3'd3: glyph = 5'd21;
            3'd4: glyph = 5'd26;
            default: glyph = 5'h1f;
        endcase
        5'd3: case (character)
            3'd0: glyph = 5'd28;
            3'd1: glyph = 5'd20;
            3'd2: glyph = 5'd29;
            3'd3: glyph = 5'd18;
            3'd4: glyph = 5'd26;
            default: glyph = 5'h1f;
        endcase
        5'd4: case (character)
            3'd0: glyph = 5'd16;
            3'd1: glyph = 5'd24;
            3'd2: glyph = 5'd3;
            3'd3: glyph = 5'd25;
            default: glyph = 5'h1f;
        endcase
        5'd5: case (character)
            3'd0: glyph = 5'd28;
            3'd1: glyph = 5'd10;
            3'd2: glyph = 5'd29;
            3'd3: glyph = 5'd18;
            default: glyph = 5'h1f;
        endcase
        5'd6: case (character)
            3'd0: glyph = 5'd4;
            3'd1: glyph = 5'd23;
            3'd2: glyph = 5'd12;
            3'd3: glyph = 5'd18;
            default: glyph = 5'h1f;
        endcase
        5'd7: case (character)
            3'd0: glyph = 5'd14;
            3'd1: glyph = 5'd19;
            3'd2: glyph = 5'd29;
            3'd3: glyph = 5'd21;
            default: glyph = 5'h1f;
        endcase
        5'd8: case (character)
            3'd0: glyph = 5'd6;
            3'd1: glyph = 5'd15;
            3'd2: glyph = 5'd16;
            3'd3: glyph = 5'd24;
            default: glyph = 5'h1f;
        endcase
        5'd9: case (character)
            3'd0: glyph = 5'd27;
            3'd1: glyph = 5'd13;
            3'd2: glyph = 5'd17;
            3'd3: glyph = 5'd1;
            3'd4: glyph = 5'd8;
            default: glyph = 5'h1f;
        endcase
        5'd10: case (character)
            3'd0: glyph = 5'd14;
            3'd1: glyph = 5'd19;
            3'd2: glyph = 5'd9;
            default: glyph = 5'h1f;
        endcase
        5'd11: case (character)
            3'd0: glyph = 5'd22;
            3'd1: glyph = 5'd9;
            default: glyph = 5'h1f;
        endcase
        5'd12: case (character)
            3'd0: glyph = 5'd7;
            3'd1: glyph = 5'd9;
            default: glyph = 5'h1f;
        endcase
        5'd13: case (character)
            3'd0: glyph = 5'd12;
            3'd1: glyph = 5'd18;
            3'd2: glyph = 5'd3;
            3'd3: glyph = 5'd25;
            default: glyph = 5'h1f;
        endcase
        5'd14: case (character)
            3'd0: glyph = 5'd29;
            3'd1: glyph = 5'd18;
            3'd2: glyph = 5'd3;
            3'd3: glyph = 5'd25;
            default: glyph = 5'h1f;
        endcase
        5'd15: case (character)
            3'd0: glyph = 5'd16;
            3'd1: glyph = 5'd24;
            3'd2: glyph = 5'd3;
            3'd3: glyph = 5'd25;
            default: glyph = 5'h1f;
        endcase
        5'd16: case (character)
            3'd0: glyph = 5'd2;
            3'd1: glyph = 5'd0;
            3'd2: glyph = 5'd3;
            3'd3: glyph = 5'd25;
            default: glyph = 5'h1f;
        endcase
        default: glyph = 5'h1f;
    endcase
end

wire [10:0] rom_address = {glyph, row};
wire [23:0] left_bits;
wire [23:0] right_bits;
assign bits = {left_bits, right_bits[15:0]};

`ifdef ORDER_UI_SIMULATION
reg [23:0] simulation_left [0:2047];
reg [23:0] simulation_right [0:2047];
reg [23:0] simulation_left_bits;
reg [23:0] simulation_right_bits;
initial $readmemh("../../project/rtl/display/order_title_font_left.dath", simulation_left);
initial $readmemh("../../project/rtl/display/order_title_font_right.dath", simulation_right);
always @(posedge clk) begin
    simulation_left_bits <= simulation_left[rom_address];
    simulation_right_bits <= simulation_right[rom_address];
end
assign left_bits = simulation_left_bits;
assign right_bits = simulation_right_bits;
`else
EG_LOGIC_BRAM #(
    .DATA_WIDTH_A(24), .ADDR_WIDTH_A(11), .DATA_DEPTH_A(2048),
    .DATA_WIDTH_B(24), .ADDR_WIDTH_B(11), .DATA_DEPTH_B(2048),
    .MODE("SP"), .REGMODE_A("NOREG"), .IMPLEMENT("9K"),
    .DEBUGGABLE("NO"), .PACKABLE("NO"),
    .INIT_FILE("order_title_font_left.mif"), .FILL_ALL("NONE")
) u_title_left_bram (
    .dia(24'd0), .dib(24'd0), .addra(rom_address), .addrb(11'd0),
    .cea(1'b1), .ceb(1'b0), .ocea(1'b0), .oceb(1'b0),
    .clka(clk), .clkb(1'b0), .wea(1'b0), .web(1'b0),
    .bea(1'b0), .beb(1'b0), .rsta(1'b0), .rstb(1'b0),
    .doa(left_bits), .dob()
);
EG_LOGIC_BRAM #(
    .DATA_WIDTH_A(24), .ADDR_WIDTH_A(11), .DATA_DEPTH_A(2048),
    .DATA_WIDTH_B(24), .ADDR_WIDTH_B(11), .DATA_DEPTH_B(2048),
    .MODE("SP"), .REGMODE_A("NOREG"), .IMPLEMENT("9K"),
    .DEBUGGABLE("NO"), .PACKABLE("NO"),
    .INIT_FILE("order_title_font_right.mif"), .FILL_ALL("NONE")
) u_title_right_bram (
    .dia(24'd0), .dib(24'd0), .addra(rom_address), .addrb(11'd0),
    .cea(1'b1), .ceb(1'b0), .ocea(1'b0), .oceb(1'b0),
    .clka(clk), .clkb(1'b0), .wea(1'b0), .web(1'b0),
    .bea(1'b0), .beb(1'b0), .rsta(1'b0), .rstb(1'b0),
    .doa(right_bits), .dob()
);
`endif
endmodule
