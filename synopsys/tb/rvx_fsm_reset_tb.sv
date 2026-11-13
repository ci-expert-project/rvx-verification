`timescale 1ns/1ps

module rvx_fsm_reset_tb;

  localparam [3:0] STATE_RESET       = 4'b0001;
  localparam [3:0] STATE_OPERATING   = 4'b0010;
  localparam [3:0] STATE_TRAP_TAKEN  = 4'b0100;
  localparam [3:0] STATE_TRAP_RETURN = 4'b1000;

  localparam MEMORY_SIZE = 8192;
  localparam MAX_WAIT_CYCLES = 500;

  reg clock;
  reg reset;
  reg halt;

  reg [15:0] irq_fast;
  reg irq_external;
  reg irq_timer;
  reg irq_software;
  reg [63:0] real_time_clock;

  wire [31:0] rw_address;
  wire [31:0] read_data;
  wire read_request;
  wire read_response;
  wire [31:0] write_data;
  wire [3:0] write_strobe;
  wire write_request;
  wire write_response;

  wire irq_external_response;
  wire irq_timer_response;
  wire irq_software_response;
  wire [15:0] irq_fast_response;

  reg [3:0] target_state;
  reg [8*32-1:0] target_name;
  integer cycles;
  string target;

  // Clock: 500 MHz
  initial begin
    clock = 1'b0;
    forever #1 clock = ~clock;
  end

  // DUT
  rvx_core #(
    .BOOT_ADDRESS(32'h00000000)
  ) rvx_core_instance (
    .clock                  (clock),
    .reset                  (reset),
    .halt                   (halt),

    .rw_address             (rw_address),
    .read_data              (read_data),
    .read_request            (read_request),
    .read_response           (read_response),
    .write_data              (write_data),
    .write_strobe            (write_strobe),
    .write_request           (write_request),
    .write_response          (write_response),

    .irq_external            (irq_external),
    .irq_external_response   (irq_external_response),
    .irq_timer               (irq_timer),
    .irq_timer_response      (irq_timer_response),
    .irq_software            (irq_software),
    .irq_software_response   (irq_software_response),
    .irq_fast                (irq_fast),
    .irq_fast_response       (irq_fast_response),

    .real_time_clock         (real_time_clock)
  );

  // RAM
  rvx_ram #(
    .MEMORY_SIZE(MEMORY_SIZE),
    .MEMORY_INIT_FILE("")
  ) rvx_ram_instance (
    .clock          (clock),
    .reset          (reset),

    .rw_address     (rw_address),
    .read_data      (read_data),
    .read_request   (read_request),
    .read_response  (read_response),

    .write_data     (write_data),
    .write_strobe   (write_strobe),
    .write_request  (write_request),
    .write_response (write_response)
  );

  // Directed FSM reset test
  initial begin

    reset = 1'b1;
    halt = 1'b0;

    irq_fast = 16'b0;
    irq_external = 1'b0;
    irq_timer = 1'b0;
    irq_software = 1'b0;
    real_time_clock = 64'b0;

    if (!$value$plusargs("TARGET=%s", target))
      target = "OPERATING";

    if (target == "OPERATING") begin
      target_state = STATE_OPERATING;
      target_name = "OPERATING";
    end
    else if (target == "TRAP_TAKEN") begin
      target_state = STATE_TRAP_TAKEN;
      target_name = "TRAP_TAKEN";
    end
    else if (target == "TRAP_RETURN") begin
      target_state = STATE_TRAP_RETURN;
      target_name = "TRAP_RETURN";
    end
    else if (target == "TRAP_RETURN_TO_OPERATING") begin
      target_state = STATE_TRAP_RETURN;
      target_name = "TRAP_RETURN_TO_OPERATING";
    end
    else begin
      $fatal(1, "Invalid TARGET: %s", target);
    end

    $display("========================================");
    $display(" RVX FSM DIRECTED RESET TEST");
    $display(" TARGET: %s", target_name);
    $display("========================================");

    // Wait for RAM initialization, then load the directed program.
    #0.1;

    $readmemh(
      "synopsys/coverage/fsm_reset/build/rvx_fsm_reset.hex",
      rvx_ram_instance.ram
    );

    // Initial reset.
    repeat (5)
      @(posedge clock);

    @(negedge clock);
    reset = 1'b0;

    $display("[%0t] Initial reset released", $time);

    // Wait for the requested FSM state.
    cycles = 0;

    while ((rvx_core_instance.current_state !== target_state) &&
           (cycles < MAX_WAIT_CYCLES)) begin
      @(negedge clock);
      cycles = cycles + 1;
    end

    if (rvx_core_instance.current_state !== target_state) begin
      $display("FAIL: Target state not reached");
      $display("TARGET: %s", target_name);
      $display("CURRENT STATE: %b",
               rvx_core_instance.current_state);
      $fatal(1, "FSM target timeout");
    end

    $display("[%0t] Target state reached: %s (%b)",
             $time,
             target_name,
             rvx_core_instance.current_state);

    // Fourth scenario: allow normal TRAP_RETURN -> OPERATING transition.
    if (target == "TRAP_RETURN_TO_OPERATING") begin

      $display("[%0t] Waiting for STATE_OPERATING", $time);

      cycles = 0;

      while ((rvx_core_instance.current_state !== STATE_OPERATING) &&
             (cycles < MAX_WAIT_CYCLES)) begin
        @(negedge clock);
        cycles = cycles + 1;
      end

      if (rvx_core_instance.current_state !== STATE_OPERATING) begin
        $display("FAIL: STATE_OPERATING not reached after TRAP_RETURN");
        $display("CURRENT STATE: %b",
                 rvx_core_instance.current_state);
        $fatal(1, "FSM return-to-operating timeout");
      end

      $display("[%0t] PASS: STATE_TRAP_RETURN -> STATE_OPERATING",
               $time);

    end
    else begin

      // Original reset scenarios: unchanged.
      reset = 1'b1;

      @(posedge clock);
      #0.1;

      if (rvx_core_instance.current_state !== STATE_RESET) begin
        $display("FAIL: FSM did not enter STATE_RESET");
        $display("CURRENT STATE: %b",
                 rvx_core_instance.current_state);
        $fatal(1, "FSM reset transition failed");
      end

      $display("[%0t] PASS: %s -> STATE_RESET",
               $time, target_name);

      repeat (2)
        @(posedge clock);

    end

    $display("========================================");
    $display(" FSM DIRECTED TEST PASSED");
    $display("========================================");

    $finish;
  end

endmodule
