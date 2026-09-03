# Auditoria de produção — 2026-09-02 (recorte de infraestrutura)

Recorte dos achados que vivem **neste** repositório. O documento completo — incluindo os
achados do pipeline de ingestão e o que falta para o dbt — está em
`camara-senado-data-ingestion/AUDITORIA_PRODUCAO_2026-09-02.md`.

Levantamento feito contra a conta `904464083417` (us-east-1), os dois repositórios e os
últimos 10 merges em `develop`/`main` de ambos.

---

## O que já estava certo

`main` == `develop`, último merge 2026-08-20 (PRs #25/#26/#27), CI "Terraform Prod" verde e
aplicando de verdade. Existem em produção e conferem com o código: os 4 buckets de dados,
os 16 Glue databases, os repositórios ECR com lifecycle de 2 imagens, o cluster
`dataplatform-ecs-cluster-prod`, a task definition `dataplatform-ingestion-task-prod:2`
apontando para `camara-ingestion:prod`, os roles de dados e o role OIDC do GitHub Actions.

O IAM está **mais completo do que a documentação sugere**: `dataplatform_airflow_ec2` já
tem `iam:PassRole` para os quatro roles (dev *e* prod), embora
`camara-senado-data-ingestion/docs/PROD_AIRFLOW_EC2_RUNBOOK.md` listasse só o par de dev.
Isso foi corrigido no runbook.

Bucket `dataplatform-camara-prod-db` com SSE-AES256 e Public Access Block completo.

---

## Aplicado na Sprint 0 (2026-09-03) — concluído e verificado

Mergeado em `main` via PRs #28 e #29 (`6e8fd47`), aplicado pelo job "Terraform Prod" com
**`Plan: 4 to add, 1 to change, 0 to destroy`** — nenhum bucket, role, cluster ou task
definition foi tocado. Estado conferido na AWS depois do apply:

| recurso | verificação |
|---|---|
| `dataplatform-alerts-prod` | criado |
| assinatura de e-mail | **confirmada** — `SubscriptionArn` = `...:6de0ee52-...` |
| versionamento | `Enabled` em `dataplatform-camara-prod-db` e `dataplatform-senado-prod-db` |
| retenção do log group | `30` |
| `sns:Publish` no role | presente na policy inline `dataplatform-airflow-ec2-ecs` |

O e-mail de confirmação da AWS caiu no spam. Vale marcar `no-reply@sns.amazonaws.com` como
remetente confiável — um alerta que vai para o spam equivale a não ter alerta.

Tudo em `environments/prod/`:

- **`aws_s3_bucket_versioning` nos buckets de dados.** Resposta a um incidente concreto: na
  run `scheduled__2026-08-23`, uma segunda tentativa da mesma task gravou `[]` por cima do
  resultado bom da primeira, na mesma chave — `raw/votacoes/votacoes` foi de 42.050
  registros (40 MB) para 2 bytes, com as 56 tasks reportando `success`. Sem versionamento o
  dado era irrecuperável. Isto é a rede de segurança; a **causa** está em
  `task_io.py::_write_s3` no repo de ingestão e continua pendente (Sprint 1).
- **`aws_sns_topic` + `aws_sns_topic_subscription`** (`dataplatform-alerts-prod`). Antes
  disso a conta tinha **zero alarmes CloudWatch e zero tópicos SNS** — uma falha em
  produção era totalmente silenciosa. Consumido pelo `on_failure_callback` da DAG.
  A assinatura por e-mail exige **uma confirmação clicada no e-mail**; até lá o Terraform a
  mantém em `pending confirmation` e nada é entregue.
- **`variable "alert_email"`** em `variables.tf`.
- **Retenção do log group ECS de 7 → 30 dias.** 7 dias é mais curto que o intervalo entre
  duas execuções semanais: quando a run seguinte começava, o log da anterior já tinha
  expirado e o post-mortem era impossível.

Fora do Terraform, aplicado diretamente porque o role é provisionado à mão pelo runbook:
`sns:Publish` na policy inline `dataplatform-airflow-ec2-ecs` do role
`dataplatform_airflow_ec2` (6 → 7 statements).

Essa statement é exatamente o tipo de coisa que o item "host do Airflow para IaC" abaixo
existe para eliminar: ela vive fora do `terraform apply`, ninguém a vê num plan, e o próximo
`put-role-policy` feito à mão pode sobrescrevê-la sem aviso.

---

## Backlog deste repositório

### Alta — o host do Airflow é um single point of failure fora do IaC

O `modules/` deste repositório está **vazio**. A instância `i-0e11709bd1c1dae07`
(`t3.micro`, 913 MB), seu security group, role, instance profile, swapfile, arquivo `.env`
e os dois crons existem **apenas** como checklist manual em
`camara-senado-data-ingestion/docs/PROD_AIRFLOW_EC2_RUNBOOK.md`. Se a instância morrer, a
recuperação é um runbook de 8 passos executado à mão, e o metadata DB do Airflow (estado
de pause das DAGs e todo o histórico) vive num volume Docker no EBS **sem snapshot**.

- [ ] `modules/airflow_host/` — EC2, SG, IAM role, instance profile e user-data em
      Terraform.
- [ ] Snapshot DLM do volume EBS da instância.
- [ ] Alarme de auto-recovery do EC2 (`StatusCheckFailed_System`).
- [ ] CloudWatch agent na instância: **hoje não existe métrica de memória nem de disco**
      para esse host — exatamente as duas que o derrubaram (5 OOM-kills entre 30 e 31/08,
      host inacessível por 4 dias). A margem medida na run bem-sucedida foi de **31 MB de
      RAM livre no pico** e 807 MB de swap.

### Média — habilitar o consumo pelo dbt

Os 16 Glue databases existem mas têm **0 tabelas**, e não há nenhum crawler
(`list-crawlers` retorna vazio). O workgroup Athena `primary` está com
`ResultConfiguration` vazio — sem `s3_staging_dir`, o `profiles.yml` do dbt não tem para
onde escrever.

- [ ] Tabelas externas no Glue para o schema `..._raw`, via DDL versionada (preferível a
      crawler: o schema é conhecido e estável). **Depende** de o writer emitir NDJSON e
      particionar por `ingestion_date` — ver D-1 e D-3 no documento do repo de ingestão.
- [ ] Workgroup Athena dedicado com `ResultConfiguration` apontando para um bucket de
      resultados próprio, `EnforceWorkGroupConfiguration = true` e limite de bytes
      escaneados por query.
- [ ] Lifecycle no bucket de resultados do Athena (expirar em poucos dias).

### Média — custo e isolamento

- [ ] **Lifecycle policy no bucket prod.** Hoje não existe nenhuma
      (`NoSuchLifecycleConfiguration`); ~600 MB brutos por semana acumulam em Standard
      indefinidamente. Com o versionamento **agora ligado** (Sprint 0), isso passou a incluir
      versões não-atuais, então a regra de expiração de versões antigas deixou de ser
      hipótese e virou custo real acumulando por semana.
- [ ] **Lifecycle no repositório ECR `camara-ingestion`.** A regra de "manter só as 2
      imagens mais recentes" é aplicada por `aws_ecr_lifecycle_policy.lifecycle` apenas aos
      repositórios de `local.ecr_repositories` (`dataplatform-docker-images-repository-*`).
      O `camara-ingestion`, que é o que a task definition de produção realmente usa, foi
      criado fora do IaC e **não tem lifecycle nenhum** — por isso acumula imagens sem tag a
      cada build. Vale trazê-lo para o Terraform junto com a regra.
- [ ] **Isolamento de rede dev/prod.** `NETWORK_CONFIGURATION` na DAG
      (`camara-senado-data-ingestion/airflow/dags/camera_ingestion_dag.py`) tem 6 subnets e
      1 security group **hardcoded**, compartilhados entre dev e prod, com
      `assignPublicIp: ENABLED`. VPC/subnets/SG próprios por ambiente, expostos como
      output do Terraform em vez de literais na DAG.

### Baixa — higiene

- [ ] Variáveis mortas de EMR em `environments/{dev,prod}/variables.tf`
      (`emr_release_label`, `cluster_master_instance_type`, `cluster_core_instance_type`,
      `cluster_instance_count`, `cluster_auto_termination_minutes`): nenhum recurso EMR é
      criado por este código.
- [ ] Variável `localstack_endpoint` também órfã, resquício da fase de LocalStack.
- [ ] **Paridade dev/prod**: versionamento, tópico SNS e retenção de 30 dias foram
      aplicados só em `environments/prod/`. Avaliar se `dev` deve acompanhar — retenção
      de log provavelmente sim, alerta por e-mail provavelmente não.
- [ ] `environments/{dev,prod}/*.tf` não passam em `terraform fmt -check` (indentação de
      4 espaços em vez de 2). É consistente em todo o repo, então é uma decisão de estilo a
      tomar de uma vez — ou reformatar tudo e adicionar `fmt -check` ao CI, ou deixar como
      está deliberadamente.
