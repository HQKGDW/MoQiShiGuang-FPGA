`timescale 1ns/1ps

module video_transition_720p #(
    parameter integer H_ACTIVE = 1280,
    parameter integer V_ACTIVE = 720,
    parameter integer TRANSITION_FRAMES = 16,
    parameter integer IRIS_X_SHIFT = 6,
    parameter integer IRIS_Y_SHIFT = 5
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        frame_start,
    input  wire        player_active,
    input  wire [1:0]  requested_index,
    input  wire        auto_enabled,
    input  wire        fade_request,
    input  wire        direct_request,
    input  wire        vs,
    input  wire        de,
    input  wire [23:0] rgb_in,
    output reg  [1:0]  active_index,
    output reg         vs_out,
    output reg         de_out,
    output reg  [23:0] rgb_out,
    output wire        transition_busy,
    output wire        fade_active,
    output wire        wipe_active,
    output wire [4:0]  transition_level,
    output wire [1:0]  transition_kind
);
    localparam [1:0] S_IDLE = 2'd0;
    localparam [1:0] S_OUT  = 2'd1;
    localparam [1:0] S_HOLD = 2'd2;
    localparam [1:0] S_IN   = 2'd3;
    localparam integer WIPE_STEP = H_ACTIVE / TRANSITION_FRAMES;

    reg [1:0] state;
    reg [4:0] level;
    reg       wipe_mode;
    reg       wipe_reverse;
    reg       iris_mode;
    reg [1:0] target_index;
    reg       de_q;
    reg [10:0] pixel_x;
    reg [9:0] pixel_y;
    reg       iris_mask_q;

    wire [4:0] wipe_count = (state == S_OUT) ?
                            TRANSITION_FRAMES - level : level;
    wire [10:0] wipe_boundary = wipe_count * WIPE_STEP;
    wire [10:0] reverse_boundary = H_ACTIVE - wipe_boundary;
    wire [10:0] iris_level_x = {6'd0, level};
    wire [9:0] iris_level_y = {5'd0, level};
    wire [10:0] iris_half_width = iris_level_x << IRIS_X_SHIFT;
    wire [9:0] iris_half_height = iris_level_y << IRIS_Y_SHIFT;
    wire iris_horizontal = (iris_half_width >= H_ACTIVE / 2) ||
                           ((pixel_x >= H_ACTIVE / 2 - iris_half_width) &&
                            (pixel_x < H_ACTIVE / 2 + iris_half_width));
    wire iris_vertical = (iris_half_height >= V_ACTIVE / 2) ||
                         ((pixel_y >= V_ACTIVE / 2 - iris_half_height) &&
                          (pixel_y < V_ACTIVE / 2 + iris_half_height));
    wire iris_mask = iris_horizontal && iris_vertical;
    wire wipe_mask = wipe_reverse ?
                     ((state == S_OUT) ?
                      (pixel_x >= reverse_boundary) :
                      (pixel_x < reverse_boundary)) :
                     ((state == S_OUT) ?
                      (pixel_x < wipe_boundary) :
                      (pixel_x >= wipe_boundary));

    wire [12:0] scaled_r = rgb_in[23:16] * level;
    wire [12:0] scaled_g = rgb_in[15:8] * level;
    wire [12:0] scaled_b = rgb_in[7:0] * level;
    wire [7:0] faded_r = scaled_r / TRANSITION_FRAMES;
    wire [7:0] faded_g = scaled_g / TRANSITION_FRAMES;
    wire [7:0] faded_b = scaled_b / TRANSITION_FRAMES;

    assign transition_busy = state != S_IDLE;
    assign fade_active = transition_busy && !wipe_mode;
    assign wipe_active = transition_busy && wipe_mode;
    assign transition_level = level;
    assign transition_kind = wipe_mode ? 2'd2 :
                             transition_busy ? 2'd1 : 2'd0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            level <= TRANSITION_FRAMES;
            wipe_mode <= 1'b0;
            wipe_reverse <= 1'b0;
            iris_mode <= 1'b0;
            target_index <= 2'd0;
            active_index <= 2'd0;
        end else if (frame_start) begin
            if (!player_active) begin
                state <= S_IDLE;
                level <= TRANSITION_FRAMES;
                wipe_mode <= 1'b0;
                wipe_reverse <= 1'b0;
                iris_mode <= 1'b0;
                target_index <= requested_index;
                active_index <= requested_index;
            end else begin
                case (state)
                S_IDLE: begin
                    level <= TRANSITION_FRAMES;
                    if (direct_request) begin
                        target_index <= requested_index;
                        active_index <= requested_index;
                        state <= S_IDLE;
                        iris_mode <= 1'b0;
                    end else if (fade_request) begin
                        target_index <= requested_index;
                        state <= S_OUT;
                        wipe_mode <= 1'b0;
                        wipe_reverse <= 1'b0;
                        iris_mode <= 1'b1;
                    end else if (requested_index != active_index) begin
                        target_index <= requested_index;
                        state <= S_OUT;
                        wipe_mode <= !auto_enabled;
                        wipe_reverse <= requested_index != (active_index + 2'd1);
                        iris_mode <= auto_enabled;
                    end
                end
                S_OUT: begin
                    if (level > 1'b1) begin
                        level <= level - 1'b1;
                    end else begin
                        level <= 5'd0;
                        active_index <= target_index;
                        state <= S_HOLD;
                    end
                end
                S_HOLD: begin
                    level <= 5'd0;
                    state <= S_IN;
                end
                S_IN: begin
                    if (level < TRANSITION_FRAMES - 1) begin
                        level <= level + 1'b1;
                    end else begin
                        level <= TRANSITION_FRAMES;
                        state <= S_IDLE;
                        wipe_mode <= 1'b0;
                        wipe_reverse <= 1'b0;
                        iris_mode <= 1'b0;
                    end
                end
                default: begin
                    state <= S_IDLE;
                    level <= TRANSITION_FRAMES;
                    wipe_mode <= 1'b0;
                    wipe_reverse <= 1'b0;
                    iris_mode <= 1'b0;
                end
                endcase
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            de_q <= 1'b0;
            pixel_x <= 11'd0;
            pixel_y <= 10'd0;
            iris_mask_q <= 1'b0;
            vs_out <= 1'b0;
            de_out <= 1'b0;
            rgb_out <= 24'd0;
        end else begin
            de_q <= de;
            if (!de)
                pixel_x <= 11'd0;
            else if (!de_q)
                pixel_x <= 11'd1;
            else
                pixel_x <= pixel_x + 1'b1;
            if (vs)
                pixel_y <= 10'd0;
            else if (de && !de_q)
                pixel_y <= pixel_y + 1'b1;
            iris_mask_q <= iris_mask;

            vs_out <= vs;
            de_out <= de;
            if (!player_active || state == S_IDLE)
                rgb_out <= rgb_in;
            else if (wipe_mode)
                rgb_out <= (de && wipe_mask) ? 24'd0 : rgb_in;
            else if (iris_mode && state == S_IN)
                rgb_out <= (de && iris_mask_q) ? {faded_r, faded_g, faded_b} : 24'd0;
            else
                rgb_out <= {faded_r, faded_g, faded_b};
        end
    end
endmodule

module order_ui_transition_720p #(
    parameter integer H_ACTIVE = 1280,
    parameter integer V_ACTIVE = 720,
    parameter integer TRANSITION_FRAMES = 16
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        frame_start,
    input  wire [1:0]  requested_menu,
    input  wire [1:0]  requested_dish,
    input  wire        vs,
    input  wire        de,
    input  wire [23:0] rgb_in,
    output reg  [1:0]  active_menu,
    output reg  [1:0]  active_dish,
    output reg         vs_out,
    output reg         de_out,
    output reg  [23:0] rgb_out
);
    localparam [1:0] S_IDLE = 2'd0;
    localparam [1:0] S_OUT  = 2'd1;
    localparam [1:0] S_IN   = 2'd2;
    localparam integer WIPE_STEP = H_ACTIVE / TRANSITION_FRAMES;

    reg [1:0] state;
    reg [4:0] level;
    reg       wipe_mode;
    reg       wipe_reverse;
    reg       de_q;
    reg [10:0] pixel_x;
    reg [9:0] pixel_y;
    reg       iris_mask_q;
    reg [10:0] wipe_boundary;
    reg [10:0] reverse_boundary;

    wire request_changed = requested_menu != active_menu ||
                           requested_menu == 2'd1 && requested_dish != active_dish;
    wire [10:0] iris_half_width = {6'd0, level} << 6;
    wire [9:0] iris_half_height = {5'd0, level} << 5;
    wire iris_horizontal = iris_half_width >= H_ACTIVE / 2 ||
                           pixel_x >= H_ACTIVE / 2 - iris_half_width &&
                           pixel_x < H_ACTIVE / 2 + iris_half_width;
    wire iris_vertical = iris_half_height >= V_ACTIVE / 2 ||
                         pixel_y >= V_ACTIVE / 2 - iris_half_height &&
                         pixel_y < V_ACTIVE / 2 + iris_half_height;
    wire iris_mask = iris_horizontal && iris_vertical;
    wire wipe_mask = wipe_reverse ?
                     (state == S_OUT ? pixel_x >= reverse_boundary :
                      pixel_x < reverse_boundary) :
                     (state == S_OUT ? pixel_x < wipe_boundary :
                      pixel_x >= wipe_boundary);
    wire [12:0] scaled_r = rgb_in[23:16] * level;
    wire [12:0] scaled_g = rgb_in[15:8] * level;
    wire [12:0] scaled_b = rgb_in[7:0] * level;
    wire [7:0] faded_r = scaled_r / TRANSITION_FRAMES;
    wire [7:0] faded_g = scaled_g / TRANSITION_FRAMES;
    wire [7:0] faded_b = scaled_b / TRANSITION_FRAMES;
    wire [23:0] faded_rgb = {faded_r, faded_g, faded_b};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            level <= TRANSITION_FRAMES;
            wipe_mode <= 1'b0;
            wipe_reverse <= 1'b0;
            active_menu <= 2'd0;
            active_dish <= 2'd0;
            wipe_boundary <= 11'd0;
            reverse_boundary <= H_ACTIVE;
        end else if (frame_start) begin
            case (state)
            S_IDLE: begin
                level <= TRANSITION_FRAMES;
                wipe_boundary <= 11'd0;
                reverse_boundary <= H_ACTIVE;
                if (request_changed) begin
                    state <= S_OUT;
                    wipe_mode <= requested_menu == active_menu &&
                                 requested_menu == 2'd1;
                    wipe_reverse <= requested_dish != active_dish + 2'd1;
                end
            end
            S_OUT: begin
                if (level > 1'b1) begin
                    level <= level - 1'b1;
                    wipe_boundary <= wipe_boundary + WIPE_STEP;
                    reverse_boundary <= reverse_boundary - WIPE_STEP;
                end else begin
                    level <= 5'd0;
                    wipe_boundary <= 11'd0;
                    reverse_boundary <= H_ACTIVE;
                    active_menu <= requested_menu;
                    active_dish <= requested_dish;
                    state <= S_IN;
                end
            end
            S_IN: begin
                if (level < TRANSITION_FRAMES - 1) begin
                    level <= level + 1'b1;
                    wipe_boundary <= wipe_boundary + WIPE_STEP;
                    reverse_boundary <= reverse_boundary - WIPE_STEP;
                end else begin
                    level <= TRANSITION_FRAMES;
                    wipe_boundary <= H_ACTIVE;
                    reverse_boundary <= 11'd0;
                    state <= S_IDLE;
                    wipe_mode <= 1'b0;
                end
            end
            default: begin
                state <= S_IDLE;
                level <= TRANSITION_FRAMES;
                wipe_mode <= 1'b0;
                wipe_boundary <= 11'd0;
                reverse_boundary <= H_ACTIVE;
            end
            endcase
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            de_q <= 1'b0;
            pixel_x <= 11'd0;
            pixel_y <= 10'd0;
            iris_mask_q <= 1'b0;
            vs_out <= 1'b0;
            de_out <= 1'b0;
            rgb_out <= 24'd0;
        end else begin
            de_q <= de;
            if (!de)
                pixel_x <= 11'd0;
            else if (!de_q)
                pixel_x <= 11'd1;
            else
                pixel_x <= pixel_x + 1'b1;
            if (vs)
                pixel_y <= 10'd0;
            else if (de && !de_q)
                pixel_y <= pixel_y + 1'b1;
            iris_mask_q <= iris_mask;
            vs_out <= vs;
            de_out <= de;
            if (state == S_IDLE)
                rgb_out <= rgb_in;
            else if (wipe_mode)
                rgb_out <= de && wipe_mask ? 24'd0 : rgb_in;
            else if (state == S_IN)
                rgb_out <= de && iris_mask_q ? faded_rgb : 24'd0;
            else
                rgb_out <= faded_rgb;
        end
    end
endmodule

module thumbnail_transition_control (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       frame_start,
    input  wire       thumbnail_mode,
    input  wire       thumbnail_exit_toggle,
    input  wire       transition_busy,
    input  wire [4:0] transition_level,
    output reg        thumbnail_mode_frame,
    output reg        fade_request,
    output reg        direct_request
);
    (* async_reg = "true" *) reg thumbnail_mode_sync0;
    (* async_reg = "true" *) reg thumbnail_mode_sync1;
    (* async_reg = "true" *) reg [2:0] thumbnail_exit_sync;
    reg thumbnail_enter_pending;

    wire thumbnail_enter_event = thumbnail_mode_sync0 && !thumbnail_mode_sync1;
    wire thumbnail_exit_event = thumbnail_exit_sync[2] != thumbnail_exit_sync[1];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            thumbnail_mode_sync0 <= 1'b0;
            thumbnail_mode_sync1 <= 1'b0;
            thumbnail_exit_sync <= 3'b000;
            thumbnail_enter_pending <= 1'b0;
            thumbnail_mode_frame <= 1'b0;
            fade_request <= 1'b0;
            direct_request <= 1'b0;
        end else begin
            thumbnail_mode_sync0 <= thumbnail_mode;
            thumbnail_mode_sync1 <= thumbnail_mode_sync0;
            thumbnail_exit_sync <= {thumbnail_exit_sync[1:0], thumbnail_exit_toggle};

            if (thumbnail_exit_event) begin
                thumbnail_enter_pending <= 1'b0;
                fade_request <= 1'b0;
                direct_request <= 1'b1;
            end else if (thumbnail_enter_event) begin
                thumbnail_enter_pending <= 1'b1;
                fade_request <= 1'b1;
                direct_request <= 1'b0;
            end else if (frame_start) begin
                if (fade_request && !transition_busy)
                    fade_request <= 1'b0;
                if (direct_request && !transition_busy)
                    direct_request <= 1'b0;
                if (thumbnail_enter_pending && transition_busy && transition_level == 5'd0)
                    thumbnail_enter_pending <= 1'b0;
            end

            if (frame_start) begin
                if (direct_request && !transition_busy)
                    thumbnail_mode_frame <= 1'b0;
                else if (thumbnail_enter_pending) begin
                    if (transition_busy && transition_level == 5'd0)
                        thumbnail_mode_frame <= 1'b1;
                end else if (thumbnail_mode_sync1)
                    thumbnail_mode_frame <= 1'b1;
            end
        end
    end
endmodule
