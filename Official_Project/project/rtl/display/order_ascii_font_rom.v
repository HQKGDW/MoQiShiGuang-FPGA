`timescale 1ns/1ps

module order_ascii_font_rom (
    input wire clk, input wire [7:0] character, input wire [4:0] row,
    output wire [15:0] bits
);
reg [4:0] glyph;

always @* begin
    glyph = 5'd20;
    case (character)
        "0": glyph = 5'd0;
        "1": glyph = 5'd1;
        "2": glyph = 5'd2;
        "3": glyph = 5'd3;
        "4": glyph = 5'd4;
        "5": glyph = 5'd5;
        "6": glyph = 5'd6;
        "7": glyph = 5'd7;
        "8": glyph = 5'd8;
        "9": glyph = 5'd9;
        "/": glyph = 5'd10;
        "X": glyph = 5'd11;
        "Y": glyph = 5'd12;
        "T": glyph = 5'd13;
        "A": glyph = 5'd14;
        "C": glyph = 5'd15;
        "I": glyph = 5'd16;
        "E": glyph = 5'd17;
        "S": glyph = 5'd18;
        "g": glyph = 5'd19;
        default: glyph = 5'd20;
    endcase
end

wire [9:0] rom_address = {glyph, row};

`ifdef ORDER_UI_SIMULATION
reg [15:0] simulation_rom [0:1023];
reg [15:0] simulation_bits;
initial $readmemh("../../project/rtl/display/order_ascii_font.dath", simulation_rom);
always @(posedge clk) simulation_bits <= simulation_rom[rom_address];
assign bits = simulation_bits;
`else
EG_LOGIC_BRAM #(
    .DATA_WIDTH_A(16), .ADDR_WIDTH_A(10), .DATA_DEPTH_A(1024),
    .DATA_WIDTH_B(16), .ADDR_WIDTH_B(10), .DATA_DEPTH_B(1024),
    .MODE("SP"), .REGMODE_A("NOREG"), .IMPLEMENT("9K"),
    .DEBUGGABLE("NO"), .PACKABLE("NO"),
    .INIT_FILE("order_ascii_font.mif"), .FILL_ALL("NONE")
) u_ascii_bram (
    .dia(16'd0), .dib(16'd0), .addra(rom_address), .addrb(10'd0),
    .cea(1'b1), .ceb(1'b0), .ocea(1'b0), .oceb(1'b0),
    .clka(clk), .clkb(1'b0), .wea(1'b0), .web(1'b0),
    .bea(1'b0), .beb(1'b0), .rsta(1'b0), .rstb(1'b0),
    .doa(bits), .dob()
);
`endif
endmodule
