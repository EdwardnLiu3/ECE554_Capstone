import ob_pkg::*;
module ob_opb opb(
    input logic i_clk,
    input logic i_rst_n,
    input logic [ORDERID_LEN-1:0] i_order_id,
    input logic [QUATITY_LEN-1:0] i_quantity,
    input logic i_action,
    input logic i_valid,
    input logic [PRICE_LEN-1:0] i_price,
    output logic o_add,
    output logic [PRICE_LEN-1:0] o_price,
    output logic o_valid,
    output logic [QUANTITY_LEN-1:0] o_quantity
); 

// OPB: use orderid as index and store the price and quantity of the given 
(* ram_style = "block" *) logic [W-1:0] OPB [0:DEPTH-1];

// this table track tif each entry is valid (purpose: not reset bram when rst_n)
logic valid_table[0:DEPTH-1];


// current packet being fed (only used when it is an add order)
ob_packet_t packet_in;
assign packet_in = '{price:i_price, quantity:i_quantity};

// action status
logic add, cancel, execute;
assign add = i_action == 2'b00;
assign cancel = i_action = 2'b01;
assign execute = i_action = 2'b10;

// updated packet if it is the given orderid is canceled or executed

// add order
always_ff @(posedge i_clk, negedge i_rst_n) begin
    if(!rst_n) begin
    end
    else if(add && i_valid) begin
        OPB[i_order_id] <= packet_in;
    end
end



// execute order
always_ff @(posedge i_clk, negedge i_rst_n) begin
    if(!i_rst_n) begin
    end
    else if(execute && i_valid && valid_table[i_order_id] == 1) begin
        if(OPB[i_order_id].quantity > i_quantity) begin
            OPB[i_order_id].quantity <= OPB[i_order_id].quantity - i_quantity;  // todo: parallel this since now read/write bram happen in the same cycle which violated it property
        end else begin
            OPB[i_order_id].quantity <= '0;
        end
    end
end

endmodule