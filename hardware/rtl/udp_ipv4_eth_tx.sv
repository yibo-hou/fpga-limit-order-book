`timescale 1ns / 1ps

// Generates a complete Ethernet frame stream including preamble, SFD, FCS and
// inter-frame gap. UDP checksum is zero, which is valid for IPv4.
//
// Ethernet cannot pause after a frame starts.  The payload source must hold
// the first byte while payload_ready is low and then provide one valid byte on
// every cycle for payload_length cycles once payload_ready goes high.
module udp_ipv4_eth_tx #(
    parameter logic [47:0] SRC_MAC  = 48'h00_0a_35_01_02_03,
    parameter logic [31:0] SRC_IP   = 32'hc0a8_010a,
    parameter logic [31:0] DST_IP   = 32'hc0a8_0164,
    parameter logic [15:0] SRC_PORT = 16'd5000,
    parameter logic [15:0] DST_PORT = 16'd5000
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic [47:0] dst_mac,

    input  logic        packet_start_valid,
    output logic        packet_start_ready,
    input  logic [15:0] payload_length,
    output logic        busy,

    input  logic [7:0]  payload_data,
    input  logic        payload_valid,
    output logic        payload_ready,
    input  logic        payload_last,
    output logic        payload_error,

    output logic [7:0]  tx_data,
    output logic        tx_valid,
    output logic        packet_start,
    output logic        packet_end
);

localparam integer PAYLOAD_OFFSET = 14 + 20 + 8;

typedef enum logic [2:0] {
    ST_IDLE,
    ST_PREAMBLE,
    ST_FRAME,
    ST_FCS,
    ST_IFG
} state_t;

state_t state;
logic [3:0] preamble_index;
logic [15:0] frame_index;
logic [2:0] fcs_index;
logic [3:0] ifg_index;
logic [15:0] udp_length_latched;
logic [15:0] ip_total_length_latched;
logic [15:0] frame_bytes_latched;
logic [15:0] ip_identification;
logic [31:0] fcs_value;
logic [7:0] frame_byte;
logic [31:0] crc_state;
logic [31:0] crc_next;
logic crc_init;
logic crc_enable;
logic [15:0] ip_header_checksum_latched;
logic expected_payload_last;
logic [47:0] dst_mac_latched;

function automatic logic [7:0] mac_byte;
    input logic [47:0] mac;
    input integer index;
    begin
        mac_byte = mac >> ((5-index)*8);
    end
endfunction

function automatic logic [7:0] ip_byte;
    input logic [31:0] ip;
    input integer index;
    begin
        ip_byte = ip >> ((3-index)*8);
    end
endfunction

function automatic logic [15:0] ipv4_checksum;
    input logic [15:0] identification;
    input logic [15:0] total_length;
    logic [31:0] sum;
    begin
        sum = 32'h0000_4500 + total_length + identification +
              32'h0000_4000 + 32'h0000_4011 +
              {16'h0000, SRC_IP[31:16]} + {16'h0000, SRC_IP[15:0]} +
              {16'h0000, DST_IP[31:16]} + {16'h0000, DST_IP[15:0]};
        sum = (sum & 32'h0000_ffff) + (sum >> 16);
        sum = (sum & 32'h0000_ffff) + (sum >> 16);
        ipv4_checksum = ~sum[15:0];
    end
endfunction

assign packet_start_ready = (state == ST_IDLE);
assign expected_payload_last = (frame_index == frame_bytes_latched - 1'b1);

always_comb begin
    frame_byte = 8'h00;

    if (frame_index < 6)
        frame_byte = mac_byte(dst_mac_latched, frame_index);
    else if (frame_index < 12)
        frame_byte = mac_byte(SRC_MAC, frame_index - 6);
    else begin
        case (frame_index)
            12: frame_byte = 8'h08;
            13: frame_byte = 8'h00;
            14: frame_byte = 8'h45;
            15: frame_byte = 8'h00;
            16: frame_byte = ip_total_length_latched[15:8];
            17: frame_byte = ip_total_length_latched[7:0];
            18: frame_byte = ip_identification[15:8];
            19: frame_byte = ip_identification[7:0];
            20: frame_byte = 8'h40;
            21: frame_byte = 8'h00;
            22: frame_byte = 8'd64;
            23: frame_byte = 8'd17;
            24: frame_byte = ip_header_checksum_latched[15:8];
            25: frame_byte = ip_header_checksum_latched[7:0];
            26: frame_byte = ip_byte(SRC_IP, 0);
            27: frame_byte = ip_byte(SRC_IP, 1);
            28: frame_byte = ip_byte(SRC_IP, 2);
            29: frame_byte = ip_byte(SRC_IP, 3);
            30: frame_byte = ip_byte(DST_IP, 0);
            31: frame_byte = ip_byte(DST_IP, 1);
            32: frame_byte = ip_byte(DST_IP, 2);
            33: frame_byte = ip_byte(DST_IP, 3);
            34: frame_byte = SRC_PORT[15:8];
            35: frame_byte = SRC_PORT[7:0];
            36: frame_byte = DST_PORT[15:8];
            37: frame_byte = DST_PORT[7:0];
            38: frame_byte = udp_length_latched[15:8];
            39: frame_byte = udp_length_latched[7:0];
            40: frame_byte = 8'h00;
            41: frame_byte = 8'h00;
            default: frame_byte = payload_valid ? payload_data : 8'h00;
        endcase
    end
end

always_comb begin
    tx_data       = 8'h00;
    tx_valid      = 1'b0;
    payload_ready = 1'b0;
    crc_init      = (state == ST_IDLE) || (state == ST_PREAMBLE);
    crc_enable    = (state == ST_FRAME);

    case (state)
        ST_PREAMBLE: begin
            tx_valid = 1'b1;
            tx_data  = (preamble_index == 7) ? 8'hd5 : 8'h55;
        end
        ST_FRAME: begin
            tx_valid = 1'b1;
            tx_data  = frame_byte;
            payload_ready = (frame_index >= PAYLOAD_OFFSET);
        end
        ST_FCS: begin
            tx_valid = 1'b1;
            case (fcs_index)
                0: tx_data = fcs_value[7:0];
                1: tx_data = fcs_value[15:8];
                2: tx_data = fcs_value[23:16];
                default: tx_data = fcs_value[31:24];
            endcase
        end
        default: begin
            tx_valid = 1'b0;
            tx_data  = 8'h00;
        end
    endcase
end

ethernet_crc32 u_ethernet_crc32 (
    .clk        (clk),
    .rst_n      (rst_n),
    .init       (crc_init),
    .data_valid (crc_enable),
    .data       (frame_byte),
    .crc_state  (crc_state),
    .crc_next   (crc_next)
);

always_ff @(posedge clk) begin
    if (!rst_n) begin
        state                  <= ST_IDLE;
        preamble_index         <= '0;
        frame_index            <= '0;
        fcs_index              <= '0;
        ifg_index              <= '0;
        udp_length_latched     <= '0;
        ip_total_length_latched <= '0;
        frame_bytes_latched    <= '0;
        ip_header_checksum_latched <= '0;
        dst_mac_latched        <= '0;
        ip_identification      <= '0;
        fcs_value              <= '0;
        busy                   <= 1'b0;
        packet_start           <= 1'b0;
        packet_end             <= 1'b0;
        payload_error          <= 1'b0;
    end else begin
        packet_start <= 1'b0;
        packet_end   <= 1'b0;

        case (state)
            ST_IDLE: begin
                busy <= 1'b0;
                if (packet_start_valid && packet_start_ready) begin
                    dst_mac_latched          <= dst_mac;
                    udp_length_latched       <= payload_length + 16'd8;
                    ip_total_length_latched  <= payload_length + 16'd28;
                    frame_bytes_latched      <= payload_length + 16'd42;
                    ip_header_checksum_latched <=
                        ipv4_checksum(ip_identification,
                                      payload_length + 16'd28);
                    state                    <= ST_PREAMBLE;
                    preamble_index           <= '0;
                    busy                     <= 1'b1;
                    packet_start             <= 1'b1;
                    payload_error            <= 1'b0;
                end
            end

            ST_PREAMBLE: begin
                if (preamble_index == 7) begin
                    state       <= ST_FRAME;
                    frame_index <= '0;
                end else begin
                    preamble_index <= preamble_index + 1'b1;
                end
            end

            ST_FRAME: begin
                if (frame_index >= PAYLOAD_OFFSET) begin
                    if (!payload_valid || (payload_last != expected_payload_last))
                        payload_error <= 1'b1;
                end

                if (frame_index == frame_bytes_latched - 1'b1) begin
                    fcs_value <= ~crc_next;
                    fcs_index <= '0;
                    state     <= ST_FCS;
                end else begin
                    frame_index <= frame_index + 1'b1;
                end
            end

            ST_FCS: begin
                if (fcs_index == 3) begin
                    packet_end        <= 1'b1;
                    ip_identification <= ip_identification + 1'b1;
                    ifg_index         <= '0;
                    state             <= ST_IFG;
                end else begin
                    fcs_index <= fcs_index + 1'b1;
                end
            end

            ST_IFG: begin
                if (ifg_index == 11) begin
                    state <= ST_IDLE;
                    busy  <= 1'b0;
                end else begin
                    ifg_index <= ifg_index + 1'b1;
                end
            end

            default: state <= ST_IDLE;
        endcase
    end
end

endmodule
