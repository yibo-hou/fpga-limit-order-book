`timescale 1ns / 1ps

// Fixed 1-Gbit/s RGMII receiver. OPPOSITE_EDGE captures the low nibble on
// RXC rising and the high nibble on RXC falling; the following rising edge
// combines the previous complete pair into one byte.
module rgmii_rx (
    input  wire        rgmii_rxc,
    input  wire        ref_clk_200m,
    input  logic       idelay_rst_n,
    input  logic       rst_n,
    input  wire [3:0]  rgmii_rxd,
    input  wire        rgmii_rx_ctl,
    output wire        rx_clk,
    output wire        idelay_ready,
    output logic [7:0] rx_data,
    output logic       rx_valid,
    output logic       rx_error
);
  wire rxc_ibuf;
  wire rxc_io;
  wire [3:0] rxd_delayed;
  wire rx_ctl_delayed;
  wire [3:0] data_rise;
  wire [3:0] data_fall;
  wire ctl_rise;
  wire ctl_fall;
  logic [3:0] low_nibble_q;

  IBUF u_rxc_ibuf (.I(rgmii_rxc), .O(rxc_ibuf));
  BUFIO u_rxc_bufio (.I(rxc_ibuf), .O(rxc_io));
  BUFG u_rxc_bufg (.I(rxc_ibuf), .O(rx_clk));

  (* IODELAY_GROUP = "rgmii_rx_delay" *)
  IDELAYCTRL u_idelayctrl (
      .REFCLK(ref_clk_200m), .RST(!idelay_rst_n), .RDY(idelay_ready));

  genvar i;
  generate
    for (i = 0; i < 4; i = i + 1) begin : g_rx_idelay
      (* IODELAY_GROUP = "rgmii_rx_delay" *)
      IDELAYE2 #(
          .CINVCTRL_SEL("FALSE"), .DELAY_SRC("IDATAIN"),
          .HIGH_PERFORMANCE_MODE("TRUE"), .IDELAY_TYPE("FIXED"),
          .IDELAY_VALUE(20), .PIPE_SEL("FALSE"),
          .REFCLK_FREQUENCY(200.0), .SIGNAL_PATTERN("DATA")
      ) u_idelay_data (
          .DATAOUT(rxd_delayed[i]), .DATAIN(1'b0),
          .C(1'b0), .CE(1'b0), .CINVCTRL(1'b0),
          .CNTVALUEIN(5'b00000), .IDATAIN(rgmii_rxd[i]),
          .INC(1'b0), .LD(1'b0), .LDPIPEEN(1'b0), .REGRST(1'b0),
          .CNTVALUEOUT());
    end
  endgenerate

  (* IODELAY_GROUP = "rgmii_rx_delay" *)
  IDELAYE2 #(
      .CINVCTRL_SEL("FALSE"), .DELAY_SRC("IDATAIN"),
      .HIGH_PERFORMANCE_MODE("TRUE"), .IDELAY_TYPE("FIXED"),
      .IDELAY_VALUE(20), .PIPE_SEL("FALSE"),
      .REFCLK_FREQUENCY(200.0), .SIGNAL_PATTERN("DATA")
  ) u_idelay_ctl (
      .DATAOUT(rx_ctl_delayed), .DATAIN(1'b0),
      .C(1'b0), .CE(1'b0), .CINVCTRL(1'b0),
      .CNTVALUEIN(5'b00000), .IDATAIN(rgmii_rx_ctl),
      .INC(1'b0), .LD(1'b0), .LDPIPEEN(1'b0), .REGRST(1'b0),
      .CNTVALUEOUT());

  generate
    for (i = 0; i < 4; i = i + 1) begin : g_rx_iddr
      IDDR #(
          .DDR_CLK_EDGE("OPPOSITE_EDGE"),
          .INIT_Q1(1'b0), .INIT_Q2(1'b0), .SRTYPE("ASYNC")
      ) u_iddr_data (
          .Q1(data_rise[i]), .Q2(data_fall[i]), .C(rxc_io),
          .CE(1'b1), .D(rxd_delayed[i]), .R(1'b0), .S(1'b0));
    end
  endgenerate

  IDDR #(
      .DDR_CLK_EDGE("OPPOSITE_EDGE"),
      .INIT_Q1(1'b0), .INIT_Q2(1'b0), .SRTYPE("ASYNC")
  ) u_iddr_ctl (
      .Q1(ctl_rise), .Q2(ctl_fall), .C(rxc_io),
      .CE(1'b1), .D(rx_ctl_delayed), .R(1'b0), .S(1'b0));

  always_ff @(posedge rx_clk or negedge rst_n) begin
    if (!rst_n) begin
      rx_data  <= 8'h00;
      rx_valid <= 1'b0;
      rx_error <= 1'b0;
      low_nibble_q <= 4'h0;
    end else begin
      // At this register point the primitive outputs straddle the byte
      // boundary: data_rise is this byte's high nibble, while data_fall is
      // the following byte's low nibble. Retain the latter for the next byte.
      rx_data  <= {data_rise, low_nibble_q};
      low_nibble_q <= data_fall;
      rx_valid <= ctl_rise;
      rx_error <= ctl_rise ^ ctl_fall;
    end
  end
endmodule
