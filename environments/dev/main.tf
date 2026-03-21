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

# Creation of IAM Groups
resource "aws_iam_group" "groups" {
    for_each = local.iam_groups
    name     = "${local.prefix}_${each.key}"
}

# Creation of IAM Users
locals {
    user_to_group = flatten([
        for group, users in local.iam_groups : [
            for user in users : {
                user  = user
                group = group
            }
        ]
    ])
}

resource "aws_iam_user" "users" {
    for_each = toset([for u in local.user_to_group : u.user])
    name     = each.value
    tags     = var.tags
}

# Add Users to Groups
resource "aws_iam_group_membership" "team" {
    for_each = aws_iam_group.groups
    name     = "${each.value.name}_membership"
    group    = each.value.name
    users    = [
        for u in local.user_to_group : u.user if u.group == each.key
    ]
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

# S3 read-only policy 
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

# S3 + Glue read-write policy 
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