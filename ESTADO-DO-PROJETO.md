# Sistema de Controle de Repasses — Canaverde & Aguiar Advogados
**Documento de estado do projeto.** Atualizado em 23/07/2026.
**Leia este arquivo inteiro antes de responder qualquer pedido sobre este sistema.**

---

## 0. Instruções para o assistente (Claude Code)

- **Responder sempre em português (pt-BR).** O usuário é o **Danilo Ferro**, da área **Financeira e Administrativa** — ele gerencia uma equipe no escritório, mas **não é advogado**. É **leigo em programação**. Explicar sem jargão, passo a passo, dizendo o **porquê** junto do **como**.
- **Nunca editar `atendimento.html` na mão.** Editar **sempre** `index.html` e rodar `python3 transform.py` para regerar o gêmeo.
- **Validar antes de entregar:** extrair o último `<script>` e rodar `node --check`.
- **Banco em produção com dados reais.** Toda migração deve ser **aditiva** (`add column if not exists`, `create or replace`). **Nunca** recriar tabela nem re-inserir dados.
- **Testar mudanças de banco dentro de transação com `rollback`** antes de aplicar de verdade (ver §9).
- Ao terminar um assunto, **oferecer o resumo atualizado deste documento**.

---

## 1. O que é

Sistema web para controlar repasses de valores a clientes do escritório. Dois aplicativos HTML de página única (vanilla JS, sem framework, sem build), ligados a um banco Supabase compartilhado, publicados na Vercel via GitHub.

- **`index.html`** — acesso da **gestão**. Vê valores, tempo pendente, financeiro, gerencia usuários.
- **`atendimento.html`** — acesso do **atendimento**. **Nunca vê valores** e **não altera pagamento** (bloqueio no banco, não só na tela).

Os dois leem/gravam a mesma base: o que um faz, o outro vê (atualização automática a cada 30s + botão Atualizar).

---

## 2. Endereços e acessos

- **Repositório:** https://github.com/danilo-ferro/sistema-repasses-canaverde (branch `main`) — **público**
- **Supabase project_id:** `maytgfyzvoufepaerwwn`
- **SUPABASE_URL:** `https://maytgfyzvoufepaerwwn.supabase.co`
- **Chave publicável:** `sb_publishable_U4pGdy1Bom36dZ2bo6nb3g_VMAAYELY` (pública por design; já está dentro dos HTML). A chave **secret/service_role NUNCA** vai para o site nem para o repositório.
- **Vercel:** conectado ao GitHub → commit no repo republica sozinho (~30s), URL fixa.

**Estado da publicação em 23/07/2026:** GitHub, Vercel e os arquivos locais estão **100% em sincronia**. O conteúdo publicado é exatamente o descrito neste documento.

---

## 3. Banco de dados (Supabase)

### Tabela `repasses` — **261 lançamentos** (~R$ 615.016,64 | 15 pagos, 246 pendentes)
`id` (bigint identity), `nome`, `nome_norm` (sem acento, maiúsculo), `cpf`, `processo`, `reu`, `grupo`, `advogado`, `tipo`, `conta`, `competencia` ("Mmm/AAAA"), `ano`, `mes`, `valor_num` (numeric), `busca`, `cp` (bool), `pago` (bool), `data_pagamento` (text ISO), `valor_pago` (text BR), `obs`, `pix_chave`, `pix_banco`, `pix_agencia`, `pix_conta`, `atualizado_por`, `atualizado_em`, `criado_em`.

Grupos: Max, Mariah, Jezieli, Yunes, Kaled, Nardon, JLM, Máximo Êxito.

### Tabela `profiles`
`id` (uuid → `auth.users`, **ON DELETE CASCADE**), `email` (text), `nome` (text), `perfil` (text NOT NULL, default `'atendimento'`, valores `gestao` | `atendimento`).

- **RLS:** policy `perfil_proprio` — cada usuário só enxerga **o próprio** registro.
  → Por isso a lista de usuários do painel usa a função `listar_usuarios()`, e **não** um `select` direto em `profiles`.
- Trigger `handle_new_user` (em `auth.users`) cria o profile automaticamente com perfil `atendimento` e **sem nome**.

### Segurança de valores (atendimento não vê dinheiro)
- **RLS na `repasses`:** policy `repasses_gestao` — só perfil `gestao` acessa a tabela (que tem valores).
- **View `repasses_atendimento`** (`security_invoker = off`) — **não expõe `valor_num` nem `valor_pago`**. É por ela que o atendimento lê e grava.
- **Função `recibo_dados(bigint[])`** (security definer) — entrega o valor só dos lançamentos escolhidos, para o atendimento gerar recibo. **Está concedida (`granted`).**
  Para bloquear: `revoke execute on function public.recibo_dados(bigint[]) from authenticated;`

### Segurança de pagamento (NOVO em 23/07/2026)
- **Trigger `trg_bloqueia_pagamento`** (BEFORE INSERT OR UPDATE em `repasses`) → função `bloqueia_pagamento_nao_gestao()`.
- Impede que **qualquer usuário logado que não seja `gestao`** altere `pago`, `data_pagamento` ou `valor_pago` — pela tela, pela view ou por chamada direta à API.
- `auth.uid()` nulo (service_role / migrações) **passa livre**, de propósito.
- A restrição na tela é apenas cosmética; **a trava real é esta**.

### Gerenciamento de usuários (NOVO em 23/07/2026) — todas SECURITY DEFINER, só `gestao`
| Função | Argumentos | O que faz |
|---|---|---|
| `listar_usuarios()` | — | Lista `email`, `nome`, `perfil`. Devolve **0 linhas** se quem chama não for gestão. |
| `admin_criar_usuario(p_email, p_nome, p_senha, p_perfil)` | text ×4 | Cria em `auth.users` + `auth.identities` + ajusta `profiles`. |
| `admin_atualizar_usuario(p_email, p_nome, p_perfil, p_nova_senha)` | text ×4 | Atualiza nome/perfil; troca a senha **só se** `p_nova_senha` vier preenchida. |
| `admin_excluir_usuario(p_email)` | text | Apaga identidade + usuário (o profile sai por cascata). |
| `admin_definir_senha(target_email, nova_senha)` | text ×2 | **Legada.** Trocava só a senha. Substituída por `admin_atualizar_usuario`. Mantida por compatibilidade; **não é usada pela tela**. |

**Proteções embutidas (testadas):** perfil não-gestão é recusado; e-mail duplicado barrado; senha mínima 6 caracteres; perfil só aceita `gestao`/`atendimento`; **não** dá para excluir a própria conta; **não** dá para excluir nem rebaixar o **último** usuário `gestao`.

> ⚠️ **Senha:** as funções gravam o hash com `extensions.crypt(senha, gen_salt('bf'))` — mesmo padrão bcrypt do Supabase Auth. Funciona bem neste porte, mas é acoplado ao formato interno do GoTrue; se o Supabase mudar isso, precisará de ajuste.

> ⚠️ **E-mail é a chave de login.** Por isso o painel deixa o e-mail **somente leitura** na edição. Para trocar o e-mail de alguém: excluir e criar de novo.

### Histórico / auditoria
- Tabela `repasses_log` + view `repasses_log_atendimento` (filtra linhas de valor).
- Triggers `trg_marca_autor` (carimba `atualizado_por`/`atualizado_em`) e `trg_registra_log` (grava criou/alterou/excluiu, campo, de → para, quem, quando).
- Funções `meu_perfil()`, `meu_email()`, `meu_nome()`.
- Grava desde 15/07/2026. **Não há histórico anterior a isso.**

### Usuários cadastrados (11 em 23/07/2026)
| Nome | E-mail | Perfil |
|---|---|---|
| Danilo Ferro | canaverdeadvogados8@gmail.com | gestao |
| Fernanda Simões | canaverdeadvogados27@gmail.com | gestao |
| Caio Soares | csoares.canaverdeadvs@gmail.com | gestao |
| Max Canaverde | max.etecfran@gmail.com | gestao |
| Anderson Andrade | canaverdeadvogados2@gmail.com | atendimento |
| Jorge Mesquita | canaverdeadvogados11@gmail.com | atendimento |
| Isabela Guedes | iguedes.canaverdeadvs@gmail.com | atendimento |
| Irís Pereira | ipereira.canaverdeadvs@gmail.com | atendimento |
| Jenifer Gonçalves | jgoncalves.canaverdeadvs@gmail.com | atendimento |
| Lucas Mesquita | lmesquita.canaverdeadvs@gmail.com | atendimento |
| Nathalia Gomes | ngomes.canaverdeadvs@gmail.com | atendimento |

---

## 4. Funcionalidades prontas

1. **Lista de lançamentos** — busca (ignora acentos), filtros por status/ano/mês/grupo, "Só C.P.", ordenação, visão *Por lançamento* e *Por cliente* (consolidada).
2. **Tempo pendente** (só gestão) — calculado pela **competência**: ≤3m verde, 4–6 amarelo, 7–12 laranja, >12 vermelho.
3. **Baixa de pagamento** (**só gestão**) — data, valor pago, observação.
4. **Status PAGO/PENDENTE** — botão clicável na gestão; **texto fixo (somente leitura) no atendimento**.
5. **Financeiro** (só gestão) — filtro por período pela **data de pagamento** (+ atalhos Este mês / Mês passado / Este ano / Todo o período), total pago, quantidade, clientes, valor médio, total por grupo, tabela e CSV com linha de total. Avisa quando há pago sem data.
6. **Painel de Usuários** (só gestão) — botão **"Usuários"** no topo. Lista todos (nome, e-mail, perfil colorido) e permite **criar**, **editar** (nome, perfil, senha opcional) e **excluir**. No atendimento o botão fica escondido.
7. **Modo claro/escuro** — botão no topo, salvo em localStorage por pessoa.
8. **Histórico** — botão no topo (últimas 150) + "última alteração por X em data" dentro de cada lançamento + histórico individual.
9. **Recibo de quitação** — botão por lançamento e "Recibo do cliente" (consolida vários processos, soma o total, caixinhas marcáveis; pendentes vêm marcados). Dados bancários (Chave Pix, Banco, Agência, Conta) salvos no lançamento. Documento pronto para imprimir/PDF.
10. **Backup** — botão baixa JSON com todos os registros. (Plano grátis do Supabase **não faz backup automático**.)

---

## 5. O recibo de quitação (detalhes importantes)

- Reproduz **fielmente** o modelo do escritório: logo CANAVERDE no topo e rodapé timbrado (telefone, e-mail, endereço), ambos embutidos em base64.
- **Texto mantido literal**, inclusive os erros de digitação do original: **"PRESTAÇAO"**, **"conta bancaria a baixo"**. *(Pendência: Danilo pode querer corrigir.)*
- **Comarca e Vara não existem** no recibo (removidos a pedido — o sistema não tem esses dados).
- **3 itens** numerados: quitação + prestação de contas / juros e correção + cláusula quarta / orientação e alcance da quitação.
- **Em negrito:** "Cliente:", "CPF/CNPJ:", "Número do processo:", "CANAVERDE & AGUIAR SOCIEDADE DE ADVOGADOS", todo o bloco de dados bancários, "Declaro, ainda, que com o recebimento do referido valor:" e os numerais (via `ol li::marker`).
- **Valor por extenso** em pt-BR — função `extensoReais()`, testada em 15+ casos (regras do "e", "cem/cento", "de reais" para milhão/bilhão exatos).
- Data no formato "São Paulo, 15 de Julho de 2026."
- Abre em nova janela (`window.open`) — **pop-ups precisam estar liberados**.
- O recibo abre em `about:blank`: **URL relativa não funciona lá dentro** (ver pendência 1).

---

## 6. Identidade visual

- **Emblema:** símbolo da Canaverde (círculo verde), no topo e no login. O antigo "MLE" foi removido.
- **Subtítulos:** "Gestão - Canaverde & Aguiar Advogados" / "Atendimento - Canaverde & Aguiar Advogados".
- Cores: `--azul:#1a3a5c`, `--azul2:#2d6a9f`, `--azul-cl:#eaf2fa`. Tema escuro via `[data-theme="dark"]` sobre variáveis CSS.

---

## 7. Estrutura técnica dos HTML (~194 KB cada, 1205 linhas)

Arquivo único: `<style>` (variáveis CSS + tema escuro) → HTML (header, stats, filtros, wrap, modais: editar, histórico, recibo, **usuários**, login) → `<script>`.

Blocos do JS, na ordem:
config Supabase (`SUPABASE_URL`, `SUPABASE_ANON_KEY`, `_normUrl()`) → `MODE`/`isGestao`/`TABLE` → utilitários (`norm`, `parseComp`, `mesesPend`, `tempoCls`, `esc`, `brl`, `parseBR`, `fmtBR`) → `loadData` → filtros → render (`renderStats`, `renderFlat`, `rowHTML`, `expHTML`, `renderCards`, `clRow`) → ações (`persist`, `toggleCp`, `togglePago`, `savePag`, `saveObs`, `delRec`) → modal (`openModal`, `saveModal`) → export (`doExportJSON`, `doExportCSV`) → `LOGO_B64`/`RODAPE_B64` → tema → extenso → auditoria (`openLog`) → financeiro (`renderFin`, `finPreset`, `exportFinCSV`) → recibo (`openRec`, `openRecCliente`, `buildRec`, `gerarRecibo`, `abrirRecibo`) → **usuários (`openSenhas`, `closeSenhas`, `renderUsuarios`, `formNovo`, `formEditar`, `mostrarForm`, `salvarUsuario`, `excluirUsuario`)** → login/init (`boot`, `doLogin`, `onLogged`, `canRefresh`, `doLogout`).

**Pontos-chave de perfil no código:**
- `const MODE` / `const isGestao` (linha ~372) — origem de tudo.
- `rowHTML()` e `clRow()` — status vira `<span>` quando não é gestão.
- `togglePago()` — trava por perfil logo na primeira linha.
- Bloco final `if(!isGestao){...}` — esconde `btnFin` e `btnSenhas`.

**Os dois arquivos são gêmeos** — mudam só `<title>`, o subtítulo (2×) e `const MODE`.
**Basta trabalhar no `index.html`: o `atendimento.html` sai do `transform.py`.**

**Como validar antes de entregar:** extrair o último `<script>` e rodar `node --check`; opcionalmente um harness em Node com DOM/Supabase simulados (precisa stub de `confirm`, `alert`, `localStorage`, `window.matchMedia`, `window.open`, e `sb.from()` encadeável + `sb.rpc`).

---

## 8. Pendências e próximos passos

1. **[PRIORIDADE] Emagrecer os arquivos** — ~107 KB dos 194 KB são as imagens (logo, rodapé, emblema) em base64 dentro do HTML. Tirar para arquivos separados (`logo.png`, `rodape.png`, `emblema.png`) referenciados por **URL absoluta** (`new URL('logo.png', location.href).href` — atenção: o recibo abre em `about:blank`, então **URL relativa não funciona**). Resultado: HTML cai para ~87 KB e o app abre mais rápido. Exige subir as 3 imagens no repo uma vez.
2. Corrigir (ou não) os erros de digitação do modelo do recibo ("PRESTAÇAO", "conta bancaria a baixo").
3. Decidir se o atendimento continua vendo valor no recibo (hoje vê; `recibo_dados` está concedida).
4. Backup automático: só no Supabase Pro (US$ 25/mês). Hoje o backup é manual pelo botão. Considerar rotina de backup agendada.
5. Avaliar remover a função legada `admin_definir_senha` (não é mais usada pela tela).
6. Permitir troca de e-mail de usuário (hoje exige excluir + recriar).

---

## 9. Receitas úteis (Supabase)

**Testar migração sem gravar nada** — envolver em transação e dar `rollback` no fim:
```sql
drop table if exists _res;
create temp table _res(cenario text, resultado text);
do $$
begin
  -- simular usuário logado:
  perform set_config('request.jwt.claims',
    json_build_object('sub','<uuid-do-usuario>','role','authenticated')::text, true);
  begin
    -- ação a testar
    insert into _res values ('cenario X','OK');
  exception when others then
    insert into _res values ('cenario X','RECUSADO');
  end;
end $$;
select * from _res;
rollback;
```

**UUIDs úteis para teste:**
- Danilo (gestao): `f8186172-3101-42ab-a681-f0e897282efa`
- Anderson (atendimento): `f3da50f3-49a0-4dd1-876e-8a7f56fd8e15`

**Conferir estado antes de aplicar:** usar `information_schema.columns`, `pg_trigger`, `pg_policy`, `pg_proc`.

---

## 10. Armadilhas já vividas (não repetir)

- **`--` em SQL é comentário** — linhas assim não executam nada.
- **Nome de arquivo com `(1)`** (ex.: `index (1).html`) → Vercel devolve 404. Tem que ser exatamente `index.html` / `atendimento.html`.
- **Chave do Supabase:** projetos novos usam `sb_publishable_...` (não existe mais `anon`). Erro típico: "Invalid API key".
- **URL do Supabase:** é `https://xxx.supabase.co` — **não** a do painel (`supabase.com/dashboard/project/...`). Erro típico: "Invalid path specified in request URL (404)". Há um `_normUrl()` no código que conserta os casos comuns.
- **Publicar direto pela Vercel desincroniza o GitHub** — o próximo commit reverteria tudo. **O GitHub é a fonte da verdade.**
- **`auth.uid()` retorna null** em contexto service_role/postgres (sem JWT) — usado de propósito para migrações passarem pelas travas.
- **SECURITY DEFINER exige `set search_path`** explícito, senão o Supabase acusa no advisor.
- **`auth.identities.email` é coluna gerada** (`lower(identity_data->>'email')`) — **não** incluir em INSERT.
- **Criar usuário exige as duas tabelas:** `auth.users` **e** `auth.identities` (com `email_confirmed_at = now()`), senão o login do GoTrue não funciona.
- **Conector Supabase (MCP):** SQL com vários comandos só devolve o **último** resultado; `raise notice` dentro de `DO` **não aparece** — gravar numa temp table e dar `select`.
- **Contagem de bytes × caracteres:** o arquivo tem acentos (UTF-8), então `len()` em Python (caracteres) é menor que `wc -c` (bytes). Não é sinal de divergência.

---

## 11. Como trabalhar

**Fluxo com Claude Code (atual):** o Claude Code tem a pasta e o Git. Editar `index.html` → `python3 transform.py` → `node --check` → commit → a Vercel republica em ~30s.

**Fluxo manual (fallback, sem Claude Code):** baixar os dois HTML → GitHub → *Add file → Upload files* → *Commit*.
Mudanças de **banco** entram na hora (via Supabase); só o **frontend** exige o commit.

**Economia de contexto (o limite já estourou antes):**
- **Um chat por assunto.** Ao terminar, pedir o resumo atualizado deste documento.
- Trabalhar só no `index.html` (o gêmeo é derivado).
- **Prints só para erro visual**; para erro de sistema, o texto basta.
- **Juntar todos os pedidos numa mensagem só.**
