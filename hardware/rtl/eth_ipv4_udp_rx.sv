`timescale 1ns / 1ps

// Minimal receive parser for Ethernet-II, ARP, IPv4 (IHL=5, no fragments)
// and UDP. It deliberately exposes only payloads addressed to LOCAL_IP and
// UDP_PORT, plus valid ARP requests and replies involving LOCAL_IP.
module eth_ipv4_udp_rx #(
    parameter logic [47:0] LOCAL_MAC = 48'h00_0a_35_01_02_03,
    parameter logic [31:0] LOCAL_IP  = 32'hc0a8_010a,
    parameter logic [15:0] UDP_PORT  = 16'd5001
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic [7:0]  rx_data,
    input  logic        rx_valid,
    input  logic        rx_error,

    output logic [7:0]  payload_data,
    output logic        payload_valid,
    output logic        payload_start,
    output logic        payload_last,
    output logic [15:0] payload_length,
    output logic [31:0] udp_source_ip,
    output logic [15:0] udp_source_port,

    output logic        arp_request,
    output logic        arp_reply,
    output logic [47:0] arp_sender_mac,
    output logic [31:0] arp_sender_ip,

    output logic        frame_seen,
    output logic        frame_drop,
    output logic        udp_packet_seen
);

logic in_frame;
logic [3:0] preamble_count;
logic [15:0] frame_index;
logic frame_has_error;

logic [47:0] dst_mac_shift;
logic [47:0] src_mac_shift;
logic [15:0] ether_type;
logic [31:0] src_ip_shift;
logic [31:0] dst_ip_shift;
logic [15:0] src_port_shift;
logic [15:0] dst_port_shift;
logic [15:0] udp_length_shift;
logic [15:0] udp_payload_index;
logic udp_match;
logic ip_header_ok;

logic [15:0] arp_opcode_shift;
logic [47:0] arp_sha_shift;
logic [31:0] arp_spa_shift;
logic [47:0] arp_tha_shift;
logic [31:0] arp_tpa_shift;
logic arp_header_ok;

wire [47:0] dst_mac_next = {dst_mac_shift[39:0], rx_data};
wire [47:0] src_mac_next = {src_mac_shift[39:0], rx_data};
wire [31:0] src_ip_next  = {src_ip_shift[23:0], rx_data};
wire [31:0] dst_ip_next  = {dst_ip_shift[23:0], rx_data};
wire [15:0] src_port_next = {src_port_shift[7:0], rx_data};
wire [15:0] dst_port_next = {dst_port_shift[7:0], rx_data};
wire [15:0] udp_length_next = {udp_length_shift[7:0], rx_data};
wire [47:0] arp_sha_next = {arp_sha_shift[39:0], rx_data};
wire [31:0] arp_spa_next = {arp_spa_shift[23:0], rx_data};
wire [47:0] arp_tha_next = {arp_tha_shift[39:0], rx_data};
wire [31:0] arp_tpa_next = {arp_tpa_shift[23:0], rx_data};

always_ff @(posedge clk) begin
    if (!rst_n) begin
        in_frame          <= 1'b0;
        preamble_count     <= '0;
        frame_index        <= '0;
        frame_has_error    <= 1'b0;
        dst_mac_shift      <= '0;
        src_mac_shift      <= '0;
        ether_type         <= '0;
        src_ip_shift       <= '0;
        dst_ip_shift       <= '0;
        src_port_shift     <= '0;
        dst_port_shift     <= '0;
        udp_length_shift   <= '0;
        udp_payload_index  <= '0;
        udp_match          <= 1'b0;
        ip_header_ok       <= 1'b0;
        payload_data       <= '0;
        payload_valid      <= 1'b0;
        payload_start      <= 1'b0;
        payload_last       <= 1'b0;
        payload_length     <= '0;
        udp_source_ip      <= '0;
        udp_source_port    <= '0;
        arp_opcode_shift   <= '0;
        arp_sha_shift      <= '0;
        arp_spa_shift      <= '0;
        arp_tha_shift      <= '0;
        arp_tpa_shift      <= '0;
        arp_header_ok      <= 1'b1;
        arp_request        <= 1'b0;
        arp_reply          <= 1'b0;
        arp_sender_mac     <= '0;
        arp_sender_ip      <= '0;
        frame_seen         <= 1'b0;
        frame_drop         <= 1'b0;
        udp_packet_seen    <= 1'b0;
    end else begin
        payload_valid   <= 1'b0;
        payload_start   <= 1'b0;
        payload_last    <= 1'b0;
        arp_request     <= 1'b0;
        arp_reply       <= 1'b0;
        frame_seen      <= 1'b0;
        frame_drop      <= 1'b0;
        udp_packet_seen <= 1'b0;

        if (!in_frame) begin
            if (rx_valid) begin
                if (rx_data == 8'h55) begin
                    if (preamble_count != 4'hf)
                        preamble_count <= preamble_count + 1'b1;
                end else if (rx_data == 8'hd5 && preamble_count >= 6) begin
                    in_frame         <= 1'b1;
                    frame_index      <= 16'd0;
                    frame_has_error  <= rx_error;
                    dst_mac_shift     <= '0;
                    src_mac_shift     <= '0;
                    ether_type        <= '0;
                    src_ip_shift      <= '0;
                    dst_ip_shift      <= '0;
                    src_port_shift    <= '0;
                    dst_port_shift    <= '0;
                    udp_length_shift  <= '0;
                    udp_payload_index <= '0;
                    udp_match         <= 1'b0;
                    ip_header_ok      <= 1'b1;
                    arp_opcode_shift  <= '0;
                    arp_sha_shift     <= '0;
                    arp_spa_shift     <= '0;
                    arp_tha_shift     <= '0;
                    arp_tpa_shift     <= '0;
                    arp_header_ok     <= 1'b1;
                    preamble_count    <= '0;
                end else begin
                    preamble_count <= '0;
                end
            end else begin
                preamble_count <= '0;
            end
        end else if (rx_valid) begin
            frame_has_error <= frame_has_error | rx_error;

            if (frame_index <= 5)
                dst_mac_shift <= dst_mac_next;
            else if (frame_index <= 11)
                src_mac_shift <= src_mac_next;

            case (frame_index)
                12: ether_type[15:8] <= rx_data;
                13: ether_type[7:0]  <= rx_data;

                // IPv4 fixed header.
                14: if (rx_data != 8'h45) ip_header_ok <= 1'b0;
                20: if (rx_data[5:0] != 0) ip_header_ok <= 1'b0;
                21: if (rx_data != 0) ip_header_ok <= 1'b0;
                23: if (rx_data != 8'd17) ip_header_ok <= 1'b0;
                26,27,28,29: begin
                    src_ip_shift <= src_ip_next;
                    if (frame_index == 29)
                        udp_source_ip <= src_ip_next;
                end
                30,31,32,33: dst_ip_shift <= dst_ip_next;
                34,35: begin
                    src_port_shift <= src_port_next;
                    if (frame_index == 35)
                        udp_source_port <= src_port_next;
                end
                36,37: dst_port_shift <= dst_port_next;
                38,39: begin
                    udp_length_shift <= udp_length_next;
                    if (frame_index == 39) begin
                        payload_length <= (udp_length_next >= 8) ?
                                          udp_length_next - 16'd8 : 16'd0;
                        udp_match <= (ether_type == 16'h0800) &&
                                     (dst_mac_shift == LOCAL_MAC) &&
                                     ip_header_ok &&
                                     (dst_ip_shift == LOCAL_IP) &&
                                     (dst_port_shift == UDP_PORT) &&
                                     (udp_length_next >= 16'd8);
                    end
                end
                default: begin end
            endcase

            // ARP request fields share byte offsets with IPv4 only after the
            // EtherType has already selected the interpretation.
            if (ether_type == 16'h0806) begin
                case (frame_index)
                    14: if (rx_data != 8'h00) arp_header_ok <= 1'b0;
                    15: if (rx_data != 8'h01) arp_header_ok <= 1'b0;
                    16: if (rx_data != 8'h08) arp_header_ok <= 1'b0;
                    17: if (rx_data != 8'h00) arp_header_ok <= 1'b0;
                    18: if (rx_data != 8'h06) arp_header_ok <= 1'b0;
                    19: if (rx_data != 8'h04) arp_header_ok <= 1'b0;
                    20,21: arp_opcode_shift <= {arp_opcode_shift[7:0], rx_data};
                    22,23,24,25,26,27: arp_sha_shift <= arp_sha_next;
                    28,29,30,31: arp_spa_shift <= arp_spa_next;
                    32,33,34,35,36,37: arp_tha_shift <= arp_tha_next;
                    38,39,40,41: begin
                        arp_tpa_shift <= arp_tpa_next;
                        if (frame_index == 41 &&
                            arp_header_ok &&
                            arp_opcode_shift == 16'h0001 &&
                            arp_tpa_next == LOCAL_IP &&
                            (dst_mac_shift == 48'hffff_ffff_ffff ||
                             dst_mac_shift == LOCAL_MAC)) begin
                            arp_request    <= 1'b1;
                            arp_sender_mac <= arp_sha_shift;
                            arp_sender_ip  <= arp_spa_shift;
                        end else if (frame_index == 41 &&
                            arp_header_ok &&
                            arp_opcode_shift == 16'h0002 &&
                            arp_tpa_next == LOCAL_IP &&
                            arp_tha_shift == LOCAL_MAC &&
                            dst_mac_shift == LOCAL_MAC) begin
                            arp_reply      <= 1'b1;
                            arp_sender_mac <= arp_sha_shift;
                            arp_sender_ip  <= arp_spa_shift;
                        end
                    end
                    default: begin end
                endcase
            end

            if (frame_index >= 42 && udp_match &&
                udp_payload_index < payload_length) begin
                payload_data  <= rx_data;
                payload_valid <= 1'b1;
                payload_start <= (udp_payload_index == 0);
                payload_last  <= (udp_payload_index == payload_length - 1'b1);
                if (udp_payload_index == 0)
                    udp_packet_seen <= 1'b1;
                udp_payload_index <= udp_payload_index + 1'b1;
            end

            frame_index <= frame_index + 1'b1;
        end else begin
            in_frame   <= 1'b0;
            frame_seen <= 1'b1;
            frame_drop <= frame_has_error;
        end
    end
end

endmodule
