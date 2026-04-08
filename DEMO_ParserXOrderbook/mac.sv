module MAC #
(
parameter DATA_WIDTH = 8
)
(
input clk,
input rst_n,
input En,
input Clr,
input [DATA_WIDTH-1:0] Ain,
input [DATA_WIDTH-1:0] Bin,
output logic [DATA_WIDTH-1:0] Bout,
output logic [DATA_WIDTH*3-1:0] Cout
);


always_ff @(posedge clk, negedge rst_n) begin
	if(~rst_n)
		Cout <= '0;
	else if(En)
		Cout <= (Ain * Bin) + Cout;
	else if(Clr)
		Cout <= '0;
	else 
		Cout <= Cout;
end

always_ff @(posedge clk, negedge rst_n) begin
	if(~rst_n)
		Bout <= '0;
	else if (En)
		Bout <= Bin;
	else 
		Bout <= Bout;
end

endmodule