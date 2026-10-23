# ==============================================================================
# Script de Property Verification (VC Formal / SVA) - RVX Design
# ==============================================================================

# 1. Configurar variáveis e diretórios do projeto
set PROJECT_ROOT ".."

# 2. Ler os arquivos RTL do hardware + Testbench/Bind de Asserções
# Habilita o suporte a SystemVerilog e SVA
analyze -format sverilog [list \
    $PROJECT_ROOT/dut/rvx/hardware/rvx_bus.v \
    $PROJECT_ROOT/dut/rvx/hardware/rvx_core.v \
    $PROJECT_ROOT/dut/rvx/hardware/rvx_gpio.v \
    $PROJECT_ROOT/dut/rvx/hardware/rvx_mtimer.v \
    $PROJECT_ROOT/dut/rvx/hardware/rvx_ram.v \
    $PROJECT_ROOT/dut/rvx/hardware/rvx_spi.v \
    $PROJECT_ROOT/dut/rvx/hardware/rvx_uart.v \
    $PROJECT_ROOT/dut/rvx/hardware/rvx.v \
    $PROJECT_ROOT/synopsys/tb/rvx_tb.sv \
]

# 3. Elaboar a hierarquia apontando para o topo
elaborate -top rvx

# 4. Configurar Clocks e Resets 
clock clock
reset -expression {!reset}

# 5. Inicializar o engine de Property Verification (FPV)
check_fv_setup

# 6. Executar a verificação formal das asserções
check_fv

# 7. Gerar relatório com o status de cada asserção (Proven, Falsified, Vacuous)
report_property -file property_report.rpt

exit