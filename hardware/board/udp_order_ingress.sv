`timescale 1ns / 1ps

// Converts one 32-byte UDP payload into the 256-bit LOB wire word.
module udp_order_ingress (
    input  logic         clk,
    input  logic         rst_n,
    input  logic [7:0]   payload_data,
    input  logic         payload_valid,
    input  logic         payload_start,
    input  logic         payload_last,
    input  logic [15:0]  payload_length,
    input  logic [31:0]  source_ip,
    input  logic [15:0]  source_port,
    output logic [303:0] message_data,
    output logic         message_valid,
    input  logic         message_ready,
    output logic         packet_drop
);
  logic [255:0] shift_q;
  logic [5:0] count_q;
  logic bad_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      shift_q      <= '0;
      count_q      <= '0;
      bad_q        <= 1'b0;
      message_data <= '0;
      message_valid<= 1'b0;
      packet_drop  <= 1'b0;
    end else begin
      message_valid <= 1'b0;
      packet_drop   <= 1'b0;

      if (payload_valid) begin
        if (payload_start) begin
          shift_q <= {248'b0, payload_data};
          count_q <= 6'd1;
          bad_q   <= (payload_length != 16'd32);
        end else begin
          shift_q <= {shift_q[247:0], payload_data};
          count_q <= count_q + 1'b1;
        end

        if (payload_last) begin
          if (!bad_q && payload_length == 16'd32 && count_q == 6'd31 &&
              message_ready) begin
            message_data  <= {source_ip, source_port,
                              shift_q[247:0], payload_data};
            message_valid <= 1'b1;
          end else begin
            packet_drop <= 1'b1;
          end
        end
      end
    end
  end
endmodule
