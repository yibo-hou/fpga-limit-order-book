# ALIENTEK DaVinci Pro XC7A100T, Ethernet port 0.

create_clock -period 20.000 -name sys_clk [get_ports sys_clk]
set_property -dict {PACKAGE_PIN R4 IOSTANDARD LVCMOS15} [get_ports sys_clk]
set_property -dict {PACKAGE_PIN U7 IOSTANDARD LVCMOS15 PULLUP TRUE} [get_ports sys_rst_n]
set_property CLOCK_DEDICATED_ROUTE FALSE \
  [get_nets -of_objects [get_pins u_clkgen/u_ibuf/O]]

set_property -dict {PACKAGE_PIN V9 IOSTANDARD LVCMOS15} [get_ports {led[0]}]
set_property -dict {PACKAGE_PIN Y8 IOSTANDARD LVCMOS15} [get_ports {led[1]}]
set_property -dict {PACKAGE_PIN Y7 IOSTANDARD LVCMOS15} [get_ports {led[2]}]
set_property -dict {PACKAGE_PIN W7 IOSTANDARD LVCMOS15} [get_ports {led[3]}]

create_clock -period 8.000 -name eth_rxc_0 [get_ports eth_rxc_0]
set_property -dict {PACKAGE_PIN N20 IOSTANDARD LVCMOS33} [get_ports eth_rst_n]
set_property -dict {PACKAGE_PIN U20 IOSTANDARD LVCMOS33} [get_ports eth_rxc_0]
set_property -dict {PACKAGE_PIN AA20 IOSTANDARD LVCMOS33} [get_ports eth_rx_ctl_0]
set_property -dict {PACKAGE_PIN AA21 IOSTANDARD LVCMOS33} [get_ports {eth_rxd_0[0]}]
set_property -dict {PACKAGE_PIN V20 IOSTANDARD LVCMOS33} [get_ports {eth_rxd_0[1]}]
set_property -dict {PACKAGE_PIN U22 IOSTANDARD LVCMOS33} [get_ports {eth_rxd_0[2]}]
set_property -dict {PACKAGE_PIN V22 IOSTANDARD LVCMOS33} [get_ports {eth_rxd_0[3]}]

set_property -dict {PACKAGE_PIN V18 IOSTANDARD LVCMOS33 SLEW FAST} [get_ports eth_txc_0]
set_property -dict {PACKAGE_PIN V19 IOSTANDARD LVCMOS33 SLEW FAST} [get_ports eth_tx_ctl_0]
set_property -dict {PACKAGE_PIN T21 IOSTANDARD LVCMOS33 SLEW FAST} [get_ports {eth_txd_0[0]}]
set_property -dict {PACKAGE_PIN U21 IOSTANDARD LVCMOS33 SLEW FAST} [get_ports {eth_txd_0[1]}]
set_property -dict {PACKAGE_PIN P19 IOSTANDARD LVCMOS33 SLEW FAST} [get_ports {eth_txd_0[2]}]
set_property -dict {PACKAGE_PIN R19 IOSTANDARD LVCMOS33 SLEW FAST} [get_ports {eth_txd_0[3]}]

set_property -dict {PACKAGE_PIN M20 IOSTANDARD LVCMOS33 SLEW SLOW} [get_ports eth_mdc]
set_property -dict {PACKAGE_PIN N22 IOSTANDARD LVCMOS33 PULLUP TRUE} [get_ports eth_mdio]

# The RX clock is unrelated to the MMCM-generated system clocks. All payload
# and ARP event crossings use cdc_mailbox toggle synchronizers.
set_clock_groups -asynchronous \
  -group [get_clocks eth_rxc_0] \
  -group [get_clocks -of_objects [get_pins u_clkgen/u_mmcm/CLKOUT0]] \
  -group [get_clocks -of_objects [get_pins u_clkgen/u_mmcm/CLKOUT1]] \
  -group [get_clocks sys_clk]

set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property CONFIG_MODE SPIx4 [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 50 [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
set_property BITSTREAM.CONFIG.UNUSEDPIN PULLUP [current_design]
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
