module tl_time(
    input logic clk,
    input logic rst_n,
    input logic [47:0] order_time,

    output logic [47:0] T_sub_t
    );
    localparam [47:0] total_time_NS = 48'd57_600_000_000_000;  // 4:00 PM ET — market close
    localparam [47:0] open_time_NS  = 48'd34_200_000_000_000;  // 9:30 AM ET — market open

    // order_time should always be in valid market-hours timestamp
    // If order_time could be before market or after market close, we'd need to clamp to not allow edge cases like normalization over 1 and underflow
    assign T_sub_t = total_time_NS - order_time;

endmodule