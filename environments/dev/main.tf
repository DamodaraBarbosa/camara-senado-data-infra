# Creation of Buckets S3
resource "aws_s3_bucket" "catalog" {
    for_each = toset(local.s3_buckets)

    bucket   = each.value
    tags     = var.tags
}

# Creation of roles IAM
resource "aws_iam_role" "groups" {
    assume_role_policy = jsonencode(
        {
            "Version": "2012-10-17",
            "Statement": [
                {
                    "Effect": "Allow",
                    "Principal": {
                        "Service": "ec2.amazonaws.com"
                    },
                    "Action": "sts:AssumeRole"
                }
            ]
        }
    )
    tags = var.tags
}

# Creation of compute cluster
resource "aws_emr_cluster" "dataplatform_cluster" {
    name          = "${local.prefix}-${local.environment}-cluster"
    release_label = var.emr_release_label
    service_role  = aws_iam_role.groups.arn
    
    auto_termination_policy {
        idle_timeout = var.cluster_auto_termination_minutes
    }

    ec2_attributes {
        instance_profile = "EMR_EC2_DefaultRole"
    }

    master_instance_group {
        instance_type = var.cluster_master_instance_type
    }

    core_instance_group {
        instance_type  = var.cluster_core_instance_type
        instance_count = var.cluster_instance_count
    }

    applications = ["Spark", "Hive"]
    tags         = var.tags
}
