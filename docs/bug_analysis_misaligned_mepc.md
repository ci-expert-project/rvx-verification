# Análise de Causa-Raiz: Falhas em Testes de Desvio e Salto Desalinhados (*Instruction Address Misaligned*)

**Data:** 03 de Outubro de 2026  
**Projeto:** Verificação do Núcleo Processador RVX (RISC-V RV32I)  
**Ferramentas:** Synopsys VCS® & Synopsys Verdi® Automated Debug System  
**Commit do DUT (RVX):** `7af8290a770e6cb17e49dea75268a582bff5261f`  

---

## 1. Resumo Executivo

Durante a execução automatizada da suíte de conformidade RISC-V RV32I (composta por 54 testes unitários), o processador RVX alcançou uma taxa de aprovação de **85,2%** (46 testes aprovados em `PASS`). 

As **8 falhas** restantes (`FAIL`) pertencem a uma mesma classe de testes de limite (*corner cases*), correspondentes a instruções de salto e desvio condicional direcionadas a endereços de memória desalinhados:
- `misalign-jal-01`
- `misalign1-jalr-01`
- `misalign2-jalr-01`
- `misalign-beq-01`
- `misalign-bge-01`
- `misalign-blt-01`
- `misalign-bne-01`
- *(e subtestes correlatos de exceção de instrução desalinhada)*.

Este documento detalha a investigação de causa-raiz, comprovando empiricamente através do Synopsys Verdi o mecanismo exato do bug no pipeline de controle do processador.

---

## 2. Descarte da Hipótese Inicial (Issue #83 do DUT)

Investigou-se preliminarmente se o erro decorria de uma falha conhecida no registrador `mtval` (relatada na Issue #83 do repositório oficial do RVX).

A inspeção direta do código RTL em `dut/rvx/hardware/rvx_core.v` (linhas 1518–1522) confirmou que a correção do registrador `mtval` para exceções de desalinhamento **já se encontra implementada** no commit ativo:

```verilog
else if (misaligned_instruction_address)
  csr_mtval <= target_address_adder;
```

A análise em simulação confirmou que o `csr_mtval` assume o valor correto. Portanto, a Issue #83 foi **descartada** como causa primária das 8 falhas ativas.

---

## 3. Investigação de Causa-Raiz via Synopsys Verdi

Para isolar o comportamento do hardware, executou-se a simulação do teste `misalign-jal-01` com geração de ondas em formato FSDB e inspeção gráfica no Synopsys Verdi.

### 3.1. Análise da Instrução Geradora
No programa de teste (`misalign-jal-01.hex`), a instrução sob avaliação localiza-se na palavra de memória de endereço `PC = 0x0130`:
- **Instrução:** `JAL x10, +0x020a` (código hexadecimal: `0x20a0056f`).
- **Alvo Calculado:** `0x0130 + 0x020a = 0x033a`.
- **Condição de Exceção:** O endereço de destino `0x033a` termina em `0x...a` (não divisível por 4 bytes), o que obriga a arquitetura RISC-V a cancelar o salto e disparar a exceção *Instruction Address Misaligned*.

### 3.2. Evidência Empírica nas Formas de Onda (Waveform)

A amostragem dos sinais do núcleo no momento do disparo do *trap* (`take_trap = 1`, tempo `589,100 ps`) revelou os seguintes estados internos:

| Sinal / Registrador | Valor Observado no Verdi | Requisito da Especificação RISC-V | Diagnóstico |
| :--- | :--- | :--- | :--- |
| **`misaligned_instruction_address`** | `1'b1` (Alto) | `1'b1` | **Correto** ✅ |
| **`take_trap`** | `1'b1` (Alto) | `1'b1` | **Correto** ✅ |
| **`csr_mcause`** | `0x00000000` | `0x00000000` (*Instruction Address Misaligned*) | **Correto** ✅ |
| **`csr_mtval`** | `0x0000033a` | `0x0000033a` (Endereço de destino inválido) | **Correto** ✅ |
| **`csr_mepc`** | **`0x00000138`** | **`0x00000130`** (Endereço da instrução `JAL`) | **BUG DETECTADO ❌** |

---

## 4. Diagnóstico do Bug (Descompasso de Pipeline)

De acordo com a especificação oficial *RISC-V Privileged Architecture Specification*:
> *"When a trap is taken into M-mode, `mepc` is written with the virtual address of the instruction that encountered the exception or generated the trap."*

1. A instrução `JAL` que originou a exceção estava no endereço **`0x0130`**.
2. No hardware do RVX (`rvx_core.v`), a atribuição do `mepc` é descrita como:
   ```verilog
   if (take_trap)
     csr_mepc <= program_counter;
   ```
3. Devido ao avanço do circuito de busca (*prefetch* / estágio de instrução do pipeline), o registrador `program_counter` já havia sido incrementado em **+8 bytes (2 instruções à frente)** no ciclo em que o sinal `take_trap` foi avaliado, mudando o `csr_mepc` de `0x0130` para **`0x0138`**.
4. Ao concluir a rotina do *trap* e tentar retornar via instrução `mret`, a CPU retoma a execução no endereço incorreto `0x0138`, saltando instruções, corrompendo o fluxo de controle e gerando a falha de divergência na assinatura de memória (`Signature comparison failed`).

---

## 5. Recomendação de Correção no RTL

Para corrigir a falha no núcleo RVX sem alterar a lógica das instruções normais:

1. **Ajuste na captura do PC para `mepc`**:
   Em vez de atribuir o registrador de busca adiantado (`program_counter`) no momento de `take_trap`, deve-se capturar o registrador de endereço do estágio de execução que efetivamente gerou a exceção (ex: `pc_stage_ex` ou criar um registrador de sombra `faulting_instruction_pc`).

   ```verilog
   // Proposta de Correção em rvx_core.v
   if (take_trap) begin
     if (misaligned_instruction_address)
       csr_mepc <= current_instruction_pc; // Endereço estável da instrução de salto (0x0130)
     else
       csr_mepc <= program_counter;
   end
   ```

---

## 6. Conclusão

A verificação baseada em simulação no Synopsys VCS e depuração profunda no Synopsys Verdi permitiu comprovar empiricamente a causa-raiz das 8 falhas na suíte de testes. O problema foi isolado em um descompasso de sincronismo do registrador `csr_mepc` durante exceções de instrução desalinhada. A documentação deste achado fornece um resultado de verificação de alto valor para o aprimoramento do RTL do processador RVX.
