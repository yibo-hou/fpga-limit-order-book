`timescale 1ns / 1ps

// 1-Gbit/s RGMII serializer. The YT8511 controller configures PHY-side TXID,
// so TXC is edge-aligned here and the PHY adds the required sampling delay.
module rgmii_tx (
    input  logic       clk_125m,
    input  logic       rst_n,
    input  logic [7:0] tx_data,
    input  logic       tx_valid,
    output logic       rgmii_txc,
    output logic [3:0] rgmii_txd,
    output logic       rgmii_tx_ctl
);

logic [7:0] tx_data_q;
logic tx_valid_q;

// Break the protocol-generator combinational path before the I/O DDR cells.
always_ff @(posedge clk_125m or negedge rst_n) begin
    if (!rst_n) begin
        tx_data_q  <= 8'h00;
        tx_valid_q <= 1'b0;
    end else begin
        tx_data_q  <= tx_data;
        tx_valid_q <= tx_valid;
    end
end

genvar i;
generate
    for (i = 0; i < 4; i = i + 1) begin : g_rgmii_data
        ODDR #(
            .DDR_CLK_EDGE("SAME_EDGE"),
            .INIT(1'b0),
            .SRTYPE("ASYNC")
        ) u_oddr_txd (
            .Q  (rgmii_txd[i]),
            .C  (clk_125m),
            .CE (1'b1),
            .D1 (tx_data_q[i]),
            .D2 (tx_data_q[i+4]),
            .R  (!rst_n),
            .S  (1'b0)
        );
    end
endgenerate

ODDR #(
    .DDR_CLK_EDGE("SAME_EDGE"),
    .INIT(1'b0),
    .SRTYPE("ASYNC")
) u_oddr_tx_ctl (
    .Q  (rgmii_tx_ctl),
    .C  (clk_125m),
    .CE (1'b1),
    .D1 (tx_valid_q),
    .D2 (tx_valid_q),
    .R  (!rst_n),
    .S  (1'b0)
);

ODDR #(
    .DDR_CLK_EDGE("SAME_EDGE"),
    .INIT(1'b0),
    .SRTYPE("ASYNC")
) u_oddr_txc (
    .Q  (rgmii_txc),
    .C  (clk_125m),
    .CE (1'b1),
    .D1 (1'b1),
    .D2 (1'b0),
    .R  (!rst_n),
    .S  (1'b0)
);

endmodule
