module udp_classifier (
    input  wire        clk,
    input  wire        rst,

    input  wire [7:0]  macrx_data,
    input  wire         macrx_data_valid,
    input  wire         macrx_sof,
    input  wire         macrx_eof,
    input  wire         macrx_frame_ok,

    input  wire         cfg_wr_en,
    input  wire [3:0]  cfg_wr_idx,
    input  wire [31:0] cfg_dst_ip,
    input  wire [15:0] cfg_dst_port,
    input  wire         cfg_entry_en,

    output wire         classifier_valid,
    output wire         classifier_accept,
    output wire [31:0] classifier_dst_ip,
    output wire [15:0] classifier_dst_port,
    output wire [15:0] classifier_payload_len
);

    localparam [15:0] ETHERTYPE_IPV4 = 16'h0800;
    localparam [7:0]  IPPROTO_UDP    = 8'd17;

    reg [31:0] entry_ip   [0:15];
    reg [15:0] entry_port [0:15];
    reg [15:0] entry_en;

    always @(posedge clk) begin
        if (rst) begin
            entry_en <= 16'd0;
        end else if (cfg_wr_en) begin
            entry_ip[cfg_wr_idx]   <= cfg_dst_ip;
            entry_port[cfg_wr_idx] <= cfg_dst_port;
            entry_en[cfg_wr_idx]   <= cfg_entry_en;
        end
    end

    reg [15:0] offs;         // next byte's offset (0 at sof, since sof
                             // accompanies the first byte)
    reg [7:0]  eth_hi;       // ethertype high byte, pending pair check
    reg        is_ipv4;
    reg        ver_ok;
    reg [3:0]  ihl;
    reg        is_udp;
    reg [31:0] dst_ip;
    reg [15:0] dst_port;
    reg [15:0] udp_len;
    reg        seen_eth, seen_ver, seen_proto,
               seen_dip, seen_dport, seen_ulen;

    // offset of the current byte (sof restarts the count in-cycle)
    wire [15:0] cur = macrx_sof ? 16'd0 : offs;
    // UDP header start: 14 (eth) + IHL*4 (IP header incl. options)
    wire [15:0] udp_base = 16'd14 + {10'd0, ihl, 2'b00};

    always @(posedge clk) begin
        if (rst) begin
            offs <= 16'd0;
            seen_eth <= 1'b0; seen_ver <= 1'b0; seen_proto <= 1'b0;
            seen_dip <= 1'b0; seen_dport <= 1'b0; seen_ulen <= 1'b0;
        end else if (macrx_data_valid) begin
            if (macrx_sof) begin
                seen_eth <= 1'b0; seen_ver <= 1'b0; seen_proto <= 1'b0;
                seen_dip <= 1'b0; seen_dport <= 1'b0; seen_ulen <= 1'b0;
            end

            // fixed-offset fields
            case (cur)
                16'd12: eth_hi <= macrx_data;
                16'd13: begin
                    is_ipv4  <= ({eth_hi, macrx_data} == ETHERTYPE_IPV4);
                    seen_eth <= 1'b1;
                end
                16'd14: begin
                    ver_ok   <= (macrx_data[7:4] == 4'd4);
                    ihl      <= macrx_data[3:0];
                    seen_ver <= 1'b1;
                end
                16'd23: begin
                    is_udp     <= (macrx_data == IPPROTO_UDP);
                    seen_proto <= 1'b1;
                end
                16'd30, 16'd31, 16'd32, 16'd33: begin
                    dst_ip <= {dst_ip[23:0], macrx_data};
                    if (cur == 16'd33) seen_dip <= 1'b1;
                end
                default: ;
            endcase

            if (seen_ver) begin
                if (cur == udp_base + 16'd2 || cur == udp_base + 16'd3) begin
                    dst_port <= {dst_port[7:0], macrx_data};
                    if (cur == udp_base + 16'd3) seen_dport <= 1'b1;
                end
                if (cur == udp_base + 16'd4 || cur == udp_base + 16'd5) begin
                    udp_len <= {udp_len[7:0], macrx_data};
                    if (cur == udp_base + 16'd5) seen_ulen <= 1'b1;
                end
            end

            offs <= cur + 16'd1;
        end
    end

    reg match_any;
    integer i;
    always @* begin
        match_any = 1'b0;
        for (i = 0; i < 16; i = i + 1)
            if (entry_en[i] && entry_ip[i] == dst_ip
                            && entry_port[i] == dst_port)
                match_any = 1'b1;
    end

    wire hdrs_complete = seen_eth & seen_ver & seen_proto
                       & seen_dip & seen_dport & seen_ulen;
    wire hdrs_valid    = is_ipv4 & ver_ok & (ihl >= 4'd5) & is_udp
                       & (udp_len >= 16'd8);

    assign classifier_valid  = macrx_eof;
    assign classifier_accept = macrx_eof & macrx_frame_ok
                             & hdrs_complete & hdrs_valid & match_any;

    assign classifier_dst_ip      = dst_ip;
    assign classifier_dst_port    = dst_port;
    assign classifier_payload_len = udp_len - 16'd8;

endmodule
