# Creation of Buckets S3
resource "aws_s3_bucket" "catalog" {
    for_each = toset(local.s3_buckets)
    bucket   = each.value
    tags     = var.tags
}

# Creation of schema prefixes inside S3 buckets (simulates Glue databases)
locals {
    schema_prefixes = {
        for pair in flatten([
            for bucket in local.s3_buckets : [
                for schema in var.schema_names : {
                    key   = "${bucket}/${schema}"
                    bucket = bucket
                    schema = schema
                }
            ]
        ]) : pair.key => pair
    }
}

resource "aws_s3_object" "schema_prefix" {
    for_each = local.schema_prefixes
    bucket   = each.value.bucket
    key      = "${each.value.schema}/"
    content  = ""

    depends_on = [aws_s3_bucket.catalog]
}

# Creation of IAM roles
resource "aws_iam_role" "data_roles" {
    for_each = local.iam_roles
    name     = each.value.name

    assume_role_policy = jsonencode({
        Version = "2012-10-17"
        Statement = [{
            Effect    = "Allow"
            Principal = { Service = "ec2.amazonaws.com" }
            Action    = "sts:AssumeRole"
        }]
    })
    tags = var.tags
}

# S3 read-only policy (leitura para contas de BI)
resource "aws_iam_policy" "s3_read_only" {
    name = "${local.prefix}-s3-read-only"

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

# S3 + Glue read-write policy (engenheiros e CI/CD)
resource "aws_iam_policy" "s3_read_write" {
    name = "${local.prefix}-s3-read-write"

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
                Resource = ["*"]
            }
        ]
    })
}

# Vincular política de leitura às roles somente-leitura
resource "aws_iam_role_policy_attachment" "read_only" {
    for_each = toset(flatten([
        for ac in local.bucket_access_control : ac.read_only_roles
    ]))
    role       = each.value
    policy_arn = aws_iam_policy.s3_read_only.arn
    depends_on = [aws_iam_role.data_roles]
}

# Vincular política de leitura/escrita às roles de engenharia e CI/CD
resource "aws_iam_role_policy_attachment" "read_write" {
    for_each = toset(flatten([
        for ac in local.bucket_access_control : ac.read_write_roles
    ]))
    role       = each.value
    policy_arn = aws_iam_policy.s3_read_write.arn
    depends_on = [aws_iam_role.data_roles]
}