`timescale 1ns/1ps

// Selects the background music track. AUDIO.PCM holds all tracks behind a
// header (see wav_stream_player); this module passes the file extent on,
// turns the selected track number (1..8) into the player's index and drops
// play_enable for a few clocks on every change, which resets the player's
// FIFO so the new track starts cleanly.
module audio_track_control (
    input  wire        clk,
    input  wire        rst,
    input  wire        audio_available,
    input  wire        display_ready,
    input  wire [2:0]  requested_track,    // track number - 1
    input  wire [31:0] file_start_lba,
    input  wire [31:0] file_total_sectors,
    output reg         play_enable,
    output reg  [2:0]  active_track,
    output wire [31:0] track_start_lba,     // the file: the player reads its header
    output wire [31:0] track_total_sectors
);
    reg [2:0] restart_count;

    assign track_start_lba = file_start_lba;
    assign track_total_sectors = file_total_sectors;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            play_enable <= 1'b0;
            active_track <= 3'd0;
            restart_count <= 3'd0;
        end else if (!audio_available || !display_ready || file_total_sectors == 0) begin
            play_enable <= 1'b0;
            active_track <= requested_track;
            restart_count <= 3'd0;
        end else if (requested_track != active_track) begin
            play_enable <= 1'b0;
            active_track <= requested_track;
            restart_count <= 3'd7;
        end else if (restart_count != 3'd0) begin
            play_enable <= 1'b0;
            restart_count <= restart_count - 1'b1;
        end else begin
            play_enable <= 1'b1;
        end
    end
endmodule
