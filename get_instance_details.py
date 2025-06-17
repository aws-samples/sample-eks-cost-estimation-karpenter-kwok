#!/usr/bin/env python3
import argparse
import json
import subprocess
import sys
import re
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor, as_completed

def run_aws_command(command):
    """Run AWS CLI command and return the output as JSON"""
    try:
        result = subprocess.run(command, capture_output=True, text=True, check=True)
        return json.loads(result.stdout)
    except subprocess.CalledProcessError as e:
        print(f"Error executing AWS command: {e}", file=sys.stderr)
        print(f"Command output: {e.stderr}", file=sys.stderr)
        sys.exit(1)
    except json.JSONDecodeError as e:
        print(f"Error parsing AWS command output: {e}", file=sys.stderr)
        sys.exit(1)

def get_instance_types_for_family(region, instance_family):
    """Get all instance types for a given family in a region"""
    command = [
        "aws", "ec2", "describe-instance-types",
        "--region", region,
        "--filters", f"Name=instance-type,Values={instance_family}.*"
    ]
    
    result = run_aws_command(command)
    
    instance_types = [instance["InstanceType"] for instance in result.get("InstanceTypes", [])]
    
    if not instance_types:
        print(f"No instance types found for family {instance_family} in region {region}", file=sys.stderr)
    
    return instance_types

def get_instance_details(region, instance_type):
    """Get instance type details using AWS CLI"""
    command = [
        "aws", "ec2", "describe-instance-types",
        "--region", region,
        "--instance-types", instance_type
    ]
    
    result = run_aws_command(command)
    
    if not result.get("InstanceTypes"):
        print(f"Instance type {instance_type} not found in region {region}", file=sys.stderr)
        return None
    
    instance_info = result["InstanceTypes"][0]
    
    # Extract architecture
    architecture = instance_info.get("ProcessorInfo", {}).get("SupportedArchitectures", ["x86_64"])[0]
    # Convert x86_64 to amd64 for Kubernetes compatibility
    if architecture == "x86_64":
        architecture = "amd64"
    
    # Extract operating systems
    operating_systems = []
    if instance_info.get("SupportedPlatforms"):
        operating_systems = [platform.lower() for platform in instance_info.get("SupportedPlatforms")]
    else:
        # Default to linux if not specified
        operating_systems = ["linux"]
        # Check if Windows is supported
        if instance_info.get("HypervisorType") != "nitro" or "windows" in instance_info.get("ProcessorInfo", {}).get("SupportedArchitectures", []):
            operating_systems.append("windows")
    
    # Extract resources
    vcpu_count = str(instance_info.get("VCpuInfo", {}).get("DefaultVCpus", 0))
    memory_mib = instance_info.get("MemoryInfo", {}).get("SizeInMiB", 0)
    memory_gib = f"{memory_mib / 1024}Gi"
    max_pods = str(instance_info.get("NetworkInfo", {}).get("MaximumNetworkInterfaces", 8) * 10)  # Approximation
    
    resources = {
        "cpu": vcpu_count,
        "memory": memory_gib,
        "ephemeral-storage": "20Gi",  # Default value
        "pods": max_pods
    }
    
    return {
        "architecture": architecture,
        "operatingSystems": operating_systems,
        "resources": resources
    }

def get_spot_prices(region, instance_type):
    """Get spot prices for the instance type in all availability zones"""
    # Get current date in the required format using the non-deprecated approach
    import datetime
    current_time = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%S')
    
    command = [
        "aws", "ec2", "describe-spot-price-history",
        "--region", region,
        "--instance-types", instance_type,
        "--product-descriptions", "Linux/UNIX", "Windows",
        "--start-time", current_time,
        "--end-time", current_time
    ]
    
    # Use subprocess without shell=True
    try:
        result = subprocess.run(
            command,
            shell=False,
            capture_output=True,
            text=True,
            check=True
        )
        spot_data = json.loads(result.stdout)
    except subprocess.CalledProcessError as e:
        print(f"Error getting spot prices for {instance_type}: {e.stderr}", file=sys.stderr)
        return {}
    except json.JSONDecodeError as e:
        print(f"Error parsing spot price data for {instance_type}: {e}", file=sys.stderr)
        return {}
    
    prices_by_az = defaultdict(dict)
    for price_info in spot_data.get("SpotPriceHistory", []):
        az = price_info.get("AvailabilityZone")
        price = float(price_info.get("SpotPrice", 0))
        
        # Keep track of the lowest price for each AZ
        if az not in prices_by_az or price < prices_by_az[az].get("price", float('inf')):
            prices_by_az[az] = {
                "price": price,
                "available": True  # Assume available if price exists
            }
    
    return prices_by_az

def get_on_demand_price(region, instance_type):
    """Get on-demand price for the instance type"""
    # Map region to pricing region format
    region_mapping = {
        "us-east-1": "US East (N. Virginia)",
        "us-east-2": "US East (Ohio)",
        "us-west-1": "US West (N. California)",
        "us-west-2": "US West (Oregon)",
        "eu-west-1": "EU (Ireland)",
        "eu-central-1": "EU (Frankfurt)",
        "ap-northeast-1": "Asia Pacific (Tokyo)",
        "ap-southeast-1": "Asia Pacific (Singapore)",
        "ap-southeast-2": "Asia Pacific (Sydney)",
        "ap-south-1": "Asia Pacific (Mumbai)",
        "eu-west-2": "EU (London)",
        "eu-west-3": "EU (Paris)",
        "eu-north-1": "EU (Stockholm)",
        "sa-east-1": "South America (Sao Paulo)",
        "ca-central-1": "Canada (Central)",
        "ap-east-1": "Asia Pacific (Hong Kong)",
        "me-south-1": "Middle East (Bahrain)",
        "af-south-1": "Africa (Cape Town)",
        "eu-south-1": "EU (Milan)",
        # Add more mappings as needed
    }
    
    region_name = region_mapping.get(region, region)
    
    command = [
        "aws", "pricing", "get-products",
        "--service-code", "AmazonEC2",
        "--filters", 
        f"Type=TERM_MATCH,Field=instanceType,Value={instance_type}",
        f"Type=TERM_MATCH,Field=location,Value={region_name}",
        f"Type=TERM_MATCH,Field=operatingSystem,Value=Linux",
        f"Type=TERM_MATCH,Field=preInstalledSw,Value=NA",
        f"Type=TERM_MATCH,Field=tenancy,Value=Shared",
        f"Type=TERM_MATCH,Field=capacitystatus,Value=Used",
        "--region", "us-east-1"  # Pricing API is only available in us-east-1
    ]
    
    try:
        result = subprocess.run(command, capture_output=True, text=True, check=True)
        pricing_data = json.loads(result.stdout)
    except (subprocess.CalledProcessError, json.JSONDecodeError) as e:
        print(f"Error getting on-demand pricing for {instance_type}: {e}", file=sys.stderr)
        return None
    
    price = None
    for product in pricing_data.get("PriceList", []):
        try:
            product_data = json.loads(product)
            terms = product_data.get("terms", {}).get("OnDemand", {})
            for term_id, term_info in terms.items():
                for price_id, price_info in term_info.get("priceDimensions", {}).items():
                    price = float(price_info.get("pricePerUnit", {}).get("USD", 0))
                    return price
        except (json.JSONDecodeError, KeyError):
            continue
    
    return price

def get_availability_zones(region):
    """Get all availability zones in the region"""
    command = [
        "aws", "ec2", "describe-availability-zones",
        "--region", region
    ]
    
    result = run_aws_command(command)
    
    return [az["ZoneName"] for az in result.get("AvailabilityZones", [])]

def process_instance_type(region, instance_type, all_azs):
    """Process a single instance type and return its details"""
    print(f"Processing instance type: {instance_type}", file=sys.stderr)
    
    # Get instance details
    instance_details = get_instance_details(region, instance_type)
    if not instance_details:
        return None
    
    # Get spot prices by AZ
    spot_prices = get_spot_prices(region, instance_type)
    
    # Get on-demand price
    on_demand_price = get_on_demand_price(region, instance_type)
    
    # Build offerings array
    offerings = []
    
    # Add spot offerings for each AZ
    for az in all_azs:
        spot_info = spot_prices.get(az, {"price": None, "available": False})
        
        if spot_info["price"]:
            offerings.append({
                "Price": spot_info["price"],
                "Available": spot_info["available"],
                "Requirements": [
                    {
                        "key": "karpenter.sh/capacity-type",
                        "operator": "In",
                        "values": ["spot"]
                    },
                    {
                        "key": "topology.kubernetes.io/zone",
                        "operator": "In",
                        "values": [az]
                    }
                ]
            })
    
    # Add on-demand offering if price is available
    if on_demand_price:
        for az in all_azs:
            offerings.append({
                "Price": on_demand_price,
                "Available": True,
                "Requirements": [
                    {
                        "key": "karpenter.sh/capacity-type",
                        "operator": "In",
                        "values": ["on-demand"]
                    },
                    {
                        "key": "topology.kubernetes.io/zone",
                        "operator": "In",
                        "values": [az]
                    }
                ]
            })
    
    # Build final output
    return {
        "name": instance_type,
        "offerings": offerings,
        "architecture": instance_details["architecture"],
        "operatingSystems": instance_details["operatingSystems"],
        "resources": instance_details["resources"]
    }

def main():
    parser = argparse.ArgumentParser(description="Generate instance type details and pricing information")
    parser.add_argument("region", help="AWS region (e.g., us-west-2)")
    parser.add_argument("instance_families", nargs='+', help="AWS instance type families without sizes (e.g., g6 m5)")
    parser.add_argument("--output", "-o", default="instance_types.json", help="Output file path (default: instance_types.json)")
    parser.add_argument("--max-workers", "-w", type=int, default=5, help="Maximum number of worker threads (default: 5)")
    
    args = parser.parse_args()
    
    # Get all AZs in the region
    all_azs = get_availability_zones(args.region)
    
    # Collect all instance types for the specified families
    all_instance_types = []
    for family in args.instance_families:
        # Remove any size suffix if accidentally included
        family = re.sub(r'\.\d+.*$', '', family)
        instance_types = get_instance_types_for_family(args.region, family)
        all_instance_types.extend(instance_types)
    
    if not all_instance_types:
        print("No instance types found for the specified families", file=sys.stderr)
        sys.exit(1)
    
    print(f"Found {len(all_instance_types)} instance types to process", file=sys.stderr)
    
    # Process all instance types in parallel
    results = []
    with ThreadPoolExecutor(max_workers=args.max_workers) as executor:
        future_to_instance = {
            executor.submit(process_instance_type, args.region, instance_type, all_azs): instance_type
            for instance_type in all_instance_types
        }
        
        for future in as_completed(future_to_instance):
            instance_type = future_to_instance[future]
            try:
                result = future.result()
                if result:
                    results.append(result)
            except Exception as e:
                print(f"Error processing {instance_type}: {e}", file=sys.stderr)
    
    # Format JSON output
    formatted_output = json.dumps(results, indent=4)
    
    # Always write to file (default is instance_types.json)
    output_file = args.output
    with open(output_file, "w") as f:
        f.write(formatted_output)
    print(f"Output written to {output_file}")

if __name__ == "__main__":
    main()
