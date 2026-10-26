`timescale 1ns/1ps

// Short melodies at 48 kHz: 0 into the welcome scene (E5 G5 B5 E6), 1 the
// kitchen accepted an order (A5 E5 A5), 2 into the main screen (G5 C6), 3 the
// order is ready (C6 E6 G6 C7). A new trigger restarts the player.
module transition_chime #(
    parameter integer NOTE_SAMPLES = 6000,
    parameter integer GAP_SAMPLES = 900
) (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               trigger,
    input  wire [1:0]         melody,
    input  wire               sample_tick,
    output reg                active,
    output reg signed [23:0]  sample_left,
    output reg signed [23:0]  sample_right
);
    reg [1:0]  tune;
    reg [1:0]  note_index;
    reg [13:0] note_count;
    reg [10:0] gap_count;
    reg [31:0] phase;
    reg [7:0]  envelope;

    // Phase increment per sample (f * 2^32 / 48000); 0 ends the melody.
    function [31:0] note_increment;
        input [1:0] m;
        input [1:0] n;
        begin
            case ({m, n})
                4'b00_00: note_increment = 32'd58_988_691;    // E5
                4'b00_01: note_increment = 32'd70_150_238;    // G5
                4'b00_10: note_increment = 32'd88_384_163;    // B5
                4'b00_11: note_increment = 32'd117_978_278;   // E6
                4'b01_00: note_increment = 32'd78_741_067;    // A5
                4'b01_01: note_increment = 32'd58_988_691;    // E5
                4'b01_10: note_increment = 32'd78_741_067;    // A5
                4'b10_00: note_increment = 32'd70_150_238;    // G5
                4'b10_01: note_increment = 32'd93_639_235;    // C6
                4'b11_00: note_increment = 32'd93_639_235;    // C6
                4'b11_01: note_increment = 32'd117_978_278;   // E6
                4'b11_10: note_increment = 32'd140_300_654;   // G6
                4'b11_11: note_increment = 32'd187_278_917;   // C7
                default:  note_increment = 32'd0;
            endcase
        end
    endfunction

    function signed [15:0] sine;
        input [3:0] index;
        begin
            case (index)
                4'd0: sine = 16'sd0;      4'd1: sine = 16'sd3061;   4'd2: sine = 16'sd5657;
                4'd3: sine = 16'sd7391;   4'd4: sine = 16'sd8000;   4'd5: sine = 16'sd7391;
                4'd6: sine = 16'sd5657;   4'd7: sine = 16'sd3061;   4'd8: sine = 16'sd0;
                4'd9: sine = -16'sd3061;  4'd10: sine = -16'sd5657; 4'd11: sine = -16'sd7391;
                4'd12: sine = -16'sd8000; 4'd13: sine = -16'sd7391; 4'd14: sine = -16'sd5657;
                default: sine = -16'sd3061;
            endcase
        end
    endfunction

    wire [31:0] increment = note_increment(tune, note_index);
    wire [31:0] next_increment = note_increment(tune, note_index + 1'b1);
    wire signed [23:0] scaled = ($signed(sine(phase[31:28])) * $signed({1'b0, envelope})) >>> 1;

    always @* begin
        if (note_count < 14'd512)
            envelope = note_count[8:1];
        else if (note_count >= NOTE_SAMPLES - 1024)
            envelope = (NOTE_SAMPLES - note_count) >> 2;
        else
            envelope = 8'd255;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            active <= 1'b0; tune <= 2'd0; note_index <= 2'd0; note_count <= 14'd0;
            gap_count <= 11'd0; phase <= 32'd0; sample_left <= 24'sd0; sample_right <= 24'sd0;
        end else if (trigger) begin
            active <= 1'b1; tune <= melody; note_index <= 2'd0; note_count <= 14'd0;
            gap_count <= 11'd0; phase <= 32'd0;
        end else if (active && sample_tick) begin
            if (gap_count != 0) begin
                sample_left <= 24'sd0;
                sample_right <= 24'sd0;
                phase <= 32'd0;
                gap_count <= (gap_count == GAP_SAMPLES - 1) ? 11'd0 : gap_count + 1'b1;
            end else if (note_count == NOTE_SAMPLES - 1) begin
                sample_left <= 24'sd0;
                sample_right <= 24'sd0;
                note_count <= 14'd0;
                if (note_index == 2'd3 || next_increment == 0) begin
                    active <= 1'b0;
                end else begin
                    note_index <= note_index + 1'b1;
                    gap_count <= 11'd1;
                end
            end else begin
                phase <= phase + increment;
                sample_left <= scaled;
                sample_right <= scaled;
                note_count <= note_count + 1'b1;
            end
        end else if (!active) begin
            sample_left <= 24'sd0;
            sample_right <= 24'sd0;
        end
    end
endmodule
