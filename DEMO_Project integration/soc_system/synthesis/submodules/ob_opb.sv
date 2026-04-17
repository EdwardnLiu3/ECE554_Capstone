////////////////////////////////////////////////////////////////////////////////
//
// This module keep track of the price and quantity corresponding to the orderid
// and output the price, quantity, and action for FLB to make changes
//
// Each of the action take 2 cycles and is pipelined
//
////////////////////////////////////////////////////////////////////////////////
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
    output logic [QUANTITY_LEN-1:0] o_quantity,
    output logic o_side
);
import ob_pkg::*;

// OPB: force MLAB so reads are combinatorial (no 1-cycle latency like M10K)
// MLAB supports async reads — address is NOT internally registered
(* ramstyle = "MLAB" *) ob_packet_t OPB [0:OPB_DEPTH-1];

// packet captured when action=ADD (holds price/qty/side from parser)
ob_packet_t packet_in;

// Combinatorial async read from OPB using the pipelined order_id.
// p_order_id is i_order_id registered 1 cycle ago (available same cycle as p_exec_cancel).
// Bypass: if the previous cycle was an ADD, use packet_in directly to avoid
//         read-before-write hazard (OPB write hasn't committed at start of this cycle).
ob_packet_t packet_out;
assign packet_out = p_add ? packet_in : OPB[p_order_id];

// action decode
logic is_add, is_cancel, is_execute, is_delete;
assign is_add     = (i_action == ADD);
assign is_cancel  = (i_action == CANCEL);
assign is_execute = (i_action == EXECUTE);
assign is_delete  = (i_action == DELETE);

// pipeline-stage-1 registers (i_* → p_*)
logic [QUANTITY_LEN-1:0] p_quantity;
logic [ORDERID_LEN-1:0]  p_order_id;
logic                    p_add, p_exec_cancel, p_delete;
logic [PRICE_LEN-1:0]    p_price;
logic [1:0]              p_action;
logic                    p_valid;
logic                    p_side;

// pipeline-stage-2 state
logic [QUANTITY_LEN-1:0] quantity_to_remove;
logic                    delete_special_case;
logic [QUANTITY_LEN-1:0] delete_special_case_quant;

// ─── STAGE 1 ────────────────────────────────────────────────────────────────
// Register inputs and set control flags.
// Also drives outputs for the FOLLOWING cycle (stage-2 result).
always_ff @(posedge i_clk, negedge i_rst_n) begin
    if (!i_rst_n) begin
        p_quantity          <= '0;
        p_order_id          <= '0;
        p_price             <= '0;
        p_action            <= '0;
        p_valid             <= 0;
        p_side              <= 0;
        p_add               <= 0;
        p_exec_cancel       <= 0;
        p_delete            <= 0;
        delete_special_case <= 0;

        o_action   <= '0;
        o_price    <= '0;
        o_valid    <= 0;
        o_quantity <= '0;
        o_side     <= 0;
    end else begin
        // ── pipe the raw inputs ──
        p_quantity <= i_quantity;
        p_order_id <= i_order_id;
        p_price    <= i_price;
        p_action   <= i_action;
        p_valid    <= i_valid;
        p_side     <= i_side;

        // ── control flags (default off) ──
        p_add               <= 0;
        p_exec_cancel       <= 0;
        p_delete            <= 0;
        delete_special_case <= 0;

        if (is_add && i_valid) begin
            p_add    <= 1;
            packet_in <= '{price: i_price, quantity: i_quantity, side: i_side};

        end else if ((is_cancel || is_execute) && i_valid) begin
            p_exec_cancel <= 1;

        end else if (is_delete && i_valid) begin
            p_delete <= 1;
            if (p_exec_cancel && (p_order_id == i_order_id))
                delete_special_case <= 1'b1;
        end

        // ── stage-2 outputs (registered from stage-1 results) ──
        o_action   <= p_action;
        o_valid    <= p_valid;

        if (p_action == ADD) begin
            o_price    <= p_price;
            o_side     <= p_side;
            o_quantity <= p_quantity;
        end else if (p_action == DELETE) begin
            o_price    <= packet_out.price;
            o_side     <= packet_out.side;
            o_quantity <= delete_special_case ? delete_special_case_quant
                                              : packet_out.quantity;
        end else begin  // EXECUTE / CANCEL
            o_price    <= packet_out.price;   // <── MLAB async read: correct price NOW
            o_side     <= packet_out.side;
            o_quantity <= p_quantity;
        end
    end
end

// ─── STAGE 2 ────────────────────────────────────────────────────────────────
// Write updated quantities back into OPB.
always_ff @(posedge i_clk, negedge i_rst_n) begin
    if (!i_rst_n) begin
        quantity_to_remove      <= '0;
        delete_special_case_quant <= '0;
    end else begin
        if (p_add) begin
            OPB[p_order_id] <= packet_in;

        end else if (p_exec_cancel) begin
            // Consecutive execute/cancel for same order_id → accumulate
            if ((is_cancel || is_execute) && (p_order_id == i_order_id) && i_valid) begin
                quantity_to_remove <= quantity_to_remove + p_quantity;
            end else begin
                quantity_to_remove        <= '0;
                delete_special_case_quant <= '0;
                if (packet_out.quantity <= (quantity_to_remove + p_quantity)) begin
                    OPB[p_order_id] <= '{price: packet_out.price,
                                         quantity: '0,
                                         side: packet_out.side};
                end else begin
                    OPB[p_order_id] <= '{price: packet_out.price,
                                         quantity: packet_out.quantity
                                                   - quantity_to_remove
                                                   - p_quantity,
                                         side: packet_out.side};
                    delete_special_case_quant <= packet_out.quantity
                                                 - quantity_to_remove
                                                 - p_quantity;
                end
            end
        end
    end
end

endmodule
