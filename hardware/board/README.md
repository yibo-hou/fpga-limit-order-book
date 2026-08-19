# DaVinci Pro board target

Target: ALIENTEK DaVinci Pro, `XC7A100T-2FGG484`, Ethernet port 0.

The PHY and Ethernet modules required by the board build are maintained under
`hardware/rtl/`; there is no external source-tree dependency.

Network configuration:

- FPGA: `192.168.1.10`, MAC `00:0a:35:01:02:03`, UDP port `5001`
- Host: `192.168.1.100`, UDP port `5000`
- Input: one frozen-protocol 32-byte order message per UDP datagram
- Output: 32-byte execution reports and 32-byte acknowledgements

Acknowledgement payload layout:

| Byte | Field |
|---:|---|
| 0 | version (`1`) |
| 1 | type (`0x80`) |
| 2 | acknowledgement status |
| 3–7 | reserved |
| 8–15 | order ID |
| 16–19 | remaining quantity |
| 20–23 | best bid |
| 24–27 | best ask |
| 28–31 | live order count |

LEDs:

- LED0: YT8511 detected
- LED1: 1000BASE-T full-duplex link up
- LED2: toggles for each accepted UDP packet
- LED3: sticky RX/drop or TX payload error

Build, program and test:

```bash
vivado -mode batch -nolog -nojournal -source tools/build_board.tcl
vivado -mode batch -nolog -nojournal -source tools/program_board.tcl
python3 tools/board_smoke.py
python3 tools/board_stress.py --count 1000 --seed 0x1234
python3 tools/board_stress.py --scenario capacity --prime --interval 0.0005 \
  --progress 512
```

The host test sends a resting buy followed by a crossing sell and expects two
execution reports plus acknowledgements. Send one request and wait for its ACK;
the board input mailbox intentionally applies backpressure at message granularity,
while Ethernet itself cannot be paused.

The stress test generates a deterministic ADD/CANCEL/MODIFY/EXECUTE stream,
sends one command at a time over UDP, and compares every acknowledgement and
execution report against the Python golden reference.

The capacity scenario sends 8192 resting orders: the first 8191 must be accepted,
the last must return `ACK_REJECT_FULL`, and the reported live count must remain
8191. `--prime` absorbs the first post-program TX packet while ARP/PHY state is
settling; the small interval also avoids making RGMII signal-integrity artifacts
look like order-core failures during a long fill test.

`build_board_debug.tcl` creates an optional two-ILA image for PHY and RGMII RX
bring-up. The normal bitstream contains no debug cores.
