# 0002 — Armazenamento single-node

## Contexto
O laboratório precisa conservar dados do Prometheus entre reinícios de Pod,
sem introduzir um provisionador distribuído ou prometer recuperação de desastre.

## Decisão
Manter hostPath com DirectoryOrCreate e PV Retain em
`k8s/monitoring/02-prometheus.yaml`. Retenção TSDB: 24h e 512MB.
O claim de 2Gi não é quota do filesystem. Encerrar workloads preserva dados;
descarte do ambiente exige decisão explícita do operador.

## Limites
Sem backup, replicação ou HA. Perder o nó/perfil pode perder os dados.
WAL/head e outros arquivos precisam de folga além dos blocos retidos.
Retain não é proteção contra exclusão manual nem contra disco cheio.

## Verificação
`scripts/smoke.sh` consulta flags efetivas da API e exige uso ≤256MB do
orçamento de 512MB após o smoke; confere também requests/limits efetivos.
Reinício de Pod e down/up preservador devem ser exercitados no ambiente real.
Nenhuma medição de disco foi fabricada nesta implementação.
