module FIFO
#(
  parameter DEPTH=8,
  parameter DATA_WIDTH=8
)
(
  input  clk,
  input  rst_n,
  input  rden,
  input  wren,
  input  [DATA_WIDTH-1:0] i_data,
  output logic [DATA_WIDTH-1:0] o_data,
  output full,
  output empty
);

	logic [DATA_WIDTH-1:0] MEM [0:DEPTH-1];
	localparam logDepth = $clog2(DEPTH);
	logic [logDepth:0] count;
	logic [logDepth-1:0]wptr, rptr;

	assign full = count == 4'd8;
	assign empty = count == 0;

	always_ff @(posedge clk, negedge rst_n) begin
		if(!rst_n) begin
			wptr <= '0;
		end else if(wren && !full) begin
			wptr <= wptr + 1;
			MEM[wptr] <= i_data;
		end
	end

	always_ff @(posedge clk, negedge rst_n) begin
		if(!rst_n) begin
			rptr <= '0;
			o_data <= '0;
		end else if(rden && !empty) begin
			rptr <= rptr + 1;
			o_data <= MEM[rptr];
		end
	end
	
	always_ff @(posedge clk, negedge rst_n) begin
		if(!rst_n) begin
			count <= 0;
		end else if((rden&&!empty) && (wren && !full)) begin
			count <= count;
		end else if(rden&&!empty) begin
			count <= count - 1;
		end else if(wren && !full) begin
			count <= count + 1;
		end
	end
endmodule