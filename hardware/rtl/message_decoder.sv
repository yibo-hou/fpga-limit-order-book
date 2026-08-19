`timescale 1ns / 1ps
import lob_pkg::*;
// message_decoder.sv - maps the raw 256-bit UDP payload onto msg_t.
//
// Byte 0 is the MSB of the payload (version), byte 1 = msg_type, byte 2 =
// side, byte 3 = flags, bytes 4-7 = seq_num, bytes 8-15 = order_id, bytes
// 16-19 = price, bytes 20-23 = quantity, bytes 24-31 = timestamp_ns.
// msg_type / side are already the numeric encodings, so no translation is
// performed -- only a version check.

module message_decoder (
    input  logic        clk,
    input  logic        rst_n,

    input  logic [255:0] s_payload,
    input  logic        s_payload_valid,
    output logic        s_payload_ready,

    output msg_t        m_msg,
    output logic        m_msg_valid,
    input  logic        m_msg_ready,

    output logic        m_bad_version
);

  logic [255:0] payload_q;
  logic         payload_v_q;

  logic bad_version_q;

  always_comb begin
    m_msg.version      = payload_q[255:248];
    m_msg.msg_type     = msg_type_t'(payload_q[247:240]);
    m_msg.side         = side_t'(payload_q[239:232]);
    m_msg.flags        = payload_q[231:224];
    m_msg.seq_num      = payload_q[223:192];
    m_msg.order_id     = payload_q[191:128];
    m_msg.price        = payload_q[127:96];
    m_msg.quantity     = payload_q[95:64];
    m_msg.timestamp_ns = payload_q[63:0];
  end

  assign bad_version_q = (payload_q[255:248] != VERSION);
  assign m_msg_valid   = payload_v_q && !bad_version_q;
  assign m_bad_version = payload_v_q && bad_version_q;
  assign s_payload_ready = !payload_v_q;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      payload_q   <= '0;
      payload_v_q <= 1'b0;
    end else begin
      if (s_payload_valid && s_payload_ready) begin
        payload_q   <= s_payload;
        payload_v_q <= 1'b1;
      end else if ((m_msg_valid && m_msg_ready) || m_bad_version) begin
        payload_v_q <= 1'b0;
      end
    end
  end

endmodule
