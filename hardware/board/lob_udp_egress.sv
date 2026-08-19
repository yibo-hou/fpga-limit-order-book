`timescale 1ns / 1ps
import lob_pkg::*;

// Arbitrates LOB reports and acknowledgements into fixed 32-byte UDP payloads.
// Wire ACK: version=1, type=0x80, status at byte 2, then order/status fields.
module lob_udp_egress (
    input  logic         clk,
    input  logic         rst_n,
    input  logic [255:0] report_data,
    input  logic         report_valid,
    output logic         report_ready,
    input  ack_t         ack_data,
    input  logic         ack_valid,
    output logic         ack_ready,

    output logic         packet_start_valid,
    input  logic         packet_start_ready,
    output logic [15:0]  payload_length,
    output logic [7:0]   payload_data,
    output logic         payload_valid,
    input  logic         payload_ready,
    output logic         payload_last
);
  typedef enum logic [1:0] {E_IDLE, E_START, E_SEND} estate_t;
  estate_t state;
  logic [255:0] word_q;
  logic [5:0] byte_count;

  function automatic logic [255:0] pack_ack(input ack_t a);
    logic [255:0] p;
    p = '0;
    p[255:248] = VERSION;
    p[247:240] = 8'h80;
    p[239:232] = {5'b0, a.status};
    p[191:128] = a.order_id;
    p[127:96]  = a.remaining_qty;
    p[95:64]   = a.best_bid;
    p[63:32]   = a.best_ask;
    p[31:0]    = {{(32-ADDR_W){1'b0}}, a.num_orders};
    return p;
  endfunction

  assign report_ready      = (state == E_IDLE) && report_valid;
  assign ack_ready         = (state == E_IDLE) && !report_valid && ack_valid;
  assign packet_start_valid= (state == E_START);
  assign payload_length    = 16'd32;
  assign payload_data      = word_q[255:248];
  assign payload_valid     = (state == E_SEND);
  assign payload_last      = (byte_count == 6'd31);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state      <= E_IDLE;
      word_q     <= '0;
      byte_count <= '0;
    end else begin
      case (state)
        E_IDLE: begin
          if (report_valid) begin
            word_q <= report_data;
            state  <= E_START;
          end else if (ack_valid) begin
            word_q <= pack_ack(ack_data);
            state  <= E_START;
          end
        end
        E_START: begin
          if (packet_start_ready) begin
            byte_count <= '0;
            state      <= E_SEND;
          end
        end
        E_SEND: begin
          if (payload_ready) begin
            if (byte_count == 6'd31) begin
              state <= E_IDLE;
            end else begin
              word_q     <= {word_q[247:0], 8'h00};
              byte_count <= byte_count + 1'b1;
            end
          end
        end
        default: state <= E_IDLE;
      endcase
    end
  end
endmodule
