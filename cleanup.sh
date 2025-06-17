aws iam delete-user-policy --user-name velero --policy-name velero &&
aws iam delete-access-key --user-name velero --access-key-id $(aws iam list-access-keys --user-name velero --query 'AccessKeyMetadata[0].AccessKeyId' --output text) &&
aws iam delete-user --user-name velero &&
kubectl delete deployment --all -A &&
eksctl delete cluster --name=$DESTINATION_CLUSTER_NAME --region $AWS_DEFAULT_REGION --force &&
aws eks --region $AWS_DEFAULT_REGION update-kubeconfig --name $SOURCE_CLUSTER_NAME &&
kubectl delete deployment --all -A &&
eksctl delete cluster --name=$SOURCE_CLUSTER_NAME --region $AWS_DEFAULT_REGION --force &&
aws ecr delete-repository --repository-name $KWOK_DOCKER_REPO --force &&
aws s3 rb s3://$VELERO_BUCKET --force
