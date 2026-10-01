module rvx_tb;

// ============================================================
// Clock and reset
// ============================================================

logic clock;
logic reset;

// ============================================================
// RVX external interfaces
// ============================================================

logic halt;
logic uart_rx;
wire uart_tx;

logic gpio_input;
wire  gpio_oe;
wire  gpio_output;

wire sclk;
wire pico;
wire poci;
wire cs;

// ============================================================
// Clock: 50 MHz -> 20 ns period
// ============================================================

initial begin
clock = 1'b0;
forever #10 clock = ~clock;
end

// ============================================================
// RVX DUT
// ============================================================

rvx #(
.CLOCK_FREQUENCY (50_000_000),
.UART_BAUD_RATE (9600),
.MEMORY_SIZE (8192),
.MEMORY_INIT_FILE ("examples/hello_world/software/build/hello_world.hex"),
.BOOT_ADDRESS (0)
) dut (
.clock (clock),
.reset (reset),
.halt (halt),

.uart_rx (uart_rx),
.uart_tx (uart_tx),

.gpio_input (gpio_input),
.gpio_oe (gpio_oe),
.gpio_output (gpio_output),

.sclk (sclk),
.pico (pico),
.poci (poci),
.cs (cs)
);

// ============================================================
// Waveform
// ============================================================

initial begin
$fsdbDumpfile("synopsys/waves/test.fsdb");
$fsdbDumpvars(0, rvx_tb);
end

// ============================================================
// Reset and simulation control
// ============================================================

initial begin

$display("==============================================");
$display(" RVX Hello World - VCS Simulation");
$display("==============================================");

halt = 1'b0;
uart_rx = 1'b1; // UART RX idle state
gpio_input = 32'h00000000;

reset = 1'b1;

// Keep reset active for 10 clock cycles
repeat (10) @(posedge clock);

reset = 1'b0;

$display("[%0t ns] Reset released", $time);

// Run long enough for UART transmission
#50_000_000;

$display("==============================================");
$display("[%0t ns] Simulation finished", $time);
$display("==============================================");

$finish;
end

endmodule
