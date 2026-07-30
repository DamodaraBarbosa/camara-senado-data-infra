import boto3
import json
from rich.tree import Tree
from rich.console import Console

# Settings for LocalStack IAM
ENDPOINT_URL = "http://localhost:4566"
REGION = "us-east-1"

def get_iam_structure():
    iam = boto3.client("iam", endpoint_url=ENDPOINT_URL, region_name=REGION)
    console = Console()
    
    # Root of the tree
    root = Tree("🏗️ [bold blue]LocalStack IAM Hierarchy[/bold blue]")

    try:
        # 1. List Groups
        groups = iam.list_groups().get('Groups', [])
        
        if not groups:
            console.print("[yellow]No groups found in LocalStack.[/yellow]")
            return

        for group in groups:
            group_name = group['GroupName']
            group_node = root.add(f"👥 [bold green]Group: {group_name}[/bold green]")
            
            # 2. List Users within the Group
            group_users = iam.get_group(GroupName=group_name).get('Users', [])
            if group_users:
                users_node = group_node.add("[cyan]Users:[/cyan]")
                for user in group_users:
                    users_node.add(f"👤 {user['UserName']}")
            else:
                group_node.add("[red](Empty)[/red]")

        # 3. List Roles (Separate from Groups)
        roles_node = root.add("\n🎭 [bold magenta]IAM Roles (Services/Temporary Access)[/bold magenta]")
        roles = iam.list_roles().get('Roles', [])
        
        for role in roles:
            # Filter AWS default roles to focus on project-specific ones
            if "aws-service-role" not in role['Arn']:
                r_node = roles_node.add(f"🔑 {role['RoleName']}")
                
                # List Policies attached to the Role
                policies = iam.list_attached_role_policies(RoleName=role['RoleName']).get('AttachedPolicies', [])
                for pol in policies:
                    r_node.add(f"📜 [italic]{pol['PolicyName']}[/italic]")

        console.print(root)

    except Exception as e:
        console.print(f"[bold red]Error connecting to LocalStack:[/bold red] {e}")

if __name__ == "__main__":
    get_iam_structure()
