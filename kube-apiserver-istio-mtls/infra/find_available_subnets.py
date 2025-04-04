#!/usr/bin/env python3
import subprocess
import json
import sys
import ipaddress


def run_aws_cli(args, region):
    cmd = ["aws", "--region", region] + args
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        print(f"Error running aws {' '.join(cmd)}: {result.stderr}", file=sys.stderr)
        sys.exit(1)
    return json.loads(result.stdout)


def get_vpc_cidr(vpc_id, region):
    data = run_aws_cli(["ec2", "describe-vpcs", "--vpc-ids", vpc_id], region)
    try:
        cidr = data["Vpcs"][0]["CidrBlock"]
        return ipaddress.IPv4Network(cidr)
    except (KeyError, IndexError):
        print("Could not determine VPC CIDR", file=sys.stderr)
        sys.exit(1)


def get_existing_subnets(vpc_id, desired_mask, region):
    data = run_aws_cli(["ec2", "describe-subnets", "--filters", f"Name=vpc-id,Values={vpc_id}"], region)
    existing = []
    for subnet in data.get("Subnets", []):
        net = ipaddress.IPv4Network(subnet["CidrBlock"])
        if net.prefixlen == desired_mask:
            existing.append(net)
    return existing


def enumerate_possible_subnets(vpc_network, desired_mask):
    return list(vpc_network.subnets(new_prefix=desired_mask))


def main():
    if len(sys.argv) < 3:
        print("Usage: ./simplified_find_subnets.py <vpc-id> <region> [mask]", file=sys.stderr)
        sys.exit(1)

    vpc_id = sys.argv[1]
    region = sys.argv[2]
    desired_mask = int(sys.argv[3])

    vpc_network = get_vpc_cidr(vpc_id, region)
    print(f"VPC {vpc_id} CIDR: {vpc_network}")

    existing_subnets = get_existing_subnets(vpc_id, desired_mask, region)
    print(f"\nExisting /{desired_mask} subnets:")
    for net in existing_subnets:
        print(f"  {net}")

    possible_subnets = enumerate_possible_subnets(vpc_network, desired_mask)
    # Remove any subnet that overlaps with an existing one.
    available = [net for net in possible_subnets if not any(net.overlaps(ex) for ex in existing_subnets)]

    print(f"\nCandidate /{desired_mask} subnets available for use:")
    for net in available:
        print(f"  {net}")


if __name__ == "__main__":
    main()
