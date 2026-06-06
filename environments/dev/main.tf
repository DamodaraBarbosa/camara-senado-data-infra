# Creation of Buckets S3
resource "aws_s3_bucket" "catalog" {
    for_each = toset(local.s3_buckets)
    bucket   = each.value
    tags     = var.tags
}

# Creation of Glue Catalog Databases 
# Example: dataplatform_camara_dev_db.raw, dataplatform_camara_dev_db.staging
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

# ECR read-only policy
resource "aws_iam_policy" "ecr_read_only" {
    name = "${local.prefix}-ecr-read-only"

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
    name = "${local.prefix}-ecr-read-write"

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