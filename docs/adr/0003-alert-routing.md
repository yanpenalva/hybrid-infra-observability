# 0003 — Alertmanager stateless e recebimento sem entrega

## Contexto
O objetivo é demonstrar sinal, alerta e recuperação, não integrar serviços
externos. Persistir estado de notificação acrescentaria operação fora do escopo.

## Decisão
Alertmanager roda **stateless, sem PVC**, com receiver `blackhole` em
`k8s/monitoring/alertmanager.yml`. A API comprova recebimento e roteamento,
não entrega de notificação externa. Drills não criam silences e não dependem
de dedup entre execuções: cada execução observa baseline, injeção, sinal,
pending, firing, recebimento, recuperação e resolução novamente.

## Limites
Silences e nflog são perdidos em cada restart; deduplicação reinicia e pode
haver re-notificação. Isso é esperado, não perda de idempotência do drill.
Sem Slack, e-mail, PagerDuty ou garantia de entrega. Silences/inibições
preexistentes que impeçam a observação tornam o drill FAIL, nunca PASS.

## Verificação
`scripts/drill.sh` rejeita alertas ativos antigos, exige labels do nó `app`,
`activeAt`/`startsAt` novos e grupo recebido pelo receiver `blackhole`.
Exige pending e firing distintos e ausência ativa nas duas APIs após recuperar.
Timeline privada em `.local/evidence/<run>/timeline.json`, com UTC e relógio
monotônico. Deadline ou limpeza incompleta resulta em exit não zero.
Reinício do Alertmanager deve ser testado em runtime sem depender de silences
ou nflog anteriores; não foi certificado apenas pela criação deste ADR.
