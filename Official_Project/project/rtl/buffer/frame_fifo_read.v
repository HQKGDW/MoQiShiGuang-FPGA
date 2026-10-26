`timescale 1ns/1ps
module frame_fifo_read
#
(
	parameter MEM_DATA_BITS          = 32,
	parameter ADDR_BITS              = 21,
	parameter BURST_BITS             = 9,
	parameter FIFO_DEPTH             = 512,
	parameter BURST_SIZE             = 128
)               
(
	input                            rst,                  
	input                            mem_clk,                    // external memory controller user interface clock
	input							 Sdr_init_done,
	input							 Sdr_init_ref_vld,
    input							 Sdr_busy,
    input							 Sdr_rd_en,
	input							 App_wr_busy,
    output							 O_rd_busy,
	/*
    output reg                       rd_burst_req,               // to external memory controller,send out a burst read request  
	output reg[BURST_BITS - 1:0]     rd_burst_len,               // to external memory controller,data length of the burst read request, not bytes 
	output reg[ADDR_BITS - 1:0]      rd_burst_addr,              // to external memory controller,base address of the burst read request
	input                            rd_burst_data_valid,        // from external memory controller,read request data valid    
	input                            rd_burst_finish,            // from external memory controller,burst read finish
	*/
	output 							 App_rd_en,
	output  [ADDR_BITS - 1:0]		 App_rd_addr,
	
	input                            read_req,                   // data read module read request,keep '1' until read_req_ack = '1'
	output reg                       read_req_ack,               // data read module read request response
	output                           read_finish,                // data read module read request finish
	input[ADDR_BITS - 1:0]           read_addr_0,                // data read module read request base address 0, used when read_addr_index = 0
	input[ADDR_BITS - 1:0]           read_addr_1,                // data read module read request base address 1, used when read_addr_index = 1
	input[ADDR_BITS - 1:0]           read_addr_2,                // data read module read request base address 1, used when read_addr_index = 2
	input[ADDR_BITS - 1:0]           read_addr_3,                // data read module read request base address 1, used when read_addr_index = 3
	input[1:0]                       read_addr_index,            // select valid base address from read_addr_0 read_addr_1 read_addr_2 read_addr_3
	input[ADDR_BITS - 1:0]           read_len,                   // data read module read request data length
	input                            thumbnail_mode,
	output                           thumbnail_mode_active,
	output reg                       fifo_aclr,                  // to fifo asynchronous clear
	input[BURST_BITS - 1:0]         wrusedw                     // from fifo write used words

);
localparam ONE                       = 256'd1;                   //256 bit '1'   you can use ONE[n-1:0] for n bit '1'
localparam ZERO                      = 256'd0;                   //256 bit '0'
//read state machine code
localparam S_IDLE                    = 0;                        //idle state,waiting for frame read
localparam S_ACK                     = 1;                        //read request response
localparam S_CHECK_FIFO              = 2;                        //check the FIFO status, ensure that there is enough space to burst read
localparam S_READ_BURST              = 3;                        //begin a burst read
localparam S_READ_BURST_END          = 4;                        //a burst read complete
localparam S_END                     = 5;                        //a frame of data is read to complete
localparam [ADDR_BITS - 1:0] THUMBNAIL_ROW_WORDS = 1280;

reg                                  read_req_d0;                //asynchronous read request, synchronize to 'mem_clk' clock domain,first beat
reg                                  read_req_d1;                //second
reg                                  read_req_d2;                //third,Why do you need 3 ? Here's the design habit
reg[ADDR_BITS - 1:0]                 read_len_d0;                //asynchronous read_len(read data length), synchronize to 'mem_clk' clock domain first
reg[ADDR_BITS - 1:0]                 read_len_d1;                //second
reg[ADDR_BITS - 1:0]                 read_len_latch;             //lock read data length
reg[ADDR_BITS - 1:0]                 read_addr_0_d0;
reg[ADDR_BITS - 1:0]                 read_addr_0_d1;
reg[ADDR_BITS - 1:0]                 read_addr_1_d0;
reg[ADDR_BITS - 1:0]                 read_addr_1_d1;
reg[ADDR_BITS - 1:0]                 read_addr_2_d0;
reg[ADDR_BITS - 1:0]                 read_addr_2_d1;
reg[ADDR_BITS - 1:0]                 read_addr_3_d0;
reg[ADDR_BITS - 1:0]                 read_addr_3_d1;
reg[ADDR_BITS - 1:0]                 read_addr_0_latch;
reg[ADDR_BITS - 1:0]                 read_addr_1_latch;
reg[ADDR_BITS - 1:0]                 read_addr_2_latch;
reg[ADDR_BITS - 1:0]                 read_addr_3_latch;
reg[ADDR_BITS - 1:0]                 read_cnt;                   //read data counter
reg[3:0]                             state;                      //state machine
reg[1:0]                             read_addr_index_d0;         //synchronize to 'mem_clk' clock domain first
reg[1:0]                             read_addr_index_d1;         //synchronize to 'mem_clk' clock domain second
reg                                  thumbnail_mode_d0;
reg                                  thumbnail_mode_d1;
reg                                  thumbnail_mode_latch;
reg [ADDR_BITS - 1:0]	 App_rd_addr_r;
reg [10:0]                           thumbnail_pixel_x;
reg [9:0]                            thumbnail_pixel_y;
reg [ADDR_BITS - 1:0]                thumbnail_left_row_addr;
reg [ADDR_BITS - 1:0]                thumbnail_right_row_addr;

reg [BURST_BITS - 1:0]				burst_cnt;
wire								rd_burst_finish;
reg App_rd_en_r;
reg App_rd_en_d0;

wire rd_vld;
reg [3:0] rd_delay;

assign App_rd_addr = {App_rd_addr_r[ADDR_BITS - 1:0]};
assign thumbnail_mode_active = thumbnail_mode_latch;
assign rd_vld = (state == S_READ_BURST && burst_cnt >= BURST_SIZE);

assign O_rd_busy = (state == S_READ_BURST);//读指令期间
//burst_cnt代表发送的读指令
//但rd_burst_finish需要在发送完十个时钟后拉高，此时数据全部读出
assign rd_burst_finish = (rd_vld && rd_delay == 4'd10);
assign read_finish = (state == S_END) ? 1'b1 : 1'b0;             //read finish at state 'S_END'
assign App_rd_en = App_rd_en_d0;
always@(posedge mem_clk or posedge rst)
begin
	if(rst == 1'b1)
	begin
		read_req_d0    <=  1'b0;
		read_req_d1    <=  1'b0;
		read_req_d2    <=  1'b0;
		read_len_d0    <=  ZERO[ADDR_BITS - 1:0];               //equivalent to read_len_d0 <= 0;
		read_len_d1    <=  ZERO[ADDR_BITS - 1:0];               //equivalent to read_len_d1 <= 0;
		read_addr_0_d0 <= ZERO[ADDR_BITS - 1:0];
		read_addr_0_d1 <= ZERO[ADDR_BITS - 1:0];
		read_addr_1_d0 <= ZERO[ADDR_BITS - 1:0];
		read_addr_1_d1 <= ZERO[ADDR_BITS - 1:0];
		read_addr_2_d0 <= ZERO[ADDR_BITS - 1:0];
		read_addr_2_d1 <= ZERO[ADDR_BITS - 1:0];
		read_addr_3_d0 <= ZERO[ADDR_BITS - 1:0];
		read_addr_3_d1 <= ZERO[ADDR_BITS - 1:0];
		read_addr_index_d0 <= 2'b00;
		read_addr_index_d1 <= 2'b00;
		thumbnail_mode_d0 <= 1'b0;
		thumbnail_mode_d1 <= 1'b0;
	end
	else
	begin
		read_req_d0    <=  read_req;
		read_req_d1    <=  read_req_d0;
		read_req_d2    <=  read_req_d1;     
		read_len_d0    <=  read_len;
		read_len_d1    <=  read_len_d0; 
		read_addr_0_d0 <= read_addr_0;
		read_addr_0_d1 <= read_addr_0_d0;
		read_addr_1_d0 <= read_addr_1;
		read_addr_1_d1 <= read_addr_1_d0;
		read_addr_2_d0 <= read_addr_2;
		read_addr_2_d1 <= read_addr_2_d0;
		read_addr_3_d0 <= read_addr_3;
		read_addr_3_d1 <= read_addr_3_d0;
		read_addr_index_d0 <= read_addr_index;
		read_addr_index_d1 <= read_addr_index_d0;
		thumbnail_mode_d0 <= thumbnail_mode;
		thumbnail_mode_d1 <= thumbnail_mode_d0;
		
	end 
end

always @(posedge mem_clk or posedge rst)
begin
	if(rst || App_rd_en)begin
        rd_delay <= 4'd0;
    end
    else if(rd_delay < 4'd10)begin
    	rd_delay <= rd_delay + 1'b1;
    end
end
always @(posedge mem_clk or posedge rst)
begin
	if(rst == 1'b1)
	begin
		burst_cnt <= ZERO[BURST_BITS - 1:0];
		App_rd_addr_r <= ZERO[ADDR_BITS - 1:0];
		App_rd_en_d0 <= 1'b0;
		thumbnail_pixel_x <= 11'd0;
		thumbnail_pixel_y <= 10'd0;
		thumbnail_left_row_addr <= ZERO[ADDR_BITS - 1:0];
		thumbnail_right_row_addr <= ZERO[ADDR_BITS - 1:0];
		thumbnail_mode_latch <= 1'b0;
		read_addr_0_latch <= ZERO[ADDR_BITS - 1:0];
		read_addr_1_latch <= ZERO[ADDR_BITS - 1:0];
		read_addr_2_latch <= ZERO[ADDR_BITS - 1:0];
		read_addr_3_latch <= ZERO[ADDR_BITS - 1:0];
	end
	else begin
	
		if(state == S_CHECK_FIFO)
			burst_cnt <= ZERO[BURST_BITS - 1:0];
		else if(App_rd_en)
			burst_cnt <= burst_cnt + 1'b1;
		else
			burst_cnt <= burst_cnt;
		//
		if(state == S_ACK)
			begin
				thumbnail_pixel_x <= 11'd0;
				thumbnail_pixel_y <= 10'd0;
				read_addr_0_latch <= read_addr_0_d1;
				read_addr_1_latch <= read_addr_1_d1;
				read_addr_2_latch <= read_addr_2_d1;
				read_addr_3_latch <= read_addr_3_d1;
				thumbnail_left_row_addr <= read_addr_0_d1;
				thumbnail_right_row_addr <= read_addr_1_d1;
				thumbnail_mode_latch <= thumbnail_mode_d1;
				if(thumbnail_mode_d1)
					App_rd_addr_r <= read_addr_0_d1;
				else if(read_addr_index_d1 == 2'd0)
					App_rd_addr_r <= read_addr_0_d1;
				else if(read_addr_index_d1 == 2'd1)
					App_rd_addr_r <= read_addr_1_d1;
				else if(read_addr_index_d1 == 2'd2)
					App_rd_addr_r <= read_addr_2_d1;
				else if(read_addr_index_d1 == 2'd3)
					App_rd_addr_r <= read_addr_3_d1;
			end
		else if(App_rd_en)
			begin
				if(thumbnail_mode_latch)
					begin
						if(thumbnail_pixel_x == 11'd1279)
							begin
								thumbnail_pixel_x <= 11'd0;
								if(thumbnail_pixel_y == 10'd359)
									begin
										thumbnail_pixel_y <= 10'd360;
										thumbnail_left_row_addr <= read_addr_2_latch;
										thumbnail_right_row_addr <= read_addr_3_latch;
										App_rd_addr_r <= read_addr_2_latch;
									end
								else if(thumbnail_pixel_y == 10'd719)
									begin
										thumbnail_pixel_y <= 10'd0;
										thumbnail_left_row_addr <= read_addr_0_latch;
										thumbnail_right_row_addr <= read_addr_1_latch;
										App_rd_addr_r <= read_addr_0_latch;
									end
								else
									begin
										thumbnail_pixel_y <= thumbnail_pixel_y + 1'b1;
										thumbnail_left_row_addr <= thumbnail_left_row_addr + THUMBNAIL_ROW_WORDS;
										thumbnail_right_row_addr <= thumbnail_right_row_addr + THUMBNAIL_ROW_WORDS;
										App_rd_addr_r <= thumbnail_left_row_addr + THUMBNAIL_ROW_WORDS;
									end
							end
						else if(thumbnail_pixel_x == 11'd639)
							begin
								thumbnail_pixel_x <= thumbnail_pixel_x + 1'b1;
								App_rd_addr_r <= thumbnail_right_row_addr;
							end
						else
							begin
								thumbnail_pixel_x <= thumbnail_pixel_x + 1'b1;
								App_rd_addr_r <= App_rd_addr_r + 1'b1;
							end
					end
				else
					App_rd_addr_r <= App_rd_addr_r + 1'b1;
			end
		else
			App_rd_addr_r <= App_rd_addr_r;
		//
		if(App_rd_en_r && burst_cnt + App_rd_en < BURST_SIZE)
			App_rd_en_d0 <= 1'b1;
		else
			App_rd_en_d0 <= 1'b0;
	
	end		
end
always@(posedge mem_clk or posedge rst)
begin
	if(rst == 1'b1)
	begin
		state <= S_IDLE;
		read_len_latch <= ZERO[ADDR_BITS - 1:0];
		
		//rd_burst_addr <= ZERO[ADDR_BITS - 1:0];
		//rd_burst_req <= 1'b0;
		App_rd_en_r <= 1'b0;
		
		read_cnt <= ZERO[ADDR_BITS - 1:0];
		fifo_aclr <= 1'b1;
		//rd_burst_len <= ZERO[BURST_BITS - 1:0];
		read_req_ack <= 1'b0;
	end
	else
		case(state)
			//idle state,waiting for read, read_req_d2 == '1' goto the 'S_ACK'
			S_IDLE:
			begin
				if(read_req_d2 == 1'b1 && Sdr_init_done)
				begin
					state <= S_ACK;
				end
				read_req_ack <= 1'b0;
			end
			//'S_ACK' state completes the read request response, the FIFO reset, the address latch, and the data length latch
			S_ACK:
			begin
				if(read_req_d2 == 1'b0)
				begin
					state <= S_CHECK_FIFO;
					fifo_aclr <= 1'b0;
					read_req_ack <= 1'b0;
				end
				else
				begin
					//read request response
					read_req_ack <= 1'b1;
					//FIFO reset
					fifo_aclr <= 1'b1;
					//select valid base address from read_addr_0 read_addr_1 read_addr_2 read_addr_3
					/*
					if(read_addr_index_d1 == 2'd0)
						App_rd_addr <= read_addr_0;
					else if(read_addr_index_d1 == 2'd1)
						App_rd_addr <= read_addr_1;
					else if(read_addr_index_d1 == 2'd2)
						App_rd_addr <= read_addr_2;
					else if(read_addr_index_d1 == 2'd3)
						App_rd_addr <= read_addr_3;
					*/
					//latch data length
					read_len_latch <= read_len_d1;
				end
				//read data counter reset, read_cnt <= 0;
				read_cnt <= ZERO[ADDR_BITS - 1:0];
			end
			S_CHECK_FIFO:
			begin
				//if there is a read request at this time, enter the 'S_ACK' state
				if(read_req_d2 == 1'b1)
				begin
					state <= S_ACK;
				end
				//if the FIFO space is a burst read request, goto burst read state
				else if(wrusedw < (FIFO_DEPTH - BURST_SIZE) && ~App_wr_busy && !Sdr_init_ref_vld)
				begin
					state <= S_READ_BURST;
					//rd_burst_len <= BURST_SIZE[BURST_BITS - 1:0];
					//rd_burst_req <= 1'b1;
					App_rd_en_r <= 1'b1;
				end
			end
			
			S_READ_BURST:
			begin
				//burst finish  
				if(rd_burst_finish == 1'b1)
				begin
					App_rd_en_r <= 1'b0;
					state <= S_READ_BURST_END;
					//read counter + burst length
					read_cnt <= read_cnt + BURST_SIZE[ADDR_BITS - 1:0];
					//the next burst read address is generated
					//rd_burst_addr <= rd_burst_addr + BURST_SIZE[ADDR_BITS - 1:0];
				end     
			end
			S_READ_BURST_END:
			begin
				//if there is a read request at this time, enter the 'S_ACK' state
				if(read_req_d2 == 1'b1)
				begin
					state <= S_ACK;
				end
				//if the read counter value is less than the frame length, continue read,
				//otherwise the read is complete
				else if(read_cnt < read_len_latch)
				begin
					state <= S_CHECK_FIFO;
				end
				else
				begin
					state <= S_END;
				end
			end
			S_END:
			begin
				state <= S_IDLE;
			end
			default:
				state <= S_IDLE;
		endcase
end
endmodule
