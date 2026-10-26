`timescale 1ns/1ps

module fat32_volume_scanner #(
    parameter integer MAX_DIRECTORY_CLUSTERS = 1024
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        scan_start,
    output wire        scan_busy,
    output reg         scan_done,
    output reg  [7:0]  fs_error,
    output reg  [31:0] partition_lba,
    output reg  [7:0]  sectors_per_cluster,
    output reg  [2:0]  sectors_per_cluster_shift,
    output reg  [31:0] fat_start_lba,
    output reg  [31:0] data_start_lba,
    output reg  [31:0] max_cluster,
    output reg  [7:0]  resource_valid,
    output reg  [31:0] resource0_cluster,
    output reg  [31:0] resource1_cluster,
    output reg  [31:0] resource2_cluster,
    output reg  [31:0] resource3_cluster,
    output reg  [31:0] resource0_size,
    output reg  [31:0] resource1_size,
    output reg  [31:0] resource2_size,
    output reg  [31:0] resource3_size,
    output reg  [31:0] resource4_cluster,
    output reg  [31:0] resource5_cluster,
    output reg  [31:0] resource6_cluster,
    output reg  [31:0] resource7_cluster,
    output reg  [31:0] resource4_size,
    output reg  [31:0] resource5_size,
    output reg  [31:0] resource6_size,
    output reg  [31:0] resource7_size,
    output reg         audio_valid,
    output reg  [31:0] audio_cluster,
    output reg  [31:0] audio_size,
    // Advert posters AD01.BMP - AD04.BMP (any resolution, see fat32_bmp_reader).
    output reg  [3:0]  ad_valid,
    output reg  [31:0] ad0_cluster,
    output reg  [31:0] ad1_cluster,
    output reg  [31:0] ad2_cluster,
    output reg  [31:0] ad3_cluster,
    output reg  [31:0] ad0_size,
    output reg  [31:0] ad1_size,
    output reg  [31:0] ad2_size,
    output reg  [31:0] ad3_size,
    output reg         sector_req,
    output reg  [31:0] sector_lba,
    input  wire        sector_busy,
    input  wire        sector_valid,
    input  wire [7:0]  sector_byte,
    input  wire [8:0]  sector_byte_index,
    input  wire        sector_done,
    input  wire [7:0]  sector_error
);

localparam [7:0] ERR_NONE             = 8'h00;
localparam [7:0] ERR_SECTOR           = 8'h10;
localparam [7:0] ERR_BOOT_SIGNATURE   = 8'h20;
localparam [7:0] ERR_UNSUPPORTED_BPB  = 8'h21;
localparam [7:0] ERR_RESOURCE_MISSING = 8'h22;
localparam [7:0] ERR_DIRECTORY_CHAIN  = 8'h23;

localparam [4:0] ST_IDLE              = 5'd0;
localparam [4:0] ST_READ0_REQ         = 5'd1;
localparam [4:0] ST_READ0_WAIT        = 5'd2;
localparam [4:0] ST_BOOT_REQ          = 5'd3;
localparam [4:0] ST_BOOT_WAIT         = 5'd4;
localparam [4:0] ST_BOOT_PARSE        = 5'd5;
localparam [4:0] ST_LAYOUT            = 5'd6;
localparam [4:0] ST_ROOT_REQ          = 5'd7;
localparam [4:0] ST_ROOT_WAIT         = 5'd8;
localparam [4:0] ST_ROOT_FAT_REQ      = 5'd9;
localparam [4:0] ST_ROOT_FAT_WAIT     = 5'd10;
localparam [4:0] ST_ROOT_FAT_EVAL     = 5'd11;
localparam [4:0] ST_FINISH            = 5'd12;
localparam [4:0] ST_LAYOUT_OVERHEAD   = 5'd13;
localparam [4:0] ST_LAYOUT_DATA       = 5'd14;
localparam [4:0] ST_LAYOUT_MAX        = 5'd15;
localparam [4:0] ST_LAYOUT_ROOT_SHIFT = 5'd16;
localparam [4:0] ST_LAYOUT_ROOT_ADD   = 5'd17;
localparam [4:0] ST_ROOT_NEXT_SHIFT   = 5'd18;
localparam [4:0] ST_ROOT_NEXT_ADD     = 5'd19;
localparam [4:0] ST_BOOT_VALIDATE     = 5'd20;
localparam [4:0] ST_READ0_PARSE       = 5'd21;
localparam [4:0] ST_READ0_PART1       = 5'd22;
localparam [4:0] ST_READ0_PART2       = 5'd23;
localparam [4:0] ST_READ0_PART3       = 5'd24;
localparam [4:0] ST_LAYOUT_CLUSTER    = 5'd25;
localparam [4:0] ST_ROOT_FAT_CMP      = 5'd26;

reg [4:0] state;
reg [7:0] sector_buffer [0:69];
reg [31:0] total_sectors;
reg [31:0] fat_sectors;
reg [31:0] data_sector_count;
reg [31:0] data_cluster_count;
reg [31:0] root_cluster;
reg [31:0] current_root_cluster;
reg [31:0] next_root_cluster;
reg [31:0] fat_span;
reg [31:0] volume_overhead;
reg [31:0] root_cluster_delta;
reg [31:0] root_sector_offset;
reg [15:0] reserved_sectors;
reg [7:0] fat_count;
reg [7:0] root_sector_index;
reg [15:0] directory_cluster_count;
reg directory_end_seen;
reg [8:0] fat_entry_offset;
reg [7:0] fat_byte0;
reg [7:0] fat_byte1;
reg [7:0] fat_byte2;
reg [7:0] fat_byte3;
// Next directory cluster from the FAT and its checks, registered one state
// before they are used.
reg [27:0] fat_next;
reg        fat_end_of_chain;
reg        fat_chain_bad;

reg [7:0] dir_name0;
reg [7:0] dir_name1;
reg [7:0] dir_name2;
reg [7:0] dir_name3;
reg [7:0] dir_name4;
reg [7:0] dir_name5;
reg [7:0] dir_name6;
reg [7:0] dir_name7;
reg [7:0] dir_name8;
reg [7:0] dir_name9;
reg [7:0] dir_name10;
reg       dir_entry_match;
reg       dir_audio_match;
reg [2:0] dir_resource_index;
reg       dir_catalog_match;
reg       dir_cat_name_match;
reg       dir_pic_name_match;
reg       dir_dishes_name_match;
reg       dir_audio_name_match;
reg       dir_ad_name_match;
reg       dir_ad_entry;
reg [1:0] dir_ad_index;
reg [15:0] dir_cluster_high;
reg [15:0] dir_cluster_low;
reg [31:0] dir_file_size;
reg       boot_format_valid;
reg [7:0] dir_commit_pending;
reg       sector_valid_stage;
reg [7:0] sector_byte_stage;
reg [8:0] sector_byte_index_stage;
reg       sector_done_stage;
reg [7:0] sector_error_stage;

assign scan_busy = (state != ST_IDLE);

function [15:0] le16;
    input integer offset;
    begin
        le16 = {sector_buffer[offset+1], sector_buffer[offset]};
    end
endfunction

function [31:0] le32;
    input integer offset;
    begin
        le32 = {sector_buffer[offset+3], sector_buffer[offset+2],
                sector_buffer[offset+1], sector_buffer[offset]};
    end
endfunction

function valid_spc;
    input [7:0] value;
    begin
        case (value)
            8'd1, 8'd2, 8'd4, 8'd8,
            8'd16, 8'd32, 8'd64, 8'd128: valid_spc = 1'b1;
            default: valid_spc = 1'b0;
        endcase
    end
endfunction

function [2:0] spc_shift;
    input [7:0] value;
    begin
        case (value)
            8'd2:   spc_shift = 3'd1;
            8'd4:   spc_shift = 3'd2;
            8'd8:   spc_shift = 3'd3;
            8'd16:  spc_shift = 3'd4;
            8'd32:  spc_shift = 3'd5;
            8'd64:  spc_shift = 3'd6;
            8'd128: spc_shift = 3'd7;
            default: spc_shift = 3'd0;
        endcase
    end
endfunction

function supported_partition;
    input [7:0] partition_type;
    begin
        supported_partition = (partition_type == 8'h0b) ||
                              (partition_type == 8'h0c) ||
                              (partition_type == 8'h1b) ||
                              (partition_type == 8'h1c);
    end
endfunction

task finish_scan;
    input [7:0] error_code;
    begin
        fs_error <= error_code;
        state <= ST_FINISH;
    end
endtask

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state <= ST_IDLE;
        scan_done <= 1'b0;
        fs_error <= ERR_NONE;
        partition_lba <= 32'd0;
        sectors_per_cluster <= 8'd0;
        sectors_per_cluster_shift <= 3'd0;
        fat_start_lba <= 32'd0;
        data_start_lba <= 32'd0;
        max_cluster <= 32'd0;
        resource_valid <= 8'd0;
        resource0_cluster <= 32'd0;
        resource1_cluster <= 32'd0;
        resource2_cluster <= 32'd0;
        resource3_cluster <= 32'd0;
        resource0_size <= 32'd0;
        resource1_size <= 32'd0;
        resource2_size <= 32'd0;
        resource3_size <= 32'd0;
        resource4_cluster <= 32'd0;
        resource5_cluster <= 32'd0;
        resource6_cluster <= 32'd0;
        resource7_cluster <= 32'd0;
        resource4_size <= 32'd0;
        resource5_size <= 32'd0;
        resource6_size <= 32'd0;
        resource7_size <= 32'd0;
        audio_valid <= 1'b0;
        audio_cluster <= 32'd0;
        audio_size <= 32'd0;
        ad_valid <= 4'd0;
        ad0_cluster <= 32'd0;
        ad1_cluster <= 32'd0;
        ad2_cluster <= 32'd0;
        ad3_cluster <= 32'd0;
        ad0_size <= 32'd0;
        ad1_size <= 32'd0;
        ad2_size <= 32'd0;
        ad3_size <= 32'd0;
        sector_req <= 1'b0;
        sector_lba <= 32'd0;
        total_sectors <= 32'd0;
        fat_sectors <= 32'd0;
        data_sector_count <= 32'd0;
        data_cluster_count <= 32'd0;
        root_cluster <= 32'd0;
        current_root_cluster <= 32'd0;
        next_root_cluster <= 32'd0;
        fat_span <= 32'd0;
        volume_overhead <= 32'd0;
        root_cluster_delta <= 32'd0;
        root_sector_offset <= 32'd0;
        reserved_sectors <= 16'd0;
        fat_count <= 8'd0;
        sectors_per_cluster_shift <= 3'd0;
        root_sector_index <= 8'd0;
        directory_cluster_count <= 16'd0;
        directory_end_seen <= 1'b0;
        fat_entry_offset <= 9'd0;
        fat_byte0 <= 8'd0;
        fat_byte1 <= 8'd0;
        fat_byte2 <= 8'd0;
        fat_byte3 <= 8'd0;
        fat_next <= 28'd0;
        fat_end_of_chain <= 1'b0;
        fat_chain_bad <= 1'b0;
        dir_name0 <= 8'd0;
        dir_name1 <= 8'd0;
        dir_name2 <= 8'd0;
        dir_name3 <= 8'd0;
        dir_name4 <= 8'd0;
        dir_name5 <= 8'd0;
        dir_name6 <= 8'd0;
        dir_name7 <= 8'd0;
        dir_name8 <= 8'd0;
        dir_name9 <= 8'd0;
        dir_name10 <= 8'd0;
        dir_entry_match <= 1'b0;
        dir_audio_match <= 1'b0;
        dir_resource_index <= 3'd0;
        dir_catalog_match <= 1'b0;
        dir_cat_name_match <= 1'b0;
        dir_pic_name_match <= 1'b0;
        dir_dishes_name_match <= 1'b0;
        dir_audio_name_match <= 1'b0;
        dir_ad_name_match <= 1'b0;
        dir_ad_entry <= 1'b0;
        dir_ad_index <= 2'd0;
        dir_cluster_high <= 16'd0;
        dir_cluster_low <= 16'd0;
        dir_file_size <= 32'd0;
        boot_format_valid <= 1'b0;
        dir_commit_pending <= 8'd0;
        sector_valid_stage <= 1'b0;
        sector_byte_stage <= 8'd0;
        sector_byte_index_stage <= 9'd0;
        sector_done_stage <= 1'b0;
        sector_error_stage <= 8'd0;
    end else begin
        scan_done <= 1'b0;
        sector_req <= 1'b0;
        dir_commit_pending <= 8'd0;
        sector_valid_stage <= sector_valid;
        sector_byte_stage <= sector_byte;
        sector_byte_index_stage <= sector_byte_index;
        sector_done_stage <= sector_done;
        sector_error_stage <= sector_error;

        if (dir_commit_pending[0]) begin
            resource0_cluster <= {dir_cluster_high, dir_cluster_low};
            resource0_size <= dir_file_size;
            resource_valid[0] <= 1'b1;
        end
        if (dir_commit_pending[1]) begin
            resource1_cluster <= {dir_cluster_high, dir_cluster_low};
            resource1_size <= dir_file_size;
            resource_valid[1] <= 1'b1;
        end
        if (dir_commit_pending[2]) begin
            resource2_cluster <= {dir_cluster_high, dir_cluster_low};
            resource2_size <= dir_file_size;
            resource_valid[2] <= 1'b1;
        end
        if (dir_commit_pending[3]) begin
            resource3_cluster <= {dir_cluster_high, dir_cluster_low};
            resource3_size <= dir_file_size;
            resource_valid[3] <= 1'b1;
        end
        if (dir_commit_pending[4]) begin
            resource4_cluster <= {dir_cluster_high, dir_cluster_low};
            resource4_size <= dir_file_size;
            resource_valid[4] <= 1'b1;
        end
        if (dir_commit_pending[5]) begin
            resource5_cluster <= {dir_cluster_high, dir_cluster_low};
            resource5_size <= dir_file_size;
            resource_valid[5] <= 1'b1;
        end
        if (dir_commit_pending[6]) begin
            resource6_cluster <= {dir_cluster_high, dir_cluster_low};
            resource6_size <= dir_file_size;
            resource_valid[6] <= 1'b1;
        end
        if (dir_commit_pending[7]) begin
            resource7_cluster <= {dir_cluster_high, dir_cluster_low};
            resource7_size <= dir_file_size;
            resource_valid[7] <= 1'b1;
        end

        if (sector_valid_stage && state != ST_ROOT_WAIT && state != ST_ROOT_FAT_WAIT) begin
            case (sector_byte_index_stage)
                9'd0:   sector_buffer[0] <= sector_byte_stage;
                9'd11:  sector_buffer[11] <= sector_byte_stage;
                9'd12:  sector_buffer[12] <= sector_byte_stage;
                9'd13:  sector_buffer[13] <= sector_byte_stage;
                9'd14:  sector_buffer[14] <= sector_byte_stage;
                9'd15:  sector_buffer[15] <= sector_byte_stage;
                9'd16:  sector_buffer[16] <= sector_byte_stage;
                9'd17:  sector_buffer[17] <= sector_byte_stage;
                9'd18:  sector_buffer[18] <= sector_byte_stage;
                9'd22:  sector_buffer[22] <= sector_byte_stage;
                9'd23:  sector_buffer[23] <= sector_byte_stage;
                9'd32:  sector_buffer[32] <= sector_byte_stage;
                9'd33:  sector_buffer[33] <= sector_byte_stage;
                9'd34:  sector_buffer[34] <= sector_byte_stage;
                9'd35:  sector_buffer[35] <= sector_byte_stage;
                9'd36:  sector_buffer[36] <= sector_byte_stage;
                9'd37:  sector_buffer[37] <= sector_byte_stage;
                9'd38:  sector_buffer[38] <= sector_byte_stage;
                9'd39:  sector_buffer[39] <= sector_byte_stage;
                9'd44:  sector_buffer[44] <= sector_byte_stage;
                9'd45:  sector_buffer[45] <= sector_byte_stage;
                9'd46:  sector_buffer[46] <= sector_byte_stage;
                9'd47:  sector_buffer[47] <= sector_byte_stage;
                9'd450: sector_buffer[48] <= sector_byte_stage;
                9'd454: sector_buffer[49] <= sector_byte_stage;
                9'd455: sector_buffer[50] <= sector_byte_stage;
                9'd456: sector_buffer[51] <= sector_byte_stage;
                9'd457: sector_buffer[52] <= sector_byte_stage;
                9'd466: sector_buffer[53] <= sector_byte_stage;
                9'd470: sector_buffer[54] <= sector_byte_stage;
                9'd471: sector_buffer[55] <= sector_byte_stage;
                9'd472: sector_buffer[56] <= sector_byte_stage;
                9'd473: sector_buffer[57] <= sector_byte_stage;
                9'd482: sector_buffer[58] <= sector_byte_stage;
                9'd486: sector_buffer[59] <= sector_byte_stage;
                9'd487: sector_buffer[60] <= sector_byte_stage;
                9'd488: sector_buffer[61] <= sector_byte_stage;
                9'd489: sector_buffer[62] <= sector_byte_stage;
                9'd498: sector_buffer[63] <= sector_byte_stage;
                9'd502: sector_buffer[64] <= sector_byte_stage;
                9'd503: sector_buffer[65] <= sector_byte_stage;
                9'd504: sector_buffer[66] <= sector_byte_stage;
                9'd505: sector_buffer[67] <= sector_byte_stage;
                9'd510: sector_buffer[68] <= sector_byte_stage;
                9'd511: sector_buffer[69] <= sector_byte_stage;
                default: begin end
            endcase
        end

        if (sector_valid_stage && state == ST_ROOT_FAT_WAIT) begin
            if (sector_byte_index_stage == fat_entry_offset)
                fat_byte0 <= sector_byte_stage;
            else if (sector_byte_index_stage == fat_entry_offset + 1'b1)
                fat_byte1 <= sector_byte_stage;
            else if (sector_byte_index_stage == fat_entry_offset + 2'd2)
                fat_byte2 <= sector_byte_stage;
            else if (sector_byte_index_stage == fat_entry_offset + 2'd3)
                fat_byte3 <= sector_byte_stage;
        end

        if (sector_valid_stage && state == ST_ROOT_WAIT) begin
            case (sector_byte_index_stage[4:0])
                5'd0: begin
                    dir_name0 <= sector_byte_stage;
                    dir_entry_match <= 1'b0;
                    dir_audio_match <= 1'b0;
                    dir_cat_name_match <= sector_byte_stage == "C";
                    dir_pic_name_match <= sector_byte_stage == "P";
                    dir_dishes_name_match <= sector_byte_stage == "D";
                    dir_audio_name_match <= sector_byte_stage == "A";
                    dir_ad_name_match <= sector_byte_stage == "A";
                    dir_ad_entry <= 1'b0;
                    if (sector_byte_stage == 8'h00)
                        directory_end_seen <= 1'b1;
                end
                5'd1: begin
                    dir_name1 <= sector_byte_stage;
                    dir_cat_name_match <= dir_cat_name_match && sector_byte_stage == "A";
                    dir_pic_name_match <= dir_pic_name_match && sector_byte_stage == "I";
                    dir_dishes_name_match <= dir_dishes_name_match && sector_byte_stage == "I";
                    dir_audio_name_match <= dir_audio_name_match && sector_byte_stage == "U";
                    dir_ad_name_match <= dir_ad_name_match && sector_byte_stage == "D";
                end
                5'd2: begin
                    dir_name2 <= sector_byte_stage;
                    dir_cat_name_match <= dir_cat_name_match && sector_byte_stage == "T";
                    dir_pic_name_match <= dir_pic_name_match && sector_byte_stage == "C";
                    dir_dishes_name_match <= dir_dishes_name_match && sector_byte_stage == "S";
                    dir_audio_name_match <= dir_audio_name_match && sector_byte_stage == "D";
                    dir_ad_name_match <= dir_ad_name_match && sector_byte_stage == "0";
                end
                5'd3: begin
                    dir_name3 <= sector_byte_stage;
                    dir_cat_name_match <= dir_cat_name_match && sector_byte_stage == "0";
                    dir_pic_name_match <= dir_pic_name_match && sector_byte_stage >= "1" &&
                                          sector_byte_stage <= "4";
                    dir_dishes_name_match <= dir_dishes_name_match && sector_byte_stage == "H";
                    dir_audio_name_match <= dir_audio_name_match && sector_byte_stage == "I";
                    dir_ad_name_match <= dir_ad_name_match && sector_byte_stage >= "1" &&
                                         sector_byte_stage <= "4";
                    dir_ad_index <= sector_byte_stage[1:0] - 2'd1;
                    if (dir_pic_name_match && sector_byte_stage >= "1" &&
                        sector_byte_stage <= "4")
                        dir_resource_index <= sector_byte_stage - "1";
                end
                5'd4: begin
                    dir_name4 <= sector_byte_stage;
                    dir_cat_name_match <= dir_cat_name_match && sector_byte_stage >= "1" &&
                                          sector_byte_stage <= "8";
                    dir_pic_name_match <= dir_pic_name_match && sector_byte_stage == " ";
                    dir_dishes_name_match <= dir_dishes_name_match && sector_byte_stage == "E";
                    dir_audio_name_match <= dir_audio_name_match && sector_byte_stage == "O";
                    dir_ad_name_match <= dir_ad_name_match && sector_byte_stage == " ";
                    if (dir_cat_name_match && sector_byte_stage >= "1" &&
                        sector_byte_stage <= "8")
                        dir_resource_index <= sector_byte_stage - "1";
                end
                5'd5: begin
                    dir_name5 <= sector_byte_stage;
                    dir_cat_name_match <= dir_cat_name_match && sector_byte_stage == " ";
                    dir_pic_name_match <= dir_pic_name_match && sector_byte_stage == " ";
                    dir_dishes_name_match <= dir_dishes_name_match && sector_byte_stage == "S";
                    dir_audio_name_match <= dir_audio_name_match && sector_byte_stage == " ";
                    dir_ad_name_match <= dir_ad_name_match && sector_byte_stage == " ";
                end
                5'd6, 5'd7: begin
                    if (sector_byte_index_stage[4:0] == 5'd6)
                        dir_name6 <= sector_byte_stage;
                    else
                        dir_name7 <= sector_byte_stage;
                    dir_cat_name_match <= dir_cat_name_match && sector_byte_stage == " ";
                    dir_pic_name_match <= dir_pic_name_match && sector_byte_stage == " ";
                    dir_dishes_name_match <= dir_dishes_name_match && sector_byte_stage == " ";
                    dir_audio_name_match <= dir_audio_name_match && sector_byte_stage == " ";
                    dir_ad_name_match <= dir_ad_name_match && sector_byte_stage == " ";
                end
                5'd8: begin
                    dir_name8 <= sector_byte_stage;
                    dir_cat_name_match <= dir_cat_name_match && sector_byte_stage == "B";
                    dir_pic_name_match <= dir_pic_name_match && sector_byte_stage == "B";
                    dir_dishes_name_match <= dir_dishes_name_match && sector_byte_stage == "B";
                    dir_audio_name_match <= dir_audio_name_match && sector_byte_stage == "P";
                    dir_ad_name_match <= dir_ad_name_match && sector_byte_stage == "B";
                end
                5'd9: begin
                    dir_name9 <= sector_byte_stage;
                    dir_cat_name_match <= dir_cat_name_match && sector_byte_stage == "M";
                    dir_pic_name_match <= dir_pic_name_match && sector_byte_stage == "M";
                    dir_dishes_name_match <= dir_dishes_name_match && sector_byte_stage == "M";
                    dir_audio_name_match <= dir_audio_name_match && sector_byte_stage == "C";
                    dir_ad_name_match <= dir_ad_name_match && sector_byte_stage == "M";
                end
                5'd10: begin
                    dir_name10 <= sector_byte_stage;
                    dir_cat_name_match <= dir_cat_name_match && sector_byte_stage == "P";
                    dir_pic_name_match <= dir_pic_name_match && sector_byte_stage == "P";
                    dir_dishes_name_match <= dir_dishes_name_match && sector_byte_stage == "P";
                    dir_audio_name_match <= dir_audio_name_match && sector_byte_stage == "M";
                    dir_ad_name_match <= dir_ad_name_match && sector_byte_stage == "P";
                end
                5'd11: begin
                    dir_audio_match <= 1'b0;
                    dir_catalog_match <= 1'b0;
                    if ((sector_byte_stage & 8'h18) == 8'h00 && sector_byte_stage != 8'h0f &&
                        dir_cat_name_match) begin
                        dir_entry_match <= 1'b1;
                        dir_catalog_match <= 1'b1;
                    end else if ((sector_byte_stage & 8'h18) == 8'h00 && sector_byte_stage != 8'h0f &&
                        dir_pic_name_match) begin
                        dir_entry_match <= 1'b1;
                    end else if ((sector_byte_stage & 8'h18) == 8'h00 && sector_byte_stage != 8'h0f &&
                        dir_dishes_name_match) begin
                        dir_entry_match <= 1'b1;
                        dir_resource_index <= 3'd4;
                    end
                    if ((sector_byte_stage & 8'h18) == 8'h00 && sector_byte_stage != 8'h0f &&
                        dir_audio_name_match) begin
                        dir_audio_match <= 1'b1;
                    end
                    dir_ad_entry <= (sector_byte_stage & 8'h18) == 8'h00 &&
                                    sector_byte_stage != 8'h0f && dir_ad_name_match;
                end
                5'd20: dir_cluster_high[7:0] <= sector_byte_stage;
                5'd21: dir_cluster_high[15:8] <= sector_byte_stage;
                5'd26: dir_cluster_low[7:0] <= sector_byte_stage;
                5'd27: dir_cluster_low[15:8] <= sector_byte_stage;
                5'd28: dir_file_size[7:0] <= sector_byte_stage;
                5'd29: dir_file_size[15:8] <= sector_byte_stage;
                5'd30: dir_file_size[23:16] <= sector_byte_stage;
                5'd31: begin
                    dir_file_size[31:24] <= sector_byte_stage;
                    if (dir_entry_match)
                        dir_commit_pending <= 8'b00000001 << dir_resource_index;
                    if (dir_audio_match) begin
                        audio_cluster <= {dir_cluster_high, dir_cluster_low};
                        audio_size <= {sector_byte_stage, dir_file_size[23:0]};
                        audio_valid <= 1'b1;
                    end
                    if (dir_ad_entry) begin
                        case (dir_ad_index)
                            2'd0: begin
                                ad0_cluster <= {dir_cluster_high, dir_cluster_low};
                                ad0_size <= {sector_byte_stage, dir_file_size[23:0]};
                            end
                            2'd1: begin
                                ad1_cluster <= {dir_cluster_high, dir_cluster_low};
                                ad1_size <= {sector_byte_stage, dir_file_size[23:0]};
                            end
                            2'd2: begin
                                ad2_cluster <= {dir_cluster_high, dir_cluster_low};
                                ad2_size <= {sector_byte_stage, dir_file_size[23:0]};
                            end
                            default: begin
                                ad3_cluster <= {dir_cluster_high, dir_cluster_low};
                                ad3_size <= {sector_byte_stage, dir_file_size[23:0]};
                            end
                        endcase
                        ad_valid[dir_ad_index] <= 1'b1;
                    end
                end
                default: begin end
            endcase
        end

        case (state)
            ST_IDLE: if (scan_start) begin
                fs_error <= ERR_NONE;
                partition_lba <= 32'd0;
                resource_valid <= 8'd0;
                audio_valid <= 1'b0;
                audio_cluster <= 32'd0;
                audio_size <= 32'd0;
                ad_valid <= 4'd0;
                dir_commit_pending <= 8'd0;
                state <= ST_READ0_REQ;
            end

            ST_READ0_REQ: if (!sector_busy) begin
                sector_lba <= 32'd0;
                sector_req <= 1'b1;
                state <= ST_READ0_WAIT;
            end

            ST_READ0_WAIT: if (sector_done_stage) begin
                if (sector_error_stage != 0)
                    finish_scan(ERR_SECTOR);
                else if (sector_buffer[68] != 8'h55 || sector_buffer[69] != 8'haa)
                    finish_scan(ERR_BOOT_SIGNATURE);
                else
                    state <= ST_READ0_PARSE;
            end

            ST_READ0_PARSE: begin
                if ((sector_buffer[0] == 8'heb || sector_buffer[0] == 8'he9) &&
                    le16(11) == 16'd512) begin
                    partition_lba <= 32'd0;
                    state <= ST_BOOT_PARSE;
                end else if (supported_partition(sector_buffer[48])) begin
                    partition_lba <= le32(49);
                    sector_lba <= le32(49);
                    state <= ST_BOOT_REQ;
                end else begin
                    state <= ST_READ0_PART1;
                end
            end

            ST_READ0_PART1: begin
                if (supported_partition(sector_buffer[53])) begin
                    partition_lba <= le32(54);
                    sector_lba <= le32(54);
                    state <= ST_BOOT_REQ;
                end else begin
                    state <= ST_READ0_PART2;
                end
            end

            ST_READ0_PART2: begin
                if (supported_partition(sector_buffer[58])) begin
                    partition_lba <= le32(59);
                    sector_lba <= le32(59);
                    state <= ST_BOOT_REQ;
                end else begin
                    state <= ST_READ0_PART3;
                end
            end

            ST_READ0_PART3: begin
                if (supported_partition(sector_buffer[63])) begin
                    partition_lba <= le32(64);
                    sector_lba <= le32(64);
                    state <= ST_BOOT_REQ;
                end else begin
                    finish_scan(ERR_UNSUPPORTED_BPB);
                end
            end

            ST_BOOT_REQ: if (!sector_busy) begin
                sector_req <= 1'b1;
                state <= ST_BOOT_WAIT;
            end

            ST_BOOT_WAIT: if (sector_done_stage) begin
                if (sector_error_stage != 0)
                    finish_scan(ERR_SECTOR);
                else if (sector_buffer[68] != 8'h55 || sector_buffer[69] != 8'haa)
                    finish_scan(ERR_BOOT_SIGNATURE);
                else
                    state <= ST_BOOT_PARSE;
            end

            ST_BOOT_PARSE: begin
                sectors_per_cluster <= sector_buffer[13];
                sectors_per_cluster_shift <= spc_shift(sector_buffer[13]);
                reserved_sectors <= le16(14);
                fat_count <= sector_buffer[16];
                total_sectors <= le32(32);
                fat_sectors <= le32(36);
                root_cluster <= le32(44);
                fat_start_lba <= partition_lba + le16(14);
                boot_format_valid <= le16(11) == 16'd512 &&
                                     le16(17) == 0 && le16(22) == 0;
                state <= ST_BOOT_VALIDATE;
            end

            ST_BOOT_VALIDATE: begin
                if (!boot_format_valid || !valid_spc(sectors_per_cluster) ||
                    reserved_sectors == 0 ||
                    (fat_count != 1 && fat_count != 2) || total_sectors == 0 ||
                    fat_sectors == 0 || root_cluster < 2) begin
                    finish_scan(ERR_UNSUPPORTED_BPB);
                end else begin
                    state <= ST_LAYOUT;
                end
            end

            ST_LAYOUT: begin
                fat_span <= (fat_count == 2) ? (fat_sectors << 1) : fat_sectors;
                state <= ST_LAYOUT_OVERHEAD;
            end

            ST_LAYOUT_OVERHEAD: begin
                volume_overhead <= reserved_sectors + fat_span;
                state <= ST_LAYOUT_DATA;
            end

            ST_LAYOUT_DATA: begin
                data_start_lba <= partition_lba + volume_overhead;
                data_sector_count <= total_sectors - volume_overhead;
                state <= ST_LAYOUT_MAX;
            end

            ST_LAYOUT_MAX: begin
                data_cluster_count <= data_sector_count >> sectors_per_cluster_shift;
                state <= ST_LAYOUT_CLUSTER;
            end

            ST_LAYOUT_CLUSTER: begin
                max_cluster <= data_cluster_count + 1'b1;
                current_root_cluster <= root_cluster;
                root_cluster_delta <= root_cluster - 2;
                state <= ST_LAYOUT_ROOT_SHIFT;
            end

            ST_LAYOUT_ROOT_SHIFT: begin
                root_sector_offset <= root_cluster_delta << sectors_per_cluster_shift;
                state <= ST_LAYOUT_ROOT_ADD;
            end

            ST_LAYOUT_ROOT_ADD: begin
                root_sector_index <= 8'd0;
                directory_cluster_count <= 16'd1;
                directory_end_seen <= 1'b0;
                sector_lba <= data_start_lba + root_sector_offset;
                state <= ST_ROOT_REQ;
            end

            ST_ROOT_REQ: if (!sector_busy) begin
                dir_entry_match <= 1'b0;
                sector_req <= 1'b1;
                state <= ST_ROOT_WAIT;
            end

            ST_ROOT_WAIT: if (sector_done_stage) begin
                if (sector_error_stage != 0) begin
                    finish_scan(ERR_SECTOR);
                end else if (directory_end_seen) begin
                    finish_scan(ERR_NONE);
                end else if (root_sector_index + 1'b1 < sectors_per_cluster) begin
                    root_sector_index <= root_sector_index + 1'b1;
                    sector_lba <= sector_lba + 1'b1;
                    state <= ST_ROOT_REQ;
                end else begin
                    fat_entry_offset <= {current_root_cluster[6:0], 2'b00};
                    sector_lba <= fat_start_lba + (current_root_cluster >> 7);
                    state <= ST_ROOT_FAT_REQ;
                end
            end

            ST_ROOT_FAT_REQ: if (!sector_busy) begin
                sector_req <= 1'b1;
                state <= ST_ROOT_FAT_WAIT;
            end

            ST_ROOT_FAT_WAIT: if (sector_done_stage) begin
                if (sector_error_stage != 0)
                    finish_scan(ERR_SECTOR);
                else
                    state <= ST_ROOT_FAT_CMP;
            end

            ST_ROOT_FAT_CMP: begin
                fat_next <= {fat_byte3[3:0], fat_byte2, fat_byte1, fat_byte0};
                fat_end_of_chain <= {fat_byte3[3:0], fat_byte2, fat_byte1, fat_byte0} >= 28'hffffff8;
                fat_chain_bad <= {4'd0, fat_byte3[3:0], fat_byte2, fat_byte1, fat_byte0} < 2 ||
                                 {4'd0, fat_byte3[3:0], fat_byte2, fat_byte1, fat_byte0} > max_cluster ||
                                 {4'd0, fat_byte3[3:0], fat_byte2, fat_byte1, fat_byte0} == current_root_cluster ||
                                 directory_cluster_count >= MAX_DIRECTORY_CLUSTERS;
                state <= ST_ROOT_FAT_EVAL;
            end

            ST_ROOT_FAT_EVAL: begin
                next_root_cluster <= {4'd0, fat_next};
                if (fat_end_of_chain) begin
                    if (resource_valid == 8'd0)
                        finish_scan(ERR_RESOURCE_MISSING);
                    else
                        finish_scan(ERR_NONE);
                end else if (fat_chain_bad) begin
                    finish_scan(ERR_DIRECTORY_CHAIN);
                end else begin
                    current_root_cluster <= {4'd0, fat_next};
                    directory_cluster_count <= directory_cluster_count + 1'b1;
                    root_sector_index <= 8'd0;
                    root_cluster_delta <= {4'd0, fat_next} - 2;
                    state <= ST_ROOT_NEXT_SHIFT;
                end
            end

            ST_ROOT_NEXT_SHIFT: begin
                root_sector_offset <= root_cluster_delta << sectors_per_cluster_shift;
                state <= ST_ROOT_NEXT_ADD;
            end

            ST_ROOT_NEXT_ADD: begin
                sector_lba <= data_start_lba + root_sector_offset;
                state <= ST_ROOT_REQ;
            end

            ST_FINISH: begin
                if (resource_valid == 8'd0 && fs_error == ERR_NONE)
                    fs_error <= ERR_RESOURCE_MISSING;
                scan_done <= 1'b1;
                state <= ST_IDLE;
            end

            default: state <= ST_IDLE;
        endcase
    end
end

endmodule
