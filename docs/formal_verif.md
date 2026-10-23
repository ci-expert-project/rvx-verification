# Fluxo de Verificação Formal Baseada em Propriedades (SVA) — VC Formal

Este documento descreve o procedimento para executar a verificação formal de propriedades e asserções SystemVerilog (SVA) no projeto **RVX** utilizando a ferramenta **VC Formal** (`vc_static_shell`) da Synopsys.

---

## 1. Visão Geral do Fluxo

Ao contrário do Formality (focado em equivalência lógica entre RTL e Netlist), o **VC Formal (FPV - Formal Property Verification)** prova matematicamente se as asserções (`assert property`) definidas no RTL ou Testbench são satisfeitas para **todas as combinações de estímulos possíveis**, sem a necessidade de gerar vetores de teste manuais.

---

## 2. Estrutura de Ficheiros

Garanta que os scripts e listas de ficheiros estão organizados na pasta `synopsys/`:

```text
rvx-verification/
├── dut/
│   └── rvx/
│       └── hardware/            # Código RTL do design
├── synopsys/
│   ├── tb/
│   │   └── rvx_tb.sv            # Testbench / Módulo com as SVA
│   ├── run_vc_formal.tcl        # Script de execução Tcl
│   └── VC_FORMAL_SVA.md         # Esta documentação
```

---

## 3. Script Tcl de Configuração (`run_vc_formal.tcl`)

Crie o ficheiro `synopsys/run_vc_formal.tcl` com o seguinte conteúdo:

```tcl
# ==============================================================================
# Script de Property Verification (VC Formal / SVA) - RVX Design
# ==============================================================================

# 1. Configurar variáveis e diretórios do projeto
set PROJECT_ROOT ".."

# 2. Ler os arquivos RTL do hardware + Testbench/Bind de Asserções
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

# 3. Elaborar a hierarquia apontando para o módulo do topo
elaborate -top rvx

# 4. Configurar Clocks e Resets
# (Ajuste os nomes dos sinais caso o topo utilize nomes diferentes)
clock clk
reset -expression {!rst_n}

# 5. Inicializar o engine de Property Verification (FPV)
check_fv_setup

# 6. Executar a verificação formal de todas as asserções
check_fv

# 7. Gerar relatório de resultados
report_property -file property_report.rpt

exit
```

---

## 8. Como Executar no Terminal

Aceda à pasta `synopsys` no servidor (`cadmicro-el8-06`):

```bash
cd synopsys
```

### Modo Batch (Linha de comando / CI)
Para rodar a verificação em segundo plano e salvar o log de execução:

```bash
vc_static_shell -f run_vc_formal.tcl | tee vc_formal.log
```

### Modo Gráfico (GUI - Recomendado para Debug)
Se alguma asserção falhar, abra a interface gráfica para visualizar a forma de onda do **contra-exemplo** (*counterexample waveform*):

```bash
vc_static_shell -gui -f run_vc_formal.tcl
```

---

## 5. Interpretação do Relatório (`property_report.rpt`)

Após a execução, abra o ficheiro `property_report.rpt` para conferir o status de cada propriedade:

| Status | Significado | Ação Necessária |
| :--- | :--- | :--- |
| **Proven** | A propriedade foi provada matematicamente para todos os ciclos. | Nenhuma (sucesso). |
| **Falsified** | A ferramenta encontrou uma sequência de estímulos que viola a asserção. | Analisar o contra-exemplo no modo GUI. |
| **Vacuous** | A precondição da asserção nunca ocorreu (`antecedent` falso). | Rever a lógica da SVA ou as restrições de ambiente. |
| **Unprocessed** | O tempo limite de execução (*timeout*) foi atingido antes de concluir. | Aumentar o tempo limite ou simplificar a propriedade. |

---

## 6. Boas Práticas e Git

1. **Ignorar artefatos temporários:** Adicione os diretórios gerados pelo VC Formal ao `.gitignore`:
   ```text
   # VC Formal artifacts
   vc_static_shell_work/
   *.log
   *.rpt
   ```

2. **Commit das alterações na branch:**
   ```bash
   git add synopsys/run_vc_formal.tcl synopsys/VC_FORMAL_SVA.md .gitignore
   git commit -m "Add VC Formal SVA verification setup for RVX"
   git push origin feat/setup-dut
   ```