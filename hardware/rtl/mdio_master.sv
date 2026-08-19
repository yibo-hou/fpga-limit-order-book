`timescale 1ns / 1ps

// IEEE 802.3 Clause-22 MDIO master. MDC is held low between transactions.
module mdio_master #(
    parameter integer MDC_DIV = 10  // 50 MHz / (2*10) = 2.5 MHz
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        start,
    input  logic        op_read,
    input  logic [4:0]  phy_addr,
    input  logic [4:0]  reg_addr,
    input  logic [15:0] wr_data,
    output logic [15:0] rd_data,
    output logic        busy,
    output logic        done,

    output logic        mdc,
    input  logic        mdio_i,
    output logic        mdio_o,
    output logic        mdio_oe
);

localparam integer PHASE_WIDTH = (2*MDC_DIV <= 2) ? 1 : $clog2(2*MDC_DIV);

logic [63:0] tx_shift;
logic [15:0] rd_shift;
logic [6:0]  bit_index;
logic [PHASE_WIDTH-1:0] phase_count;
logic transaction_read;

always_ff @(posedge clk) begin
    if (!rst_n) begin
        tx_shift        <= '1;
        rd_shift        <= '0;
        rd_data         <= '0;
        bit_index       <= '0;
        phase_count     <= '0;
        transaction_read <= 1'b0;
        busy            <= 1'b0;
        done            <= 1'b0;
        mdc             <= 1'b0;
        mdio_o          <= 1'b1;
        mdio_oe         <= 1'b0;
    end else begin
        done <= 1'b0;

        if (!busy) begin
            mdc         <= 1'b0;
            phase_count <= '0;
            mdio_oe     <= 1'b0;

            if (start) begin
                transaction_read <= op_read;
                bit_index         <= 7'd0;
                rd_shift          <= 16'h0000;
                busy              <= 1'b1;
                mdio_oe           <= 1'b1;
                mdio_o            <= 1'b1;

                if (op_read)
                    tx_shift <= {32'hffff_ffff, 2'b01, 2'b10,
                                 phy_addr, reg_addr, 2'b00, 16'h0000};
                else
                    tx_shift <= {32'hffff_ffff, 2'b01, 2'b01,
                                 phy_addr, reg_addr, 2'b10, wr_data};
            end
        end else begin
            if (phase_count == MDC_DIV - 1) begin
                // PHY and master sample MDIO on the rising edge of MDC.
                mdc <= 1'b1;
                if (transaction_read && (bit_index >= 7'd48))
                    rd_shift <= {rd_shift[14:0], mdio_i};
                phase_count <= phase_count + 1'b1;
            end else if (phase_count == (2*MDC_DIV) - 1) begin
                // Change MDIO only while MDC is low.
                mdc         <= 1'b0;
                phase_count <= '0;

                if (bit_index == 7'd63) begin
                    busy    <= 1'b0;
                    done    <= 1'b1;
                    rd_data <= rd_shift;
                    mdio_oe <= 1'b0;
                end else begin
                    bit_index <= bit_index + 1'b1;
                    mdio_o    <= tx_shift[62-bit_index];
                    if (transaction_read)
                        mdio_oe <= ((bit_index + 1'b1) <= 7'd45);
                    else
                        mdio_oe <= 1'b1;
                end
            end else begin
                phase_count <= phase_count + 1'b1;
            end
        end
    end
end

endmodule
