#!/bin/bash
set -e

GIT_COMMIT_SHORT=$(git rev-parse --short HEAD)
echo "ℹ️ Using Git commit hash for tagging: $GIT_COMMIT_SHORT"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
source ./config.sh
ECR_URL="$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/$REPO_NAME"
VPC_ID=""

if ! eksctl get cluster --region $REGION --name $CLUSTER_NAME >/dev/null 2>&1; then
  echo "📦 Creating EKS cluster..."
  eksctl create cluster -f cluster.yaml --approve
else
  echo "✅ EKS cluster $CLUSTER_NAME already exists. Skipping creation."
fi

echo "🔗 Creating OIDC provider (if not already exists)..."
eksctl utils associate-iam-oidc-provider \
  --region $REGION \
  --cluster $CLUSTER_NAME \
  --approve

echo "🛡️  Creating IAM policy for ALB controller..."
curl -s -o iam-policy.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json
aws iam create-policy \
  --policy-name $POLICY_NAME \
  --policy-document file://iam-policy.json || echo "✅ Policy already exists."

echo "🔧 Creating/Updating service account for ALB controller using config file..."
# Export variables for envsubst (ensure they are set)
export CLUSTER_NAME
export REGION
export SERVICE_ACCOUNT_NAME
export SERVICE_ACCOUNT_NAMESPACE
export ACCOUNT_ID
export POLICY_NAME

envsubst < iam_serviceaccount_alb.yaml > processed_iamserviceaccount_alb.yaml

eksctl create iamserviceaccount -f processed_iamserviceaccount_alb.yaml --approve
# The --override-existing-serviceaccounts flag is typically implied by applying a config.
# The --approve flag is retained for non-interactive mode.

echo "🚀 Installing AWS Load Balancer Controller..."
helm repo add eks https://aws.github.io/eks-charts
helm repo update

VPC_ID=$(aws eks describe-cluster \
  --name $CLUSTER_NAME \
  --region $REGION \
  --query "cluster.resourcesVpcConfig.vpcId" \
  --output text)

helm upgrade -i aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --create-namespace \
  --wait \
  -f alb_controller_values.yaml \
  --set clusterName=$CLUSTER_NAME \
  --set region=$REGION \
  --set vpcId=$VPC_ID \
  --set serviceAccount.name=$SERVICE_ACCOUNT_NAME

echo "🐳 Creating ECR repository (if not exists)..."
aws ecr describe-repositories --repository-names $REPO_NAME --output text || \
  aws ecr create-repository --repository-name $REPO_NAME --output text

echo "🔐 Logging into ECR..."
aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin "$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com"

echo "🔨 Building and pushing Docker image..."
docker buildx create --use || true
docker buildx build --platform linux/amd64 -t $ECR_URL:$GIT_COMMIT_SHORT ./app --push

if ! kubectl get secret my-app-secret >/dev/null 2>&1; then
  kubectl create secret generic my-app-secret --from-literal=apiKey=my-secret-key
else
  echo "✅ Kubernetes secret already exists. Skipping."
fi

echo "📦 Deploying app to Kubernetes with image tag: $GIT_COMMIT_SHORT..."
# Ensure variables are exported for envsubst
export ECR_URL
export REGION
export ACCOUNT_ID
export IMAGE_TAG=$GIT_COMMIT_SHORT # Set and export IMAGE_TAG

envsubst < app_deployment.yaml | kubectl apply -f -

echo "⏳ Waiting for ALB to be created..."
sleep 60

echo "🌍 Public URL:"
kubectl get ingress my-app-ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
echo -e "\n✅ Done!"