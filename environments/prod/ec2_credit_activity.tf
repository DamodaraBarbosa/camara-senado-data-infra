# ---------------------------------------------------------------------------
# Instancia descartavel da atividade de credito do Free Tier
#
# A atividade "Launch an instance using Amazon EC2" do widget Explore AWS rende
# US$ 20 e pede lancar e terminar uma instancia. Este bloco existe para que
# isso aconteca por PR revisado, e nao por clique nao rastreado.
#
# Nada aqui toca no host do Airflow (i-0e11709bd1c1dae07), no security group
# dele ou no volume do metadata DB (vol-06402ad2abd2d4999): security group
# proprio, AZ diferente (a do Airflow e us-east-1d), sem instance profile e sem
# IP publico. Nenhum recurso deste arquivo referencia nenhum daqueles ids.
#
# Nasce desligada. Ligar e um PR, desligar e outro — ver
# FREE_TIER_CREDITS_RUNBOOK.md.
#
# Custo: t4g.micro a US$ 0,0084/h mais ~US$ 0,0007/h do volume gp3 de 8 GiB.
# Uma janela de 30 minutos fica em torno de meio centavo.
# ---------------------------------------------------------------------------

data "aws_vpc" "default" {
    default = true
}

# Subnet escolhida pela AZ, nao pela ordem de retorno da API: ver o comentario
# de credit_activity_availability_zone em variables.tf.
data "aws_subnet" "credit_activity" {
    vpc_id            = data.aws_vpc.default.id
    availability_zone = var.credit_activity_availability_zone
    default_for_az    = true
}

# O nome fixa "kernel-6.1" de proposito. As variantes de kernel da AL2023 arm64
# compartilham a mesma CreationDate, entao `most_recent` sozinho escolheria uma
# delas de forma arbitraria e o AMI id poderia mudar entre dois plans sem que
# nada tivesse mudado.
data "aws_ami" "al2023_arm64" {
    most_recent = true
    owners      = ["amazon"]

    filter {
        name   = "name"
        values = ["al2023-ami-2023.*-kernel-6.1-arm64"]
    }

    filter {
        name   = "state"
        values = ["available"]
    }
}

resource "aws_security_group" "credit_activity" {
    count = var.enable_credit_activity_instance ? 1 : 0

    name        = "${local.prefix}-credit-activity-${local.environment}"
    description = "Instancia efemera da atividade de credito do Free Tier - sem inbound"
    vpc_id      = data.aws_vpc.default.id

    # Nenhuma regra de ingress, em nenhuma porta: a instancia nao precisa ser
    # acessada. A atividade e subir e terminar.
    egress {
        from_port   = 443
        to_port     = 443
        protocol    = "tcp"
        cidr_blocks = ["0.0.0.0/0"]
        description = "HTTPS de saida"
    }

    tags = var.tags
}

resource "aws_instance" "credit_activity" {
    count = var.enable_credit_activity_instance ? 1 : 0

    ami                    = data.aws_ami.al2023_arm64.id
    # t4g.micro, nao t4g.nano: contas no Free Plan so podem lancar tipos
    # elegiveis ao Free Tier, e a nano nao e um deles — o RunInstances volta
    # InvalidParameterCombination e o apply para. Os elegiveis em arm64 sao
    # t4g.micro e t4g.small; a micro e a mais barata das duas e roda a mesma
    # AMI. Verificado em ec2:DescribeInstanceTypes com o filtro
    # free-tier-eligible=true.
    instance_type          = "t4g.micro"
    subnet_id              = data.aws_subnet.credit_activity.id
    vpc_security_group_ids = [aws_security_group.credit_activity[0].id]

    # As subnets default tem MapPublicIpOnLaunch = true, e um IPv4 publico
    # custa US$ 0,005/h, mais da metade do preco da propria t4g.micro
    # (US$ 0,0084/h). Sem inbound e sem necessidade de saida, o IP publico so
    # custaria dinheiro.
    associate_public_ip_address = false

    # Sem `iam_instance_profile` de proposito: a policy escopada do role de CI
    # nao concede iam:CreateInstanceProfile nem iam:AddRoleToInstanceProfile,
    # entao um profile aqui reprovaria o apply. Na pratica isso significa nao
    # ter SSM nesta instancia, o que e aceitavel — nao ha nada a fazer dentro
    # dela.

    root_block_device {
        # 8 GiB e o piso: e o tamanho do snapshot da propria AMI, nao da para
        # pedir menos. gp3 e o tipo da AMI e e mais barato que gp2.
        volume_size           = 8
        volume_type           = "gp3"
        delete_on_termination = true
    }

    metadata_options {
        http_endpoint = "enabled"
        http_tokens   = "required"
    }

    # Se alguem der shutdown por dentro, a instancia termina em vez de ficar
    # parada cobrando o volume.
    instance_initiated_shutdown_behavior = "terminate"

    tags = merge(
        var.tags, {
            Name = "${local.prefix}-credit-activity-${local.environment}"
            Type = "Free Tier credit activity - ephemeral"
        }
    )
}
