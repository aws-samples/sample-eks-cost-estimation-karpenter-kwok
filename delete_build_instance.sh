#!/bin/bash
set -e

echo "Starting cleanup of resources created by build_instance_create.sh..."

# Set AWS account ID
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "Using AWS Account ID: $AWS_ACCOUNT_ID"

# Find and terminate the EC2 instance
echo "Looking for EC2 instance with tag 'karpenter-kwok-build-instance'..."
INSTANCE_ID=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=karpenter-kwok-build-instance" "Name=instance-state-name,Values=running,stopped,pending,stopping" --query "Reservations[*].Instances[*].InstanceId" --output text)

if [ -n "$INSTANCE_ID" ]; then
    echo "Terminating EC2 instance: $INSTANCE_ID"
    aws ec2 terminate-instances --instance-ids $INSTANCE_ID
    echo "Waiting for instance to terminate..."
    aws ec2 wait instance-terminated --instance-ids $INSTANCE_ID
    echo "Instance terminated successfully."
else
    echo "No running instance with tag 'karpenter-kwok-build-instance' found."
fi

# Delete the key pair
KEY_PAIR_NAME=karpenter-kwok-key
echo "Deleting key pair: $KEY_PAIR_NAME"
aws ec2 delete-key-pair --key-name $KEY_PAIR_NAME
rm -f $KEY_PAIR_NAME.pem
echo "Key pair deleted."

# Delete the security group
echo "Looking for security group 'EC2EKSAccess'..."
SG_ID=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=EC2EKSAccess" --query "SecurityGroups[*].GroupId" --output text)

if [ -n "$SG_ID" ]; then
    echo "Deleting security group: $SG_ID"
    # Wait a bit to ensure the instance is fully terminated and the security group is no longer in use
    sleep 10
    aws ec2 delete-security-group --group-id $SG_ID
    echo "Security group deleted."
else
    echo "Security group 'EC2EKSAccess' not found."
fi

# Remove role from instance profile
echo "Removing role from instance profile..."
aws iam remove-role-from-instance-profile --instance-profile-name EC2EKSECRProfile --role-name EC2EKSECRRole || echo "Role may already be removed from instance profile."

# Delete the instance profile
echo "Deleting instance profile: EC2EKSECRProfile"
aws iam delete-instance-profile --instance-profile-name EC2EKSECRProfile || echo "Instance profile may not exist."

# Detach all managed policies from the role
echo "Detaching all managed policies from role EC2EKSECRRole..."
POLICIES=$(aws iam list-attached-role-policies --role-name EC2EKSECRRole --query 'AttachedPolicies[*].PolicyArn' --output text)

if [ -n "$POLICIES" ]; then
    # Convert tabs to newlines and process each line
    echo "$POLICIES" | tr '\t' '\n' | while read -r POLICY_ARN; do
        echo "Detaching policy: $POLICY_ARN"
        aws iam detach-role-policy --role-name EC2EKSECRRole --policy-arn "$POLICY_ARN"
    done
else
    echo "No managed policies attached to EC2EKSECRRole."
fi

# Remove all inline policies from the role
echo "Removing all inline policies from role EC2EKSECRRole..."
INLINE_POLICIES=$(aws iam list-role-policies --role-name EC2EKSECRRole --query 'PolicyNames' --output text)

if [ -n "$INLINE_POLICIES" ]; then
    for POLICY_NAME in $INLINE_POLICIES; do
        echo "Deleting inline policy: $POLICY_NAME"
        aws iam delete-role-policy --role-name EC2EKSECRRole --policy-name $POLICY_NAME
    done
else
    echo "No inline policies in EC2EKSECRRole."
fi

# Delete the custom policy
echo "Deleting custom policy: EksAllAccess"
aws iam delete-policy --policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/EksAllAccess" || echo "Policy may not exist."

# Delete the role
echo "Deleting role: EC2EKSECRRole"
aws iam delete-role --role-name EC2EKSECRRole || echo "Role may not exist."

echo "Cleanup complete!"
