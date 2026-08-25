# Herdr + Hermes + HerdrM — Guia Operacional da Equipe

Este é o procedimento recomendado para transformar o Herdr em um harness persistente de agentes de código, controlado pelo Hermes e visualizado pelo HerdrM no macOS.

## Decisão de arquitetura

**O Herdr principal fica na VPS. O HerdrM fica no Mac de cada pessoa.**

| Componente | Onde fica | Função |
|---|---|---|
| Herdr server principal | VPS/workbox Linux | Mantém PTYs, workspaces, panes e agentes vivos |
| Codex, Claude Code, Hermes CLI, OpenCode | VPS/workbox | Executam o trabalho de código |
| Hermes orchestrador | VPS, preferencialmente na conta `hermes-bot` | Cria worktrees, inicia agentes e acompanha estados |
| HerdrM | Mac de cada integrante | Console visual para todas as máquinas SSH |
| Herdr local | Mac, opcional | Experimentos rápidos que podem parar quando o Mac dormir |
| GitHub | Remoto compartilhado | Integração por branches, pull requests e revisão |

Tecnicamente o Herdr funciona tanto no Mac quanto na VPS. Operacionalmente, a VPS é o local correto para o runtime principal porque continua ligada quando o notebook fecha, oferece um ambiente homogêneo, centraliza as ferramentas e permite recuperação após perda de rede.

## Limitação atual importante do HerdrM

O HerdrM encaminha, via SSH, o socket remoto padrão:

```text
~/.config/herdr/herdr.sock
```

Esse é o socket da sessão Herdr **`default`**. Por isso, a configuração oficial deste harness usa:

```text
session = default
```

A separação entre projetos e tarefas acontece por **workspaces** e **Git worktrees** dentro da sessão padrão. Sessões Herdr nomeadas continuam disponíveis para isolamento especial e operação manual, mas ainda não aparecem como dispositivos remotos separados no HerdrM atual.

## Topologia obrigatória para a equipe

Use:

- uma conta Unix por integrante;
- uma chave SSH individual por integrante;
- uma conta Unix exclusiva `hermes-bot` para o orquestrador;
- um clone Git por conta Unix;
- uma sessão Herdr `default` por conta;
- um worktree por tarefa/agente;
- integração somente por push e pull request.

Exemplo:

```text
/srv/hermes/users/alice/projects/hermes-agent
/srv/hermes/users/alice/worktrees/hermes-agent
/srv/hermes/users/bob/projects/hermes-agent
/srv/hermes/users/bob/worktrees/hermes-agent
/srv/hermes/users/hermes-bot/projects/hermes-agent
/srv/hermes/users/hermes-bot/worktrees/hermes-agent
```

Não compartilhe o mesmo diretório `.git` entre contas Unix. Worktrees gravam locks e metadados administrativos no clone de origem; compartilhar esse clone causa conflito de permissões e corrupção operacional.

## 1. Preparar a VPS

A VPS precisa de:

- Linux com systemd;
- OpenSSH server;
- Git e Python 3;
- acesso ao repositório para cada conta;
- Codex, Claude Code, Hermes e/ou OpenCode instalados na conta que os executará;
- autenticação de cada CLI já concluída nessa conta.

No `sshd_config`, confirme ao menos:

```text
PubkeyAuthentication yes
PasswordAuthentication no
AllowStreamLocalForwarding yes
```

`AllowStreamLocalForwarding` é necessário para o HerdrM encaminhar o socket Unix remoto. Depois de alterar o SSH server, valide a configuração antes de recarregar o serviço.

O firewall deve expor SSH somente à rede privada, VPN ou endereços autorizados. Tailscale é uma boa opção para evitar SSH público.

## 2. Instalar o runtime principal na conta `hermes-bot`

Entre na VPS como `hermes-bot`, faça checkout desta branch e execute:

```bash
./scripts/bootstrap_herdr_harness.sh \
  --mode server \
  --profile hermes-bot \
  --session default \
  --repo-dir /srv/hermes/users/hermes-bot/projects/hermes-agent \
  --repo-url git@github.com:ORG/hermes-agent.git \
  --worktrees-root /srv/hermes/users/hermes-bot/worktrees/hermes-agent \
  --base-ref main
```

O bootstrap:

1. instala Herdr quando necessário;
2. instala o plugin nativo `herdr_harness` no Hermes;
3. instala o controlador `~/.local/bin/herdr-hermesctl`;
4. cria o perfil `~/.config/herdr-harness/hermes-bot.ini` com modo `0600`;
5. clona ou valida o repositório dessa conta;
6. instala `herdr-hermes-bot.service` como serviço `systemd --user`;
7. inicia o servidor Herdr headless;
8. tenta habilitar `loginctl enable-linger` para sobreviver a logout e reboot;
9. cria o workspace raiz e executa o doctor.

Valide:

```bash
systemctl --user status herdr-hermes-bot.service
herdr --session default status --json
herdr-hermesctl --profile hermes-bot doctor
herdr-hermesctl --profile hermes-bot agent-list
```

Quando o bootstrap informar `enabled-existing-server`, já existia um servidor Herdr iniciado fora do systemd. Preserve os agentes ativos, finalize esse servidor em uma janela controlada e depois execute:

```bash
systemctl --user start herdr-hermes-bot.service
```

## 3. Preparar cada conta de desenvolvedor na VPS

Entre como o próprio desenvolvedor. Exemplo para Alice:

```bash
./scripts/bootstrap_herdr_harness.sh \
  --mode server \
  --profile hermes-alice \
  --session default \
  --repo-dir /srv/hermes/users/alice/projects/hermes-agent \
  --repo-url git@github.com:ORG/hermes-agent.git \
  --worktrees-root /srv/hermes/users/alice/worktrees/hermes-agent \
  --base-ref main
```

Repita com caminhos, usuário e perfil próprios para cada integrante. Nunca execute todos os agentes normais dentro da conta `hermes-bot`.

## 4. Configurar o OpenSSH no Mac

Cada integrante configura um alias em `~/.ssh/config`:

```sshconfig
Host hermes-workbox
  HostName SEU_HOST_OU_IP_PRIVADO
  User alice
  IdentityFile ~/.ssh/id_ed25519_hermes_alice
  IdentitiesOnly yes
  PreferredAuthentications publickey
  PasswordAuthentication no
  ServerAliveInterval 15
  ServerAliveCountMax 3
  ControlMaster auto
  ControlPersist 10m
  ControlPath ~/.ssh/cm-%C
```

Permissões:

```bash
chmod 700 ~/.ssh
chmod 600 ~/.ssh/config ~/.ssh/id_ed25519_hermes_alice
chmod 644 ~/.ssh/id_ed25519_hermes_alice.pub
```

Teste primeiro o OpenSSH puro:

```bash
ssh hermes-workbox 'id; command -v herdr; herdr --version'
```

Chaves com passphrase devem estar no `ssh-agent`/Keychain:

```bash
ssh-add --apple-use-keychain ~/.ssh/id_ed25519_hermes_alice
```

## 5. Configurar o harness e o HerdrM no Mac

Com o HerdrM já instalado, rode no checkout desta branch:

```bash
./scripts/bootstrap_herdr_harness.sh \
  --mode client \
  --profile hermes-alice \
  --target hermes-workbox \
  --session default \
  --repo-dir /srv/hermes/users/alice/projects/hermes-agent \
  --worktrees-root /srv/hermes/users/alice/worktrees/hermes-agent \
  --base-ref main \
  --configure-herdrm \
  --herdrm-device-name "Hermes Workbox — Alice"
```

O processo usa apenas o alias OpenSSH. A chave privada, porta, ProxyJump e autenticação continuam em `~/.ssh/config`, `ssh-agent` e Keychain; nada disso é gravado no perfil do harness ou no repositório.

Feche completamente e abra novamente o HerdrM para ele recarregar:

```text
~/Library/Application Support/HerdrM/devices.json
```

O configurador cria backup antes de cada alteração e mantém o arquivo em modo `0600`.

## 6. Adicionar todas as VPS SSH ao HerdrM

Para importar todos os aliases concretos de `~/.ssh/config` que já têm Herdr rodando na sessão padrão:

```bash
python3 scripts/configure_herdrm.py sync-ssh-config --probe
```

Para limitar aos aliases do ambiente de desenvolvimento:

```bash
python3 scripts/configure_herdrm.py sync-ssh-config \
  --probe \
  --include '^(hermes-|dev-|vps-|workbox)'
```

Para adicionar um host individual:

```bash
python3 scripts/configure_herdrm.py add \
  --name "Papiro Workbox" \
  --target papiro-workbox \
  --probe
```

Ver inventário e testar todos:

```bash
python3 scripts/configure_herdrm.py list
python3 scripts/configure_herdrm.py doctor
```

O comando `--probe` somente adiciona aliases que:

- respondem com OpenSSH em modo não interativo;
- possuem o executável `herdr`;
- possuem o socket padrão ativo;
- respondem a `herdr status --json`.

Aliases com wildcard, como `Host *` ou `Host *.internal`, não são importados.

## 7. Usar o HerdrM no dia a dia

No HerdrM:

1. selecione o dispositivo remoto no canto inferior;
2. crie um **Space** para um projeto, ou abra um já existente;
3. use **⌘N** para iniciar um agente suportado;
4. use **⌘K** para localizar qualquer agente dessa máquina;
5. acompanhe estados `blocked`, `done`, `working` e `idle` na barra lateral;
6. clique no agente para entrar no PTY real;
7. quando houver `blocked`, leia a pergunta/approval antes de enviar qualquer tecla;
8. cole arquivos ou imagens diretamente no terminal quando necessário.

Fechar o HerdrM, perder Wi-Fi ou fechar o Mac não encerra os agentes remotos. O processo continua sob o Herdr server da VPS.

## 8. Fluxo recomendado por tarefa

### Criar worktree isolado

```bash
herdr-hermesctl --profile hermes-alice --json task-create issue-142-auth-timeout \
  --branch agent/issue-142-auth-timeout \
  --base main \
  --label issue-142
```

Guarde `workspace_id` e `pane_id` retornados.

### Iniciar Codex

```bash
herdr-hermesctl --profile hermes-alice --json agent-start \
  issue-142 codex '<pane-id>'
```

### Enviar a tarefa e aguardar

```bash
herdr-hermesctl --profile hermes-alice --json agent-prompt \
  issue-142 \
  'Corrija a issue #142, crie teste de regressão, rode os testes focados e resuma riscos.' \
  --wait-timeout-ms 180000
```

### Ler estado e saída

```bash
herdr-hermesctl --profile hermes-alice --json agent-get issue-142
herdr-hermesctl --profile hermes-alice --json agent-read issue-142 --lines 300
herdr-hermesctl --profile hermes-alice --json agent-wait \
  issue-142 --until idle --until done --until blocked --wait-timeout-ms 180000
```

### Validar no mesmo worktree

```bash
herdr-hermesctl --profile hermes-alice pane-run '<pane-id>' \
  'git status --short && pytest -q tests/caminho/teste.py'
herdr-hermesctl --profile hermes-alice pane-read '<pane-id>' --lines 300
```

Depois, o agente faz push da branch e abre pull request. Não trabalhe diretamente na branch principal.

## 9. Usar o Hermes como orquestrador

Na conta/processo do Hermes:

```bash
export HERDR_HARNESS_PROFILE=hermes-bot
export HERDR_HARNESS_AUTO_ENABLE=1
```

Reinicie o Hermes e valide com a tool nativa:

```text
herdr_harness(action="doctor", profile="hermes-bot")
```

O Hermes pode criar tarefa, iniciar agente, enviar prompt, aguardar estado e ler a saída. `pane_run` passa pelo mesmo guard de comandos perigosos/Tirith do terminal Hermes. Remoção forçada de worktree não é exposta ao modelo.

## 10. Regras de concorrência

1. Um agente ativo por worktree.
2. Uma branch única por tarefa.
3. Tarefas paralelas não devem editar os mesmos arquivos; quando inevitável, serialize.
4. O clone raiz serve para atualizar a base, não para o agente editar diretamente.
5. Só remova worktree depois de push e integração ou abandono explícito.
6. Integração entre usuários ocorre pelo Git remoto, nunca pelo mesmo `.git` local.
7. Um agente bloqueado deve ser lido antes de receber `esc`, `enter`, `ctrl+c` ou aprovação.

## 11. Acesso compartilhado

O padrão seguro é cada integrante acessar somente a própria conta e sessão. Não distribua a chave privada do `hermes-bot`.

O HerdrM oferece terminal interativo, não um modo remoto estritamente read-only. Portanto, não use a conta `hermes-bot` como console compartilhado da equipe. Para pairing ou incidente, crie uma conta deliberadamente compartilhada, com escopo temporário, auditoria e rotação de chave após o uso.

## 12. Recuperação

Depois de queda de rede ou reinício do Mac:

```bash
herdr-hermesctl --profile hermes-alice status
herdr-hermesctl --profile hermes-alice agent-list
herdr-hermesctl --profile hermes-alice worktree-list
```

Na VPS:

```bash
systemctl --user status herdr-hermes-alice.service
journalctl --user -u herdr-hermes-alice.service -n 200 --no-pager
```

Se a VPS reiniciou, o serviço headless restaura o shape salvo da sessão. Processos que estavam executando no momento do reboot não sobrevivem ao reboot físico; reabra o workspace e retome a sessão nativa do Codex/Claude quando disponível.

Para agente bloqueado:

```bash
herdr-hermesctl --profile hermes-alice agent-read issue-142 --lines 300
herdr-hermesctl --profile hermes-alice agent-keys issue-142 esc
```

## 13. Checklist de aceite

O ambiente está pronto quando:

- cada integrante usa identidade SSH individual;
- `ssh <alias> true` funciona sem prompt interativo;
- `AllowStreamLocalForwarding yes` está ativo;
- cada conta possui clone e worktree root próprios;
- a sessão principal é `default`;
- `systemctl --user status herdr-<perfil>.service` está ativo na VPS;
- o linger está habilitado ou existe supervisor equivalente;
- `herdr-hermesctl --profile <perfil> doctor` passa;
- `configure_herdrm.py doctor` passa no Mac;
- o HerdrM mostra o dispositivo e os agentes;
- desconectar o Mac não encerra um agente remoto;
- duas tarefas simultâneas usam branches e worktrees diferentes;
- o Hermes consegue criar, iniciar, aguardar e ler agentes;
- comandos perigosos entram no fluxo de aprovação;
- nenhuma chave ou token está em arquivo versionado;
- branches protegidas e revisão de pull request estão habilitadas;
- existe backup da VPS ou push frequente das branches valiosas.
