`timescale 1ns/1ps

module fat32_file_streamer #(
    parameter integer MAX_VISITED_CLUSTERS = 8192
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        file_start,
    input  wire [31:0] first_cluster,
    input  wire [31:0] file_size,
    input  wire [7:0]  sectors_per_cluster,
    input  wire [2:0]  sectors_per_cluster_shift,
    input  wire [31:0] fat_start_lba,
    input  wire [31:0] data_start_lba,
    input  wire [31:0] max_cluster,
    output wire        file_busy,
    output reg         file_done,
    output reg         file_valid,
    output reg  [7:0]  file_byte,
    output reg  [31:0] file_byte_offset,
    output reg  [7:0]  fs_error,
    output reg         sector_req,
    output reg  [31:0] sector_lba,
    input  wire        sector_busy,
    input  wire        sector_valid,
    input  wire [7:0]  sector_byte,
    input  wire [8:0]  sector_byte_index,
    input  wire        sector_done,
    input  wire [7:0]  sector_error
);

localparam [7:0] ERR_NONE              = 8'h00;
localparam [7:0] ERR_SECTOR            = 8'h10;
localparam [7:0] ERR_FAT_LOOP          = 8'h23;
localparam [7:0] ERR_CLUSTER_RANGE     = 8'h24;
localparam [7:0] ERR_EARLY_EOF         = 8'h25;
localparam [7:0] ERR_VISITED_EXHAUSTED = 8'h26;

localparam [3:0] ST_IDLE       = 4'd0;
localparam [3:0] ST_DATA_REQ   = 4'd1;
localparam [3:0] ST_DATA_WAIT  = 4'd2;
localparam [3:0] ST_FAT_REQ    = 4'd3;
localparam [3:0] ST_FAT_WAIT   = 4'd4;
localparam [3:0] ST_FAT_PARSE  = 4'd5;
localparam [3:0] ST_FINISH     = 4'd6;
localparam [3:0] ST_ADDR_DELTA = 4'd7;
localparam [3:0] ST_ADDR_SHIFT = 4'd8;
localparam [3:0] ST_ADDR_ADD   = 4'd9;
localparam [3:0] ST_FAT_CACHE  = 4'd10;
localparam [3:0] ST_FAT_LOAD   = 4'd11;
localparam [3:0] ST_START      = 4'd12;
localparam [3:0] ST_FAT_CHECK  = 4'd13;
localparam [3:0] ST_FAT_CMP    = 4'd14;

localparam integer CHAIN_COUNT_WIDTH = $clog2(MAX_VISITED_CLUSTERS + 1);

reg [3:0] state;
reg [31:0] current_cluster;
reg [31:0] cluster_delta;
reg [31:0] cluster_sector_offset;
reg [31:0] remaining_bytes;
reg [7:0] sector_in_cluster;
reg [8:0] fat_entry_offset;
reg [7:0] fat_byte0;
reg [7:0] fat_byte1;
reg [7:0] fat_byte2;
reg [7:0] fat_byte3;
reg [CHAIN_COUNT_WIDTH-1:0] chain_count;
// Checks of the FAT entry, registered in ST_FAT_CMP before ST_FAT_PARSE uses them.
reg fat_eoc;
reg fat_range_bad;
reg start_range_bad;                // first cluster outside 2..max_cluster
reg fat_self_loop;
reg chain_exhausted;
reg final_chain_check;
reg fat_cache_valid;
reg [31:0] fat_cache_lba;
reg [7:0] fat_cache_byte0;
reg [7:0] fat_cache_byte1;
reg [7:0] fat_cache_byte2;
reg [6:0] fat_cache_read_addr;
reg [31:0] fat_cache_read_data;
reg [31:0] fat_entry_cache [0:127] /* fehdl force_ram=1, ram_style="bram" */;
reg [31:0] start_cluster;
reg [31:0] stream_file_size;
reg fat_cache_hit;

wire [27:0] fat_entry_value;
wire [31:0] fat_entry_cluster;

assign file_busy = (state != ST_IDLE);
assign fat_entry_value = {fat_byte3[3:0], fat_byte2, fat_byte1, fat_byte0};
assign fat_entry_cluster = {4'd0, fat_entry_value};

task finish_with_error;
    input [7:0] error_code;
    begin
        fs_error <= error_code;
        state <= ST_FINISH;
    end
endtask

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        fat_cache_read_addr <= 7'd0;
        fat_cache_read_data <= 32'd0;
    end else begin
        if (state == ST_FAT_WAIT && sector_valid &&
            sector_byte_index[1:0] == 2'd3)
            fat_entry_cache[sector_byte_index[8:2]] <=
                {sector_byte, fat_cache_byte2, fat_cache_byte1, fat_cache_byte0};
        if (state == ST_FAT_CHECK)
            fat_cache_read_addr <= current_cluster[6:0];
        fat_cache_read_data <= fat_entry_cache[fat_cache_read_addr];
    end
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state <= ST_IDLE;
        file_done <= 1'b0;
        file_valid <= 1'b0;
        file_byte <= 8'd0;
        file_byte_offset <= 32'd0;
        fs_error <= ERR_NONE;
        sector_req <= 1'b0;
        sector_lba <= 32'd0;
        current_cluster <= 32'd0;
        cluster_delta <= 32'd0;
        cluster_sector_offset <= 32'd0;
        remaining_bytes <= 32'd0;
        sector_in_cluster <= 8'd0;
        fat_entry_offset <= 9'd0;
        fat_byte0 <= 8'd0;
        fat_byte1 <= 8'd0;
        fat_byte2 <= 8'd0;
        fat_byte3 <= 8'd0;
        chain_count <= 0;
        fat_eoc <= 1'b0;
        fat_range_bad <= 1'b0;
        start_range_bad <= 1'b0;
        fat_self_loop <= 1'b0;
        chain_exhausted <= 1'b0;
        final_chain_check <= 1'b0;
        fat_cache_valid <= 1'b0;
        fat_cache_lba <= 32'd0;
        fat_cache_byte0 <= 8'd0;
        fat_cache_byte1 <= 8'd0;
        fat_cache_byte2 <= 8'd0;
        start_cluster <= 32'd0;
        stream_file_size <= 32'd0;
        fat_cache_hit <= 1'b0;
    end else begin
        file_done <= 1'b0;
        file_valid <= 1'b0;
        sector_req <= 1'b0;

        if (state == ST_DATA_WAIT && sector_valid && remaining_bytes != 0) begin
            file_valid <= 1'b1;
            file_byte <= sector_byte;
            file_byte_offset <= stream_file_size - remaining_bytes;
            remaining_bytes <= remaining_bytes - 1'b1;
        end

        if (state == ST_FAT_WAIT && sector_valid) begin
            case (sector_byte_index[1:0])
                2'd0: fat_cache_byte0 <= sector_byte;
                2'd1: fat_cache_byte1 <= sector_byte;
                2'd2: fat_cache_byte2 <= sector_byte;
            endcase
            if (sector_byte_index == fat_entry_offset)
                fat_byte0 <= sector_byte;
            else if (sector_byte_index == fat_entry_offset + 1'b1)
                fat_byte1 <= sector_byte;
            else if (sector_byte_index == fat_entry_offset + 2'd2)
                fat_byte2 <= sector_byte;
            else if (sector_byte_index == fat_entry_offset + 2'd3)
                fat_byte3 <= sector_byte;
        end

        case (state)
            ST_IDLE: if (file_start) begin
                fs_error <= ERR_NONE;
                file_byte_offset <= 32'd0;
                sector_in_cluster <= 8'd0;
                chain_count <= 1;
                final_chain_check <= 1'b0;
                fat_cache_valid <= 1'b0;
                start_cluster <= first_cluster;
                start_range_bad <= first_cluster < 2 || first_cluster > max_cluster;
                stream_file_size <= file_size;
                state <= ST_START;
            end

            ST_START: begin
                remaining_bytes <= stream_file_size;
                if (stream_file_size == 0) begin
                    state <= ST_FINISH;
                end else if (start_range_bad || sectors_per_cluster == 0) begin
                    finish_with_error(ERR_CLUSTER_RANGE);
                end else begin
                    current_cluster <= start_cluster;
                    state <= ST_ADDR_DELTA;
                end
            end

            ST_ADDR_DELTA: begin
                cluster_delta <= current_cluster - 2;
                state <= ST_ADDR_SHIFT;
            end

            ST_ADDR_SHIFT: begin
                cluster_sector_offset <= cluster_delta << sectors_per_cluster_shift;
                state <= ST_ADDR_ADD;
            end

            ST_ADDR_ADD: begin
                sector_lba <= data_start_lba + cluster_sector_offset;
                state <= ST_DATA_REQ;
            end

            ST_DATA_REQ: if (!sector_busy) begin
                sector_req <= 1'b1;
                state <= ST_DATA_WAIT;
            end

            ST_DATA_WAIT: if (sector_done) begin
                if (sector_error != 0) begin
                    finish_with_error(ERR_SECTOR);
                end else if (remaining_bytes == 0 ||
                             (remaining_bytes == 1 && sector_valid)) begin
                    final_chain_check <= 1'b1;
                    sector_in_cluster <= 8'd0;
                    fat_entry_offset <= {current_cluster[6:0], 2'b00};
                    sector_lba <= fat_start_lba + (current_cluster >> 7);
                    state <= ST_FAT_CHECK;
                end else if (sector_in_cluster + 1'b1 < sectors_per_cluster) begin
                    sector_in_cluster <= sector_in_cluster + 1'b1;
                    sector_lba <= sector_lba + 1'b1;
                    state <= ST_DATA_REQ;
                end else begin
                    sector_in_cluster <= 8'd0;
                    fat_entry_offset <= {current_cluster[6:0], 2'b00};
                    sector_lba <= fat_start_lba + (current_cluster >> 7);
                    state <= ST_FAT_CHECK;
                end
            end

            ST_FAT_CHECK: begin
                fat_cache_hit <= fat_cache_valid && fat_cache_lba == sector_lba;
                state <= ST_FAT_REQ;
            end

            ST_FAT_REQ: if (fat_cache_hit) begin
                state <= ST_FAT_CACHE;
            end else if (!sector_busy) begin
                sector_req <= 1'b1;
                state <= ST_FAT_WAIT;
            end

            ST_FAT_CACHE: begin
                state <= ST_FAT_LOAD;
            end

            ST_FAT_LOAD: begin
                fat_byte0 <= fat_cache_read_data[7:0];
                fat_byte1 <= fat_cache_read_data[15:8];
                fat_byte2 <= fat_cache_read_data[23:16];
                fat_byte3 <= fat_cache_read_data[31:24];
                state <= ST_FAT_CMP;
            end

            ST_FAT_WAIT: if (sector_done) begin
                if (sector_error != 0)
                    finish_with_error(ERR_SECTOR);
                else begin
                    fat_cache_valid <= 1'b1;
                    fat_cache_lba <= sector_lba;
                    state <= ST_FAT_CMP;
                end
            end

            ST_FAT_CMP: begin
                fat_eoc <= fat_entry_value >= 28'hffffff8;
                fat_range_bad <= fat_entry_cluster < 2 || fat_entry_cluster > max_cluster;
                fat_self_loop <= fat_entry_cluster == current_cluster;
                chain_exhausted <= chain_count >= MAX_VISITED_CLUSTERS;
                state <= ST_FAT_PARSE;
            end

            ST_FAT_PARSE: begin
                if (final_chain_check) begin
                    final_chain_check <= 1'b0;
                    if (fat_eoc)
                        state <= ST_FINISH;
                    else if (fat_range_bad)
                        finish_with_error(ERR_CLUSTER_RANGE);
                    else
                        finish_with_error(ERR_FAT_LOOP);
                end else if (fat_eoc) begin
                    finish_with_error(ERR_EARLY_EOF);
                end else if (fat_range_bad) begin
                    finish_with_error(ERR_CLUSTER_RANGE);
                end else if (chain_exhausted) begin
                    finish_with_error(ERR_VISITED_EXHAUSTED);
                end else if (fat_self_loop) begin
                    finish_with_error(ERR_FAT_LOOP);
                end else begin
                    chain_count <= chain_count + 1'b1;
                    current_cluster <= fat_entry_cluster;
                    state <= ST_ADDR_DELTA;
                end
            end

            ST_FINISH: begin
                file_done <= 1'b1;
                state <= ST_IDLE;
            end

            default: state <= ST_IDLE;
        endcase
    end
end

endmodule
