# Creation of IAM Groups
resource "aws_iam_group" "groups" {
    for_each = local.iam_groups
    name     = "${local.prefix}_${each.key}"
}

# Creation of IAM Users
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
