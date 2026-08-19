`timescale 1ns / 1ps

// Minimal YT8511 management controller:
//   * scans Clause-22 addresses beginning at PREFERRED_PHY_ADDR;
//   * verifies PHY ID 0x0000010a;
//   * configures RGMII-ID delays for the enabled MAC directions;
//   * polls register 0x11 and enables TX only for 1000BASE-T full duplex.
module yt8511_ctrl #(
    parameter integer CLK_HZ             = 50_000_000,
    parameter logic [4:0] PREFERRED_PHY_ADDR = 5'd0,
    parameter integer STARTUP_WAIT_MS    = 20,
    parameter integer POLL_INTERVAL_MS   = 100,
    parameter bit     ENABLE_RX_DELAY    = 1'b0
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        phy_ready,

    output logic        mdio_start,
    output logic        mdio_read,
    output logic [4:0]  mdio_phy_addr,
    output logic [4:0]  mdio_reg_addr,
    output logic [15:0] mdio_wr_data,
    input  logic [15:0] mdio_rd_data,
    input  logic        mdio_busy,
    input  logic        mdio_done,

    output logic        phy_found,
    output logic [4:0]  detected_phy_addr,
    output logic [31:0] phy_id,
    output logic [15:0] phy_status,
    output logic        link_up,
    output logic        full_duplex,
    output logic [1:0]  speed_code,
    output logic        tx_enable
);

localparam integer STARTUP_CYCLES = (CLK_HZ / 1000) * STARTUP_WAIT_MS;
localparam integer POLL_CYCLES    = (CLK_HZ / 1000) * POLL_INTERVAL_MS;
localparam integer TIMER_WIDTH    = $clog2((POLL_CYCLES > STARTUP_CYCLES ?
                                            POLL_CYCLES : STARTUP_CYCLES) + 1);

typedef enum logic [4:0] {
    ST_STARTUP,
    ST_ID1_REQ, ST_ID1_WAIT,
    ST_ID2_REQ, ST_ID2_WAIT,
    ST_PAGE0C_REQ, ST_PAGE0C_WAIT,
    ST_PAGE0C_READ_REQ, ST_PAGE0C_READ_WAIT,
    ST_PAGE0C_WRITE_REQ, ST_PAGE0C_WRITE_WAIT,
    ST_PAGE0D_REQ, ST_PAGE0D_WAIT,
    ST_PAGE0D_READ_REQ, ST_PAGE0D_READ_WAIT,
    ST_PAGE0D_WRITE_REQ, ST_PAGE0D_WRITE_WAIT,
    ST_PAGE_RESTORE_REQ, ST_PAGE_RESTORE_WAIT,
    ST_POLL_DELAY, ST_STATUS_REQ, ST_STATUS_WAIT
} state_t;

state_t state;
logic [TIMER_WIDTH-1:0] timer;
logic [4:0] scan_addr;
logic [15:0] id1;
logic [15:0] page_data;
logic [31:0] candidate_id;

always_comb begin
    candidate_id = {id1, mdio_rd_data};
end

always_ff @(posedge clk) begin
    if (!rst_n) begin
        state             <= ST_STARTUP;
        timer             <= '0;
        scan_addr         <= PREFERRED_PHY_ADDR;
        id1               <= '0;
        page_data         <= '0;
        mdio_start        <= 1'b0;
        mdio_read         <= 1'b1;
        mdio_phy_addr     <= PREFERRED_PHY_ADDR;
        mdio_reg_addr     <= '0;
        mdio_wr_data      <= '0;
        phy_found         <= 1'b0;
        detected_phy_addr <= PREFERRED_PHY_ADDR;
        phy_id            <= '0;
        phy_status        <= '0;
        link_up           <= 1'b0;
        full_duplex       <= 1'b0;
        speed_code        <= 2'b00;
        tx_enable         <= 1'b0;
    end else begin
        mdio_start <= 1'b0;

        case (state)
            ST_STARTUP: begin
                tx_enable <= 1'b0;
                if (!phy_ready) begin
                    timer <= '0;
                end else if (timer == STARTUP_CYCLES - 1) begin
                    timer <= '0;
                    state <= ST_ID1_REQ;
                end else begin
                    timer <= timer + 1'b1;
                end
            end

            ST_ID1_REQ: if (!mdio_busy) begin
                mdio_read     <= 1'b1;
                mdio_phy_addr <= scan_addr;
                mdio_reg_addr <= 5'h02;
                mdio_start    <= 1'b1;
                state         <= ST_ID1_WAIT;
            end

            ST_ID1_WAIT: if (mdio_done) begin
                id1   <= mdio_rd_data;
                state <= ST_ID2_REQ;
            end

            ST_ID2_REQ: if (!mdio_busy) begin
                mdio_read     <= 1'b1;
                mdio_phy_addr <= scan_addr;
                mdio_reg_addr <= 5'h03;
                mdio_start    <= 1'b1;
                state         <= ST_ID2_WAIT;
            end

            ST_ID2_WAIT: if (mdio_done) begin
                // YT8511 PHY ID is 0x0000010a; revision occupies low nibble.
                if ((candidate_id & 32'hffff_fff0) == 32'h0000_0100) begin
                    phy_found         <= 1'b1;
                    detected_phy_addr <= scan_addr;
                    phy_id            <= candidate_id;
                    state             <= ST_PAGE0C_REQ;
                end else begin
                    phy_found <= 1'b0;
                    if (scan_addr == PREFERRED_PHY_ADDR - 1'b1) begin
                        // All 32 addresses tried. Pause, then scan again.
                        timer     <= '0;
                        scan_addr <= PREFERRED_PHY_ADDR;
                        state     <= ST_STARTUP;
                    end else begin
                        scan_addr <= scan_addr + 1'b1;
                        state     <= ST_ID1_REQ;
                    end
                end
            end

            // Select YT8511 extended page 0x0c.
            ST_PAGE0C_REQ: if (!mdio_busy) begin
                mdio_read     <= 1'b0;
                mdio_phy_addr <= detected_phy_addr;
                mdio_reg_addr <= 5'h1e;
                mdio_wr_data  <= 16'h000c;
                mdio_start    <= 1'b1;
                state         <= ST_PAGE0C_WAIT;
            end
            ST_PAGE0C_WAIT: if (mdio_done) state <= ST_PAGE0C_READ_REQ;

            ST_PAGE0C_READ_REQ: if (!mdio_busy) begin
                mdio_read     <= 1'b1;
                mdio_reg_addr <= 5'h1f;
                mdio_start    <= 1'b1;
                state         <= ST_PAGE0C_READ_WAIT;
            end
            ST_PAGE0C_READ_WAIT: if (mdio_done) begin
                page_data <= mdio_rd_data;
                state     <= ST_PAGE0C_WRITE_REQ;
            end

            ST_PAGE0C_WRITE_REQ: if (!mdio_busy) begin
                mdio_read    <= 1'b0;
                mdio_reg_addr <= 5'h1f;
                // GE TX delay ~=2 ns (bits 7:4=15). Bit 0 enables the
                // YT8511's nominal 1.8 ns RGMII RXC delay.
                mdio_wr_data <= (page_data & 16'hff0e) | 16'h00f6 |
                                (ENABLE_RX_DELAY ? 16'h0001 : 16'h0000);
                mdio_start   <= 1'b1;
                state        <= ST_PAGE0C_WRITE_WAIT;
            end
            ST_PAGE0C_WRITE_WAIT: if (mdio_done) state <= ST_PAGE0D_REQ;

            // Page 0x0d holds the 10/100-Mbit TX delay field. Configure it too,
            // although this transmitter deliberately runs only at 1 Gbit/s.
            ST_PAGE0D_REQ: if (!mdio_busy) begin
                mdio_read     <= 1'b0;
                mdio_reg_addr <= 5'h1e;
                mdio_wr_data  <= 16'h000d;
                mdio_start    <= 1'b1;
                state         <= ST_PAGE0D_WAIT;
            end
            ST_PAGE0D_WAIT: if (mdio_done) state <= ST_PAGE0D_READ_REQ;

            ST_PAGE0D_READ_REQ: if (!mdio_busy) begin
                mdio_read     <= 1'b1;
                mdio_reg_addr <= 5'h1f;
                mdio_start    <= 1'b1;
                state         <= ST_PAGE0D_READ_WAIT;
            end
            ST_PAGE0D_READ_WAIT: if (mdio_done) begin
                page_data <= mdio_rd_data;
                state     <= ST_PAGE0D_WRITE_REQ;
            end

            ST_PAGE0D_WRITE_REQ: if (!mdio_busy) begin
                mdio_read     <= 1'b0;
                mdio_reg_addr <= 5'h1f;
                mdio_wr_data  <= (page_data & 16'h0fff) | 16'hf000;
                mdio_start    <= 1'b1;
                state         <= ST_PAGE0D_WRITE_WAIT;
            end
            ST_PAGE0D_WRITE_WAIT: if (mdio_done) state <= ST_PAGE_RESTORE_REQ;

            ST_PAGE_RESTORE_REQ: if (!mdio_busy) begin
                mdio_read     <= 1'b0;
                mdio_reg_addr <= 5'h1e;
                mdio_wr_data  <= 16'h0000;
                mdio_start    <= 1'b1;
                state         <= ST_PAGE_RESTORE_WAIT;
            end
            ST_PAGE_RESTORE_WAIT: if (mdio_done) begin
                timer <= '0;
                state <= ST_STATUS_REQ;
            end

            ST_POLL_DELAY: begin
                if (timer == POLL_CYCLES - 1) begin
                    timer <= '0;
                    state <= ST_STATUS_REQ;
                end else begin
                    timer <= timer + 1'b1;
                end
            end

            ST_STATUS_REQ: if (!mdio_busy) begin
                mdio_read     <= 1'b1;
                mdio_phy_addr <= detected_phy_addr;
                mdio_reg_addr <= 5'h11;
                mdio_start    <= 1'b1;
                state         <= ST_STATUS_WAIT;
            end

            ST_STATUS_WAIT: if (mdio_done) begin
                phy_status  <= mdio_rd_data;
                speed_code  <= mdio_rd_data[15:14];
                full_duplex <= mdio_rd_data[13];
                link_up     <= mdio_rd_data[10];
                tx_enable   <= mdio_rd_data[10] && mdio_rd_data[11] &&
                               mdio_rd_data[13] && (mdio_rd_data[15:14] == 2'b10);
                timer       <= '0;
                state       <= ST_POLL_DELAY;
            end

            default: state <= ST_STARTUP;
        endcase
    end
end

endmodule
