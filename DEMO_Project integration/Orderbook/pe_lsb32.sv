module pe_lsb128(
    input logic [31:0] i_data,
    output logic        o_found,
    output logic [4:0]  o_idx
);

always_comb begin
    o_found = 1'b0;
    o_idx   = 5'd0;

    for (int i = 0; i < 32; i++) begin
        if (i_data[i]) begin
            o_found = 1'b1;
            o_idx   = i[4:0];
            break;
        end
    end
end

endmodule
