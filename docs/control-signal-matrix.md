# Controle → sinal → regra → drill → evidência

Estado: implementação estática; **nenhuma evidência de runtime certificada**.
IDs abaixo são os literais produzidos por `ansible/control-node/ssh_metrics/audit.py`.
`pass`, `fail`, `error`, `exception` são estados distintos. Ausência nunca é PASS.

| ID estável | Controle/verificação | Sinal | Regra | Drill/recuperação | Evidência privada |
| --- | --- | --- | --- | --- | --- |
| ssh_syntax | sshd -t | lab_hardening_control_pass | HardeningDrift | ssh; reaplicar baseline autorizado | audit.json |
| ssh_effective | sshd -T -C para ansible/root: StrictModes, senha/root/interativo, X11 e MaxAuthtries | lab_hardening_control_pass; lab_ssh_auth_failures_total | HardeningDrift; SSHRejectedAttempts | ssh; política permanece ativa | audit.json; timeline.json |
| ssh_dropin | 00-hio.conf root:root 0644 e conteúdo esperado | lab_hardening_control_pass | HardeningDrift | ssh; reaplicar baseline | audit.json |
| ssh_key_modes | .ssh 0700 e authorized_keys 0600, dono ansible | lab_hardening_control_pass | HardeningDrift | ssh; corrigir metadados autorizadamente | audit.json |
| secops | **removido do contrato no passe de fix (item 3)**: a conta privilegiada é derivada do Vault, não um literal `secops` | — | — | — | — |
| shadow_mode | /etc/shadow root:shadow 0640; sem ler conteúdo | lab_hardening_control_pass | HardeningDrift | auditoria pré/pós drills | audit.json |
| vault_directory | diretório root:root 0700, sem symlink | lab_hardening_control_pass | HardeningDrift | auditoria pré/pós drills | audit.json |
| credentials_mode | arquivo root:root 0600, sem ler conteúdo/symlink | lab_hardening_control_pass | HardeningDrift | auditoria pré/pós drills | audit.json |
| banner | **removido do contrato no passe de fix (item 3)**: o baseline não aplica Banner/issue.net | — | — | — | — |
| logrotate | configuração existente e logrotate --debug válido | lab_hardening_control_pass | HardeningDrift | rotação real ainda pendente | audit.json |
| app_identity | processo app.py não-root e NoNewPrivs=1 em app | lab_hardening_control_pass | HardeningDrift | /health antes/depois de cada drill | audit.json; timeline.json |
| sudo_exception | concessão literal NOPASSWD:ALL da automação | lab_hardening_exception | nenhuma aprovação de compliance | não remover privilégio implicitamente | audit.json, estado exception |
| AUDIT-FRESH | idade/ausência da coleta | lab_hardening_audit_timestamp_seconds | HardeningAuditStale | reiniciar coletor e repetir auditoria | audit.json |
| SSH-PIPELINE | parser e timer supervisionado | lab_ssh_collector_timestamp_seconds; lab_ssh_collector_error; lab_ssh_collector_unmatched_total | SSHMetricsStale | ssh; restaurar timer/log | timeline.json |
| NODE-UP | disponibilidade dos dois exporters | up | InstanceDown | instance-down; supervisorctl start node_exporter | timeline.json |
| CPU-BOUNDED | um worker, 120s, cgroup ≤0,5 CPU e ≤128 PIDs | node_cpu_seconds_total | descoberta do nome literal pela API /rules, única regra usando essa métrica | cpu; encerrar apenas grupo do processo próprio | timeline.json |

## Fontes e contratos de execução

- Auditoria read-only: `ansible/control-node/playbooks/audit_hardening.yml` usa
  raw/changed_when:false, sem staging de módulo no alvo, handlers ou correções.
  Só escreve no controlador, por padrão `.local/evidence/<run>/audit.json`.
  O mount do controlador Compose é read-only: fornecer
  `-e audit_evidence_root=/tmp/hio-evidence -e audit_run=<run>` e copiar o JSON
  sanitizado para `.local/evidence/<run>/audit.json`; o drill faz essa projeção
  como `audit-baseline.json` e `audit-recovered.json`. Falha é registrada antes
  do assert; alvos inacessíveis podem impedir relatório completo e dão erro.
- Deployment: `ansible/control-node/playbooks/deploy_ssh_metrics.yml` instala
  `ansible/control-node/ssh_metrics/collector.py` e o probe read-only.
  Timer de 5s pertence ao supervisor, não systemd. O deployment é mutante;
  não é o playbook de auditoria. Publica textfile atomicamente em diretório
  root-owned, legível pelo exporter; estado/log ficam privados. É invocado por
  `make up` logo após `security_hardening`; `scripts/smoke.sh` e
  `scripts/drill.sh` fazem preflight de `supervisorctl status ssh_metrics` e
  falham cedo, com mensagem explícita, se o timer não estiver RUNNING.
- Regras F2/F3: `k8s/monitoring/alert-rules-ssh.yml`; disponibilidade:
  `k8s/monitoring/alert-rules.yml`. O builder da monitoração deve montar/carregar
  o primeiro nome literal. Criar o arquivo não prova que Prometheus o carrega.
  Testes promtool: `prometheus-rules.test.yml` (canônicas),
  `alert-rules-ssh.test.yml` (limiar SSH cruzado/não cruzado, drift ==0,
  staleness por timestamp velho e por série ausente) e
  `demo-slo-overlay.test.yml`; `scripts/check.sh` roda `check rules`/`test rules`
  dos três arquivos.
- Prova F4: `k8s/monitoring/demo-slo-overlay.yml` é um overlay local de janelas
  curtas (1m) do burn-rate, com guarda de 0.1 req/s, validado por promtool mas
  fora do ConfigMap canônico. `scripts/smoke.sh` injeta 503 via `POST /chaos`
  em loopback dentro de app, confere o contador 5xx e o burn curto em firing, e
  remove o overlay em `finally`/trap (re-aplica `k8s/monitoring` e reinicia o
  Prometheus), de modo que o estado canônico volta mesmo em falha.
- Drills: `scripts/drill.sh instance-down|cpu|ssh`. API F1 `/health` em
  `127.0.0.1:8080` dentro de app; APIs Prometheus/Alertmanager via forwards
  próprios em loopback. Sem silences, scans externos, password guessing ou
  dependência de dedup. SSH oferece exatamente seis chaves rejeitadas e exige
  delta seis, agregando somente motivos enumerados, nunca IP/usuário/chave.
- `collector.py --self-test` cobre mensagens duplicadas da mesma tentativa,
  linhas parciais, restart, rename/rotação e truncamento. Unidade: um registro
  OpenSSH `Failed <method>`, não `Invalid user` ou fechamento preauth.
  Reinício preserva contadores; recriação pode resetá-los; consultas usam increase.
  Retenção limitada pode perder eventos se coletor ficar parado além de duas
  rotações; truncamento com recrescimento acima do cursor entre polls é limite
  conhecido. Não usar copytruncate; rotação por rename reabre logs do supervisor.

## Escopo do probe após o passe de fix (item 3)

Decisão registrada (caminho menor, sem tocar o baseline): o probe read-only foi
reescopado aos controles que o baseline disposable de fato implementa.

- `secops` saiu do contrato. A conta privilegiada do baseline é `lab_admin`,
  derivada do Vault (`vault_security_admin_user`), criada por
  `security_hardening.yml`; um probe read-only sem acesso ao Vault não pode
  resolver esse nome, e criar um literal `secops` só para satisfazer a auditoria
  seria conformidade fabricada.
- `banner` saiu do contrato. Nem `ansible/managed-node/entrypoint.sh` nem
  `security_hardening.yml` aplicam `Banner`/`/etc/issue.net`.
- `ssh_effective` verifica apenas `ansible` e `root`.
- Reabrir qualquer um dos dois exige mudar o baseline (drop-in de Banner e
  conta dedicada) e esta matriz; o `--self-test` do probe falha se o conjunto de
  IDs mudar sem atualização aqui.
- O único estado `exception` aceito é `sudo_exception`. `scripts/drill.sh`
  exige `pass` nos demais controles na auditoria de baseline e na de recuperação.

## Gates ainda não comprovados / fronteiras da partição

O probe cobre somente os controles listados acima e nunca fabrica conformidade:
ausência de série é ausência, não PASS. Alterações no baseline, app, compose,
smoke, CI e wiring Kubernetes pertencem a outros builders.
CPU não é automaticamente métrica do cgroup: sem cruzamento real seguro da
regra o drill falha; não aumenta workers nem reduz limiar canônico. A regra CPU
de F4 deve existir antes do drill; seu nome não é inventado nesta matriz.
O overlay de SLO curto e o passo de injeção 503 em `scripts/smoke.sh` estão
implementados e validados por promtool, mas seguem sem execução certificada:
nenhuma medição de runtime foi fabricada.

Known_hosts/host checking são configurados em
`ansible/control-node/ansible.cfg`; o drill SSH usa verificação estrita e exige
rejeição publickey (host key divergente não conta). Teste negativo de host key,
sentinelas de segredo, rotação real, ausência de séries, interrupção dos drills,
política de rede positiva/negativa, retenção e recursos efetivos precisam de
execução integrada. Não são substituídos por checks de existência de arquivos.
`scripts/check.sh` valida YAML, Bash, higiene, os testes de unidade de
`ansible/app`, os dois `--self-test` (`collector.py`, `audit.py`) e os três
arquivos de teste promtool (regras canônicas, SSH e overlay de demo).

Decisões: `docs/adr/0001-local-exposure.md`,
`docs/adr/0002-single-node-storage.md`, `docs/adr/0003-alert-routing.md`.
Verificações existentes adicionais: `scripts/smoke.sh` (recursos/retencão/rota),
`scripts/check.sh` (segredos sintéticos e estática). Logrotate configurado não
é prova de rotação executada; receiver blackhole não é entrega externa.
