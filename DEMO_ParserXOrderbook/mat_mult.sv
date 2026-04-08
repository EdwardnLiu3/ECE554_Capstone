module mat_mult #(
    parameter DATA_WIDTH = 8, 
    parameter DEPTH = 8
)

(
    input logic clk, 
    input logic rst_n, 
    input logic Clr,

    input logic wren,

    input logic [DATA_WIDTH-1:0] a_mat [0:DEPTH-1],
    input logic [DATA_WIDTH-1:0] b_vec,
    
    output logic [DATA_WIDTH*3-1:0] sum [0:7]
)


logic [7:0] En;

logic all_full;
logic [8:0] full;
logic [8:0] empty;
assign all_full = &full;

////////////////ENABLE LOGIC//////////////////////////
always_ff @(posedge clk, negedge rst_n) begin
    if(!rst_n) begin
        En <= '0;
    end
    else if(Clr)begin
        En <= '0;
    end
    else if(all_full)begin
        En <= 8'd1;
    end
    else if(En[7])begin
        En <= {En[6:0],1'b0};
    end
    else begin
        En <= {En[6:0], En[0]};
    end
end




///////////////     MAC     ///////////////////////

logic [DATA_WIDTH*3-1:0] Cout [0:DEPTH-1];
logic [DATA_WIDTH-1:0] Ain [0:DEPTH-1];        //TODO: hook up Ain to the FIFOs
logic [DATA_WIDTH-1:0] Bin [0:DEPTH-1];        //TODO: hook up Bin[0] to its FIFO

logic [DATA_WIDTH-1:0] Bout [0:DEPTH-1]; 

assign Bin [1:7] = Bout[0:6];

MAC [7:0] mac(.clk(clk), .rst_n(rst_n), .En(En), .Clr({8{Clr}}), .Ain(Ain), .Bin(Bin), .Bout(Bout), .Cout(Cout));

assign sum = Cout;



////////////// fifo a //////////
genvar i;
generate
  for (i=0; i<8; i=i+1) begin : fifo_gen
     FIFO
     #(
     .DEPTH(DEPTH),
     .DATA_WIDTH(DATA_WIDTH)
     ) input_fifo
     (
     .clk(clk),
     .rst_n(rst_n),
     .rden(En[i]),
     .wren(wren),
     .i_data(a_mat[i]),
     .o_data(Ain[i]),
     .full(full[i]),
     .empty(empty[i])
     );
  end
endgenerate


////////// fifo b /////////////
FIFO fifo_b (
    #(
     .DEPTH(DEPTH),
     .DATA_WIDTH(DATA_WIDTH)
     ) input_fifo
     (
     .clk(clk),
     .rst_n(rst_n),
     .rden(En[0]),
     .wren(wren),
     .i_data(b_vec),
     .o_data(Bin[0]),
     .full(full[8]),
     .empty(empty[8])
     )
);

endmodule