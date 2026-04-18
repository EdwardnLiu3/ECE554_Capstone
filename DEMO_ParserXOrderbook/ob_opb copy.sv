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
(* ram_style = "M10K" *) logic [PRICE_LEN-1:0] OPB_price [0:OPB_DEPTH-1];
(* ram_style = "M10K" *) logic [QUANTITY_LEN-1:0] OPB_quantity [0:OPB_DEPTH-1];
(* ram_style = "M10K" *) logic OPB_side [0:OPB_DEPTH-1];
// ob_packet_t OPB [0:OPB_DEPTH-1];



// action status
logic is_add, is_cancel, is_execute, is_delete;
assign is_add = (i_action == ADD);
assign is_cancel = (i_action == CANCEL);
assign is_execute = (i_action == EXECUTE);
assign is_delete = (i_action == DELETE);

// updated packet if it is the given orderid is canceled or executed
logic [PRICE_LEN-1:0] packet_out_price, packet_delete_price, packet_in_price;
logic [QUANTITY_LEN-1:0] packet_out_quantity, packet_delete_quantity, packet_in_quantity;
logic packet_out_side, packet_delete_side, packet_in_side;
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
logic                       p_side;

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
        o_side <= 0;
    end else begin
        p_quantity <= i_quantity;
        p_order_id <= i_order_id;
        p_price <= i_price;
        p_action <= i_action;
        p_valid <= i_valid;
        p_side <= i_side;
        o_action <= p_action;
        o_valid <= p_valid;
        o_quantity <= p_quantity;
        if(p_action == ADD) begin
            o_price <= p_price;
            o_side <= p_side;
        end else if(p_action == DELETE) begin
            o_price <= packet_delete_price;
            o_side <= packet_delete_side;
        end else begin
            o_price <= packet_out_price;
            o_side <= packet_out_side;
        end
        if(p_action == DELETE) begin
            if(delete_special_case) begin
                o_quantity <= delete_special_case_quant;
            end else begin
                o_quantity <= packet_delete_quantity;
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
        end else if((is_cancel || is_execute) && i_valid) begin
            p_exec_cancel <= 1;
        end else if(is_delete && i_valid && (p_exec_cancel) && (p_order_id == i_order_id)) begin
            delete_special_case <= 1'b1;
        end
    end
end


// BRAM
always_ff@(posedge i_clk) begin
    if(is_add && i_valid) begin
        packet_in_price <= i_price;
        packet_in_quantity <= i_quantity;
        packet_in_side <= i_side;
    end else if((is_cancel || is_execute) && i_valid) begin
        if(p_add && (p_order_id == i_order_id)) begin
            packet_out_quantity <= packet_in_quantity;
            packet_out_price <= packet_in_price;
            packet_out_side <= packet_in_side;
        end else begin
            packet_out_quantity <= OPB_quantity[i_order_id];
            packet_out_price <= OPB_price[i_order_id];
            packet_out_side <= OPB_side[i_order_id];
        end
    end else if(is_delete && i_valid) begin
        if(p_add && (p_order_id == i_order_id)) begin
            packet_delete_quantity <= packet_in_quantity;
            packet_delete_price <= packet_in_price;
            packet_delete_side <= packet_in_side;
        end else begin
            packet_delete_quantity <= OPB_quantity[i_order_id];
            packet_delete_price <= OPB_price[i_order_id];
            packet_delete_side <= OPB_side[i_order_id];
        end
    end

    if(p_add) begin
        OPB_price[p_order_id] <= packet_in_price;
        OPB_quantity[p_order_id] <= packet_in_quantity;
        OPB_side[p_order_id] <= packet_in_side;
    end else if(p_exec_cancel) begin
        if(!((is_cancel || is_execute) && (p_order_id == i_order_id) && (i_valid))) begin
            if (packet_out_quantity <= (quantity_to_remove + p_quantity)) begin
                OPB_quantity[p_order_id] <= '0;
            end else begin
                OPB_quantity[p_order_id] <= packet_out_quantity - quantity_to_remove - p_quantity;
            end
        end
    end
end

// second cycle
always_ff @(posedge i_clk, negedge i_rst_n) begin
    if(!i_rst_n) begin
        quantity_to_remove <= '0;
    end else begin
        if(p_exec_cancel) begin
            if((is_cancel || is_execute) && (p_order_id == i_order_id) && (i_valid)) begin
                quantity_to_remove <= quantity_to_remove + p_quantity;
            end else begin
                quantity_to_remove <= '0;
                delete_special_case_quant <= '0;
                if (!(packet_out_quantity <= (quantity_to_remove + p_quantity))) begin
                    delete_special_case_quant <= packet_out_quantity - quantity_to_remove - p_quantity;
                end
            end
        end
    end
end

endmodule
import ob_pkg::*;

module ob_opb (
    input  logic                     i_clk,
    input  logic                     i_rst_n,
    input  logic [ORDERID_LEN-1:0]   i_order_id,
    input  logic [QUANTITY_LEN-1:0]  i_quantity,
    input  logic [1:0]               i_action,
    input  logic                     i_valid,
    input  logic                     i_side,
    input  logic [PRICE_LEN-1:0]     i_price,

    output logic [1:0]               o_action,
    output logic [PRICE_LEN-1:0]     o_price,
    output logic                     o_valid,
    output logic [QUANTITY_LEN-1:0]  o_quantity,
    output logic                     o_side
);

    // ============================================================
    // Memory arrays
    // ============================================================
    (* ramstyle = "M10K" *) logic [PRICE_LEN-1:0]    opb_price    [0:OPB_DEPTH-1];
    (* ramstyle = "M10K" *) logic [QUANTITY_LEN-1:0] opb_quantity [0:OPB_DEPTH-1];
    (* ramstyle = "M10K" *) logic                    opb_side     [0:OPB_DEPTH-1];

    // ============================================================
    // Input decode
    // ============================================================
    logic is_add, is_cancel, is_execute, is_delete;

    assign is_add     = (i_action == ADD);
    assign is_cancel  = (i_action == CANCEL);
    assign is_execute = (i_action == EXECUTE);
    assign is_delete  = (i_action == DELETE);

    // ============================================================
    // Stage 0 input pipeline
    // ============================================================
    logic [ORDERID_LEN-1:0]   s0_order_id;
    logic [QUANTITY_LEN-1:0]  s0_quantity;
    logic [PRICE_LEN-1:0]     s0_price;
    logic                     s0_side;
    logic [1:0]               s0_action;
    logic                     s0_valid;

    logic                     s0_add, s0_cancel, s0_execute, s0_delete;

    always_ff @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            s0_order_id <= '0;
            s0_quantity <= '0;
            s0_price    <= '0;
            s0_side     <= 1'b0;
            s0_action   <= '0;
            s0_valid    <= 1'b0;

            s0_add      <= 1'b0;
            s0_cancel   <= 1'b0;
            s0_execute  <= 1'b0;
            s0_delete   <= 1'b0;
        end else begin
            s0_order_id <= i_order_id;
            s0_quantity <= i_quantity;
            s0_price    <= i_price;
            s0_side     <= i_side;
            s0_action   <= i_action;
            s0_valid    <= i_valid;

            s0_add      <= is_add;
            s0_cancel   <= is_cancel;
            s0_execute  <= is_execute;
            s0_delete   <= is_delete;
        end
    end

    // ============================================================
    // RAM interface signals
    // ============================================================
    logic [ORDERID_LEN-1:0]   rd_addr;
    logic [PRICE_LEN-1:0]     rd_price;
    logic [QUANTITY_LEN-1:0]  rd_quantity;
    logic                     rd_side;

    logic                     wr_en_price, wr_en_quantity, wr_en_side;
    logic [ORDERID_LEN-1:0]   wr_addr;
    logic [PRICE_LEN-1:0]     wr_price;
    logic [QUANTITY_LEN-1:0]  wr_quantity;
    logic                     wr_side;

    // ============================================================
    // Pure RAM block
    // No reset here
    // ============================================================
    always_ff @(posedge i_clk) begin
        rd_price    <= opb_price[rd_addr];
        rd_quantity <= opb_quantity[rd_addr];
        rd_side     <= opb_side[rd_addr];

        if (wr_en_price) begin
            opb_price[wr_addr] <= wr_price;
        end
        if (wr_en_quantity) begin
            opb_quantity[wr_addr] <= wr_quantity;
        end
        if (wr_en_side) begin
            opb_side[wr_addr] <= wr_side;
        end
    end

    // ============================================================
    // Read address generation
    // Always read current incoming order id
    // ============================================================
    always_ff @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            rd_addr <= '0;
        end else begin
            rd_addr <= i_order_id;
        end
    end

    // ============================================================
    // Stage 1 pipeline
    // Holds action aligned with RAM read data from previous cycle
    // ============================================================
    logic [ORDERID_LEN-1:0]   s1_order_id;
    logic [QUANTITY_LEN-1:0]  s1_quantity;
    logic [PRICE_LEN-1:0]     s1_price;
    logic                     s1_side;
    logic [1:0]               s1_action;
    logic                     s1_valid;

    logic                     s1_add, s1_cancel, s1_execute, s1_delete;

    logic [PRICE_LEN-1:0]     s1_mem_price;
    logic [QUANTITY_LEN-1:0]  s1_mem_quantity;
    logic                     s1_mem_side;

    always_ff @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            s1_order_id     <= '0;
            s1_quantity     <= '0;
            s1_price        <= '0;
            s1_side         <= 1'b0;
            s1_action       <= '0;
            s1_valid        <= 1'b0;

            s1_add          <= 1'b0;
            s1_cancel       <= 1'b0;
            s1_execute      <= 1'b0;
            s1_delete       <= 1'b0;

            s1_mem_price    <= '0;
            s1_mem_quantity <= '0;
            s1_mem_side     <= 1'b0;
        end else begin
            s1_order_id     <= s0_order_id;
            s1_quantity     <= s0_quantity;
            s1_price        <= s0_price;
            s1_side         <= s0_side;
            s1_action       <= s0_action;
            s1_valid        <= s0_valid;

            s1_add          <= s0_add;
            s1_cancel       <= s0_cancel;
            s1_execute      <= s0_execute;
            s1_delete       <= s0_delete;

            s1_mem_price    <= rd_price;
            s1_mem_quantity <= rd_quantity;
            s1_mem_side     <= rd_side;
        end
    end

    // ============================================================
    // Simple same-ID bypass from previous add
    // This is outside the RAM block
    // ============================================================
    logic prev_add_valid;
    logic [ORDERID_LEN-1:0]   prev_add_order_id;
    logic [PRICE_LEN-1:0]     prev_add_price;
    logic [QUANTITY_LEN-1:0]  prev_add_quantity;
    logic                     prev_add_side;

    always_ff @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            prev_add_valid    <= 1'b0;
            prev_add_order_id <= '0;
            prev_add_price    <= '0;
            prev_add_quantity <= '0;
            prev_add_side     <= 1'b0;
        end else begin
            prev_add_valid <= s0_valid && s0_add;
            if (s0_valid && s0_add) begin
                prev_add_order_id <= s0_order_id;
                prev_add_price    <= s0_price;
                prev_add_quantity <= s0_quantity;
                prev_add_side     <= s0_side;
            end
        end
    end

    logic use_bypass;
    logic [PRICE_LEN-1:0]     eff_price;
    logic [QUANTITY_LEN-1:0]  eff_quantity;
    logic                     eff_side;

    always_comb begin
        use_bypass   = 1'b0;
        eff_price    = s1_mem_price;
        eff_quantity = s1_mem_quantity;
        eff_side     = s1_mem_side;

        if (prev_add_valid && (prev_add_order_id == s1_order_id)) begin
            use_bypass   = 1'b1;
            eff_price    = prev_add_price;
            eff_quantity = prev_add_quantity;
            eff_side     = prev_add_side;
        end
    end

    // ============================================================
    // Write control
    // ============================================================
    logic [QUANTITY_LEN-1:0] new_quantity;
    logic                    zero_after_remove;

    always_comb begin
        wr_en_price    = 1'b0;
        wr_en_quantity = 1'b0;
        wr_en_side     = 1'b0;

        wr_addr        = s1_order_id;
        wr_price       = eff_price;
        wr_quantity    = eff_quantity;
        wr_side        = eff_side;

        zero_after_remove = (eff_quantity <= s1_quantity);

        if (s1_valid) begin
            if (s1_add) begin
                wr_en_price    = 1'b1;
                wr_en_quantity = 1'b1;
                wr_en_side     = 1'b1;

                wr_addr        = s1_order_id;
                wr_price       = s1_price;
                wr_quantity    = s1_quantity;
                wr_side        = s1_side;
            end
            else if (s1_cancel || s1_execute) begin
                wr_en_quantity = 1'b1;
                wr_addr        = s1_order_id;

                if (zero_after_remove) begin
                    wr_quantity = '0;
                end else begin
                    wr_quantity = eff_quantity - s1_quantity;
                end
            end
            else if (s1_delete) begin
                // optional: clear quantity only
                wr_en_quantity = 1'b1;
                wr_addr        = s1_order_id;
                wr_quantity    = '0;
            end
        end
    end

    // ============================================================
    // Outputs
    // ============================================================
    always_ff @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            o_action   <= '0;
            o_price    <= '0;
            o_valid    <= 1'b0;
            o_quantity <= '0;
            o_side     <= 1'b0;
        end else begin
            o_action <= s1_action;
            o_valid  <= s1_valid;

            if (s1_add) begin
                o_price    <= s1_price;
                o_quantity <= s1_quantity;
                o_side     <= s1_side;
            end
            else if (s1_cancel || s1_execute) begin
                o_price    <= eff_price;
                o_quantity <= s1_quantity;
                o_side     <= eff_side;
            end
            else if (s1_delete) begin
                o_price    <= eff_price;
                o_quantity <= eff_quantity;
                o_side     <= eff_side;
            end
            else begin
                o_price    <= '0;
                o_quantity <= '0;
                o_side     <= 1'b0;
            end
        end
    end

endmodule