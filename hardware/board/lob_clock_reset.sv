`timescale 1ns / 1ps

module reset_sync (
    input  logic clk,
    input  logic async_rst_n,
    input  logic release_enable_async,
    output logic rst_n
);
  (* ASYNC_REG = "TRUE" *) logic [2:0] sync_ff;

  always_ff @(posedge clk or negedge async_rst_n) begin
    if (!async_rst_n)
      sync_ff <= '0;
    else if (!release_enable_async)
      sync_ff <= '0;
    else
      sync_ff <= {sync_ff[1:0], 1'b1};
  end

  assign rst_n = sync_ff[2];
endmodule

module lob_clock_gen (
    input  wire  sys_clk,
    input  logic sys_rst_n,
    output wire  clk_50m,
    output wire  clk_125m,
    output wire  clk_200m,
    output logic locked
);
  wire clk_in;
  wire clk_fb;
  wire clk_fb_buf;
  wire clk_125_raw;
  wire clk_200_raw;

  IBUF u_ibuf (.I(sys_clk), .O(clk_in));
  BUFG u_50_buf (.I(clk_in), .O(clk_50m));
  BUFG u_fb_buf (.I(clk_fb), .O(clk_fb_buf));
  BUFG u_125_buf (.I(clk_125_raw), .O(clk_125m));
  BUFG u_200_buf (.I(clk_200_raw), .O(clk_200m));

  MMCME2_BASE #(
      .BANDWIDTH("OPTIMIZED"),
      .CLKIN1_PERIOD(20.000),
      .DIVCLK_DIVIDE(1),
      .CLKFBOUT_MULT_F(20.000),
      .CLKOUT0_DIVIDE_F(8.000),
      .CLKOUT1_DIVIDE(5),
      .STARTUP_WAIT("FALSE")
  ) u_mmcm (
      .CLKIN1(clk_50m),
      .CLKFBIN(clk_fb_buf),
      .RST(!sys_rst_n),
      .PWRDWN(1'b0),
      .CLKFBOUT(clk_fb),
      .CLKFBOUTB(),
      .CLKOUT0(clk_125_raw),
      .CLKOUT0B(),
      .CLKOUT1(clk_200_raw),
      .CLKOUT1B(),
      .CLKOUT2(), .CLKOUT2B(), .CLKOUT3(), .CLKOUT3B(),
      .CLKOUT4(), .CLKOUT5(), .CLKOUT6(),
      .LOCKED(locked)
  );
endmodule
