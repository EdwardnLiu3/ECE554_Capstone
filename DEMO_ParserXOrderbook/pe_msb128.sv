module pe_msb128(
    input logic [127:0] i_data,
    output logic        o_found,
    output logic [6:0]  o_idx
);

always_comb begin
    o_found = 1'b0;
    o_idx   = 7'd0;

    for (int i = 127; i >= 0; i--) begin
        if (i_data[i]) begin
            o_found = 1'b1;
            o_idx   = i[6:0];
            break;
        end
    end
end

endmodule