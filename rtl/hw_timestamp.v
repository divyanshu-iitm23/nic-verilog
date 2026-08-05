module hw_timestamp (
    input  wire        clk,
    input  wire        rst,

    input  wire         macrx_sof,

    output wire [63:0] hwts_counter,
    output wire [63:0] hwts_value,
    output wire         hwts_valid
);

    reg [63:0] counter_q;
    reg [63:0] value_q;
    reg        valid_q;

    always @(posedge clk) begin
        if (rst) begin
            counter_q <= 64'd0;
            value_q   <= 64'd0;
            valid_q   <= 1'b0;
        end else begin
            counter_q <= counter_q + 64'd1;

            if (macrx_sof)
                value_q <= counter_q;

            valid_q <= macrx_sof;
        end
    end

    assign hwts_counter = counter_q;
    assign hwts_value   = value_q;
    assign hwts_valid   = valid_q;


endmodule
