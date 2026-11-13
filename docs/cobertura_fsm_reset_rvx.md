# Cobertura Dirigida do FSM do RVX com Synopsys VCS e URG

- **Data:** 10 de novembro de 2026
- **Projeto:** Verificação do núcleo RVX (RISC-V)
- **Ferramentas:** Synopsys VCS W-2024.09-SP2-3 e URG W-2024.09-SP2-3
- **Ambiente:** CADMICRO / Linux

---

## 1. Objetivo

Documentar a verificação dirigida das transições do finite-state machine
(FSM) do núcleo RVX, com foco nas transições relacionadas ao reset e no
retorno normal do estado de tratamento de exceção.

O experimento complementa a análise de cobertura de código já realizada
no projeto. Foram desenvolvidos cenários específicos para exercitar
transições que não haviam sido cobertas pela regressão funcional original.

O resultado consolidado alcançou 100% de cobertura FSM para o escopo
instrumentado e analisado pelo Synopsys URG.

## 2. Escopo e arquivos utilizados

O experimento utiliza o núcleo RVX e sua memória, com um testbench
independente da regressão funcional original.

| Elemento | Arquivo |
|---|---|
| RTL do núcleo | `dut/rvx/hardware/rvx_core.v` |
| RTL da memória | `dut/rvx/hardware/rvx_ram.v` |
| Testbench dirigido | `synopsys/tb/rvx_fsm_reset_tb.sv` |
| Filelist | `synopsys/filelist/rvx_fsm_reset.f` |
| Programa Assembly | `synopsys/coverage/fsm_reset/rvx_fsm_reset.S` |
| Programa HEX | `synopsys/coverage/fsm_reset/build/rvx_fsm_reset.hex` |

A lista de arquivos utilizada foi:

```text
dut/rvx/hardware/rvx_core.v
dut/rvx/hardware/rvx_ram.v
synopsys/tb/rvx_fsm_reset_tb.sv
```

O testbench instancia `rvx_core` e `rvx_ram`, gera o clock, controla
o reset e carrega o programa de teste na memória.

A seleção dos cenários é realizada pelo argumento `+TARGET`.

## 3. Metodologia

A metodologia foi dividida em quatro etapas:

1. Identificação das transições FSM não cobertas no relatório anterior.
2. Desenvolvimento de cenários dirigidos em testbench independente.
3. Compilação e execução das simulações com instrumentação de cobertura FSM.
4. Consolidação dos bancos de cobertura e análise do relatório URG.

O sinal interno `current_state` foi monitorado hierarquicamente por meio
da instância `rvx_core_instance`.

O FSM utiliza quatro estados:

| Estado | Codificação |
|---|---|
| STATE_RESET | `0001` |
| STATE_OPERATING | `0010` |
| STATE_TRAP_TAKEN | `0100` |
| STATE_TRAP_RETURN | `1000` |

A transição para `STATE_RESET` é realizada pelo mecanismo de reset
interno (`reset_internal`), enquanto as transições normais dependem
da lógica de controle do FSM.

## 4. Cenários de verificação

Foram executados quatro cenários independentes.

### 4.1. Reset durante STATE_OPERATING

**Parâmetro:** `+TARGET=OPERATING`

Procedimento:

1. Liberar o reset inicial.
2. Aguardar a entrada em `STATE_OPERATING`.
3. Aplicar reset durante a execução normal.
4. Verificar a entrada em `STATE_RESET`.

Resultado: PASS.

### 4.2. Reset durante STATE_TRAP_TAKEN

**Parâmetro:** `+TARGET=TRAP_TAKEN`

Procedimento:

1. Executar a instrução `ecall` para provocar uma exceção.
2. Aguardar a entrada em `STATE_TRAP_TAKEN`.
3. Aplicar reset.
4. Verificar a entrada em `STATE_RESET`.

Resultado: PASS.

### 4.3. Reset durante STATE_TRAP_RETURN

**Parâmetro:** `+TARGET=TRAP_RETURN`

Procedimento:

1. Executar `ecall` para entrar no tratamento de exceção.
2. Executar o handler e a instrução `mret`.
3. Aguardar a entrada em `STATE_TRAP_RETURN`.
4. Aplicar reset antes da transição normal seguinte.
5. Verificar a entrada em `STATE_RESET`.

Resultado: PASS.

### 4.4. Retorno normal STATE_TRAP_RETURN → STATE_OPERATING

**Parâmetro:** `+TARGET=TRAP_RETURN_TO_OPERATING`

Este cenário foi acrescentado para cobrir a transição normal que
permanecia descoberta no relatório anterior.

Procedimento:

1. Executar `ecall`.
2. Aguardar o tratamento da exceção.
3. Executar `mret`.
4. Detectar `STATE_TRAP_RETURN`.
5. Não aplicar reset.
6. Aguardar a transição para `STATE_OPERATING`.
7. Confirmar a transição e encerrar o teste.

Resultado: PASS.

A simulação registrou:

```text
[30000] Target state reached: TRAP_RETURN_TO_OPERATING (1000)
[30000] Waiting for STATE_OPERATING
[32000] PASS: STATE_TRAP_RETURN -> STATE_OPERATING
FSM DIRECTED TEST PASSED
```

## 5. Programa de teste

O programa Assembly utilizado configura o vetor de exceção,
executa `ecall` e retorna ao fluxo normal por meio de `mret`.

Trecho principal:

```asm
.option norvc
.section .text
.globl _start

_start:
    addi x5, x0, 256
    csrw mtvec, x5
    ecall

main_loop:
    jal x0, main_loop

.org 0x100
trap_handler:
    csrr x6, mepc
    addi x6, x6, 4
    csrw mepc, x6
    mret
```

O programa foi compilado com a toolchain RISC-V 14.2.0:

```bash
riscv64-elf-gcc \
  -march=rv32i_zicsr \
  -mabi=ilp32 \
  -nostdlib \
  -nostartfiles \
  -Wl,-Ttext=0 \
  -Wl,--no-relax \
  -Wl,-e,_start \
  synopsys/coverage/fsm_reset/rvx_fsm_reset.S \
  -o synopsys/coverage/fsm_reset/build/rvx_fsm_reset.elf
```

O ELF foi convertido para HEX para carregamento na memória do testbench.

## 6. Compilação com Synopsys VCS

### 6.1. Compilação inicial dos três cenários de reset

A compilação instrumentada foi realizada com:

```bash
vcs -full64 \
  -f synopsys/filelist/rvx_fsm_reset.f \
  -sverilog \
  -timescale=1ns/1ps \
  -debug_access+all \
  -kdb \
  -cm fsm \
  -cm_dir synopsys/coverage/fsm_reset/design.vdb \
  -l synopsys/coverage/fsm_reset/build/compile_coverage_rebuild.log \
  -o synopsys/coverage/fsm_reset/build/simv_fsm_reset_rebuild
```

### 6.2. Compilação do quarto cenário

Para incluir o cenário de retorno normal, foi realizada uma nova compilação:

```bash
vcs -full64 \
  -f synopsys/filelist/rvx_fsm_reset.f \
  -sverilog \
  -timescale=1ns/1ps \
  -debug_access+all \
  -kdb \
  -cm fsm \
  -cm_dir synopsys/coverage/fsm_reset/design_rebuild4.vdb \
  -l synopsys/coverage/fsm_reset/build/compile_rebuild4.log \
  -o synopsys/coverage/fsm_reset/build/simv_fsm_reset_rebuild4
```

A comparação dos arquivos `fsm.verilog.shape.xml` dos dois bancos
de projeto confirmou que são idênticos.

## 7. Execução dos cenários

Os três primeiros cenários foram executados com o executável
`simv_fsm_reset_rebuild`.

Exemplo:

```bash
synopsys/coverage/fsm_reset/build/simv_fsm_reset_rebuild \
  -cm fsm \
  -cm_dir synopsys/coverage/fsm_reset/database_rebuild/operating.vdb \
  +TARGET=OPERATING
```

Os demais parâmetros foram:

```text
+TARGET=TRAP_TAKEN
+TARGET=TRAP_RETURN
```

O quarto cenário foi executado com o executável atualizado:

```bash
synopsys/coverage/fsm_reset/build/simv_fsm_reset_rebuild4 \
  -cm fsm \
  -cm_dir synopsys/coverage/fsm_reset/database_rebuild/trap_return_to_operating.vdb \
  +TARGET=TRAP_RETURN_TO_OPERATING \
  -l synopsys/coverage/fsm_reset/build/trap_return_to_operating.log
```

Todos os quatro cenários foram concluídos com resultado PASS.

## 8. Consolidação com Synopsys URG

Os bancos de dados de cobertura dos quatro testes foram consolidados
com o banco de projeto `design.vdb`.

Comando utilizado:

```bash
urg \
  -dir synopsys/coverage/fsm_reset/design.vdb \
       synopsys/coverage/fsm_reset/database_rebuild/operating.vdb \
       synopsys/coverage/fsm_reset/database_rebuild/trap_taken.vdb \
       synopsys/coverage/fsm_reset/database_rebuild/trap_return.vdb \
       synopsys/coverage/fsm_reset/database_rebuild/trap_return_to_operating.vdb \
  -report synopsys/coverage/fsm_reset/final_report_4tests/report \
  -metric fsm \
  -format both \
  -log synopsys/coverage/fsm_reset/final_report_4tests/merge.log
```

O URG concluiu a consolidação e gerou o relatório sem erros.

## 9. Resultados

### 9.1. Comparação da cobertura FSM

O relatório anterior, com três cenários, apresentava 87,50% de cobertura
FSM, correspondendo a sete das oito transições.

Após a inclusão do quarto cenário, o resultado passou a 100%.

| Indicador | Três cenários | Quatro cenários |
|---|---:|---:|
| Testes consolidados | 3 | 4 |
| Estados cobertos | 4/4 | 4/4 |
| Transições cobertas | 7/8 | 8/8 |
| FSM Coverage | 87,50% | 100,00% |

### 9.2. Transições cobertas

| Transição | Situação no relatório final |
|---|---|
| STATE_RESET → STATE_OPERATING | Coberta |
| STATE_OPERATING → STATE_RESET | Coberta |
| STATE_OPERATING → STATE_TRAP_TAKEN | Coberta |
| STATE_OPERATING → STATE_TRAP_RETURN | Coberta |
| STATE_TRAP_TAKEN → STATE_OPERATING | Coberta |
| STATE_TRAP_TAKEN → STATE_RESET | Coberta |
| STATE_TRAP_RETURN → STATE_RESET | Coberta |
| STATE_TRAP_RETURN → STATE_OPERATING | Coberta |

### 9.3. Resumo do dashboard URG

Dados registrados em `dashboard.txt`:

```text
Number of tests: 4

Total Coverage Summary
SCORE   FSM
100.00  100.00

Hierarchical coverage data for top-level instances
SCORE   FSM    NAME
100.00  100.00 rvx_fsm_reset_tb

Total Module Definition Coverage Summary
SCORE   FSM
100.00  100.00
```

## 10. Artefatos e rastreabilidade

Os principais artefatos gerados foram preservados nos seguintes caminhos:

| Artefato | Caminho |
|---|---|
| Testbench | `synopsys/tb/rvx_fsm_reset_tb.sv` |
| Filelist | `synopsys/filelist/rvx_fsm_reset.f` |
| Assembly | `synopsys/coverage/fsm_reset/rvx_fsm_reset.S` |
| Executável VCS | `synopsys/coverage/fsm_reset/build/` |
| Banco de projeto | `synopsys/coverage/fsm_reset/design.vdb` |
| Banco do quarto build | `synopsys/coverage/fsm_reset/design_rebuild4.vdb` |
| Bancos dos quatro testes | `synopsys/coverage/fsm_reset/database_rebuild/` |
| Relatório URG final | `synopsys/coverage/fsm_reset/final_report_4tests/report/` |
| Log de consolidação | `synopsys/coverage/fsm_reset/final_report_4tests/merge.log` |

O dashboard principal do resultado final está disponível em:

`synopsys/coverage/fsm_reset/final_report_4tests/report/dashboard.txt`

O relatório anterior de 87,50% foi preservado em
`final_report_rebuild_complete/report/`, permitindo rastrear a evolução
da cobertura.

## 11. Conclusão e limitações

A verificação dirigida demonstrou que os quatro cenários executados
cobrem todas as oito transições do FSM instrumentado.

O resultado final foi de 100% de cobertura FSM, com quatro estados
e oito transições cobertos.

O experimento demonstra a cobertura das transições modeladas e
instrumentadas no FSM do núcleo. Não representa 100% de cobertura
de linhas, condições, branches, toggles, funcionalidades do processador
ou conformidade integral com a especificação RISC-V.

Também não representa uma comparação entre as implementações RVX
com diferentes granularidades de TMR.

Nenhuma alteração no RTL do DUT foi necessária para atingir esse
resultado; a atividade foi realizada por meio de testbench e cenários
de verificação dirigidos.
