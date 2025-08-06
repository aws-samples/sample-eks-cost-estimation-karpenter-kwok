#!/bin/bash
aws iam create-role --role-name EC2EKSECRRole --assume-role-policy-document '{
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
}'

EKS_ALL_ACCESS_POLICY=$(echo '{
       "Version": "2012-10-17",
       "Statement": [
           {
               "Effect": "Allow",
               "Action": "eks:*",
               "Resource": "*"
           },
           {
               "Action": [
                   "ssm:GetParameter",
                   "ssm:GetParameters"
               ],
               "Resource": [
                   "arn:aws:ssm:*:'"${AWS_ACCOUNT_ID}"':parameter/aws/*",
                   "arn:aws:ssm:*::parameter/aws/*"
               ],
               "Effect": "Allow"
           },
           {
                "Action": [
                  "kms:CreateGrant",
                  "kms:DescribeKey"
                ],
                "Resource": "*",
                "Effect": "Allow"
           },
           {
                "Action": [
                  "logs:PutRetentionPolicy"
                ],
                "Resource": "*",
                "Effect": "Allow"
           }        
       ]
   }')
aws iam create-policy --policy-name EksAllAccess --policy-document "$EKS_ALL_ACCESS_POLICY"


# Attach the AWS managed policies to the role
aws iam attach-role-policy --role-name EC2EKSECRRole --policy-arn arn:aws:iam::${AWS_ACCOUNT_ID}:policy/EksAllAccess
aws iam attach-role-policy --role-name EC2EKSECRRole --policy-arn arn:aws:iam::aws:policy/AmazonEC2FullAccess
aws iam attach-role-policy --role-name EC2EKSECRRole --policy-arn arn:aws:iam::aws:policy/IAMFullAccess
aws iam attach-role-policy --role-name EC2EKSECRRole --policy-arn arn:aws:iam::aws:policy/AWSCloudFormationFullAccess
aws iam attach-role-policy --role-name EC2EKSECRRole --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryFullAccess
aws iam attach-role-policy --role-name EC2EKSECRRole --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess
aws iam attach-role-policy --role-name EC2EKSECRRole --policy-arn arn:aws:iam::aws:policy/AWSPriceListServiceFullAccess

# Create an instance profile and add the role to it
aws iam create-instance-profile --instance-profile-name EC2EKSECRProfile
aws iam add-role-to-instance-profile --instance-profile-name EC2EKSECRProfile --role-name EC2EKSECRRole


# Get the latest Amazon Linux 2023 AMI ID
AMI_ID=$(aws ec2 describe-images --owners amazon --filters "Name=name,Values=al2023-ami-2023.*-x86_64" "Name=state,Values=available" --query "sort_by(Images, &CreationDate)[-1].ImageId" --output text)

# Create a security group (adjust as needed for your VPC)
SG_ID=$(aws ec2 create-security-group --group-name EC2EKSAccess --description "Security group for EC2 with EKS access" --query 'GroupId' --output text)

# Add your own public IP addresses to restrict the access to the EC2 instance
aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port 22 --cidr 0.0.0.0/0

# Create a new key pair
KEY_PAIR_NAME=karpenter-kwok-key
aws ec2 create-key-pair --key-name $KEY_PAIR_NAME --query 'KeyMaterial' --output text > $KEY_PAIR_NAME.pem

# Set proper permissions on the key file
chmod 400 $KEY_PAIR_NAME.pem


export INSTANCE_ID=$(aws ec2 run-instances \
  --image-id $AMI_ID \
  --instance-type t3.xlarge \
  --iam-instance-profile Name=EC2EKSECRProfile \
  --security-group-ids $SG_ID \
  --key-name $KEY_PAIR_NAME \
  --block-device-mappings "[{\"DeviceName\":\"/dev/xvda\",\"Ebs\":{\"VolumeSize\":100,\"VolumeType\":\"gp3\"}}]" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=karpenter-kwok-build-instance}]" \
  --query 'Instances[0].InstanceId' \
  --output text)

INSTANCE_DNS=$(aws ec2 describe-instances --instance-ids $INSTANCE_ID --query "Reservations[0].Instances[0].PublicDnsName" --output text)
