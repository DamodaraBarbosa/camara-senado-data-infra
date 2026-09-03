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
