
`timescale 1ns/1ps

module rvx_core_tb;

  localparam integer MEMORY_SIZE = 2097152;
  localparam integer MAX_CYCLES  = 500000;

  localparam [31:0] FINISH_ADDR = 32'h00001000;

  localparam string PROGRAM_FILE =
      "dut/rvx/hardware/tests/core/unit_tests/programs/add-01.hex";

  localparam string REFERENCE_FILE =
      "dut/rvx/hardware/tests/core/unit_tests/references/add-01.reference.hex";

  localparam string DUMP_FILE =
      "sim/results/dumps/add-01.dump.hex";


  logic        clock;
  logic        reset;
  logic        halt;

  logic [15:0] irq_fast;
  logic        irq_external;
  logic        irq_timer;
  logic        irq_software;
  logic [63:0] real_time_clock;

  wire        irq_external_response;
  wire        irq_timer_response;
  wire        irq_software_response;
  wire [15:0] irq_fast_response;

  wire [31:0] rw_address;
  wire [31:0] read_data;
  wire        read_request;
  wire        read_response;

  wire [31:0] write_data;
  wire [3:0]  write_strobe;
  wire        write_request;
  wire        write_response;


  /*
   * RVX Core
   */
    /*
   * RVX Core
   */
  rvx_core #(
    .BOOT_ADDRESS(32'h00000000)
  ) rvx_core_instance (
    .clock            (clock),
    .reset            (reset),
    .halt             (halt),

    .irq_fast         (irq_fast),
    .irq_external     (irq_external),
    .irq_timer        (irq_timer),
    .irq_software     (irq_software),

    .real_time_clock  (real_time_clock),

    .rw_address       (rw_address),
    .read_data        (read_data),
    .read_request     (read_request),
    .read_response    (read_response),

    .write_data       (write_data),
    .write_strobe     (write_strobe),
    .write_request    (write_request),
    .write_response   (write_response),

    .irq_external_response (irq_external_response),
    .irq_timer_response    (irq_timer_response),
    .irq_software_response (irq_software_response),
    .irq_fast_response     (irq_fast_response)
  );


  /*
   * RVX RAM
   */
  rvx_ram #(
    .MEMORY_SIZE      (MEMORY_SIZE),
    .MEMORY_INIT_FILE ("")
  ) rvx_ram_instance (
    .clock            (clock),
    .reset            (reset),

    .rw_address       (rw_address),
    .read_data        (read_data),
    .read_request     (read_request),
    .read_response    (read_response),

    .write_data       (write_data),
    .write_strobe     (write_strobe),
    .write_request    (write_request),
    .write_response   (write_response)

  );


  /*
   * Clock
   */
  initial begin
    clock = 1'b0;

    forever #1 clock = ~clock;
  end


  /*
   * Interrupts / RTC
   */
  initial begin
    halt            = 1'b0;
    irq_fast        = 16'b0;
    irq_external    = 1'b0;
    irq_timer       = 1'b0;
    irq_software    = 1'b0;
    real_time_clock = 64'b0;
  end


  /*
   * Reset
   */
  initial begin

    reset = 1'b1;

    repeat (100)
      @(posedge clock);

    reset = 1'b0;

    $display("[%0t] Reset released", $time);

  end


  /*
   * Initialize RAM exactly like the official RVX flow:
   *
   * 1. Fill entire RAM with DEADBEEF
   * 2. Load add-01.hex
   */
  integer i;

  initial begin

    // Allow rvx_ram's internal initialization to complete.
    #0.1;

    for (i = 0; i < MEMORY_SIZE/4; i = i + 1)
      rvx_ram_instance.ram[i] = 32'hDEADBEEF;

    $readmemh(
      PROGRAM_FILE,
      rvx_ram_instance.ram
    );

    $display("==============================================");
    $display(" RAM CHECK");
    $display(" RAM[0] = %08h", rvx_ram_instance.ram[0]);
    $display(" RAM[1] = %08h", rvx_ram_instance.ram[1]);
    $display(" RAM[2] = %08h", rvx_ram_instance.ram[2]);
    $display(" RAM[3] = %08h", rvx_ram_instance.ram[3]);
    $display("==============================================");

    $display("RAM initialized with add-01.hex");

  end


  /*
   * Signature dump + comparison
   */
  task automatic dump_and_compare_signature;

    integer dump_fd;
    integer ref_fd;

    integer start_index;
    integer stop_index;

    integer address;
    integer reference_count;

    integer scan_status;

    reg [31:0] start_addr;
    reg [31:0] stop_addr;

    reg [31:0] actual_word;
    reg [31:0] expected_word;

    integer errors;


    begin

      errors = 0;
      reference_count = 0;


      /*
       * Official RVX protocol:
       *
       * RAM[2047] = start address
       * RAM[2046] = stop address
       */
      start_addr = rvx_ram_instance.ram[2047];
      stop_addr  = rvx_ram_instance.ram[2046];


      $display("");
      $display("==============================================");
      $display(" RVX SIGNATURE");
      $display("==============================================");

      $display("Start address : 0x%08h", start_addr);
      $display("Stop address  : 0x%08h", stop_addr);
      $display("Signature size: %0d bytes",
               stop_addr - start_addr);


      /*
       * Basic sanity checks.
       */
      if (start_addr >= stop_addr) begin

        $fatal(
          1,
          "Invalid signature range: start >= stop"
        );

      end


      if ((start_addr[1:0] != 2'b00) ||
          (stop_addr[1:0]  != 2'b00)) begin

        $fatal(
          1,
          "Signature addresses are not 32-bit aligned"
        );

      end


      start_index = start_addr >> 2;
      stop_index  = stop_addr  >> 2;


      if (stop_index > MEMORY_SIZE/4) begin

        $fatal(
          1,
          "Signature range exceeds RAM"
        );

      end


      /*
       * ------------------------------------------------------------
       * 1. Dump actual signature
       * ------------------------------------------------------------
       */
      dump_fd = $fopen(DUMP_FILE, "w");

      if (dump_fd == 0) begin

        $fatal(
          1,
          "Could not open dump file: %s",
          DUMP_FILE
        );

      end


      for (address = start_index;
           address < stop_index;
           address = address + 1) begin

        actual_word = rvx_ram_instance.ram[address];

        $fdisplay(
          dump_fd,
          "%08h",
          actual_word
        );

      end


      $fclose(dump_fd);


      $display(
        "Signature dump  : %s",
        DUMP_FILE
      );


      /*
       * ------------------------------------------------------------
       * 2. Compare against official reference
       * ------------------------------------------------------------
       */
      ref_fd = $fopen(REFERENCE_FILE, "r");

      if (ref_fd == 0) begin

        $fatal(
          1,
          "Could not open reference file: %s",
          REFERENCE_FILE
        );

      end


      for (address = start_index;
           address < stop_index;
           address = address + 1) begin

        scan_status = $fscanf(
          ref_fd,
          "%h",
          expected_word
        );


        /*
         * Reference file ended before DUT signature.
         */
        if (scan_status != 1) begin

          errors = errors + 1;

          $display(
            "ERROR: reference ended before DUT signature at word %0d",
            reference_count
          );

        end
        else begin

          actual_word = rvx_ram_instance.ram[address];

          if (actual_word !== expected_word) begin

            errors = errors + 1;

            $display(
              "MISMATCH [%0d] addr=0x%08h DUT=0x%08h REF=0x%08h",
              reference_count,
              address * 4,
              actual_word,
              expected_word
            );

          end

        end


        reference_count = reference_count + 1;

      end


      /*
       * Check if the reference contains additional words.
       */
      if ($fscanf(ref_fd, "%h", expected_word) == 1) begin

        errors = errors + 1;

        $display(
          "ERROR: reference file contains more words than DUT signature"
        );

      end


      $fclose(ref_fd);


      /*
       * ------------------------------------------------------------
       * 3. Final result
       * ------------------------------------------------------------
       */
      $display("");
      $display("==============================================");
      $display(" RVX CORE TEST RESULT");
      $display("==============================================");

      $display("Test            : add-01");
      $display("Cycles          : %0d", cycles);
      $display("Signature words : %0d", reference_count);
      $display("Errors          : %0d", errors);


      if (errors == 0) begin

        $display("");
        $display("**************************************");
        $display(" PASS: add-01");
        $display("**************************************");
        $display("");

      end
      else begin

        $display("");
        $display("**************************************");
        $display(" FAIL: add-01");
        $display("**************************************");
        $display("");

        $fatal(
          1,
          "Signature comparison failed"
        );

      end

    end

  endtask


  /*
   * Simulation control
   */
  integer cycles;

  initial begin

    cycles = 0;


    /*
     * Wait until reset has been released.
     */
    wait (reset == 1'b0);


    forever begin

      @(posedge clock);

      cycles = cycles + 1;

	#0.1;

	if (cycles < 20) begin
          $display("DEBUG cycle=%0d ADDR=%h RD_REQ=%b RD_DATA=%h RD_RESP=%b WR_REQ=%b WR_DATA=%h",
           cycles,
           rw_address,
           read_request,
           read_data,
           read_response,
           write_request,
           write_data);
	end

      /*
       * Official RVX test completion protocol:
       *
       * write 0x00000001 to address 0x00001000
       */
      if ((rw_address == FINISH_ADDR) &&
          (write_request == 1'b1) &&
          (write_data == 32'h00000001)) begin


        $display("");
        $display("==============================================");
        $display(" RVX CORE TEST FINISHED");
        $display("==============================================");

        $display("Test       : add-01");
        $display("Cycles     : %0d", cycles);
        $display("Finish addr: 0x%08h", rw_address);
        $display("Write data : 0x%08h", write_data);


        /*
         * Give the final memory write one delta cycle
         * to settle before reading the signature.
         */
        #0;

        dump_and_compare_signature;


        $finish;

      end


      /*
       * Timeout protection.
       */
      if (cycles >= MAX_CYCLES) begin

        $display("");
        $display("==============================================");
        $display(" RVX CORE TEST TIMEOUT");
        $display("==============================================");

        $display("Test   : add-01");
        $display("Cycles : %0d", cycles);

        $fatal(
          1,
          "Maximum cycle count reached"
        );

      end

    end

  end

endmodule
