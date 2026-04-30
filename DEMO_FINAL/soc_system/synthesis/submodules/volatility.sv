import ob_pkg::*;
module volatility_ewma (
    input  logic        clk,
    input  logic        rst_n,
    input  logic [15:0] lambda, //Q0.16
    input  logic        price_valid,
    input  logic [PRICE_LEN-1:0] mid_price,
    output logic [47:0] sigma_out,//Q32.16
    output logic        sigma_valid
);


    logic [31:0] prev_price;
    logic prev_valid;
    logic [47:0] sigma_reg;

    //Price change squared
    logic signed [32:0] delta;
    assign delta = $signed({1'b0, mid_price}) - $signed({1'b0, prev_price});
    logic [65:0] delta_sq;
    assign delta_sq = delta * delta;

    //Scale up since its a decimal
    logic [81:0] new_sq_scaled;
    assign new_sq_scaled = {delta_sq, 16'h0000}; //should be in Q32.16
    logic [16:0] one_minus_lambda; //Q1.16
    assign one_minus_lambda = 17'h10000 - {1'b0, lambda};

    logic [98:0] term_new_full;
    assign term_new_full = one_minus_lambda * new_sq_scaled;

    logic [64:0] term_old_full;
    assign term_old_full = lambda * sigma_reg;
    
    logic [47:0] term_new_shifted;
    logic [47:0] term_old_shifted;
    logic [47:0] sigma_next;
    // Practical mid-price deltas are small in these replays, so the lower 48 bits
    // preserve the useful EWMA signal while avoiding the old 16-bit truncation.
    assign term_new_shifted = term_new_full[63:16];
    assign term_old_shifted = term_old_full[63:16];
    assign sigma_next = term_new_shifted + term_old_shifted;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            prev_price   <= '0;
            prev_valid   <= 1'b0;
            sigma_reg   <= '0;
            sigma_valid <= 1'b0;
        end else if (price_valid) begin
            prev_price <= mid_price;
            prev_valid <= 1'b1;
            if (prev_valid) begin
                sigma_reg   <= sigma_next;
                sigma_valid <= 1'b1;
            end
        end
    end

    assign sigma_out = sigma_reg;

endmodule
