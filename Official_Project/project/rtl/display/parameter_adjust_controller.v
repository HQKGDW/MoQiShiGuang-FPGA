`timescale 1ns/1ps

module parameter_adjust_controller #(
    parameter integer CLK_FREQ_HZ = 100_000_000,
    parameter integer DEBOUNCE_MS = 10,
    parameter integer LONG_PRESS_MS = 500,
    parameter integer REPEAT_MS = 60,
    parameter integer DISPLAY_HOLD_MS = 2000,
    parameter [7:0] DEFAULT_BRIGHTNESS = 8'd100,
    parameter [7:0] DEFAULT_CONTRAST   = 8'd50,
    parameter [7:0] DEFAULT_VOLUME     = 8'd100,
    parameter [3:0] DEFAULT_TICKER_SPEED = 4'd5,
    parameter [3:0] DEFAULT_AUTO_INTERVAL = 4'd4,     // level 4 = 8 s
    parameter [3:0] DEFAULT_WAVE_COLOR = 4'd1,
    parameter [7:0] STEP               = 8'd1
) (
    input  wire       clk,
    input  wire       rst,
    input  wire       key_increase,
    input  wire       key_decrease,
    input  wire       key_toggle,       // K3: music on / off in mode 0111
    input  wire       popup_on_switch,  // show the selected parameter when a switch moves
    input  wire       sw1,
    input  wire       sw2,
    input  wire       sw3,
    input  wire       sw4,
    output reg [7:0] brightness,
    output reg [7:0] contrast,
    output reg [7:0] volume,
    output reg [3:0] ticker_speed,     // 1 slowest .. 10 fastest
    output reg [3:0] auto_interval,    // 1 shortest (5 s) .. 11 longest (15 s)
    output reg [3:0] wave_color,       // colour 1..10 of waveform and bars
    output reg       music_on,         // background music playing (default on)
    output reg       display_active,
    output reg [2:0] selected_parameter
);
    localparam integer DISPLAY_HOLD_CYCLES = (CLK_FREQ_HZ / 1000) * DISPLAY_HOLD_MS;
    localparam integer LONG_PRESS_CYCLES = (CLK_FREQ_HZ / 1000) * LONG_PRESS_MS;
    localparam integer REPEAT_CYCLES = (CLK_FREQ_HZ / 1000) * REPEAT_MS;
    wire key_increase_press;
    wire key_decrease_press;
    wire key_increase_stable;
    wire key_decrease_stable;
    wire key_toggle_press;
    // Switch levels are asynchronous; synchronise before comparing them.
    // Modes {SW4, SW3, SW2, SW1}: 0001 brightness .. 0110 colour; in 0111
    // (music) only K3 acts: it switches the music on and off.
    reg  [3:0] switch_sync0;
    reg  [3:0] switch_sync1;
    reg  [3:0] selected_q;
    wire [3:0] selected = switch_sync1;
    wire       selection_changed = selected != selected_q;
    wire       adjustable = selected != 4'b0000 && selected <= 4'b0110;
    // The popup and seven-segment display show selected_parameter. It only
    // follows the switches when a value is actually adjusted, so a fading
    // popup keeps its own value instead of jumping to another one (or to 0).
    wire [2:0] selected_code = selected[2:0] - 3'd1;   // 0001 -> 0 .. 0111 -> 6
    reg [31:0] display_hold_count;
    reg        increase_pending;
    reg        decrease_pending;
    reg        increase_repeat;
    reg        decrease_repeat;
    reg [31:0] increase_hold_count;
    reg [31:0] decrease_hold_count;
    reg [31:0] increase_repeat_count;
    reg [31:0] decrease_repeat_count;

    key_press_debounce #(
        .CLK_FREQ_HZ (CLK_FREQ_HZ),
        .DEBOUNCE_MS (DEBOUNCE_MS)
    ) u_key_increase_debounce (
        .clk              (clk),
        .rst              (rst),
        .button_in       (key_increase),
        .press_pulse     (key_increase_press),
        .button_stable_out(key_increase_stable)
    );

    key_press_debounce #(
        .CLK_FREQ_HZ (CLK_FREQ_HZ),
        .DEBOUNCE_MS (DEBOUNCE_MS)
    ) u_key_decrease_debounce (
        .clk              (clk),
        .rst              (rst),
        .button_in        (key_decrease),
        .press_pulse      (key_decrease_press),
        .button_stable_out(key_decrease_stable)
    );

    key_press_debounce #(
        .CLK_FREQ_HZ (CLK_FREQ_HZ),
        .DEBOUNCE_MS (DEBOUNCE_MS)
    ) u_key_toggle_debounce (
        .clk              (clk),
        .rst              (rst),
        .button_in        (key_toggle),
        .press_pulse      (key_toggle_press),
        .button_stable_out()
    );

    function [7:0] step_up;
        input [7:0] value;
        begin
            if (value >= 8'd100 - STEP)
                step_up = 8'd100;
            else
                step_up = value + STEP;
        end
    endfunction

    function [3:0] speed_up;
        input [3:0] value;
        begin
            speed_up = (value >= 4'd10) ? 4'd10 : value + 1'b1;
        end
    endfunction

    function [3:0] speed_down;
        input [3:0] value;
        begin
            speed_down = (value <= 4'd1) ? 4'd1 : value - 1'b1;
        end
    endfunction

    // Interval: 11 levels, one per second from 5 s to 15 s.
    function [3:0] interval_up;
        input [3:0] value;
        begin
            interval_up = (value >= 4'd11) ? 4'd11 : value + 1'b1;
        end
    endfunction

    function [7:0] step_down;
        input [7:0] value;
        begin
            if (value <= STEP)
                step_down = 8'd0;
            else
                step_down = value - STEP;
        end
    endfunction

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            brightness         <= DEFAULT_BRIGHTNESS;
            contrast           <= DEFAULT_CONTRAST;
            volume             <= DEFAULT_VOLUME;
            ticker_speed       <= DEFAULT_TICKER_SPEED;
            auto_interval      <= DEFAULT_AUTO_INTERVAL;
            wave_color         <= DEFAULT_WAVE_COLOR;
            music_on           <= 1'b1;
            display_active     <= 1'b0;
            display_hold_count <= 32'd0;
            selected_parameter <= 3'd3;    // the reset value is never shown
            switch_sync0       <= 4'b0000;
            switch_sync1       <= 4'b0000;
            selected_q         <= 4'b0000;
            increase_pending   <= 1'b0;
            decrease_pending   <= 1'b0;
            increase_repeat    <= 1'b0;
            decrease_repeat    <= 1'b0;
            increase_hold_count <= 32'd0;
            decrease_hold_count <= 32'd0;
            increase_repeat_count <= 32'd0;
            decrease_repeat_count <= 32'd0;
        end else begin
            switch_sync0 <= {~sw4, ~sw3, ~sw2, ~sw1};
            switch_sync1 <= switch_sync0;
            selected_q   <= selected;
            if (display_active) begin
                if (display_hold_count >= DISPLAY_HOLD_CYCLES - 1) begin
                    display_hold_count <= 32'd0;
                    display_active <= 1'b0;
                end else begin
                    display_hold_count <= display_hold_count + 1'b1;
                end
            end

            if (selection_changed) begin
                // A switch move shows the newly selected parameter (0001-0111)
                // with its current value; a held key stops repeating and a
                // fresh K1/K2 press adjusts it. Other modes end the popup.
                display_hold_count <= 32'd0;
                if (popup_on_switch && selected != 4'b0000 && selected <= 4'b0111) begin
                    display_active <= 1'b1;
                    selected_parameter <= selected_code;
                end else begin
                    display_active <= 1'b0;
                end
            end

            // K3 in mode 0111 switches the music on and off and shows the popup.
            if (selected == 4'b0111 && !selection_changed && key_toggle_press) begin
                music_on <= !music_on;
                display_active <= 1'b1;
                selected_parameter <= selected_code;
                display_hold_count <= 32'd0;
            end

            if (!adjustable || selection_changed) begin
                increase_pending <= 1'b0;
                decrease_pending <= 1'b0;
                increase_repeat <= 1'b0;
                decrease_repeat <= 1'b0;
                increase_hold_count <= 32'd0;
                decrease_hold_count <= 32'd0;
                increase_repeat_count <= 32'd0;
                decrease_repeat_count <= 32'd0;
            end else begin
                if (key_increase_press) begin
                    increase_pending <= 1'b1;
                    increase_hold_count <= 32'd0;
                    increase_repeat_count <= 32'd0;
                end
                if (key_decrease_press) begin
                    decrease_pending <= 1'b1;
                    decrease_hold_count <= 32'd0;
                    decrease_repeat_count <= 32'd0;
                end

                if (!key_increase_stable) begin
                    if (increase_pending) begin
                        if (increase_hold_count >= LONG_PRESS_CYCLES - 1) begin
                            increase_pending <= 1'b0;
                            increase_repeat <= 1'b1;
                            increase_repeat_count <= 32'd0;
                            display_active <= 1'b1;
                            selected_parameter <= selected_code;
                            display_hold_count <= 32'd0;
                            case (selected)
                                4'b0001: brightness   <= step_up(brightness);
                                4'b0010: contrast     <= step_up(contrast);
                                4'b0011: volume       <= step_up(volume);
                                4'b0100: ticker_speed <= speed_up(ticker_speed);    // K1: faster
                                4'b0101: auto_interval <= interval_up(auto_interval); // K1: longer
                                4'b0110: wave_color <= speed_up(wave_color);          // K1: next colour
                                default: begin end
                            endcase
                        end else begin
                            increase_hold_count <= increase_hold_count + 1'b1;
                        end
                    end else if (increase_repeat) begin
                        if (increase_repeat_count >= REPEAT_CYCLES - 1) begin
                            increase_repeat_count <= 32'd0;
                            display_active <= 1'b1;
                            selected_parameter <= selected_code;
                            display_hold_count <= 32'd0;
                            case (selected)
                                4'b0001: brightness   <= step_up(brightness);
                                4'b0010: contrast     <= step_up(contrast);
                                4'b0011: volume       <= step_up(volume);
                                4'b0100: ticker_speed <= speed_up(ticker_speed);    // K1: faster
                                4'b0101: auto_interval <= interval_up(auto_interval); // K1: longer
                                4'b0110: wave_color <= speed_up(wave_color);          // K1: next colour
                                default: begin end
                            endcase
                        end else begin
                            increase_repeat_count <= increase_repeat_count + 1'b1;
                        end
                    end
                end else begin
                    if (increase_pending) begin
                        display_active <= 1'b1;
                        selected_parameter <= selected_code;
                        display_hold_count <= 32'd0;
                        case (selected)
                            4'b0001: brightness   <= step_up(brightness);
                            4'b0010: contrast     <= step_up(contrast);
                            4'b0011: volume       <= step_up(volume);
                            4'b0100: ticker_speed <= speed_up(ticker_speed);    // K1: faster
                            4'b0101: auto_interval <= interval_up(auto_interval); // K1: longer
                            4'b0110: wave_color <= speed_up(wave_color);          // K1: next colour
                            default: begin end
                        endcase
                    end
                    increase_pending <= 1'b0;
                    increase_repeat <= 1'b0;
                    increase_hold_count <= 32'd0;
                    increase_repeat_count <= 32'd0;
                end

                if (!key_decrease_stable) begin
                    if (decrease_pending) begin
                        if (decrease_hold_count >= LONG_PRESS_CYCLES - 1) begin
                            decrease_pending <= 1'b0;
                            decrease_repeat <= 1'b1;
                            decrease_repeat_count <= 32'd0;
                            display_active <= 1'b1;
                            selected_parameter <= selected_code;
                            display_hold_count <= 32'd0;
                            case (selected)
                                4'b0001: brightness   <= step_down(brightness);
                                4'b0010: contrast     <= step_down(contrast);
                                4'b0011: volume       <= step_down(volume);
                                4'b0100: ticker_speed <= speed_down(ticker_speed);  // K2: slower
                                4'b0101: auto_interval <= speed_down(auto_interval); // K2: shorter
                                4'b0110: wave_color <= speed_down(wave_color);       // K2: previous
                                default: begin end
                            endcase
                        end else begin
                            decrease_hold_count <= decrease_hold_count + 1'b1;
                        end
                    end else if (decrease_repeat) begin
                        if (decrease_repeat_count >= REPEAT_CYCLES - 1) begin
                            decrease_repeat_count <= 32'd0;
                            display_active <= 1'b1;
                            selected_parameter <= selected_code;
                            display_hold_count <= 32'd0;
                            case (selected)
                                4'b0001: brightness   <= step_down(brightness);
                                4'b0010: contrast     <= step_down(contrast);
                                4'b0011: volume       <= step_down(volume);
                                4'b0100: ticker_speed <= speed_down(ticker_speed);  // K2: slower
                                4'b0101: auto_interval <= speed_down(auto_interval); // K2: shorter
                                4'b0110: wave_color <= speed_down(wave_color);       // K2: previous
                                default: begin end
                            endcase
                        end else begin
                            decrease_repeat_count <= decrease_repeat_count + 1'b1;
                        end
                    end
                end else begin
                    if (decrease_pending) begin
                        display_active <= 1'b1;
                        selected_parameter <= selected_code;
                        display_hold_count <= 32'd0;
                        case (selected)
                            4'b0001: brightness   <= step_down(brightness);
                            4'b0010: contrast     <= step_down(contrast);
                            4'b0011: volume       <= step_down(volume);
                            4'b0100: ticker_speed <= speed_down(ticker_speed);  // K2: slower
                            4'b0101: auto_interval <= speed_down(auto_interval); // K2: shorter
                            4'b0110: wave_color <= speed_down(wave_color);       // K2: previous
                            default: begin end
                        endcase
                    end
                    decrease_pending <= 1'b0;
                    decrease_repeat <= 1'b0;
                    decrease_hold_count <= 32'd0;
                    decrease_repeat_count <= 32'd0;
                end
            end
        end
    end
endmodule
