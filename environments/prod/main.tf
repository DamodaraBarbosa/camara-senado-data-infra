data "aws_caller_identity" "current" {}

data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

# Creation of Buckets S3
resource "aws_s3_bucket" "catalog" {
    for_each = toset(local.s3_buckets)

    force_destroy = var.environment == "prod" ? false : true
    bucket        = each.value
    tags          = var.tags
}

# Versionamento dos buckets de dados.
#
# Nao e politica generica de "boa pratica": e a resposta a um incidente real.
# Na run scheduled__2026-08-23 uma segunda tentativa da mesma task gravou `[]`
# por cima do resultado bom da primeira, na mesma chave — raw/votacoes/votacoes
# foi de 42.050 registros (40MB) para 2 bytes, e as 56 tasks reportaram
# success. Sem versionamento o dado era irrecuperavel.
#
# Isto e a rede de seguranca, nao a correcao: a causa esta em
# task_io.py::_write_s3, que escreve numa chave deterministica por run_id sem
# nenhuma protecao contra sobrescrita. Ver
# camara-senado-data-ingestion/AUDITORIA_PRODUCAO_2026-09-02.md (P0-2).
resource "aws_s3_bucket_versioning" "catalog" {
    for_each = aws_s3_bucket.catalog
    bucket   = each.value.id

    versioning_configuration {
        status = "Enabled"
    }
}

# Creation of Glue Catalog Databases
# Example: dataplatform_camara_prod_db.raw, dataplatform_camara_prod_db.staging
resource "aws_glue_catalog_database" "catalog_db" {
  for_each = {
    for pair in flatten([
      for bucket in local.s3_buckets : [
        for schema in var.schema_names : {
          key    = "${bucket}.${schema}"
          db_name = "${bucket}_${schema}"
        }
      ]
    ]) : pair.key => pair.db_name
  }

  name = lower(each.value)

  parameters = {
    PROJECT     = local.project
    ENVIRONMENT = local.environment
  }
}

# ECR repositories creation
resource "aws_ecr_repository" "repositories" {
    for_each             = toset(local.ecr_repositories)
    name                 = each.value
    image_tag_mutability = "MUTABLE"

    image_scanning_configuration {
        scan_on_push = true
    }

    tags     = merge(
        var.tags, {
            Type = "ECR Repository"
        }
    )
}

# ECR life cycle policy to keep only the 2 most recent images
resource "aws_ecr_lifecycle_policy" "lifecycle" {
    for_each   = aws_ecr_repository.repositories
    repository = each.value.name

    policy = jsonencode({
        rules = [
            {
                rulePriority = 1
                description  = "Keep only the 2 most recent images"
                selection    = {
                    tagStatus     = "any"
                    countType     = "imageCountMoreThan"
                    countNumber   = 2
                }
                action       = {
                    type = "expire"
                }
            }
        ]
    })
}
# Creation of IAM roles
# Groups/users live in global/ (shared across environments); roles and their
# policies stay per-environment since they scope access to this env's own
# buckets/repos. create_before_destroy avoids a permission gap on renames.
resource "aws_iam_role" "data_roles" {
    for_each = local.iam_roles
    name     = each.value.name

    assume_role_policy = jsonencode({
        Version = "2012-10-17"
        Statement = [{
            Effect    = "Allow"
            Principal = { Service = each.value.service }
            Action    = "sts:AssumeRole"
        }]
    })
    tags = var.tags

    lifecycle {
        create_before_destroy = true
    }
}

# S3 read-only policy
resource "aws_iam_policy" "s3_read_only" {
    name = "${local.prefix}-s3-read-only-${local.environment}"

    lifecycle {
        create_before_destroy = true
    }

    policy = jsonencode({
        Version = "2012-10-17"
        Statement = [{
            Effect = "Allow"
            Action = ["s3:GetObject", "s3:GetBucketLocation", "s3:ListBucket"]
            Resource = flatten([
                for bucket in local.s3_buckets : [
                    "arn:aws:s3:::${bucket}",
                    "arn:aws:s3:::${bucket}/*"
                ]
            ])
        }]
    })
}

# S3 + Glue read-write policy
resource "aws_iam_policy" "s3_read_write" {
    name = "${local.prefix}-s3-read-write-${local.environment}"

    lifecycle {
        create_before_destroy = true
    }

    policy = jsonencode({
        Version = "2012-10-17"
        Statement = [
            {
                Effect = "Allow"
                Action = [
                    "s3:GetObject", "s3:PutObject", "s3:DeleteObject",
                    "s3:GetBucketLocation", "s3:ListBucket"
                ]
                Resource = flatten([
                    for bucket in local.s3_buckets : [
                        "arn:aws:s3:::${bucket}",
                        "arn:aws:s3:::${bucket}/*"
                    ]
                ])
            },
            {
                Effect = "Allow"
                Action = [
                    "glue:GetDatabase", "glue:GetDatabases",
                    "glue:GetTable", "glue:GetTables",
                    "glue:CreateTable", "glue:UpdateTable", "glue:DeleteTable",
                    "glue:BatchCreatePartition", "glue:GetPartition", "glue:GetPartitions"
                ]
                Resource = [
                    "arn:aws:glue:${var.aws_region}:${data.aws_caller_identity.current.account_id}:catalog",
                    "arn:aws:glue:${var.aws_region}:${data.aws_caller_identity.current.account_id}:database/${local.prefix}*",
                    "arn:aws:glue:${var.aws_region}:${data.aws_caller_identity.current.account_id}:table/${local.prefix}*/*"
                ]
            }
        ]
    })
}

# ECR read-only policy
resource "aws_iam_policy" "ecr_read_only" {
    name = "${local.prefix}-ecr-read-only-${local.environment}"

    lifecycle {
        create_before_destroy = true
    }

    policy = jsonencode({
        Version = "2012-10-17"
        Statement = [{
            Effect = "Allow"
            Action = [
                "ecr:GetDownloadUrlForLayer",
                "ecr:BatchGetImage",
                "ecr:DescribeImages",
                "ecr:DescribeRepositories"
            ]
            Resource = [
                for repo in local.ecr_repositories :
                "arn:aws:ecr:${var.aws_region}:*:repository/${repo}"
            ]
        },
        {
            Effect = "Allow"
            Action = [
                "ecr:GetAuthorizationToken"
            ]
            Resource = ["*"]
        }]
    })
}

# ECR read-write policy
resource "aws_iam_policy" "ecr_read_write" {
    name = "${local.prefix}-ecr-read-write-${local.environment}"

    lifecycle {
        create_before_destroy = true
    }

    policy = jsonencode({
        Version = "2012-10-17"
        Statement = [{
            Effect = "Allow"
            Action = [
                "ecr:GetDownloadUrlForLayer",
                "ecr:BatchGetImage",
                "ecr:PutImage",
                "ecr:InitiateLayerUpload",
                "ecr:UploadLayerPart",
                "ecr:CompleteLayerUpload",
                "ecr:DescribeImages",
                "ecr:DescribeRepositories"
            ]
            Resource = [
                for repo in local.ecr_repositories :
                "arn:aws:ecr:${var.aws_region}:*:repository/${repo}"
            ]
        },
        {
            Effect = "Allow"
            Action = [
                "ecr:GetAuthorizationToken"
            ]
            Resource = ["*"]
        }]
    })
}

# Granting read policies to roles
resource "aws_iam_role_policy_attachment" "read_only" {
    for_each = toset(flatten([
        for ac in local.bucket_access_control : ac.read_only_roles
    ]))
    role       = each.value
    policy_arn = aws_iam_policy.s3_read_only.arn
    depends_on = [aws_iam_role.data_roles]
}

# Granting read/write policies to engineering and CI/CD roles
resource "aws_iam_role_policy_attachment" "read_write" {
    for_each = toset(flatten([
        for ac in local.bucket_access_control : ac.read_write_roles
    ]))
    role       = each.value
    policy_arn = aws_iam_policy.s3_read_write.arn
    depends_on = [aws_iam_role.data_roles]
}

# Granting ECR read-only policies to BI and monitoring roles
resource "aws_iam_role_policy_attachment" "ecr_read_only" {
    for_each = toset([
        local.iam_roles.sp_bi.name,
        local.iam_roles.sp_ci.name
    ])
    role       = each.value
    policy_arn = aws_iam_policy.ecr_read_only.arn
    depends_on = [aws_iam_role.data_roles]
}

# Granting ECR read-write policies to engineering and deployment roles
resource "aws_iam_role_policy_attachment" "ecr_read_write" {
    for_each = toset([
        local.iam_roles.tech_leadership.name,
        local.iam_roles.analytics_engineers.name,
        local.iam_roles.data_engineers.name,
        local.iam_roles.sp_ci.name,
        local.iam_roles.sp_env.name
    ])
    role       = each.value
    policy_arn = aws_iam_policy.ecr_read_write.arn
    depends_on = [aws_iam_role.data_roles]
}

# ECS Cluster for data ingestion pipeline
resource "aws_ecs_cluster" "ingestion_cluster" {
    name = "${local.prefix}-ecs-cluster-${local.environment}"
    tags = var.tags

    setting {
        name  = "containerInsights"
        value = "enabled"
    }
}

# ECS Cluster Capacity Providers
resource "aws_ecs_cluster_capacity_providers" "ingestion_cluster_providers" {
    cluster_name = aws_ecs_cluster.ingestion_cluster.name

    capacity_providers = ["FARGATE", "FARGATE_SPOT"]

    default_capacity_provider_strategy {
        base              = 1
        weight            = 100
        capacity_provider = "FARGATE"
    }
}

# IAM Role for ECS Task Execution
resource "aws_iam_role" "ecs_task_execution_role" {
    name = "${local.prefix}_ecs_task_execution_role_${local.environment}"

    assume_role_policy = jsonencode({
        Version = "2012-10-17"
        Statement = [{
            Effect    = "Allow"
            Principal = { Service = "ecs-tasks.amazonaws.com" }
            Action    = "sts:AssumeRole"
        }]
    })
    tags = var.tags
}

# Attach ECS Task Execution Role Policy
resource "aws_iam_role_policy_attachment" "ecs_task_execution_role_policy" {
    role       = aws_iam_role.ecs_task_execution_role.name
    policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# CloudWatch Log Group for ECS Tasks
resource "aws_cloudwatch_log_group" "ingestion_logs" {
    name = "/ecs/${local.prefix}-ingestion-task-${local.environment}"
    # Eram 7 dias, mais curto que o intervalo entre duas execucoes semanais:
    # quando a run seguinte comecava, o log da anterior ja tinha expirado e o
    # post-mortem era impossivel. 30 dias cobrem quatro execucoes.
    retention_in_days = 30
    tags              = var.tags
}

# Topico de alerta do pipeline.
#
# Ate agora uma falha em producao era totalmente silenciosa: email_on_failure
# desligado na DAG, sem SMTP, sem topico SNS e sem alarme no CloudWatch. Numa
# cadencia semanal isso significa descobrir a falha uma semana depois, na
# melhor das hipoteses. Consumido pelo on_failure_callback da DAG
# (camara-senado-data-ingestion, airflow/dags/camera_ingestion_dag.py).
resource "aws_sns_topic" "alerts" {
    name = "${local.prefix}-alerts-${local.environment}"
    tags = var.tags
}

resource "aws_sns_topic_subscription" "alerts_email" {
    topic_arn = aws_sns_topic.alerts.arn
    protocol  = "email"
    endpoint  = var.alert_email
}

# ECS Task Definition for Data Ingestion
resource "aws_ecs_task_definition" "ingestion_task" {
    family                   = "${local.prefix}-ingestion-task-${local.environment}"
    network_mode             = "awsvpc"
    requires_compatibilities = ["FARGATE"]
    cpu                      = "1024"
    memory                   = "2048"
    execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn
    task_role_arn            = aws_iam_role.data_roles["airflow"].arn

    container_definitions = jsonencode([
        {
            name      = "ingestion-container"
            image     = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com/${var.ingestion_ecr_repository}:${var.ingestion_image_tag}"
            essential = true

            logConfiguration = {
                logDriver = "awslogs"
                options = {
                    "awslogs-group"         = aws_cloudwatch_log_group.ingestion_logs.name
                    "awslogs-region"        = var.aws_region
                    "awslogs-stream-prefix" = "ecs"
                }
            }

            # Container will receive command and environment from EcsRunTaskOperator
            environment = []
        }
    ])

    tags = var.tags
}

# GitHub Actions CI/CD role with OIDC authentication
resource "aws_iam_role" "github_actions_ci" {
  name = "${local.prefix}_github_actions_${local.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = data.aws_iam_openid_connect_provider.github.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        StringLike = {
          "token.actions.githubusercontent.com:sub" = [
            "repo:DamodaraBarbosa/camara-senado-data-infra:ref:refs/heads/main",
            "repo:DamodaraBarbosa/camara-senado-data-infra:pull_request",
            "repo:DamodaraBarbosa/camara-senado-data-infra:environment:production",
            "repo:DamodaraBarbosa/camara-senado-data-ingestion:environment:production"
          ]
        }
      }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "github_actions_ci_power_user" {
  role       = aws_iam_role.github_actions_ci.name
  policy_arn = "arn:aws:iam::aws:policy/PowerUserAccess"
}

resource "aws_iam_policy" "github_actions_ci_iam_scoped" {
  name = "${local.prefix}-github-actions-iam-${local.environment}"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "iam:CreateRole", "iam:DeleteRole", "iam:GetRole", "iam:TagRole",
          "iam:UpdateAssumeRolePolicy",
          "iam:CreatePolicy", "iam:DeletePolicy", "iam:GetPolicy", "iam:GetPolicyVersion",
          "iam:CreatePolicyVersion", "iam:DeletePolicyVersion", "iam:ListPolicyVersions",
          "iam:AttachRolePolicy", "iam:DetachRolePolicy", "iam:ListAttachedRolePolicies",
          "iam:PassRole"
        ]
        Resource = [
          "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${local.prefix}_*",
          "arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/${local.prefix}-*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "iam:ListOpenIDConnectProviders",
          "iam:ListRolePolicies",
          "iam:GetOpenIDConnectProvider"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "github_actions_ci_iam_scoped" {
  role       = aws_iam_role.github_actions_ci.name
  policy_arn = aws_iam_policy.github_actions_ci_iam_scoped.arn
}

# ---------------------------------------------------------------------------
# Host do Airflow: backup e auto-recovery
#
# A instancia, seu security group, role, instance profile, swapfile e os dois
# crons existem apenas como checklist manual em
# camara-senado-data-ingestion/docs/PROD_AIRFLOW_EC2_RUNBOOK.md — o modules/
# deste repositorio esta vazio. Trazer o host inteiro para o Terraform e um
# `terraform import` grande e arriscado; estes recursos sao aditivos e cobrem o
# risco concreto sem tocar na instancia viva:
#
#   - o metadata DB do Airflow (estado de pause das DAGs e todo o historico)
#     vive num volume Docker no EBS **sem nenhum snapshot**;
#   - a conta tem **zero alarmes CloudWatch**, entao o host ficou inacessivel
#     por 4 dias (5 OOM-kills entre 30 e 31/08) sem ninguem ser avisado.
# ---------------------------------------------------------------------------

# O volume nao tem tag nenhuma, e a DLM so seleciona por tag. Taguear pelo
# Terraform, com aws_ec2_tag, em vez de por `aws ec2 create-tags` a mao: um
# recurso gerenciado fora do apply e exatamente o problema que este bloco
# existe para nao repetir. aws_ec2_tag governa uma unica tag sem assumir a
# posse do volume, que continua provisionado pelo runbook.
resource "aws_ec2_tag" "airflow_data_volume_backup" {
    resource_id = var.airflow_data_volume_id
    key         = "Backup"
    value       = "airflow-metadata"
}

resource "aws_iam_role" "dlm_lifecycle" {
    name = "${local.prefix}-dlm-lifecycle-${local.environment}"

    assume_role_policy = jsonencode({
        Version = "2012-10-17"
        Statement = [{
            Effect    = "Allow"
            Action    = "sts:AssumeRole"
            Principal = { Service = "dlm.amazonaws.com" }
        }]
    })

    tags = var.tags
}

resource "aws_iam_role_policy_attachment" "dlm_lifecycle" {
    role       = aws_iam_role.dlm_lifecycle.name
    policy_arn = "arn:aws:iam::aws:policy/service-role/AWSDataLifecycleManagerServiceRole"
}

# Snapshot diario do volume que guarda o metadata DB. A janela e 07:00 UTC:
# depois da run semanal (domingo 06:00 UTC, ~42 min), para que o snapshot de
# domingo ja contenha o resultado dela.
resource "aws_dlm_lifecycle_policy" "airflow_metadata" {
    # A descricao da DLM so aceita [0-9A-Za-z _-]: parenteses reprovam na
    # validacao da API, em tempo de plan.
    description        = "Snapshot diario do metadata DB do Airflow - host ${var.airflow_instance_id}"
    execution_role_arn = aws_iam_role.dlm_lifecycle.arn
    state              = "ENABLED"

    policy_details {
        resource_types = ["VOLUME"]

        target_tags = {
            Backup = aws_ec2_tag.airflow_data_volume_backup.value
        }

        schedule {
            name = "diario-7-dias"

            create_rule {
                interval      = 24
                interval_unit = "HOURS"
                times         = ["07:00"]
            }

            retain_rule {
                count = 7
            }

            copy_tags = true
        }
    }

    tags = var.tags
}

# Auto-recovery do host. StatusCheckFailed_System cobre falha da infraestrutura
# subjacente (host fisico, rede, energia) — o caso em que a instancia nao volta
# sozinha e a recuperacao manual e um runbook de 8 passos. A acao `recover`
# migra a instancia para outro host fisico preservando id, IPs e volumes EBS.
#
# Nao cobre OOM (que e falha dentro do SO, nao do sistema). Para isso e preciso
# metrica de memoria, que nao existe: o host nao roda CloudWatch agent. Ver o
# passo correspondente no PROD_AIRFLOW_EC2_RUNBOOK.
resource "aws_cloudwatch_metric_alarm" "airflow_host_system_check" {
    alarm_name          = "${local.prefix}-airflow-host-system-check-${local.environment}"
    alarm_description   = "Falha de status check de sistema no host do Airflow; dispara auto-recovery."
    namespace           = "AWS/EC2"
    metric_name         = "StatusCheckFailed_System"
    statistic           = "Maximum"
    comparison_operator = "GreaterThanOrEqualToThreshold"
    threshold           = 1
    period              = 60
    evaluation_periods  = 2
    treat_missing_data  = "missing"

    dimensions = {
        InstanceId = var.airflow_instance_id
    }

    alarm_actions = [
        "arn:aws:automate:${var.aws_region}:ec2:recover",
        aws_sns_topic.alerts.arn,
    ]
    ok_actions = [aws_sns_topic.alerts.arn]

    tags = var.tags
}

# ---------------------------------------------------------------------------
# Ciclo de vida e postura dos buckets de dados
# ---------------------------------------------------------------------------

# Nao havia nenhuma lifecycle policy (`NoSuchLifecycleConfiguration`), e o
# bucket de producao ja acumula 6,3 GB em 225 objetos.
#
# Cada run semanal grava um **snapshot completo**, nao um delta: os extractors
# reextraem a janela inteira toda semana (blocos tem exatamente 690 B nas 4
# runs; despesas, 632,7 / 632,7 / 635,1 / 634,3 MiB). Sao ~1,4 GB por semana
# com mais de 95% de redundancia, ~75 GB/ano. Retencao, portanto, e a questao —
# nao higiene.
resource "aws_s3_bucket_lifecycle_configuration" "catalog" {
    for_each = aws_s3_bucket.catalog
    bucket   = each.value.id

    # A regra de versoes nao-atuais so faz sentido com o versionamento ligado.
    depends_on = [aws_s3_bucket_versioning.catalog]

    # A mais urgente das tres. O _write_s3 aborta o multipart no except, mas um
    # kill duro do container (OOM, task Fargate morta) deixa partes orfas que
    # faturam em silencio e nao aparecem em `s3 ls`. O pipeline sobe 632 MB por
    # multipart toda semana.
    rule {
        id     = "abort-incomplete-multipart-uploads"
        status = "Enabled"

        filter {}

        abort_incomplete_multipart_upload {
            days_after_initiation = 7
        }
    }

    # O versionamento ligado na Sprint 0 e rede de seguranca contra sobrescrita,
    # nao arquivo permanente: 30 dias cobrem quatro execucoes semanais, que e o
    # prazo em que uma sobrescrita ainda seria descoberta e revertida.
    rule {
        id     = "expire-noncurrent-versions"
        status = "Enabled"

        filter {}

        noncurrent_version_expiration {
            noncurrent_days = 30
        }
    }

    # ~8 semanas de snapshots ficam quentes; o resto vai para Glacier Instant
    # Retrieval, que mantem leitura em milissegundos (o dbt pode precisar de
    # historico) a uma fracao do custo do Standard.
    rule {
        id     = "archive-old-snapshots"
        status = "Enabled"

        filter {
            prefix = "raw/"
        }

        transition {
            days          = 60
            storage_class = "GLACIER_IR"
        }
    }
}

# SSE e Public Access Block existem nos dois buckets de producao, mas por
# **default da AWS**, nao por configuracao nossa: nenhum dos dois aparecia neste
# codigo. Sem o recurso declarado, desligar qualquer um deles nao apareceria em
# nenhum `terraform plan`. Declarar nao muda o estado atual — fixa-o.
resource "aws_s3_bucket_server_side_encryption_configuration" "catalog" {
    for_each = aws_s3_bucket.catalog
    bucket   = each.value.id

    rule {
        apply_server_side_encryption_by_default {
            sse_algorithm = "AES256"
        }
    }
}

resource "aws_s3_bucket_public_access_block" "catalog" {
    for_each = aws_s3_bucket.catalog
    bucket   = each.value.id

    block_public_acls       = true
    block_public_policy     = true
    ignore_public_acls      = true
    restrict_public_buckets = true
}
