# ---------------------------------------------------------------------------
# Relatorio semanal de custo
#
# A auditoria de 2026-09-02 registrou que uma falha em producao era totalmente
# silenciosa. O mesmo valia para o custo: com o credito do Free Tier abatendo a
# fatura inteira, o Cost Explorer devolvia zero no liquido e nada distinguia
# "de graca" de "pago com credito que vai acabar". Esta funcao publica os dois
# numeros lado a lado no topico de alertas que ja existe.
#
# Custa US$ 0,01 por execucao: a API do Cost Explorer cobra US$ 0,01 por
# request e o codigo faz exatamente um — o CE aceita duas dimensoes de GroupBy
# por chamada, entao SERVICE x RECORD_TYPE entrega o detalhamento por servico e
# a divisao uso-versus-credito de uma vez so. Invocacao e compute ficam dentro
# da franquia perpetua do Lambda (1M requests / 400k GB-s por mes).
# ---------------------------------------------------------------------------

locals {
    cost_report_name = "${local.prefix}-cost-report-${local.environment}"
}

data "archive_file" "cost_report" {
    type        = "zip"
    source_dir  = "${path.module}/lambda/cost_report"
    output_path = "${path.module}/.terraform-build/cost_report.zip"

    # O .gitignore nao protege aqui: o archive_file empacota o diretorio do
    # disco, versionado ou nao. Sem isto, um `python3 main.py` local deixa
    # __pycache__ para tras, o bytecode entra no zip e o source_code_hash muda
    # — o Terraform passa a reimplantar a funcao sem que o codigo tenha mudado.
    excludes = ["__pycache__", "*.pyc"]
}

# Underscore, nao hifen: a policy escopada do role de CI
# (github_actions_ci_iam_scoped) so autoriza iam:CreateRole em
# `role/${local.prefix}_*`. Com hifen o apply reprova com AccessDenied depois
# de ja ter criado os outros recursos — foi o commit a4fa58b.
resource "aws_iam_role" "cost_report" {
    name = "${local.prefix}_cost_report_${local.environment}"

    assume_role_policy = jsonencode({
        Version = "2012-10-17"
        Statement = [{
            Effect    = "Allow"
            Principal = { Service = "lambda.amazonaws.com" }
            Action    = "sts:AssumeRole"
        }]
    })

    tags = var.tags
}

# Policy gerenciada e attachment, nunca `aws_iam_role_policy` inline: a policy
# do CI concede CreatePolicy e AttachRolePolicy, mas **nao** iam:PutRolePolicy,
# entao uma policy inline falharia no apply.
resource "aws_iam_policy" "cost_report" {
    name = local.cost_report_name

    lifecycle {
        create_before_destroy = true
    }

    policy = jsonencode({
        Version = "2012-10-17"
        Statement = [
            {
                # O Cost Explorer nao suporta permissao por recurso.
                Effect   = "Allow"
                Action   = ["ce:GetCostAndUsage"]
                Resource = "*"
            },
            {
                Effect   = "Allow"
                Action   = ["sns:Publish"]
                Resource = [aws_sns_topic.alerts.arn]
            },
            {
                Effect   = "Allow"
                Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
                Resource = ["${aws_cloudwatch_log_group.cost_report.arn}:*"]
            }
        ]
    })
}

resource "aws_iam_role_policy_attachment" "cost_report" {
    role       = aws_iam_role.cost_report.name
    policy_arn = aws_iam_policy.cost_report.arn
}

# Declarado explicitamente para fixar a retencao. Se o Lambda criar o grupo
# sozinho na primeira invocacao, ele nasce com retencao "never expire" e os
# logs acumulam para sempre. 30 dias e a convencao ja usada pelo grupo da task
# de ingestao.
resource "aws_cloudwatch_log_group" "cost_report" {
    name              = "/aws/lambda/${local.cost_report_name}"
    retention_in_days = 30
    tags              = var.tags
}

resource "aws_lambda_function" "cost_report" {
    function_name = local.cost_report_name
    role          = aws_iam_role.cost_report.arn
    handler       = "main.lambda_handler"
    runtime       = "python3.12"

    # arm64 e ~20% mais barato que x86_64 por GB-s e o codigo e Python puro com
    # boto3, que ja vem no runtime — nao ha dependencia compilada para portar.
    architectures = ["arm64"]
    memory_size   = 256
    timeout       = 30

    filename         = data.archive_file.cost_report.output_path
    source_code_hash = data.archive_file.cost_report.output_base64sha256

    environment {
        variables = {
            SNS_TOPIC_ARN = aws_sns_topic.alerts.arn

            # Limita o gasto acidental pela function URL: sem cache, dez
            # refreshes na pagina custariam US$ 0,10 em chamadas ao CE.
            CACHE_TTL_SECONDS = "3600"
        }
    }

    depends_on = [
        aws_cloudwatch_log_group.cost_report,
        aws_iam_role_policy_attachment.cost_report,
    ]

    tags = var.tags
}

# A atividade de credito do Free Tier pede uma funcao **com function URL**.
# AWS_IAM, nao NONE: uma URL publica exporia dados de faturamento da conta a
# quem descobrisse o endereco.
resource "aws_lambda_function_url" "cost_report" {
    function_name      = aws_lambda_function.cost_report.function_name
    authorization_type = "AWS_IAM"
}

# Com AWS_IAM a chamada precisa ser assinada (SigV4) por um principal desta
# conta que tenha lambda:InvokeFunctionUrl. Esta statement nao abre nada para
# fora: ela apenas permite que a propria conta seja esse principal.
resource "aws_lambda_permission" "cost_report_url" {
    statement_id           = "AllowInvokeFunctionUrlFromAccount"
    action                 = "lambda:InvokeFunctionUrl"
    function_name          = aws_lambda_function.cost_report.function_name
    principal              = data.aws_caller_identity.current.account_id
    function_url_auth_type = "AWS_IAM"
}

# Segunda-feira 12:00 UTC: depois da run semanal do pipeline (domingo 06:00
# UTC, ~42 min), para que o relatorio ja inclua o custo dela.
resource "aws_cloudwatch_event_rule" "cost_report_weekly" {
    name                = "${local.prefix}-cost-report-weekly-${local.environment}"
    description         = "Dispara o relatorio semanal de custo da plataforma de dados"
    schedule_expression = "cron(0 12 ? * MON *)"
    tags                = var.tags
}

resource "aws_cloudwatch_event_target" "cost_report_weekly" {
    rule      = aws_cloudwatch_event_rule.cost_report_weekly.name
    target_id = "cost-report-lambda"
    arn       = aws_lambda_function.cost_report.arn
}

resource "aws_lambda_permission" "cost_report_events" {
    statement_id  = "AllowExecutionFromEventBridge"
    action        = "lambda:InvokeFunction"
    function_name = aws_lambda_function.cost_report.function_name
    principal     = "events.amazonaws.com"
    source_arn    = aws_cloudwatch_event_rule.cost_report_weekly.arn
}

# Nao existe outputs.tf neste ambiente e criar um arquivo para um unico valor
# nao se paga; o runbook le a URL daqui com `terraform output`.
output "cost_report_function_url" {
    value       = aws_lambda_function_url.cost_report.function_url
    description = "URL assinada (SigV4) do relatorio de custo sob demanda"
}
