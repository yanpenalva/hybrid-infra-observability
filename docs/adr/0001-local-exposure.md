# 0001 — Exposição local

## Contexto
Compose hospeda os nós geridos; Kubernetes hospeda a observabilidade. A topologia
suportada é Linux, Docker Engine local e perfil Minikube dedicado
`hybrid-infra-observability`, driver Docker. UIs não precisam de acesso pela LAN.

## Decisão
Usar Services ClusterIP, substituindo NodePort, e port-forward com
`--address 127.0.0.1`. Exporters e app precisam de uma interface de bridge
explicitamente verificada e filtro de origem permitindo somente o Minikube.
O nome de gateway do laboratório não constitui uma fronteira de segurança.
`scripts/drill.sh` cria e encerra seus próprios forwards locais.

## Limites
Não há acesso público, TLS, autenticação própria, multi-driver ou HA.
Bind em localhost dos exporters impediria o scrape pelos Pods; bind em todas
as interfaces sem firewall não é uma alternativa aprovada. DNS não prova rota.

## Verificação
`scripts/smoke.sh` exige contexto dedicado, Services ClusterIP e targets UP;
`scripts/drill.sh` valida também o driver e `/health` da F1 no nó app.
Teste positivo a partir de Pod e negativo a partir de origem proibida são gates
de runtime, não comprovados pela análise dos manifests. Sem esses testes,
exposição restrita continua pendente e publicação bloqueada.
