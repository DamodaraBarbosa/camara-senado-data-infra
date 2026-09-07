"""Weekly month-to-date AWS cost report for the data platform.

Publishes two numbers the Billing console does not show side by side: what the
account actually consumed, and how much of that a Free Tier credit absorbed.
Between July and September 2026 those were USD 22.57 and USD -22.57 — the net
was always zero, so nothing ever looked wrong until the credits ran out.

Cost control is a design constraint here, not an afterthought. The Cost
Explorer API bills USD 0.01 per request and is the only recurring cost of this
function, so it makes exactly ONE call per report: Cost Explorer accepts two
GroupBy dimensions per request, and SERVICE x RECORD_TYPE yields both the
per-service breakdown and the usage-vs-credit split from a single call.

The function URL (required by the Free Tier "web app" activity, and useful on
its own as an on-demand "what am I spending" endpoint) is guarded by a warm
container cache: without it, refreshing the page ten times would cost USD 0.10.
"""

import datetime as dt
import os
import time

import boto3

SNS_TOPIC_ARN = os.environ["SNS_TOPIC_ARN"]
CACHE_TTL_SECONDS = int(os.environ.get("CACHE_TTL_SECONDS", "3600"))

ce = boto3.client("ce")
sns = boto3.client("sns")

# Credits and refunds are the record types that make a bill look free.
_NOT_A_CHARGE = ("Credit", "Refund")

# Warm-container cache: (fetched_at, payload). Reset on every cold start.
_cache = None


def _month_to_date():
    """Cost Explorer treats End as exclusive, so today+1 is what includes today."""
    today = dt.date.today()
    return today.replace(day=1).isoformat(), (today + dt.timedelta(days=1)).isoformat()


def _fetch(start, end):
    """One Cost Explorer call, grouped by service AND record type."""
    response = ce.get_cost_and_usage(
        TimePeriod={"Start": start, "End": end},
        Granularity="MONTHLY",
        Metrics=["UnblendedCost"],
        GroupBy=[
            {"Type": "DIMENSION", "Key": "SERVICE"},
            {"Type": "DIMENSION", "Key": "RECORD_TYPE"},
        ],
    )

    by_service = {}
    by_record_type = {}
    for result in response["ResultsByTime"]:
        for group in result["Groups"]:
            service, record_type = group["Keys"]
            amount = float(group["Metrics"]["UnblendedCost"]["Amount"])
            by_record_type[record_type] = by_record_type.get(record_type, 0.0) + amount
            if record_type not in _NOT_A_CHARGE:
                by_service[service] = by_service.get(service, 0.0) + amount

    return by_service, by_record_type


def _fetch_cached(start, end):
    global _cache
    now = time.monotonic()
    if _cache is not None and now - _cache[0] < CACHE_TTL_SECONDS:
        return _cache[1]
    payload = _fetch(start, end)
    _cache = (now, payload)
    return payload


def _render(start, end, by_service, by_record_type):
    usage = sum(v for k, v in by_record_type.items() if k not in _NOT_A_CHARGE)
    credit = sum(v for k, v in by_record_type.items() if k in _NOT_A_CHARGE)

    # Credito e uso se cancelam ate o ultimo centavo enquanto a cobertura dura,
    # e o residuo em ponto flutuante imprime "-0.00", que parece defeito.
    net = usage + credit
    if abs(net) < 0.005:
        net = 0.0

    lines = [
        f"AWS cost report - {start} to {end}",
        "",
        f"  Billable usage : USD {usage:9.2f}",
        f"  Credit applied : USD {credit:9.2f}",
        f"  You pay        : USD {net:9.2f}",
        "",
        "By service (credits and refunds excluded):",
    ]

    services = sorted(
        ((v, k) for k, v in by_service.items() if v > 0.001), reverse=True
    )
    lines += [f"  USD {amount:9.2f}  {name}" for amount, name in services]
    if not services:
        lines.append("  (no billable usage yet this month)")

    if credit < -0.001:
        lines += [
            "",
            "The line above is covered by Free Tier credit, not by being free.",
            "Credits expire 12 months after the account was opened.",
        ]

    return "\n".join(lines)


def lambda_handler(event, context):
    start, end = _month_to_date()
    by_service, by_record_type = _fetch_cached(start, end)
    report = _render(start, end, by_service, by_record_type)

    # A function URL request carries requestContext.http; a scheduled
    # EventBridge invocation does not. Only the schedule sends email — an HTTP
    # caller is already looking at the answer.
    is_http = "http" in event.get("requestContext", {})
    if is_http:
        return {
            "statusCode": 200,
            "headers": {"content-type": "text/plain; charset=utf-8"},
            "body": report,
        }

    sns.publish(
        TopicArn=SNS_TOPIC_ARN,
        Subject=f"[prod] AWS cost report - {start[:7]}",
        Message=report,
    )
    return {"statusCode": 200, "body": report}
