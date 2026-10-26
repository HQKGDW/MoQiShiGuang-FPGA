`timescale 1ns/1ps

// Memories of the kitchen console. KITCHEN_SIM selects behavioural models
// loading the .dath files; synthesis maps to EG_LOGIC_BRAM with the .mif
// files next to this source.
`ifndef KITCHEN_MEM_DIR
`define KITCHEN_MEM_DIR "../../project/rtl/kitchen/"
`endif

// Synchronous ROM, one clock of latency.
module kitchen_rom #(
    parameter integer WIDTH = 16,
    parameter integer DEPTH = 1024,
    parameter integer ADDR_W = 10,
    parameter FILE = "kitchen_font_ascii",
    parameter IMPLEMENT = "9K"
) (
    input  wire              clk,
    input  wire [ADDR_W-1:0] addr,
    output wire [WIDTH-1:0]  data
);
`ifdef KITCHEN_SIM
reg [WIDTH-1:0] memory [0:DEPTH-1];
reg [WIDTH-1:0] q;
initial $readmemh({`KITCHEN_MEM_DIR, FILE, ".dath"}, memory);
always @(posedge clk)
    q <= (addr < DEPTH) ? memory[addr] : {WIDTH{1'b0}};
assign data = q;
`else
EG_LOGIC_BRAM #(
    .DATA_WIDTH_A(WIDTH), .ADDR_WIDTH_A(ADDR_W), .DATA_DEPTH_A(DEPTH),
    .DATA_WIDTH_B(WIDTH), .ADDR_WIDTH_B(ADDR_W), .DATA_DEPTH_B(DEPTH),
    .MODE("SP"), .REGMODE_A("NOREG"), .IMPLEMENT(IMPLEMENT),
    .DEBUGGABLE("NO"), .PACKABLE("NO"),
    .INIT_FILE({FILE, ".mif"}), .FILL_ALL("NONE")
) u_bram (
    .dia({WIDTH{1'b0}}), .dib({WIDTH{1'b0}}), .addra(addr), .addrb({ADDR_W{1'b0}}),
    .cea(1'b1), .ceb(1'b0), .ocea(1'b0), .oceb(1'b0),
    .clka(clk), .clkb(1'b0), .wea(1'b0), .web(1'b0),
    .bea(1'b0), .beb(1'b0), .rsta(1'b0), .rstb(1'b0),
    .doa(data), .dob()
);
`endif
endmodule

// Tile map: two 2048-entry buffers of 32-bit tiles. Port A belongs to the
// composer (read or write), port B to the display (read).
module kitchen_tile_ram (
    input  wire        clk,
    input  wire [11:0] addra,
    input  wire        wea,
    input  wire [31:0] dia,
    output wire [31:0] doa,
    input  wire [11:0] addrb,
    output wire [31:0] dob
);
`ifdef KITCHEN_SIM
reg [31:0] memory [0:4095];
reg [31:0] qa, qb;
integer i;
initial for (i = 0; i < 4096; i = i + 1) memory[i] = 32'd0;
always @(posedge clk) begin
    if (wea)
        memory[addra] <= dia;
    qa <= memory[addra];
    qb <= memory[addrb];
end
assign doa = qa;
assign dob = qb;
`else
EG_LOGIC_BRAM #(
    .DATA_WIDTH_A(32), .ADDR_WIDTH_A(12), .DATA_DEPTH_A(4096),
    .DATA_WIDTH_B(32), .ADDR_WIDTH_B(12), .DATA_DEPTH_B(4096),
    .MODE("DP"), .REGMODE_A("NOREG"), .REGMODE_B("NOREG"),
    .WRITEMODE_A("NORMAL"), .WRITEMODE_B("NORMAL"), .IMPLEMENT("9K"),
    .DEBUGGABLE("NO"), .PACKABLE("NO"), .INIT_FILE("NONE"), .FILL_ALL("NONE")
) u_bram (
    .dia(dia), .dib(32'd0), .addra(addra), .addrb(addrb),
    .cea(1'b1), .ceb(1'b1), .ocea(1'b0), .oceb(1'b0),
    .clka(clk), .clkb(clk), .wea(wea), .web(1'b0),
    .bea(1'b0), .beb(1'b0), .rsta(1'b0), .rstb(1'b0),
    .doa(doa), .dob(dob)
);
`endif
endmodule
