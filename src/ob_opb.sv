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
    output logic [QUANTITY_LEN-1:0] o_quantity
); 

// OPB: use orderid as index and store the price and quantity of the given 
// (* ram_style = "block" *) ob_packet_t OPB [0:OPB_DEPTH-1];
ob_packet_t OPB [0:OPB_DEPTH-1];
// this table track tif each entry is valid (purpose: not reset bram when rst_n)
logic [OPB_DEPTH-1:0]valid_table;


// packet being fed from prev cycle (only used when it is an add order)
ob_packet_t packet_in;

// action status
logic add, cancel, execute, delete;
assign add = (i_action == 2'b00);
assign cancel = (i_action == 2'b01);
assign execute = (i_action == 2'b10);
assign delete = (i_action == 2'b11);

// updated packet if it is the given orderid is canceled or executed
ob_packet_t                 packet_out, packet_delete;
logic [QUANTITY_LEN-1:0]    quantity_to_remove;

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
        if(p_action == add) begin
            o_price <= p_price;
        end else begin
            o_price <= packet_out.price;
        end
        if(p_action == 2'b11) begin
            o_quantity <= packet_delete.quantity;
        end else begin
            o_quantity <= p_quantity;
        end
    end
end


// add order
always_ff @(posedge i_clk, negedge i_rst_n) begin
    if(!i_rst_n) begin
        p_add <= 0;
    end else begin
        p_add <= 0;
        if(add && i_valid) begin
            p_add <= 1;
            packet_in <= '{price:i_price, quantity:i_quantity};
        end
        if(p_add)
            OPB[p_order_id] <= packet_in;
    end
end

// cancel and execute order
always_ff @(posedge i_clk, negedge i_rst_n) begin
    if(!i_rst_n) begin
        p_exec_cancel <= 0;
        quantity_to_remove <= '0;
    end else begin
        p_exec_cancel <= 0;
        if((cancel || execute) && i_valid && valid_table[i_order_id]) begin
            packet_out <= OPB[i_order_id];
            p_exec_cancel <= 1;
        end
        if (p_exec_cancel) begin
            if((cancel || execute) && (p_order_id == i_order_id)) begin
                quantity_to_remove <= quantity_to_remove + p_quantity;
            end else begin
                if (packet_out.quantity <= (quantity_to_remove + p_quantity)) begin
                    OPB[p_order_id].quantity <= '0;
                end else begin
                    OPB[p_order_id].quantity <= packet_out.quantity - quantity_to_remove - p_quantity;
                end
            end
        end
    end
end

// delete order (and valid table)
always_ff @(posedge i_clk, negedge i_rst_n) begin
    if(!i_rst_n) begin
        p_delete <= 0;
    end else begin
        p_delete <= 0;
        if(delete && i_valid && valid_table[i_order_id]) begin
            p_delete <= 1;
            packet_delete <= OPB[i_order_id];
        end
    end
end

// valid table
always_ff @(posedge i_clk, negedge i_rst_n) begin
    if(!i_rst_n)
        valid_table <= '0;
    else begin
        if(p_delete) begin
            valid_table[p_order_id] <= 0;
        end else if(p_exec_cancel && (packet_out.quantity <= (quantity_to_remove + p_quantity))) begin
            valid_table[p_order_id] <= 0;
        end else if(p_add) begin
            valid_table[p_order_id] <= 1;
        end
    end
end




endmodule