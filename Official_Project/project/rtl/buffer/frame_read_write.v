`timescale 1ns/1ps
module frame_read_write
#
(
	parameter MEM_DATA_BITS          = 32,
	parameter READ_DATA_BITS         = 32,
	parameter WRITE_DATA_BITS        = 32,
	parameter ADDR_BITS              = 21,
	parameter BURST_BITS             = 9,//
	parameter BURST_SIZE             = 256,
	parameter PACK_RGB565            = 0,      // 1: store two RGB565 pixels in each SDRAM word
	parameter WRITE_V_FLIP           = 1,      // 1: vertical flip when writing TF/BMP frame into SDRAM
	parameter FRAME_WIDTH            = 640,
	parameter FRAME_HEIGHT           = 480
) 
(
	input                            rst,                  
	input                            mem_clk,                    // external memory controller user interface clock
	input							 Sdr_init_done,
	input							 Sdr_init_ref_vld,
    input							 Sdr_busy,
	
    /*
    output                           rd_burst_req,               // to external memory controller,send out a burst read request
	output[BURST_BITS - 1:0]         rd_burst_len,               // to external memory controller,data length of the burst read request, not bytes
	output[ADDR_BITS - 1:0]          rd_burst_addr,              // to external memory controller,base address of the burst read request 
	input                            rd_burst_data_valid,        // from external memory controller,read data valid 
	input[MEM_DATA_BITS - 1:0]       rd_burst_data,              // from external memory controller,read request data
	input                            rd_burst_finish,            // from external memory controller,burst read finish
	*/
	output							 App_rd_en,
	output[ADDR_BITS - 1:0]			 App_rd_addr,
	input							 Sdr_rd_en,					 //read_data_valid
	input[MEM_DATA_BITS - 1:0]		 Sdr_rd_dout,
	
	input                            read_clk,                   // data read module clock
	input                            read_req,                   // data read module read request,keep '1' until read_req_ack = '1'
	output                           read_req_ack,               // data read module read request response
	output                           read_finish,                // data read module read request finish
	input[ADDR_BITS - 1:0]           read_addr_0,                // data read module read request base address 0, used when read_addr_index = 0
	input[ADDR_BITS - 1:0]           read_addr_1,                // data read module read request base address 1, used when read_addr_index = 1
	input[ADDR_BITS - 1:0]           read_addr_2,                // data read module read request base address 1, used when read_addr_index = 2
	input[ADDR_BITS - 1:0]           read_addr_3,                // data read module read request base address 1, used when read_addr_index = 3
	input[1:0]                       read_addr_index,            // select valid base address from read_addr_0 read_addr_1 read_addr_2 read_addr_3
	input[ADDR_BITS - 1:0]           read_len,                   // data read module read request data length
	input                            thumbnail_mode,
	input                            read_en,                    // data read module read request for one data, read_data valid next clock
	output[READ_DATA_BITS  - 1:0]    read_data,                  // read data
	output                           read_underflow,
	/*
	output                           wr_burst_req,               // to external memory controller,send out a burst write request
	output[BURST_BITS - 1:0]         wr_burst_len,               // to external memory controller,data length of the burst write request, not bytes
	output[ADDR_BITS - 1:0]          wr_burst_addr,              // to external memory controller,base address of the burst write request 
	input                            wr_burst_data_req,          // from external memory controller,write data request ,before data 1 clock
	output[MEM_DATA_BITS - 1:0]      wr_burst_data,              // to external memory controller,write data
	input                            wr_burst_finish,            // from external memory controller,burst write finish
	*/
	output							 App_wr_en,
	output[ADDR_BITS - 1:0]			 App_wr_addr,
	output[MEM_DATA_BITS - 1:0]	 App_wr_din,
	output[3:0]						 App_wr_dm,
	
	//
	input                            write_clk,                  // data write module clock
	input                            write_req,                  // data write module write request,keep '1' until read_req_ack = '1'
	output                           write_req_ack,              // data write module write request response
	output                           write_finish,               // data write module write request finish
	input[ADDR_BITS - 1:0]           write_addr_0,               // data write module write request base address 0, used when write_addr_index = 0
	input[ADDR_BITS - 1:0]           write_addr_1,               // data write module write request base address 1, used when write_addr_index = 1
	input[ADDR_BITS - 1:0]           write_addr_2,               // data write module write request base address 1, used when write_addr_index = 2
	input[ADDR_BITS - 1:0]           write_addr_3,               // data write module write request base address 1, used when write_addr_index = 3
	input[1:0]                       write_addr_index,           // select valid base address from write_addr_0 write_addr_1 write_addr_2 write_addr_3
	input                            write_asset_mode,
	input[ADDR_BITS - 1:0]           write_asset_addr,
	input[ADDR_BITS - 1:0]           write_len,                  // data write module write request data length
	input                            write_en,                   // data write module write request for one data
	input[WRITE_DATA_BITS - 1:0]     write_data                 // write data

);
localparam WRITE_FIFO_DATA_BITS = PACK_RGB565 ? 16 : WRITE_DATA_BITS;
localparam READ_FIFO_DATA_BITS  = PACK_RGB565 ? 16 : READ_DATA_BITS;

wire[BURST_BITS - 1:0]                           wrusedw;                    // write used words
wire[BURST_BITS - 1:0]                           rdusedw;                    // read used words
wire[WRITE_FIFO_DATA_BITS - 1:0]                 write_fifo_data;
wire[READ_FIFO_DATA_BITS - 1:0]                  read_fifo_raw_data;
wire[READ_FIFO_DATA_BITS - 1:0]                  read_fifo_prefetch_data;
wire[MEM_DATA_BITS - 1:0]                        read_fifo_write_data;
wire                                              read_fifo_write_enable;
wire                                              thumbnail_mode_active;
wire                                              read_fifo_empty;
wire                                              read_fifo_valid;
wire                                              read_fifo_prefetch_enable;
wire                                              read_fifo_prefetch_valid;
reg [READ_FIFO_DATA_BITS - 1:0]                   read_pixel_data;
reg [15:0]                                        thumbnail_first_pixel;
reg                                               thumbnail_pixel_half;

wire 								 App_rd_busy;
wire								 App_wr_busy;

wire                                 read_fifo_aclr;             // fifo Asynchronous clear
wire                                 write_fifo_aclr;            // fifo Asynchronous clear

wire O_wr_busy;
wire O_rd_busy;

assign App_wr_busy = O_wr_busy;//下个时钟写指令拉高
assign App_rd_busy = O_rd_busy;//读指令还没有过去十个时钟;因为写指令优先，不需要在意下个时钟是否是读指令
assign App_wr_dm = 4'b0000;
assign write_fifo_data = PACK_RGB565 ?
	{write_data[31:27], write_data[23:18], write_data[15:11]} : write_data;
assign read_data = PACK_RGB565 ?
	{{read_pixel_data[15:11], read_pixel_data[15:13]},
	 {read_pixel_data[10:5], read_pixel_data[10:9]},
	 {read_pixel_data[4:0], read_pixel_data[4:2]}, 8'h00} : read_pixel_data;
assign read_underflow = read_en && !read_fifo_prefetch_valid;
assign read_fifo_write_enable = thumbnail_mode_active ?
	(Sdr_rd_en && thumbnail_pixel_half) : Sdr_rd_en;
assign read_fifo_write_data = thumbnail_mode_active ?
	{Sdr_rd_dout[15:0], thumbnail_first_pixel} : Sdr_rd_dout;

always @(posedge mem_clk or posedge rst) begin
	if(rst || read_fifo_aclr) begin
		thumbnail_first_pixel <= 16'd0;
		thumbnail_pixel_half <= 1'b0;
	end else if(thumbnail_mode_active && Sdr_rd_en) begin
		if(!thumbnail_pixel_half)
			thumbnail_first_pixel <= Sdr_rd_dout[15:0];
		thumbnail_pixel_half <= ~thumbnail_pixel_half;
	end else if(!thumbnail_mode_active) begin
		thumbnail_pixel_half <= 1'b0;
	end
end

//instantiate an asynchronous FIFO 
wfifo_32_32_512 #(
	.DATA_WIDTH_W              (WRITE_FIFO_DATA_BITS       ),
	.DATA_WIDTH_R              (MEM_DATA_BITS              ),
	.ADDR_WIDTH_W              (PACK_RGB565 ? BURST_BITS + 1 : BURST_BITS),
	.ADDR_WIDTH_R              (BURST_BITS                 )
) write_buf
	(
	.clkr                      	(mem_clk                  ),          // Read side clock
	.clkw                      	(write_clk                ),          // Write side clock
	.rst                       	(write_fifo_aclr          ),          // Asynchronous clear
	.we                      	(write_en                 ),          // Write Request
	.re                      	(App_wr_en        		  ),          // Read Request
	.di                       	(write_fifo_data          ),          // Input Data
	.empty_flag                 (                         ),          // Read side Empty flag
	.full_flag                  (                         ),          // Write side Full flag
	.wrusedw                	(              	  		  ),          // Read Used Words
	.rdusedw                	(rdusedw                  ),          // Write Used Words
	.dout                       (App_wr_din		          ),
	.valid                      (),
	.afull                      (),
	.aempty                     ()
);

frame_fifo_write
#
(
	.MEM_DATA_BITS              (MEM_DATA_BITS            ),
	.ADDR_BITS                  (ADDR_BITS                ),
	.BURST_BITS                 (BURST_BITS               ),
	.BURST_SIZE                 (BURST_SIZE               ),
	.WRITE_V_FLIP               (WRITE_V_FLIP             ),
	.FRAME_WIDTH                (PACK_RGB565 ? FRAME_WIDTH / 2 : FRAME_WIDTH),
	.FRAME_HEIGHT               (FRAME_HEIGHT             )
) 
frame_fifo_write_m0              
(  
	.rst                        (rst                      ),
	.mem_clk                    (mem_clk                  ),
    .Sdr_init_done				(Sdr_init_done),
	.Sdr_init_ref_vld			(Sdr_init_ref_vld),
    .Sdr_busy					(Sdr_busy),
	.App_rd_busy				(App_rd_busy),
    .O_wr_busy					(O_wr_busy),
	
	.App_wr_en					(App_wr_en),
    .App_wr_addr				(App_wr_addr),
	.write_req                  (write_req                ),
	.write_req_ack              (write_req_ack            ),
	.write_finish               (write_finish             ),
	.write_addr_0               (write_addr_0             ),
	.write_addr_1               (write_addr_1             ),
	.write_addr_2               (write_addr_2             ),
	.write_addr_3               (write_addr_3             ),
	.write_addr_index           (write_addr_index         ),    
	.write_asset_mode           (write_asset_mode         ),
	.write_asset_addr           (write_asset_addr         ),
	.write_len                  (write_len                ),
	.fifo_aclr                  (write_fifo_aclr          ),
	.rdusedw                 	(rdusedw                  )
);

//instantiate an asynchronous FIFO 
rfifo_32_32_512 #(
	.DATA_WIDTH_W              (MEM_DATA_BITS              ),
	.DATA_WIDTH_R              (READ_FIFO_DATA_BITS        ),
	.ADDR_WIDTH_W              (BURST_BITS                 ),
	.ADDR_WIDTH_R              (PACK_RGB565 ? BURST_BITS + 1 : BURST_BITS)
) read_buf
	(
	.clkr                     	(read_clk                   ),          // Read side clock
	.clkw                     	(mem_clk                    ),          // Write side clock
	.rst                      	(read_fifo_aclr             ),          // Asynchronous clear
	.we                     	(read_fifo_write_enable		),          // Write Request
	.re                     	(read_fifo_prefetch_enable   ),          // Read Request
	.di                      	(read_fifo_write_data       ),          // Input Data
	.empty_flag					(read_fifo_empty            ),          // Read side Empty flag
	.full_flag					(                           ),          // Write side Full flag
	.wrusedw                	(wrusedw         	  	  		 ),          // Read Used Words
	.rdusedw                	(                  			 ),          // Write Used Words
	.dout						(read_fifo_raw_data         ),
	.valid						(read_fifo_valid            ),
	.afull						(),
	.aempty						()
);

fifo_prefetch_2 #(
	.DATA_WIDTH                (READ_FIFO_DATA_BITS       )
) read_prefetch (
	.clk                       (read_clk                 ),
	.rst                       (read_fifo_aclr           ),
	.raw_empty                 (read_fifo_empty          ),
	.raw_valid                 (read_fifo_valid          ),
	.raw_data                  (read_fifo_raw_data       ),
	.raw_read_en               (read_fifo_prefetch_enable),
	.consume                   (read_en                  ),
	.out_valid                 (read_fifo_prefetch_valid ),
	.out_empty                 (                         ),
	.out_data                  (read_fifo_prefetch_data  )
);

always @(posedge read_clk or posedge read_fifo_aclr) begin
	if(read_fifo_aclr)
		read_pixel_data <= {READ_FIFO_DATA_BITS{1'b0}};
	else if(read_en)
		read_pixel_data <= read_fifo_prefetch_valid ?
			read_fifo_prefetch_data : {READ_FIFO_DATA_BITS{1'b0}};
end

frame_fifo_read
#
(
	.MEM_DATA_BITS              (MEM_DATA_BITS            ),
	.ADDR_BITS                  (ADDR_BITS                ),
	.BURST_BITS                 (BURST_BITS               ),
	.BURST_SIZE                 (BURST_SIZE               )
)
frame_fifo_read_m0
(
	.rst                        (rst                      ),
	.mem_clk                    (mem_clk                  ),
    .Sdr_init_done				(Sdr_init_done),
	.Sdr_init_ref_vld			(Sdr_init_ref_vld),
    .Sdr_busy					(Sdr_busy),
    .Sdr_rd_en					(Sdr_rd_en),
	.App_wr_busy				(App_wr_busy),
    .O_rd_busy					(O_rd_busy),
	
    .App_rd_en					(App_rd_en),
    .App_rd_addr				(App_rd_addr),
	.read_req                   (read_req                 ),
	.read_req_ack               (read_req_ack             ),
	.read_finish                (read_finish              ),
	.read_addr_0                (read_addr_0              ),
	.read_addr_1                (read_addr_1              ),
	.read_addr_2                (read_addr_2              ),
	.read_addr_3                (read_addr_3              ),
	.read_addr_index            (read_addr_index          ),
	.read_len                   (read_len                 ),
	.thumbnail_mode             (thumbnail_mode           ),
	.thumbnail_mode_active      (thumbnail_mode_active    ),
	.fifo_aclr                  (read_fifo_aclr           ),
	.wrusedw                	(wrusedw                  )
);

endmodule

module fifo_prefetch_2 #(
	parameter DATA_WIDTH = 32
)(
	input  wire                  clk,
	input  wire                  rst,
	input  wire                  raw_empty,
	input  wire                  raw_valid,
	input  wire [DATA_WIDTH-1:0] raw_data,
	output wire                  raw_read_en,
	input  wire                  consume,
	output wire                  out_valid,
	output wire                  out_empty,
	output wire [DATA_WIDTH-1:0] out_data
);

	reg [DATA_WIDTH-1:0] slot0;
	reg [DATA_WIDTH-1:0] slot1;
	reg [1:0]            count;
	reg [1:0]            outstanding;

	wire pop = consume && (count != 0);
	wire [2:0] reserved = {1'b0, count} + {1'b0, outstanding};

	assign raw_read_en = !raw_empty &&
		((reserved < 3'd2) || (pop && (reserved == 3'd2)));
	assign out_valid = (count != 0);
	assign out_empty = (count == 0);
	assign out_data  = slot0;

	always @(posedge clk or posedge rst) begin
		if (rst) begin
			slot0       <= {DATA_WIDTH{1'b0}};
			slot1       <= {DATA_WIDTH{1'b0}};
			count       <= 2'd0;
			outstanding <= 2'd0;
		end else begin
			case ({raw_read_en, raw_valid})
				2'b10: outstanding <= outstanding + 2'd1;
				2'b01: outstanding <= outstanding - 2'd1;
				default: outstanding <= outstanding;
			endcase

			case ({pop, raw_valid})
				2'b00: count <= count;
				2'b01: begin
					if (count == 2'd0)
						slot0 <= raw_data;
					else
						slot1 <= raw_data;
					count <= count + 2'd1;
				end
				2'b10: begin
					if (count == 2'd2)
						slot0 <= slot1;
					count <= count - 2'd1;
				end
				2'b11: begin
					if (count == 2'd1)
						slot0 <= raw_data;
					else begin
						slot0 <= slot1;
						slot1 <= raw_data;
					end
					count <= count;
				end
			endcase
		end
	end

endmodule
