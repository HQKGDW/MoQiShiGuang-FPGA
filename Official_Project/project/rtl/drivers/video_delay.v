module video_delay
#(
	parameter DATA_WIDTH = 24                       // Video data one clock data width
)
(
	input                       video_clk,          // Video pixel clock
	input                       rst,
	output                      read_en,            // Read data enable
	input[DATA_WIDTH - 1:0]     read_data,          // Read data
	input                      hs,                 // horizontal synchronization
	input                      vs,                 // vertical synchronization
	input                      de,                 // video valid
	input                      photo_mode,
	input                      read_underflow,

	output                      hs_r,                 // horizontal synchronization
	output                      vs_r,                 // vertical synchronization
	output                      de_r,                 // video valid
	output[DATA_WIDTH - 1:0]    vout_data           // video data

);
reg [20:0] hs_d;
reg [20:0] vs_d;
reg [20:0] de_d;
reg [20:0] photo_window_d;
reg[DATA_WIDTH - 1:0]  vout_data_r;
reg [10:0] pixel_x;
reg [9:0] pixel_y;
reg de_q;
reg read_underflow_d;

wire photo_window = de && pixel_x >= 11'd64 && pixel_x < 11'd464 &&
                    pixel_y >= 10'd130 && pixel_y < 10'd422;

assign read_en = photo_mode ? photo_window_d[18] : de_d[18];
assign hs_r = hs_d[20];
assign vs_r = vs_d[20];
assign de_r = de_d[20];
assign vout_data = vout_data_r;
always@(posedge video_clk or posedge rst)
begin
	if(rst == 1'b1)
		vout_data_r <= {DATA_WIDTH{1'b0}};
	else if(read_underflow || read_underflow_d)
		vout_data_r <= {DATA_WIDTH{1'b0}};
	else if(photo_mode ? photo_window_d[19] : de_d[19])
		vout_data_r <= read_data;
	else
		vout_data_r <= {DATA_WIDTH{1'b0}};
end
always @(posedge video_clk or posedge rst)begin
	if(rst)begin
    	hs_d <= 20'b0;
        vs_d <= 20'b0;
		de_d <= 20'b0;
        photo_window_d <= 20'b0;
        pixel_x <= 11'd0;
        pixel_y <= 10'd0;
        de_q <= 1'b0;
		read_underflow_d <= 1'b0;
    end
	else begin
    	
    	hs_d <= {hs_d[19:0],hs};
        vs_d <= {vs_d[19:0],vs};
    	de_d <= {de_d[19:0],de};
        photo_window_d <= {photo_window_d[19:0], photo_window};
        de_q <= de;
		read_underflow_d <= read_underflow;
        if(vs)begin
            pixel_x <= 11'd0;
            pixel_y <= 10'd0;
        end
        else if(de)begin
            pixel_x <= pixel_x + 1'b1;
        end
        else begin
            pixel_x <= 11'd0;
            if(de_q)
                pixel_y <= pixel_y + 1'b1;
        end
    end
end
endmodule
