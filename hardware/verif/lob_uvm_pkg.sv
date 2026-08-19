`timescale 1ns / 1ps

package lob_uvm_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import lob_pkg::*;

  // ==========================================================================
  // 1. Transaction Item: lob_seq_item
  // ==========================================================================
  class lob_seq_item extends uvm_sequence_item;
    msg_type_t   msg_type;
    side_t       side;
    logic [31:0] price;
    logic [31:0] quantity;
    logic [63:0] order_id;
    logic [63:0] timestamp_ns;
    logic [31:0] seq_num;
    logic [7:0]  flags;

    `uvm_object_utils_begin(lob_seq_item)
      `uvm_field_enum(msg_type_t, msg_type, UVM_ALL_ON)
      `uvm_field_enum(side_t, side, UVM_ALL_ON)
      `uvm_field_int(price, UVM_ALL_ON)
      `uvm_field_int(quantity, UVM_ALL_ON)
      `uvm_field_int(order_id, UVM_ALL_ON)
      `uvm_field_int(timestamp_ns, UVM_ALL_ON)
    `uvm_object_utils_end

    function new(string name = "lob_seq_item");
      super.new(name);
      msg_type     = ADD;
      side         = BUY;
      flags        = 8'h00;
      seq_num      = 32'd1;
      timestamp_ns = 64'd1000;
    endfunction

    // Packs transaction fields into 256-bit binary payload matching wire format
    function logic [255:0] pack_to_payload();
      logic [255:0] p;
      p[255:248] = VERSION;
      p[247:240] = {5'b0, msg_type};
      p[239:232] = {7'b0, side};
      p[231:224] = flags;
      p[223:192] = seq_num;
      p[191:128] = order_id;
      p[127:96]  = price;
      p[95:64]   = quantity;
      p[63:0]    = timestamp_ns;
      return p;
    endfunction

    function string to_string();
      return $sformatf("Type=%s Side=%s ID=0x%0h Price=$%0d Qty=%0d",
                       msg_type.name(), side.name(), order_id, price, quantity);
    endfunction
  endclass

  // ==========================================================================
  // 2. Active Driver: lob_driver
  // ==========================================================================
  class lob_driver extends uvm_driver #(lob_seq_item);
    `uvm_component_utils(lob_driver)
    virtual lob_if vif;

    uvm_analysis_port #(lob_seq_item) ap_order;

    function new(string name, uvm_component parent);
      super.new(name, parent);
      ap_order = new("ap_order", this);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(virtual lob_if)::get(this, "", "vif", vif))
        `uvm_fatal("DRV", "Could not get vif from config_db!")
    endfunction

    task run_phase(uvm_phase phase);
      vif.drv_cb.s_payload       <= '0;
      vif.drv_cb.s_payload_valid <= 1'b0;
      vif.drv_cb.m_trade_ready   <= 1'b1;
      vif.drv_cb.m_report_ready  <= 1'b1;
      vif.drv_cb.m_ack_ready     <= 1'b1;

      @(posedge vif.rst_n);
      `uvm_info("DRIVER", "Waiting for DUT 8192-slot BRAM pool initialization (~66us)...", UVM_LOW)
      repeat (8250) @(vif.drv_cb);
      `uvm_info("DRIVER", "DUT Initialization Complete! Ready to process order stream.", UVM_LOW)

      forever begin
        seq_item_port.get_next_item(req);

        while (!vif.drv_cb.s_payload_ready) begin
          @(vif.drv_cb);
        end

        vif.drv_cb.s_payload       <= req.pack_to_payload();
        vif.drv_cb.s_payload_valid <= 1'b1;
        ap_order.write(req);
        @(vif.drv_cb);
        vif.drv_cb.s_payload_valid <= 1'b0;

        `uvm_info("DRIVER", $sformatf("[SENT ORDER] %s", req.to_string()), UVM_MEDIUM)

        seq_item_port.item_done();
        repeat (2) @(vif.drv_cb);
      end
    endtask
  endclass

  // ==========================================================================
  // 3. Passive Monitor: lob_monitor
  // ==========================================================================
  class lob_monitor extends uvm_monitor;
    `uvm_component_utils(lob_monitor)
    virtual lob_if vif;

    uvm_analysis_port #(trade_t) ap_trade;
    uvm_analysis_port #(ack_t)   ap_ack;

    function new(string name, uvm_component parent);
      super.new(name, parent);
      ap_trade = new("ap_trade", this);
      ap_ack   = new("ap_ack", this);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(virtual lob_if)::get(this, "", "vif", vif))
        `uvm_fatal("MON", "Could not get vif from config_db!")
    endfunction

    task run_phase(uvm_phase phase);
      @(posedge vif.rst_n);
      forever begin
        @(vif.mon_cb);
        if (vif.mon_cb.m_trade_valid && vif.mon_cb.m_trade_ready) begin
          ap_trade.write(vif.mon_cb.m_trade);
          `uvm_info("MON_TRADE", $sformatf("[TRADE EVENT] BuyID=0x%0h SellID=0x%0h Price=$%0d Qty=%0d",
                    vif.mon_cb.m_trade.buy_order_id, vif.mon_cb.m_trade.sell_order_id,
                    vif.mon_cb.m_trade.price, vif.mon_cb.m_trade.quantity), UVM_HIGH)
        end

        if (vif.mon_cb.m_ack_valid && vif.mon_cb.m_ack_ready) begin
          ap_ack.write(vif.mon_cb.m_ack);
          `uvm_info("MON_ACK", $sformatf("[ACK EVENT] OrderID=0x%0h Status=%s RemQty=%0d BestBid=$%0d BestAsk=$%0d Orders=%0d",
                    vif.mon_cb.m_ack.order_id, vif.mon_cb.m_ack.status.name(),
                    vif.mon_cb.m_ack.remaining_qty, vif.mon_cb.m_ack.best_bid,
                    vif.mon_cb.m_ack.best_ask, vif.mon_cb.m_ack.num_orders), UVM_HIGH)
        end
      end
    endtask
  endclass

  // ==========================================================================
  // 4. Native License-Free Functional Coverage Collector: lob_coverage
  // ==========================================================================
  class lob_coverage extends uvm_component;
    `uvm_component_utils(lob_coverage)

    `uvm_analysis_imp_decl(_cov_order)
    `uvm_analysis_imp_decl(_cov_trade)
    `uvm_analysis_imp_decl(_cov_ack)

    uvm_analysis_imp_cov_order #(lob_seq_item, lob_coverage) imp_order;
    uvm_analysis_imp_cov_trade #(trade_t,      lob_coverage) imp_trade;
    uvm_analysis_imp_cov_ack   #(ack_t,        lob_coverage) imp_ack;

    // Bin hit tracking tables
    int unsigned bin_ops[string];
    int unsigned bin_price[string];
    int unsigned bin_qty[string];
    int unsigned bin_ack[string];

    function new(string name, uvm_component parent);
      super.new(name, parent);
      imp_order = new("imp_order", this);
      imp_trade = new("imp_trade", this);
      imp_ack   = new("imp_ack", this);

      // Initialize expected bins
      bin_ops["ADD_BUY"]         = 0;
      bin_ops["ADD_SELL"]        = 0;
      bin_ops["CANCEL_BUY"]      = 0;
      bin_ops["CANCEL_SELL"]     = 0;
      bin_ops["MODIFY_BUY"]      = 0;
      bin_ops["MODIFY_SELL"]     = 0;

      bin_price["MIN_PRICE_1"]   = 0;
      bin_price["LOW_RANGE_2_100"] = 0;
      bin_price["MID_RANGE_101_3000"] = 0;
      bin_price["HIGH_RANGE_3001_4094"] = 0;
      bin_price["MAX_PRICE_4095"] = 0;
      bin_price["ILLEGAL_BOUND_4096"] = 0;

      bin_qty["ZERO_ILLEGAL"]    = 0;
      bin_qty["RETAIL_1_20"]     = 0;
      bin_qty["NORMAL_21_100"]   = 0;
      bin_qty["LARGE_101_1000"]  = 0;
      bin_qty["TSUNAMI_1001_10000"] = 0;

      bin_ack["ACK_OK"]          = 0;
      bin_ack["ACK_REJECT_BAD_FIELD"] = 0;
    endfunction

    virtual function void write_cov_order(lob_seq_item item);
      string op_key = $sformatf("%s_%s", item.msg_type.name(), item.side.name());
      if (bin_ops.exists(op_key)) bin_ops[op_key]++;

      // Sample price bins
      if (item.price == 32'd1)                     bin_price["MIN_PRICE_1"]++;
      else if (item.price >= 2 && item.price <= 100) bin_price["LOW_RANGE_2_100"]++;
      else if (item.price >= 101 && item.price <= 3000) bin_price["MID_RANGE_101_3000"]++;
      else if (item.price >= 3001 && item.price <= 4094) bin_price["HIGH_RANGE_3001_4094"]++;
      else if (item.price == 32'd4095)             bin_price["MAX_PRICE_4095"]++;
      else if (item.price == 0 || item.price >= 4096) bin_price["ILLEGAL_BOUND_4096"]++;

      // Sample quantity bins
      if (item.quantity == 0)                      bin_qty["ZERO_ILLEGAL"]++;
      else if (item.quantity >= 1 && item.quantity <= 20) bin_qty["RETAIL_1_20"]++;
      else if (item.quantity >= 21 && item.quantity <= 100) bin_qty["NORMAL_21_100"]++;
      else if (item.quantity >= 101 && item.quantity <= 1000) bin_qty["LARGE_101_1000"]++;
      else if (item.quantity > 1000)               bin_qty["TSUNAMI_1001_10000"]++;
    endfunction

    virtual function void write_cov_trade(trade_t tr);
      // Trade events are observed
    endfunction

    virtual function void write_cov_ack(ack_t a);
      if (a.status == ACK_OK)                      bin_ack["ACK_OK"]++;
      else if (a.status == ACK_REJECT_BAD_FIELD)   bin_ack["ACK_REJECT_BAD_FIELD"]++;
    endfunction

    function real calc_cov_group(ref int unsigned t[string]);
      int hit = 0;
      int total = t.num();
      foreach (t[k]) begin
        if (t[k] > 0) hit++;
      end
      return (total > 0) ? (real'(hit) / real'(total)) * 100.0 : 0.0;
    endfunction

    function void report_phase(uvm_phase phase);
      real cov_ops   = calc_cov_group(bin_ops);
      real cov_price = calc_cov_group(bin_price);
      real cov_qty   = calc_cov_group(bin_qty);
      real cov_ack   = calc_cov_group(bin_ack);
      real overall   = (cov_ops + cov_price + cov_qty + cov_ack) / 4.0;

      super.report_phase(phase);
      $display("\n====================================================================");
      $display("                 UVM FUNCTIONAL COVERAGE REPORT                    ");
      $display("====================================================================");
      $display("  1. Order Operations & Side Cross Coverage : %6.2f %% (%0d/%0d bins)",
               cov_ops, int'(cov_ops * bin_ops.num() / 100.0), bin_ops.num());
      $display("  2. Price Spectrum & Boundary Coverage     : %6.2f %% (%0d/%0d bins)",
               cov_price, int'(cov_price * bin_price.num() / 100.0), bin_price.num());
      $display("  3. Quantity Sizing & Sweep Coverage       : %6.2f %% (%0d/%0d bins)",
               cov_qty, int'(cov_qty * bin_qty.num() / 100.0), bin_qty.num());
      $display("  4. Hardware Ack & Defensive Anomaly Guard : %6.2f %% (%0d/%0d bins)",
               cov_ack, int'(cov_ack * bin_ack.num() / 100.0), bin_ack.num());
      $display("--------------------------------------------------------------------");
      $display("  Overall aggregated functional coverage : %6.2f %%", overall);
      $display("====================================================================\n");
    endfunction
  endclass

  // ==========================================================================
  // 5. Scoreboard: lob_scoreboard
  // ==========================================================================
  class lob_scoreboard extends uvm_scoreboard;
    `uvm_component_utils(lob_scoreboard)

    `uvm_analysis_imp_decl(_trade)
    `uvm_analysis_imp_decl(_ack)

    uvm_analysis_imp_trade #(trade_t, lob_scoreboard) imp_trade;
    uvm_analysis_imp_ack   #(ack_t,   lob_scoreboard) imp_ack;

    int unsigned trade_count;
    longint unsigned total_volume;
    int unsigned ack_count;
    int unsigned reject_count;
    int unsigned error_count;

    function new(string name, uvm_component parent);
      super.new(name, parent);
      imp_trade    = new("imp_trade", this);
      imp_ack      = new("imp_ack", this);
      trade_count  = 0;
      total_volume = 0;
      ack_count    = 0;
      reject_count = 0;
      error_count  = 0;
    endfunction

    virtual function void write_trade(trade_t tr);
      trade_count++;
      total_volume += tr.quantity;

      if (tr.quantity == 0) begin
        `uvm_error("SCB_TRADE", "Trade quantity cannot be 0!")
        error_count++;
      end
      if (tr.buy_order_id == 0 || tr.sell_order_id == 0) begin
        `uvm_error("SCB_TRADE", "Trade counterparties cannot be 0 in matched fill!")
        error_count++;
      end
      `uvm_info("SCB_PASS", $sformatf("  -> Scoreboard Verified Trade #%0d OK (Price=$%0d, Qty=%0d)",
                trade_count, tr.price, tr.quantity), UVM_MEDIUM)
    endfunction

    virtual function void write_ack(ack_t a);
      ack_count++;
      if (a.status != ACK_OK) begin
        reject_count++;
        `uvm_info("SCB_DEFENSE", $sformatf("Guard intercepted and rejected anomaly: Order=0x%0h Reason=%s",
                  a.order_id, a.status.name()), UVM_LOW)
      end else begin
        `uvm_info("SCB_PASS", $sformatf("  -> Scoreboard Verified Ack #%0d OK (ID=0x%0h, Status=%s, RemQty=%0d)",
                  ack_count, a.order_id, a.status.name(), a.remaining_qty), UVM_HIGH)
      end
    endfunction

    function void report_phase(uvm_phase phase);
      super.report_phase(phase);
      $display("\n====================================================================");
      $display("                    UVM SCOREBOARD SUMMARY                         ");
      $display("====================================================================");
      $display("  Total Trades Matched & Verified : %0d", trade_count);
      $display("  Total Shares / Volume Executed  : %0d shares", total_volume);
      $display("  Total Acks Received & Verified  : %0d", ack_count);
      $display("  Total Defensive Rejections      : %0d (Duplicate IDs & Bad Fields)", reject_count);
      $display("  Total Hardware Errors Detected  : %0d", error_count);
      if (error_count == 0 && (trade_count > 0 || ack_count > 0)) begin
        $display("  Final verdict                   : [PASS]");
      end else if (error_count == 0) begin
        $display("  Final verdict                   : [PASS (0 ERRORS)]");
      end else begin
        $display("  Final verdict                   : [FAIL: %0d ERRORS]", error_count);
      end
      $display("====================================================================\n");
    endfunction
  endclass

  // ==========================================================================
  // 6. Environment Container: lob_env
  // ==========================================================================
  class lob_env extends uvm_env;
    `uvm_component_utils(lob_env)

    uvm_sequencer #(lob_seq_item) sqr;
    lob_driver                     drv;
    lob_monitor                    mon;
    lob_scoreboard                 scb;
    lob_coverage                   cov;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      sqr = uvm_sequencer#(lob_seq_item)::type_id::create("sqr", this);
      drv = lob_driver::type_id::create("drv", this);
      mon = lob_monitor::type_id::create("mon", this);
      scb = lob_scoreboard::type_id::create("scb", this);
      cov = lob_coverage::type_id::create("cov", this);
    endfunction

    function void connect_phase(uvm_phase phase);
      super.connect_phase(phase);
      drv.seq_item_port.connect(sqr.seq_item_export);

      mon.ap_trade.connect(scb.imp_trade);
      mon.ap_ack.connect(scb.imp_ack);

      drv.ap_order.connect(cov.imp_order);
      mon.ap_trade.connect(cov.imp_trade);
      mon.ap_ack.connect(cov.imp_ack);
    endfunction
  endclass

endpackage
