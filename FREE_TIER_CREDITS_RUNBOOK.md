# Runbook: Claim the remaining Free Tier activity credits

This document is a manual checklist. **Nothing here runs automatically in CI** — the Terraform in `environments/prod/` provisions the resources that *last*, but AWS tracks activity completion through the **Explore AWS** widget on the Console Home, and its documentation does not state that a Terraform-created equivalent registers the credit. Treat the console steps below as the credit path and the Terraform as the value path.

Run these with the `damodarabarbosa-admin` user in account `904464083417` (region `us-east-1`), reviewing each step before acting.

> **Never run `terraform apply` locally against this state.** The local binary is 1.16.1; CI pins `TF_VERSION: "1.14.7"`. An apply from your machine writes `terraform_version: 1.16.1` into the shared S3 state, after which CI refuses to run at all ("state snapshot was created by a newer Terraform") and production is stuck until someone rewrites the state by hand. `terraform plan` and `terraform validate` are safe; `apply` belongs to CI.

## 0. Why this is time-boxed

The account is on the AWS **Free Plan**, which does not simply start billing when it ends — [the account closes automatically](https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/free-tier-plans.html) and AWS retains the content for 90 days before deleting it. The plan expires **six months after the account was opened**, and the activities have the same deadline:

> "You will need to complete the activities within 6 months from the date you open your AWS account to earn Free Tier credits." — [AWS Free Tier FAQs](https://aws.amazon.com/free/free-tier-faqs/)

The IAM admin user was created `2026-03-22`, which puts both deadlines around **2026-09-22**. Confirm the exact date in **Billing and Cost Management → Home** before relying on it.

Four activities remain, USD 20 each. RDS/Aurora is deliberately **out of scope**: it is the only one where forgetting to delete the resource costs more than the credit it pays.

| Activity | Terraform equivalent in this repo | Console step required |
|---|---|---|
| AWS Budgets | `environments/prod/budgets.tf` | Yes |
| AWS Lambda | `environments/prod/lambda_cost_report.tf` | Yes |
| Amazon EC2 | `environments/prod/ec2_credit_activity.tf` | Yes |
| Amazon Bedrock | none possible | Yes |

## 1. Record the starting balance

Do this first, so that "did the credit land?" has an answer later.

```bash
# Credits already consumed, by month. There is no API for the remaining
# balance — Cost Explorer only reports credits applied.
aws ce get-cost-and-usage \
  --time-period Start=2026-03-01,End=2026-09-30 \
  --granularity MONTHLY --metrics UnblendedCost \
  --filter '{"Dimensions":{"Key":"RECORD_TYPE","Values":["Credit"]}}' \
  --region us-east-1
```

Then open **Billing and Cost Management → Credits** and write down the remaining amount and the expiry date. Each Cost Explorer API request costs USD 0.01.

## 2. Deploy the Terraform first

Merging to `main` applies `environments/prod` with `terraform apply -auto-approve` and **no approval gate**. Confirm the plan on the PR shows only additions before merging.

```bash
git switch develop && git pull
# PR: feat/free-tier-credit-activities -> develop   (plans dev: no changes)
# PR: develop -> main                               (plans prod: adds only)
```

Expected additions: one `aws_budgets_budget`, the cost-report Lambda with its role, managed policy, log group, function URL and weekly EventBridge rule. The EC2 instance stays absent — `enable_credit_activity_instance` defaults to `false`.

## 3. AWS Budgets activity — USD 20

Console Home → **Explore AWS** widget → filter **Earn AWS credits** → *Set up a cost budget using AWS Budgets*.

This is the only one of the four with no service charge of its own. Follow the guided flow even though `budgets.tf` already created a budget: the widget tracks the console flow, not the resource.

The budget this repo creates sets `cost_types.include_credit = false` deliberately. By default AWS Budgets *subtracts* credits, so a cost budget measures the net payable — which is ~USD 0 for as long as the Free Plan credits last, and would therefore stay silent right up to the day they run out. Measuring gross usage cost instead means it tracks the number you will actually be charged the day after.

Note the account has room for exactly **one** more budget. AWS Budgets includes 60 budget-days per month (two budgets running all month); `My Zero-Spend Budget` occupies one and `dataplatform-monthly-cost-prod` the other. A third would cost USD 0.02/day.

## 4. Amazon Bedrock activity — USD 20

This one has no Terraform equivalent, and as of 2026 it has no prerequisite either. The **Model access page has been retired**: serverless foundation models are enabled automatically, account-wide, in every AWS commercial region the first time they are invoked. There is nothing to request and nothing to wait for.

1. Console Home → **Explore AWS** → *Use a foundational model in the Amazon Bedrock playground*.
2. Pick an **Amazon-owned serverless** model — Nova Micro or Titan Text Express.
3. Submit one short prompt. A single prompt on a micro model costs a fraction of a cent.

Step 2 is not arbitrary. Two categories still carry friction that an Amazon-owned serverless model avoids entirely:

- **Anthropic models** may ask a first-time user to submit use-case details before granting access.
- **AWS Marketplace models** need a user holding Marketplace permissions to invoke them once before they work account-wide.

Access is still governable — administrators restrict it through IAM policies and SCPs — but nothing needs to be turned *on* first.

The local AWS CLI is version `1.18.69` (2020) and has **no `bedrock` command**, so do not try to script this — the console is the shortest path.

## 5. AWS Lambda activity — USD 20

Console Home → **Explore AWS** → *Create a web app using AWS Lambda*.

The activity asks for a function with a function URL. `lambda_cost_report.tf` already creates one with `authorization_type = "AWS_IAM"` — deliberately not public, since the function returns account billing figures. If the guided flow creates a second, throwaway function with a public URL, **delete it in step 8**.

Verify the real one works:

```bash
aws lambda invoke --function-name dataplatform-cost-report-prod \
  --region us-east-1 /tmp/cost_report.json
cat /tmp/cost_report.json
```

An email should arrive via `dataplatform-alerts-prod` (subscription already confirmed). Each report makes **one** Cost Explorer call — USD 0.01 — because Cost Explorer accepts two `GroupBy` dimensions per request and `SERVICE` x `RECORD_TYPE` returns both views at once.

To exercise the function URL itself (the "web app" half of the activity), note that the local `curl` is 7.68.0 and predates `--aws-sigv4`, so sign the request with botocore instead:

```bash
FN_URL=$(cd environments/prod && terraform output -raw cost_report_function_url)
venv/bin/python3 - "$FN_URL" <<'PY'
import sys, boto3, urllib.request
from botocore.auth import SigV4Auth
from botocore.awsrequest import AWSRequest
url = sys.argv[1]
session = boto3.Session()
req = AWSRequest(method="GET", url=url)
SigV4Auth(session.get_credentials(), "lambda", "us-east-1").add_auth(req)
print(urllib.request.urlopen(
    urllib.request.Request(url, headers=dict(req.headers))).read().decode())
PY
```

The function caches its Cost Explorer response for one hour per warm container, so refreshing the URL does not bill USD 0.01 each time.

## 6. Amazon EC2 activity — USD 20

Console Home → **Explore AWS** → *Launch an instance using Amazon EC2*, then terminate it.

To do it through the repo instead, open a PR to `main` flipping the toggle:

```hcl
# environments/prod/variables.tf
variable "enable_credit_activity_instance" {
    default = true   # was false
}
```

That creates a `t4g.nano` (USD 0.0042/h) in the default VPC, with a dedicated security group that has no ingress rules, no public IP and an 8 GiB gp3 root volume. It does not touch the Airflow host, its security group or its metadata volume. The AZ is pinned to `us-east-1a` on purpose: **`t4g.nano` is not offered in `us-east-1e`**, and one of the account's six default subnets lives there.

> **Let Terraform do the termination.** Do not terminate this instance from the console while `enable_credit_activity_instance` is still `true` — the next prod apply would see it gone and recreate it, so any unrelated push to `main` would silently relaunch it. Flipping the flag back to `false` performs the `TerminateInstances` call *and* removes it from state in one action, which also satisfies the "clean up your instances" half of the activity.

## 7. Verify the credits landed

Credits take up to 30 minutes to appear.

**Billing and Cost Management → Credits.** The balance should have risen by USD 20 per completed activity. This is the only confirmation that counts — a green checkmark in the widget is not the same as a credit posted.

If an activity does not credit, re-check that you completed it through the widget flow rather than only through Terraform or the CLI.

## 8. Clean up

```bash
# Any throwaway function the Lambda guided flow created (NOT the cost report)
aws lambda list-functions --region us-east-1 \
  --query 'Functions[].FunctionName' --output text

# Confirm only the Airflow host remains
aws ec2 describe-instances --region us-east-1 \
  --query 'Reservations[].Instances[?State.Name==`running`].[InstanceId,InstanceType]' \
  --output text
```

Then open the PR flipping `enable_credit_activity_instance` back to `false` and merge it to `main`.

## 9. Upgrade to the Paid Plan

Do this **after** the activities and **before** the plan expires. Remaining credits survive the upgrade:

> "When you upgrade to paid plan, your remaining Free Tier credits will automatically apply to future AWS bills until they expire." — [AWS Free Tier FAQs](https://aws.amazon.com/free/free-tier-faqs/)

Credits expire 12 months after the account was opened (~2027-03-22), so the upgrade does not start real spending — at the current ~USD 15.70/month the existing balance runs out around the same time it would have expired anyway.

**Billing and Cost Management → Upgrade plan.**

Do **not** upgrade by joining AWS Organizations or setting up a Control Tower landing zone:

> "However, if you upgrade to paid plan by joining an AWS Organization or setting up an AWS Control Tower landing zone, your Free Tier credits expire immediately, and your account will be ineligible to earn more AWS Free Tier credits." — [AWS Free Tier FAQs](https://aws.amazon.com/free/free-tier-faqs/)

That route would destroy the balance this runbook exists to build.
