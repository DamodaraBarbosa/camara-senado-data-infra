# ---------------------------------------------------------------------------
# Orcamento mensal da conta
#
# Nao e higiene de FinOps: e a resposta a um ponto cego real. A conta operou de
# julho a setembro de 2026 com uso faturavel de US$ 13,37, US$ 6,09 e US$ 3,10,
# integralmente abatido por credito do Free Tier. O Cost Explorer devolvia zero
# no liquido, o unico orcamento existente era o `My Zero-Spend Budget` de US$ 1
# criado pela propria AWS, e nenhum alarme de billing existia — entao o fim da
# cobertura de credito nao geraria aviso nenhum ate a fatura chegar.
#
# Escopo deliberado: um unico orcamento. A franquia do AWS Budgets e de 60
# budget-days por mes (dois orcamentos ativos o mes inteiro) e o zero-spend ja
# ocupa um. Um terceiro sairia da franquia e custaria US$ 0,02/dia. Por isso
# ele vive aqui e nao tambem em environments/dev/: orcamento e recurso de
# conta, nao de ambiente.
# ---------------------------------------------------------------------------
resource "aws_budgets_budget" "monthly_cost" {
    name        = "${local.prefix}-monthly-cost-${local.environment}"
    budget_type = "COST"
    time_unit   = "MONTHLY"

    # A API do Budgets devolve o valor com uma casa decimal — o orcamento
    # existente volta como "1.0". Passar "25" cru geraria diff perpetuo contra
    # "25.0" em todo plan, e o CI aplicaria um update inocuo para sempre.
    limit_amount = format("%.1f", var.monthly_budget_limit_usd)
    limit_unit   = "USD"

    # Fixado: sem isto o provider usa a data corrente a cada plan.
    time_period_start = "2026-09-01_00:00"

    # `include_credit = false` e a linha que da sentido a este recurso.
    #
    # Por padrao o Budgets **subtrai** os creditos, de modo que um orcamento de
    # custo mede o liquido a pagar — que e ~US$ 0 enquanto o credito do Free
    # Plan durar. Um orcamento assim ficaria em silencio exatamente ate o dia
    # em que o credito acaba, que e o unico dia em que ele precisava falar.
    # Com include_credit = false ele mede o custo **bruto** de uso: o valor que
    # passa a ser cobrado no dia seguinte. E a mesma distincao que a Lambda de
    # relatorio publica via RECORD_TYPE.
    cost_types {
        include_credit             = false
        include_refund             = false
        include_discount           = true
        include_other_subscription = true
        include_recurring          = true
        include_subscription       = true
        include_support            = true
        include_tax                = true
        include_upfront            = true
        use_amortized              = false
        use_blended                = false
    }

    # Assinatura por e-mail direta, nao SNS. O topico dataplatform-alerts-prod
    # esta com a policy default da AWS, e `aws_sns_topic_policy` **substitui** o
    # documento inteiro em vez de acrescentar: declarar um statement so para
    # budgets.amazonaws.com apagaria o __default_statement_ID, que e o que
    # permite ao aws_cloudwatch_metric_alarm.airflow_host_system_check
    # publicar. Seria trocar um alerta novo por uma falha silenciosa no alerta
    # que ja existe — o oposto do motivo pelo qual aquele topico foi criado.
    #
    # ACTUAL a 80% avisa quando o gasto ja aconteceu; FORECASTED a 100% avisa
    # antes, pela projecao do mes. Sozinho, o ACTUAL chega tarde num mes que
    # acelera no fim; sozinho, o FORECASTED e ruidoso nos primeiros dias.
    notification {
        comparison_operator        = "GREATER_THAN"
        threshold                  = 80
        threshold_type             = "PERCENTAGE"
        notification_type          = "ACTUAL"
        subscriber_email_addresses = [var.alert_email]
    }

    notification {
        comparison_operator        = "GREATER_THAN"
        threshold                  = 100
        threshold_type             = "PERCENTAGE"
        notification_type          = "FORECASTED"
        subscriber_email_addresses = [var.alert_email]
    }

    tags = var.tags
}
