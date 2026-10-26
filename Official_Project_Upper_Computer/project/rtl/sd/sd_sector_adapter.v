`timescale 1ns/1ps

module sd_sector_adapter #(
    parameter integer CLK_FREQ_HZ = 100_000_000,
    parameter integer READ_TIMEOUT_MS = 500
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        sector_req,
    input  wire [31:0] sector_lba,
    output wire        sector_busy,
    output wire        sector_valid,
    output wire [7:0]  sector_byte,
    output wire [8:0]  sector_byte_index,
    output reg         sector_done,
    output reg  [7:0]  sector_error,
    output reg         sd_sec_read,
    output reg  [31:0] sd_sec_read_addr,
    input  wire        sd_sec_read_data_valid,
    input  wire [7:0]  sd_sec_read_data,
    input  wire        sd_sec_read_end
);

localparam [7:0] ERR_NONE    = 8'h00;
localparam [7:0] ERR_TIMEOUT = 8'h11;
localparam [7:0] ERR_SHORT   = 8'h12;
localparam integer TIMEOUT_CYCLES =
    ((CLK_FREQ_HZ / 1000) * READ_TIMEOUT_MS > 0) ?
    ((CLK_FREQ_HZ / 1000) * READ_TIMEOUT_MS) : 1;

reg busy_reg;
reg [9:0] byte_count;
reg [31:0] timeout_count;

assign sector_busy = busy_reg;
assign sector_valid = busy_reg && sd_sec_read_data_valid;
assign sector_byte = sd_sec_read_data;
assign sector_byte_index = byte_count[8:0];

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        busy_reg <= 1'b0;
        byte_count <= 10'd0;
        timeout_count <= 32'd0;
        sector_done <= 1'b0;
        sector_error <= ERR_NONE;
        sd_sec_read <= 1'b0;
        sd_sec_read_addr <= 32'd0;
    end else begin
        sector_done <= 1'b0;
        sector_error <= ERR_NONE;

        if (!busy_reg) begin
            sd_sec_read <= 1'b0;
            byte_count <= 10'd0;
            timeout_count <= 32'd0;
            if (sector_req) begin
                busy_reg <= 1'b1;
                sd_sec_read <= 1'b1;
                sd_sec_read_addr <= sector_lba;
            end
        end else if (sd_sec_read_end) begin
            busy_reg <= 1'b0;
            sd_sec_read <= 1'b0;
            sector_done <= 1'b1;
            sector_error <= (byte_count == 10'd512) ? ERR_NONE : ERR_SHORT;
            byte_count <= 10'd0;
            timeout_count <= 32'd0;
        end else if (timeout_count >= TIMEOUT_CYCLES - 1) begin
            busy_reg <= 1'b0;
            sd_sec_read <= 1'b0;
            sector_done <= 1'b1;
            sector_error <= ERR_TIMEOUT;
            byte_count <= 10'd0;
            timeout_count <= 32'd0;
        end else if (sd_sec_read_data_valid) begin
            if (byte_count < 10'd512)
                byte_count <= byte_count + 1'b1;
            timeout_count <= 32'd0;
        end else begin
            timeout_count <= timeout_count + 1'b1;
        end
    end
end

endmodule
