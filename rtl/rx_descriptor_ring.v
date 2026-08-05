module rx_descriptor_ring (
    input  wire        clk,
    input  wire        rst,

    input  wire [7:0]  macrx_data,
    input  wire         macrx_data_valid,
    input  wire         macrx_sof,
    input  wire         macrx_eof,

    input  wire         classifier_valid,
    input  wire         classifier_accept,
    input  wire [31:0] classifier_dst_ip,
    input  wire [15:0] classifier_dst_port,
    input  wire [15:0] classifier_payload_len,

    input  wire [63:0] hwts_value,

    input  wire         sw_ren,

    output wire         ring_desc_valid,
    output wire [31:0] ring_desc_ip,
    output wire [15:0] ring_desc_port,
    output wire [15:0] ring_desc_len,
    output wire [63:0] ring_desc_timestamp,
    output wire [11:0] ring_desc_payload_addr,
    output wire         ring_full,
    output wire [3:0]  ring_head_ptr,
    output wire [3:0]  ring_tail_ptr
);

    localparam DESC_DEPTH   = 16;
    localparam PAYLOAD_SIZE = 4096;

    reg [7:0]  payload_mem [0:PAYLOAD_SIZE-1];

    reg [31:0] d_ip     [0:DESC_DEPTH-1];
    reg [15:0] d_port   [0:DESC_DEPTH-1];
    reg [15:0] d_len    [0:DESC_DEPTH-1];
    reg [63:0] d_ts     [0:DESC_DEPTH-1];
    reg [11:0] d_addr   [0:DESC_DEPTH-1];
    reg [12:0] d_stored [0:DESC_DEPTH-1];  // buffered byte count (internal,
                                           // for free-space accounting)

    reg [3:0]  head;            // software-side read pointer
    reg [3:0]  tail;            // hardware-side write pointer
    reg [4:0]  count;           // committed descriptors (0..16)

    reg [11:0] wr_ptr;          // speculative payload write pointer
    reg [11:0] frame_start;     // wr_ptr at sof, rewind target
    reg [12:0] frame_bytes;     // bytes written for the in-flight frame
    reg [12:0] committed_used;  // payload bytes owned by committed descs
    reg        overflow;        // in-flight frame ran out of buffer space

    wire [12:0] spec_used = committed_used + frame_bytes;
    wire        can_write = (spec_used < PAYLOAD_SIZE[12:0]) && !overflow;
    wire        do_write  = macrx_data_valid && can_write;

    wire [12:0] stored_total = frame_bytes + (do_write ? 13'd1 : 13'd0);

    wire pop    = sw_ren && (count != 5'd0);
    wire commit = classifier_valid && classifier_accept
                  && !overflow && can_write     // no byte was ever dropped
                  && (count != DESC_DEPTH[4:0]); // conservative: full means
                                                 // drop, even if popping now

    always @(posedge clk) begin
        if (rst) begin
            head           <= 4'd0;
            tail           <= 4'd0;
            count          <= 5'd0;
            wr_ptr         <= 12'd0;
            frame_start    <= 12'd0;
            frame_bytes    <= 13'd0;
            committed_used <= 13'd0;
            overflow       <= 1'b0;
        end else begin

            if (macrx_sof)
                frame_start <= wr_ptr;

            if (macrx_data_valid) begin
                if (can_write) begin
                    payload_mem[wr_ptr] <= macrx_data;
                    wr_ptr      <= wr_ptr + 12'd1;
                    frame_bytes <= frame_bytes + 13'd1;
                end else begin
                    overflow <= 1'b1;  // frame partially lost -> must drop
                end
            end

            if (classifier_valid) begin
                if (commit) begin
                    d_ip[tail]     <= classifier_dst_ip;
                    d_port[tail]   <= classifier_dst_port;
                    d_len[tail]    <= classifier_payload_len;
                    d_ts[tail]     <= hwts_value;
                    d_addr[tail]   <= frame_start;
                    d_stored[tail] <= stored_total;
                    tail           <= tail + 4'd1;
                    committed_used <= committed_used + stored_total
                                      - (pop ? d_stored[head] : 13'd0);
                end else begin
                    // reject/drop: rewind — speculative bytes reclaimed
                    wr_ptr <= frame_start;
                    committed_used <= committed_used
                                      - (pop ? d_stored[head] : 13'd0);
                end
                frame_bytes <= 13'd0;
                overflow    <= 1'b0;
            end else if (pop) begin
                committed_used <= committed_used - d_stored[head];
            end

            // ---- software pop ----
            if (pop)
                head <= head + 4'd1;

            count <= count + (commit ? 5'd1 : 5'd0) - (pop ? 5'd1 : 5'd0);
        end
    end

    assign ring_desc_valid        = (count != 5'd0);
    assign ring_desc_ip           = d_ip[head];
    assign ring_desc_port         = d_port[head];
    assign ring_desc_len          = d_len[head];
    assign ring_desc_timestamp    = d_ts[head];
    assign ring_desc_payload_addr = d_addr[head];
    assign ring_full              = (count == DESC_DEPTH[4:0]);
    assign ring_head_ptr          = head;
    assign ring_tail_ptr          = tail;

endmodule
