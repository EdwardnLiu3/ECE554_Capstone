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
    input logic [PRICE_LEN-1:0] i_price,
    output logic [1:0]o_action,
    output logic [PRICE_LEN-1:0] o_price,
    output logic o_valid,
    output logic [QUANTITY_LEN-1:0] o_quantity // add: quantity added, others: quantity removed
); 

// OPB: use orderid as index and store the price and quantity of the given 
(* ram_style = "block" *) ob_packet_t OPB [0:OPB_DEPTH-1];
// ob_packet_t OPB [0:OPB_DEPTH-1];

// packet being fed from prev cycle (only used when it is an add order)
ob_packet_t packet_in;

// action status
logic is_add, is_cancel, is_execute, is_delete;
assign is_add = (i_action == ADD);
assign is_cancel = (i_action == CANCEL);
assign is_execute = (i_action == EXECUTE);
assign is_delete = (i_action == DELETE);

// updated packet if it is the given orderid is canceled or executed
ob_packet_t                 packet_out, packet_delete;
logic [QUANTITY_LEN-1:0]    quantity_to_remove;
logic                       delete_special_case; // this is when previous execute and delete are the same orderid
logic [QUANTITY_LEN-1:0]    delete_special_case_quant; // store the delete special case quant

//pipeline vars
logic [QUANTITY_LEN-1:0]    p_quantity;
logic [ORDERID_LEN-1:0]     p_order_id;
logic                       p_add, p_exec_cancel, p_delete;
logic [PRICE_LEN-1:0]       p_price;
logic [1:0]                 p_action;
logic                       p_valid;

// pipeline orderid / quantity / price / action / valid
always_ff @(posedge i_clk, negedge i_rst_n) begin
    if(!i_rst_n) begin
        p_quantity <= '0;
        p_order_id <= '0;
        p_price <= '0;
        p_action <= '0;
        p_valid <= 0;
        o_action <= '0;
        o_price <= '0;
        o_valid <= 0;
        o_quantity <= '0;
    end else begin
        p_quantity <= i_quantity;
        p_order_id <= i_order_id;
        p_price <= i_price;
        p_action <= i_action;
        p_valid <= i_valid;
        o_action <= p_action;
        o_valid <= p_valid;
        o_quantity <= p_quantity;
        if(p_action == ADD) begin
            o_price <= p_price;
        end else if(p_action == DELETE) begin
            o_price <= packet_delete.price;
        end else begin
            o_price <= packet_out.price;
        end
        if(p_action == DELETE) begin
            if(delete_special_case) begin
                o_quantity <= delete_special_case_quant;
            end else begin
                o_quantity <= packet_delete.quantity;
            end
        end else begin
            o_quantity <= p_quantity;
        end
    end
end


// first cycle
always_ff@(posedge i_clk, negedge i_rst_n) begin
    if(!i_rst_n) begin
        p_add <= 0;
        p_exec_cancel <= 0;
        delete_special_case <= 0;
    end else begin
        p_add <= 0;
        p_exec_cancel <= 0;
        delete_special_case <= 0;
        if(is_add && i_valid) begin
            p_add <= 1;
            packet_in <= '{price:i_price, quantity:i_quantity};
        end else if((is_cancel || is_execute) && i_valid) begin
            if(p_add && (p_order_id == i_order_id)) begin
                packet_out <= packet_in;
            end else begin
                packet_out <= OPB[i_order_id];
            end
            p_exec_cancel <= 1;
        end else if(is_delete && i_valid) begin
            if(p_add && (p_order_id == i_order_id)) begin
                packet_delete <= packet_in;
            end else begin
                packet_delete <= OPB[i_order_id];
            end
            if((p_exec_cancel) && (p_order_id == i_order_id)) begin
                delete_special_case <= 1'b1;
            end 
        end
    end
end

// second cycle
always_ff @(posedge i_clk, negedge i_rst_n) begin
    if(!i_rst_n) begin
        quantity_to_remove <= '0;
    end else begin
        if(p_add) begin
            OPB[p_order_id] <= packet_in;
        end else if(p_exec_cancel) begin
            if((is_cancel || is_execute) && (p_order_id == i_order_id) && (i_valid)) begin
                quantity_to_remove <= quantity_to_remove + p_quantity;
            end else begin
                quantity_to_remove <= '0;
                delete_special_case_quant <= '0;
                if (packet_out.quantity <= (quantity_to_remove + p_quantity)) begin
                    OPB[p_order_id].quantity <= '0;
                end else begin
                    OPB[p_order_id].quantity <= packet_out.quantity - quantity_to_remove - p_quantity;
                    delete_special_case_quant <= packet_out.quantity - quantity_to_remove - p_quantity;
                end
            end
        end
    end
end

endmodule