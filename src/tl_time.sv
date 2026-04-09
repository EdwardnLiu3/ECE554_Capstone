module tl_time(
    input logic clk,
    input logic rst_n,
    input logic [47:0] order_time,

    output logic [47:0] T_sub_t
    );
    localparam [47:0] total_time_NS = 48'd57_600_000_000_000;
    localparam [47:0] open_time_NS  = 48'd34_200_000_000_000;

    assign T_sub_t = total_time_NS - order_time;

endmodule