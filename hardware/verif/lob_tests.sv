`timescale 1ns / 1ps

package lob_tests_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import lob_pkg::*;
  import lob_uvm_pkg::*;

  // ==========================================================================
  // Base Sequence: lob_base_seq
  // ==========================================================================
  class lob_base_seq extends uvm_sequence #(lob_seq_item);
    `uvm_object_utils(lob_base_seq)

    function new(string name = "lob_base_seq");
      super.new(name);
    endfunction

    // Helper task to send an order transaction
    task send_order(
      input msg_type_t   mtype,
      input side_t       s,
      input logic [31:0] p,
      input logic [31:0] q,
      input logic [63:0] id,
      input logic [63:0] ts = 64'd1000
    );
      lob_seq_item item = lob_seq_item::type_id::create("item");
      start_item(item);
      item.msg_type     = mtype;
      item.side         = s;
      item.price        = p;
      item.quantity     = q;
      item.order_id     = id;
      item.timestamp_ns = ts;
      finish_item(item);
    endtask
  endclass

  // ==========================================================================
  // Scenario 1: Smoke Test Sequence (Fast-Path Match Verification)
  // ==========================================================================
  class smoke_seq extends lob_base_seq;
    `uvm_object_utils(smoke_seq)
    function new(string name = "smoke_seq"); super.new(name); endfunction

    task body();
      `uvm_info("SEQ", ">>> Starting Smoke Test Sequence <<<", UVM_LOW)
      send_order(ADD, BUY,  32'd100, 32'd50, 64'h1001, 64'd100);
      send_order(ADD, SELL, 32'd105, 32'd50, 64'h1002, 64'd200);
      send_order(ADD, BUY,  32'd105, 32'd50, 64'h1003, 64'd300);
      #1000ns;
      `uvm_info("SEQ", ">>> Smoke Test Sequence Completed <<<", UVM_LOW)
    endtask
  endclass

  // ==========================================================================
  // Scenario 2: Multi-Level Sweep Test Sequence
  // ==========================================================================
  class sweep_seq extends lob_base_seq;
    `uvm_object_utils(sweep_seq)
    function new(string name = "sweep_seq"); super.new(name); endfunction

    task body();
      `uvm_info("SEQ", ">>> Starting Multi-Level Sweep Test Sequence <<<", UVM_LOW)
      send_order(ADD, SELL, 32'd100, 32'd30, 64'h2001, 64'd100);
      send_order(ADD, SELL, 32'd101, 32'd40, 64'h2002, 64'd200);
      send_order(ADD, SELL, 32'd102, 32'd50, 64'h2003, 64'd300);
      send_order(ADD, BUY,  32'd105, 32'd120, 64'h2004, 64'd400);
      #1000ns;
      `uvm_info("SEQ", ">>> Multi-Level Sweep Test Sequence Completed <<<", UVM_LOW)
    endtask
  endclass

  // ==========================================================================
  // Scenario 3: Cancel & Modify Test Sequence
  // ==========================================================================
  class cancel_modify_seq extends lob_base_seq;
    `uvm_object_utils(cancel_modify_seq)
    function new(string name = "cancel_modify_seq"); super.new(name); endfunction

    task body();
      `uvm_info("SEQ", ">>> Starting Cancel & Modify Test Sequence <<<", UVM_LOW)
      send_order(ADD, BUY, 32'd95, 32'd100, 64'h3001, 64'd100);
      send_order(MODIFY, BUY, 32'd95, 32'd60, 64'h3001, 64'd200);
      send_order(CANCEL, BUY, 32'd95, 32'd0, 64'h3001, 64'd300);
      #1000ns;
      `uvm_info("SEQ", ">>> Cancel & Modify Test Sequence Completed <<<", UVM_LOW)
    endtask
  endclass

  // ==========================================================================
  // Scenario 4: Heavy Realistic Financial Stress Test Sequence
  // ==========================================================================
  class stress_seq extends lob_base_seq;
    `uvm_object_utils(stress_seq)
    function new(string name = "stress_seq"); super.new(name); endfunction

    task body();
      logic [63:0] cur_id;
      logic [63:0] active_orders[$];
      logic [31:0] rand_price;
      logic [31:0] rand_qty;
      int          op_choice;

      `uvm_info("STRESS", "==================================================", UVM_LOW)
      `uvm_info("STRESS", "Starting heavy realistic stress test sequence", UVM_LOW)
      `uvm_info("STRESS", "==================================================", UVM_LOW)

      // ----------------------------------------------------------------------
      // Phase 1: Dense Book Seeding (40 passive orders across 20 price levels)
      // ----------------------------------------------------------------------
      `uvm_info("STRESS", ">>> Phase 1: Seeding 40 Passive Orders across 20 Price Levels <<<", UVM_LOW)
      for (int i = 0; i < 20; i++) begin
        cur_id = 64'h10000 + i;
        send_order(ADD, BUY, 32'd80 + (i % 20), 32'd20 + (i * 5), cur_id, 64'd1000 + i);
        active_orders.push_back(cur_id);

        cur_id = 64'h20000 + i;
        send_order(ADD, SELL, 32'd110 + (i % 20), 32'd20 + (i * 5), cur_id, 64'd2000 + i);
        active_orders.push_back(cur_id);
      end

      // ----------------------------------------------------------------------
      // Phase 2: High-Frequency Mixed Traffic Storm (100 concurrent operations)
      // ----------------------------------------------------------------------
      `uvm_info("STRESS", ">>> Phase 2: Injecting 100-Transaction High-Frequency Mixed Storm <<<", UVM_LOW)
      for (int i = 0; i < 100; i++) begin
        op_choice = $urandom_range(0, 9);
        cur_id    = 64'h30000 + i;

        case (op_choice)
          // 40% probability: Aggressive Crossing ADD (Fast-Path Match)
          0, 1, 2, 3: begin
            if ($urandom_range(0, 1) == 0) begin
              rand_price = $urandom_range(110, 125);
              rand_qty   = $urandom_range(10, 60);
              send_order(ADD, BUY, rand_price, rand_qty, cur_id, 64'd10000 + i);
            end else begin
              rand_price = $urandom_range(80, 99);
              rand_qty   = $urandom_range(10, 60);
              send_order(ADD, SELL, rand_price, rand_qty, cur_id, 64'd10000 + i);
            end
          end

          // 30% probability: Passive Resting ADD
          4, 5, 6: begin
            if ($urandom_range(0, 1) == 0) begin
              rand_price = $urandom_range(60, 79);
              rand_qty   = $urandom_range(10, 100);
              send_order(ADD, BUY, rand_price, rand_qty, cur_id, 64'd10000 + i);
              active_orders.push_back(cur_id);
            end else begin
              rand_price = $urandom_range(130, 150);
              rand_qty   = $urandom_range(10, 100);
              send_order(ADD, SELL, rand_price, rand_qty, cur_id, 64'd10000 + i);
              active_orders.push_back(cur_id);
            end
          end

          // 20% probability: Random CANCEL on active live order
          7, 8: begin
            if (active_orders.size() > 0) begin
              int idx = $urandom_range(0, active_orders.size() - 1);
              logic [63:0] target_id = active_orders[idx];
              active_orders.delete(idx);
              send_order(CANCEL, BUY, 32'd0, 32'd0, target_id, 64'd10000 + i);
            end
          end

          // 10% probability: Random MODIFY
          9: begin
            if (active_orders.size() > 0) begin
              int idx = $urandom_range(0, active_orders.size() - 1);
              logic [63:0] target_id = active_orders[idx];
              rand_qty = $urandom_range(5, 50);
              send_order(MODIFY, BUY, 32'd70, rand_qty, target_id, 64'd10000 + i);
            end
          end
        endcase
      end

      // ----------------------------------------------------------------------
      // Phase 3: Tsunami Mega-Sweep (Clearing entire multi-level depth)
      // ----------------------------------------------------------------------
      `uvm_info("STRESS", ">>> Phase 3: Tsunami Mega-Sweep to Clear Multi-Level Book <<<", UVM_LOW)
      send_order(ADD, BUY, 32'd200, 32'd5000, 64'h99991, 64'd90001);
      send_order(ADD, SELL, 32'd1, 32'd5000, 64'h99992, 64'd90002);

      // ----------------------------------------------------------------------
      // Phase 4: Corner Case Injection (Duplicate ID, Price Bounds, Min/Max, Sells)
      // ----------------------------------------------------------------------
      `uvm_info("STRESS", ">>> Phase 4: Corner Case Injection (Duplicate ID, Price Bounds) <<<", UVM_LOW)
      // 1. Min & Max boundary prices (1, 4095, mid 500, high 3500)
      send_order(ADD, BUY,  32'd1,    32'd50, 64'h99995, 64'd90006);
      send_order(ADD, SELL, 32'd4095, 32'd50, 64'h99996, 64'd90007);
      send_order(ADD, BUY,  32'd500,  32'd50, 64'h99997, 64'd90008);
      send_order(ADD, SELL, 32'd3500, 32'd50, 64'h99998, 64'd90009);
      // 2. Exercise CANCEL_SELL and MODIFY_SELL
      send_order(MODIFY, SELL, 32'd3500, 32'd25, 64'h99998, 64'd90010);
      send_order(CANCEL, SELL, 32'd0,    32'd0,  64'h99998, 64'd90011);
      // 3. Duplicate ID rejection test
      send_order(ADD, BUY,  32'd100,  32'd50, 64'h99991, 64'd90003);
      // 4. Out-of-bounds price (price = 4096)
      send_order(ADD, BUY,  32'd4096, 32'd50, 64'h99993, 64'd90004);
      // 5. Zero quantity rejection
      send_order(ADD, BUY,  32'd100,  32'd0,  64'h99994, 64'd90005);

      #3000ns;
      `uvm_info("STRESS", "==================================================", UVM_LOW)
      `uvm_info("STRESS", "Heavy stress test sequence completed", UVM_LOW)
      `uvm_info("STRESS", "==================================================", UVM_LOW)
    endtask
  endclass

  // ==========================================================================
  // Test Case Classes
  // ==========================================================================
  class lob_base_test extends uvm_test;
    `uvm_component_utils(lob_base_test)
    lob_env env;
    function new(string name = "lob_base_test", uvm_component parent = null);
      super.new(name, parent);
    endfunction
    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      env = lob_env::type_id::create("env", this);
    endfunction
  endclass

  class lob_smoke_test extends lob_base_test;
    `uvm_component_utils(lob_smoke_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_phase(uvm_phase phase);
      smoke_seq seq = smoke_seq::type_id::create("seq");
      phase.raise_objection(this);
      seq.start(env.sqr);
      #1000ns;
      phase.drop_objection(this);
    endtask
  endclass

  class lob_sweep_test extends lob_base_test;
    `uvm_component_utils(lob_sweep_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_phase(uvm_phase phase);
      sweep_seq seq = sweep_seq::type_id::create("seq");
      phase.raise_objection(this);
      seq.start(env.sqr);
      #1000ns;
      phase.drop_objection(this);
    endtask
  endclass

  class lob_cancel_modify_test extends lob_base_test;
    `uvm_component_utils(lob_cancel_modify_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_phase(uvm_phase phase);
      cancel_modify_seq seq = cancel_modify_seq::type_id::create("seq");
      phase.raise_objection(this);
      seq.start(env.sqr);
      #1000ns;
      phase.drop_objection(this);
    endtask
  endclass

  class lob_stress_test extends lob_base_test;
    `uvm_component_utils(lob_stress_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_phase(uvm_phase phase);
      stress_seq seq = stress_seq::type_id::create("seq");
      phase.raise_objection(this);
      seq.start(env.sqr);
      #3000ns;
      phase.drop_objection(this);
    endtask
  endclass

endpackage
