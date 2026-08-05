module mac_rx (
    input  wire        clk,
    input  wire        rst,

    input  wire [7:0]  phy_data,
    input  wire         phy_data_valid,

    output wire [7:0]  macrx_data,
    output wire         macrx_data_valid,
    output wire         macrx_sof,
    output wire         macrx_eof,
    output wire         macrx_frame_ok,
    output wire         macrx_ready
);

    localparam [2:0] S_IDLE      = 3'd0,
                     S_PREAMBLE  = 3'd1,
                     S_SFD       = 3'd2,
                     S_PAYLOAD   = 3'd3,
                     S_FCS_CHECK = 3'd4;

    localparam [15:0] MIN_FRAME = 16'd64;
    localparam [15:0] MAX_FRAME = 16'd1518;

    localparam [31:0] CRC_RESIDUE = 32'hDEBB20E3;

    function [31:0] crc32_step(input [31:0] crc, input [7:0] b);
        integer i;
        reg [31:0] c;
        begin
            c = crc ^ {24'h0, b};
            for (i = 0; i < 8; i = i + 1)
                c = (c >> 1) ^ (c[0] ? 32'hEDB88320 : 32'h0);
            crc32_step = c;
        end
    endfunction

    reg [2:0]  state;
    reg [2:0]  pre_cnt;      // preamble bytes seen (saturates at 7)
    reg [39:0] dline;        // 5-byte delay line, oldest byte in [39:32]
    reg [2:0]  fill;         // how many bytes currently in dline (0..5)
    reg [31:0] crc;
    reg [15:0] frame_len;    // arrival count incl. FCS (saturating)
    reg        sof_pending;  // next emitted byte is the frame's first

    // Registered outputs
    reg [7:0]  data_q;
    reg        data_valid_q;
    reg        sof_q;
    reg        eof_q;
    reg        frame_ok_q;

    wire len_ok   = (frame_len >= MIN_FRAME) && (frame_len <= MAX_FRAME);
    wire frame_ok = (crc == CRC_RESIDUE) && len_ok;

    always @(posedge clk) begin
        if (rst) begin
            state        <= S_IDLE;
            pre_cnt      <= 3'd0;
            dline        <= 40'd0;
            fill         <= 3'd0;
            crc          <= 32'hFFFFFFFF;
            frame_len    <= 16'd0;
            sof_pending  <= 1'b0;
            data_q       <= 8'd0;
            data_valid_q <= 1'b0;
            sof_q        <= 1'b0;
            eof_q        <= 1'b0;
            frame_ok_q   <= 1'b0;
        end else begin
            // outputs are single-cycle pulses unless re-asserted below
            data_valid_q <= 1'b0;
            sof_q        <= 1'b0;
            eof_q        <= 1'b0;
            frame_ok_q   <= 1'b0;

            case (state)

                S_IDLE: begin
                    if (phy_data_valid && phy_data == 8'h55) begin
                        state   <= S_PREAMBLE;
                        pre_cnt <= 3'd1;
                    end
                    // anything else on an idle line is noise — ignore
                end

                S_PREAMBLE: begin
                    if (!phy_data_valid) begin
                        state <= S_IDLE;         // carrier dropped mid-preamble
                    end else if (phy_data == 8'h55) begin
                        pre_cnt <= pre_cnt + 3'd1;
                        if (pre_cnt >= 3'd6)
                            state <= S_SFD;      // 7th preamble byte this cycle
                    end else begin
                        state <= S_IDLE;         // false carrier
                    end
                end

                S_SFD: begin
                    if (!phy_data_valid) begin
                        state <= S_IDLE;
                    end else if (phy_data == 8'hD5) begin
                        // frame starts next byte
                        state       <= S_PAYLOAD;
                        crc         <= 32'hFFFFFFFF;
                        fill        <= 3'd0;
                        frame_len   <= 16'd0;
                        sof_pending <= 1'b1;
                    end else if (phy_data == 8'h55) begin
                        state <= S_SFD;          // tolerate long preamble
                    end else begin
                        state <= S_IDLE;         // garbage where SFD expected
                    end
                end

                S_PAYLOAD: begin
                    if (phy_data_valid) begin
                        // byte arrival: CRC + length on arrival, emission
                        // from the far end of the delay line once it's full
                        crc <= crc32_step(crc, phy_data);
                        if (frame_len != 16'hFFFF)
                            frame_len <= frame_len + 16'd1;
                        dline <= {dline[31:0], phy_data};
                        if (fill == 3'd5) begin
                            data_q       <= dline[39:32];
                            data_valid_q <= 1'b1;
                            sof_q        <= sof_pending;
                            sof_pending  <= 1'b0;
                        end else begin
                            fill <= fill + 3'd1;
                        end
                    end else begin
                        // valid dropped: delay line holds last data byte +
                        // 4 FCS bytes. Emit the data byte with eof/frame_ok.
                        eof_q      <= 1'b1;
                        frame_ok_q <= frame_ok;
                        if (fill == 3'd5) begin
                            data_q       <= dline[39:32];
                            data_valid_q <= 1'b1;
                            sof_q        <= sof_pending;  // 5-byte frame edge case
                        end
                        sof_pending <= 1'b0;
                        state       <= S_FCS_CHECK;
                    end
                end

                S_FCS_CHECK: begin
                    if (phy_data_valid && phy_data == 8'h55) begin
                        state   <= S_PREAMBLE;
                        pre_cnt <= 3'd1;
                    end else begin
                        state <= S_IDLE;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    assign macrx_data       = data_q;
    assign macrx_data_valid = data_valid_q;
    assign macrx_sof        = sof_q;
    assign macrx_eof        = eof_q;
    assign macrx_frame_ok   = frame_ok_q;

    assign macrx_ready      = 1'b1;

endmodule
