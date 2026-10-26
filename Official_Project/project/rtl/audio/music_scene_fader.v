`timescale 1ns/1ps

// Background music that follows the picture. The track to play comes from
// what is on screen (the caller maps categories, adverts and thumbnails to
// tracks); when it changes, the music fades out together with the picture
// transition, the player is switched to the new track, and the music fades
// in again once the new stream is flowing. Switching the music off or on
// fades the same way.
//
// play_on / play_track drive the player (another clock domain samples them
// with a stability check). The fade runs on the 48 kHz sample ticks:
// FADE_DIV ticks per step, 255 steps (default 0.27 s, about one picture
// transition half of 16 frames). After a switch the gain stays at 0 for
// HOLD_TICKS (the request crossing into the player's clock and its FIFO
// restart) and then rises only while stream_active.
module music_scene_fader #(
    parameter integer FADE_DIV = 50,
    parameter integer HOLD_TICKS = 480
) (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               sample_tick,
    input  wire               want_on,        // music switched on (K3, mode 0111)
    input  wire [2:0]         target_track,   // 1..6 for the current screen
    input  wire               stream_active,  // the player delivers PCM
    input  wire signed [15:0] sample_in,
    output reg                play_on,
    output reg  [2:0]         play_track,
    output reg  [7:0]         gain,
    output reg  signed [15:0] sample_out      // sample_in * gain, two clocks later
);
    reg [5:0]  step_count;
    reg [12:0] hold_count;
    wire settled = play_on == want_on && (!want_on || play_track == target_track);
    reg signed [24:0] product;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            play_on <= 1'b0;
            play_track <= 3'd1;
            gain <= 8'd0;
            step_count <= 6'd0;
            hold_count <= 13'd0;
        end else if (sample_tick) begin
            if (hold_count != 0) begin
                hold_count <= hold_count - 1'b1;
            end else if (!settled) begin
                if (play_on && gain != 0) begin
                    // Fade out the track that is playing.
                    if (step_count >= FADE_DIV - 1) begin
                        step_count <= 6'd0;
                        gain <= gain - 1'b1;
                    end else begin
                        step_count <= step_count + 1'b1;
                    end
                end else begin
                    // Silent: switch the player to the new state.
                    play_on <= want_on;
                    play_track <= target_track;
                    gain <= 8'd0;
                    step_count <= 6'd0;
                    hold_count <= HOLD_TICKS;
                end
            end else if (play_on && gain != 8'd255 && stream_active) begin
                // Fade in the new track.
                if (step_count >= FADE_DIV - 1) begin
                    step_count <= 6'd0;
                    gain <= gain + 1'b1;
                end else begin
                    step_count <= step_count + 1'b1;
                end
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            product <= 25'sd0;
            sample_out <= 16'sd0;
        end else begin
            product <= sample_in * $signed({1'b0, gain});
            sample_out <= product[23:8];
        end
    end
endmodule
