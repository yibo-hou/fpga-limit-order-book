`timescale 1ns / 1ps

module arp_reply_tx #(
    parameter logic [47:0] LOCAL_MAC = 48'h00_0a_35_01_02_03,
    parameter logic [31:0] LOCAL_IP  = 32'hc0a8_010a
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        request_valid,
    output logic        request_ready,
    input  logic [47:0] requester_mac,
    input  logic [31:0] requester_ip,
    output logic        busy,
    output logic [7:0]  tx_data,
    output logic        tx_valid,
    output logic        packet_start,
    output logic        packet_end
);

typedef enum logic [2:0] {IDLE, PREAMBLE, FRAME, FCS, IFG} state_t;
state_t state;

logic [47:0] dst_mac;
logic [31:0] dst_ip;
logic [3:0] preamble_index;
logic [6:0] frame_index;
logic [2:0] fcs_index;
logic [3:0] ifg_index;
logic [7:0] frame_byte;
logic [31:0] crc_state;
logic [31:0] crc_next;
logic [31:0] fcs_value;

function automatic logic [7:0] mac_byte(input logic [47:0] mac,
                                         input integer index);
    mac_byte = mac >> ((5-index)*8);
endfunction

function automatic logic [7:0] ip_byte(input logic [31:0] ip,
                                        input integer index);
    ip_byte = ip >> ((3-index)*8);
endfunction

assign request_ready = (state == IDLE);

always_comb begin
    frame_byte = 8'h00;
    if (frame_index < 6)
        frame_byte = mac_byte(dst_mac, frame_index);
    else if (frame_index < 12)
        frame_byte = mac_byte(LOCAL_MAC, frame_index - 6);
    else begin
        case (frame_index)
            12: frame_byte = 8'h08;
            13: frame_byte = 8'h06;
            14: frame_byte = 8'h00;
            15: frame_byte = 8'h01;
            16: frame_byte = 8'h08;
            17: frame_byte = 8'h00;
            18: frame_byte = 8'h06;
            19: frame_byte = 8'h04;
            20: frame_byte = 8'h00;
            21: frame_byte = 8'h02;
            22,23,24,25,26,27: frame_byte = mac_byte(LOCAL_MAC, frame_index-22);
            28,29,30,31: frame_byte = ip_byte(LOCAL_IP, frame_index-28);
            32,33,34,35,36,37: frame_byte = mac_byte(dst_mac, frame_index-32);
            38,39,40,41: frame_byte = ip_byte(dst_ip, frame_index-38);
            default: frame_byte = 8'h00;
        endcase
    end
end

always_comb begin
    tx_data  = 8'h00;
    tx_valid = 1'b0;
    case (state)
        PREAMBLE: begin
            tx_valid = 1'b1;
            tx_data  = (preamble_index == 7) ? 8'hd5 : 8'h55;
        end
        FRAME: begin
            tx_valid = 1'b1;
            tx_data  = frame_byte;
        end
        FCS: begin
            tx_valid = 1'b1;
            case (fcs_index)
                0: tx_data = fcs_value[7:0];
                1: tx_data = fcs_value[15:8];
                2: tx_data = fcs_value[23:16];
                default: tx_data = fcs_value[31:24];
            endcase
        end
        default: begin end
    endcase
end

ethernet_crc32 u_crc (
    .clk        (clk),
    .rst_n      (rst_n),
    .init       (state == IDLE || state == PREAMBLE),
    .data_valid (state == FRAME),
    .data       (frame_byte),
    .crc_state  (crc_state),
    .crc_next   (crc_next)
);

always_ff @(posedge clk) begin
    if (!rst_n) begin
        state          <= IDLE;
        dst_mac        <= '0;
        dst_ip         <= '0;
        preamble_index <= '0;
        frame_index    <= '0;
        fcs_index      <= '0;
        ifg_index      <= '0;
        fcs_value      <= '0;
        busy           <= 1'b0;
        packet_start   <= 1'b0;
        packet_end     <= 1'b0;
    end else begin
        packet_start <= 1'b0;
        packet_end   <= 1'b0;
        case (state)
            IDLE: begin
                busy <= 1'b0;
                if (request_valid) begin
                    dst_mac        <= requester_mac;
                    dst_ip         <= requester_ip;
                    preamble_index <= '0;
                    busy           <= 1'b1;
                    packet_start   <= 1'b1;
                    state          <= PREAMBLE;
                end
            end
            PREAMBLE: begin
                if (preamble_index == 7) begin
                    frame_index <= '0;
                    state       <= FRAME;
                end else preamble_index <= preamble_index + 1'b1;
            end
            FRAME: begin
                if (frame_index == 59) begin
                    fcs_value <= ~crc_next;
                    fcs_index <= '0;
                    state     <= FCS;
                end else frame_index <= frame_index + 1'b1;
            end
            FCS: begin
                if (fcs_index == 3) begin
                    packet_end <= 1'b1;
                    ifg_index  <= '0;
                    state      <= IFG;
                end else fcs_index <= fcs_index + 1'b1;
            end
            IFG: begin
                if (ifg_index == 11) begin
                    busy  <= 1'b0;
                    state <= IDLE;
                end else ifg_index <= ifg_index + 1'b1;
            end
            default: state <= IDLE;
        endcase
    end
end

endmodule
