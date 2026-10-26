`timescale 1ns/1ps

module order_thumbnail_rom (
    input wire clk, input wire [1:0] dish, input wire [4:0] row,
    input wire [4:0] col, output wire [7:0] pixel
);
wire [11:0] rom_address = {dish, row, col};

`ifdef ORDER_UI_SIMULATION
reg [7:0] simulation_rom [0:4095];
reg [7:0] simulation_pixel;
initial $readmemh("../../project/rtl/display/order_thumbnail.dath", simulation_rom);
always @(posedge clk) simulation_pixel <= simulation_rom[rom_address];
assign pixel = simulation_pixel;
`else
EG_LOGIC_BRAM #(
    .DATA_WIDTH_A(8), .ADDR_WIDTH_A(12), .DATA_DEPTH_A(4096),
    .DATA_WIDTH_B(8), .ADDR_WIDTH_B(12), .DATA_DEPTH_B(4096),
    .MODE("SP"), .REGMODE_A("NOREG"), .IMPLEMENT("9K"),
    .DEBUGGABLE("NO"), .PACKABLE("NO"),
    .INIT_FILE("order_thumbnail.mif"), .FILL_ALL("NONE")
) u_thumbnail_bram (
    .dia(8'd0), .dib(8'd0), .addra(rom_address), .addrb(12'd0),
    .cea(1'b1), .ceb(1'b0), .ocea(1'b0), .oceb(1'b0),
    .clka(clk), .clkb(1'b0), .wea(1'b0), .web(1'b0),
    .bea(1'b0), .beb(1'b0), .rsta(1'b0), .rstb(1'b0),
    .doa(pixel), .dob()
);
`endif
endmodule
