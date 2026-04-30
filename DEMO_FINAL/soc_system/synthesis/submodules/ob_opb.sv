////////////////////////////////////////////////////////////////////////////////
// 
// This module keep track of the price and quantity corresponding to the orderid
// and output the price, quantity, and action for FLB to make changes
//
// Each of the action take 2 cycles and is pipelined
//
////////////////////////////////////////////////////////////////////////////////
import ob_pkg::*;
module ob_opb(
    input logic i_clk,
    input logic i_rst_n,
    input logic [ORDERID_LEN-1:0] i_order_id,
    input logic [QUANTITY_LEN-1:0] i_quantity,
    input logic [1:0] i_action,
    input logic i_valid,
    input logic i_side,
    input logic [PRICE_LEN-1:0] i_price,
    output logic [1:0]o_action,
    output logic [PRICE_LEN-1:0] o_price,
    output logic o_valid,
    output logic [QUANTITY_LEN-1:0] o_quantity, // add: quantity added, others: quantity removed
    output logic o_side
); 

// OPB: use orderid as index and store the price and quantity of the given 
// ob_packet_t OPB [0:OPB_DEPTH-1];
// BRAM
(* ramstyle = "M10K" *) logic [PRICE_LEN-1:0] opb_price [0:OPB_DEPTH-1];
(* ramstyle = "M10K" *) logic [QUANTITY_LEN-1:0] opb_quant [0:OPB_DEPTH-1];
(* ramstyle = "M10K" *) logic opb_side [0:OPB_DEPTH-1];

logic                       wren_price, wren_quant, wren_side;
logic [PRICE_LEN-1:0]       rd_price, wr_price;
logic [QUANTITY_LEN-1:0]    rd_quant, wr_quant;
logic                       rd_side, wr_side;

//s0
logic s0_add, s0_cancel, s0_execute, s0_delete;

//s1
logic [ORDERID_LEN-1:0]     s1_order_id;
logic [PRICE_LEN-1:0]       s1_price;
logic [QUANTITY_LEN-1:0]    s1_quant;
logic                       s1_side;
logic                       s1_add, s1_cancel, s1_execute, s1_delete;
logic                       s1_valid;
logic [1:0]                 s1_action;

logic                       s2_add, s2_cancel, s2_execute, s2_delete;
logic [ORDERID_LEN-1:0]     s2_order_id;
logic [QUANTITY_LEN-1:0]    s2_wr_quant;

logic [QUANTITY_LEN-1:0]    prev_quant;
logic [PRICE_LEN-1:0]       prev_price;
logic                       prev_side;

assign s0_add = i_action == 2'b00;
assign s0_cancel = i_action == 2'b01;
assign s0_execute = i_action == 2'b10;
assign s0_delete = i_action == 2'b11;

//BRAM
always_ff @(posedge i_clk) begin
    rd_price <= opb_price[i_order_id];
    rd_quant <= opb_quant[i_order_id];
    rd_side <= opb_side[i_order_id];
    if(wren_price)
        opb_price[s1_order_id] <= wr_price;
    if(wren_quant)
        opb_quant[s1_order_id] <= wr_quant;
    if(wren_side)
        opb_side[s1_order_id] <= wr_side;
end

// s1 input
always_ff @(posedge i_clk, negedge i_rst_n) begin
    if(!i_rst_n) begin
        s1_order_id <= '0;
        s1_price <= '0;
        s1_quant <= '0;
        s1_side <= 0;
        s1_add <= 0;
        s1_cancel <= 0;
        s1_execute <= 0;
        s1_delete <= 0;
        s1_valid <= 0;
        s1_action <='0;
    end else begin
        s1_order_id <= i_order_id;
        s1_price <= i_price;
        s1_quant <= i_quantity;
        s1_side <= i_side;
        s1_add <= s0_add;
        s1_cancel <= s0_cancel;
        s1_execute <= s0_execute;
        s1_delete <= s0_delete;
        s1_valid <= i_valid;
        s1_action <= i_action;
    end
end

// BRAM Control logic
always_comb begin
    wren_price = 0;
    wren_quant = 0;
    wren_side = 0;
    wr_price = '0;
    wr_quant = '0;
    wr_side = 0;
    if(s1_valid) begin
        if(s1_add) begin
            wren_price = 1;
            wren_quant = 1;
            wren_side = 1;
            wr_price = s1_price;
            wr_quant = s1_quant;
            wr_side = s1_side;
        end else if(s1_cancel || s1_execute) begin
            wren_quant = 1;
            if(prev_quant - s1_quant <= 0)
                wr_quant = '0;
            else 
                wr_quant = prev_quant - s1_quant;
        end else if(s1_delete) begin
            wren_quant = 1;
            wr_quant = '0;
        end
    end
end

// Some Hazard
// 1: add -> cancel/execute
// 2: cancel/execute -> cancel/execute
always_comb begin
    prev_price = rd_price;
    prev_quant = rd_quant;
    prev_side = rd_side;
    if(o_valid && (s2_add) && (s2_order_id == s1_order_id)) begin
        prev_quant = o_quantity;
        prev_price = o_price;
        prev_side = o_side;
    end else if (o_valid && (s2_cancel || s2_execute) && (s2_order_id == s1_order_id)) begin
        prev_quant = s2_wr_quant;
        prev_price = o_price;
        prev_side = o_side;
    end
end

always_ff @(posedge i_clk, negedge i_rst_n) begin
    if(!i_rst_n) begin
        o_action   <= '0;
        o_price    <= '0;
        o_valid    <= 1'b0;
        o_quantity <= '0;
        o_side     <= 1'b0;
        s2_add     <= 0;
        s2_cancel  <= 0;
        s2_execute <= 0;
        s2_order_id <= 0;
        s2_wr_quant <= '0;
    end else begin
        s2_add     <= s1_add;
        s2_cancel  <= s1_cancel;
        s2_execute <= s1_execute;
        s2_order_id <= s1_order_id;
        s2_wr_quant <= wr_quant;
        o_action   <= s1_action;
        o_valid    <= s1_valid;
        if(s1_add) begin
            o_price    <= s1_price;
            o_quantity <= s1_quant;
            o_side     <= s1_side;
        end else if (s1_cancel || s1_execute) begin
            o_price    <= prev_price;
            o_quantity <= s1_quant;
            o_side     <= prev_side;
        end else begin
            o_price    <= prev_price;
            o_quantity <= prev_quant;
            o_side     <= prev_side;
        end
    end
end

endmodule
