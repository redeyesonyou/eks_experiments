#!/bin/bash
set -e

# Script to create or delete an EKS cluster and associated resources,
# and deploy or remove a sample application.
#
# Actions:
#   create: Sets up the EKS cluster, IAM roles, ECR repository,
#           builds/pushes a Docker image, and deploys the application. (Default)
#   delete: Tears down the resources created by the 'create' action.
#
# Usage:
#   ./setup.sh [options]
#   For detailed options, run: ./setup.sh --help
#
# Configuration:
#   Default values for cluster name, region, ECR repo name, and other
#   settings are sourced from 'config.sh'. These can be overridden by
#   command-line arguments where applicable.
#
# Key parameters (see --help for all):
#   --action <create|delete>
#   --cluster-name <name>
#   --region <aws-region>
#   --image-tag <tag>
#   --ecr-repo-name <name>
#   --delete-ecr-repo (with --action delete)
#

# Default values for arguments
ARG_ACTION="create"
ARG_CLUSTER_NAME="" # Will be overridden by config.sh or args
ARG_REGION=""       # Will be overridden by config.sh or args
ARG_IMAGE_TAG=""    # Will be overridden by git hash or args
ARG_ECR_REPO_NAME="" # Will be overridden by config.sh or args
ARG_DELETE_ECR_REPO=false

usage() {
  echo "Usage: $0 [options]"
  echo "Options:"
  echo "  -a, --action <create|delete|delete-all> Action to perform (default: create)"
  echo "  -c, --cluster-name <name>       EKS cluster name (overrides config.sh)"
  echo "  -r, --region <region>           AWS region (overrides config.sh)"
  echo "  -t, --image-tag <tag>           Docker image tag (overrides git commit hash)"
  echo "  -e, --ecr-repo-name <name>      ECR repository name (overrides config.sh)"
  echo "      --delete-ecr-repo           Enable ECR repository deletion (used with --action delete)"
  echo "  -h, --help                      Display this help message"
  exit 1
}

GIT_COMMIT_SHORT=$(git rev-parse --short HEAD)
# The echo for GIT_COMMIT_SHORT will be part of the IMAGE_TAG determination logic later

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
source ./config.sh # Load defaults from config file first

# Initialize ARG_ variables with values from config.sh
ARG_CLUSTER_NAME="$CLUSTER_NAME"
ARG_REGION="$REGION"
ARG_ECR_REPO_NAME="$REPO_NAME"
# ARG_IMAGE_TAG is handled after parsing, defaulting to GIT_COMMIT_SHORT

# Temp variables for getopts
TEMP_ACTION=""
TEMP_CLUSTER_NAME=""
TEMP_REGION=""
TEMP_IMAGE_TAG=""
TEMP_ECR_REPO_NAME=""
TEMP_DELETE_ECR_REPO=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    -a|--action)
      TEMP_ACTION="$2"
      shift 2
      ;;
    -c|--cluster-name)
      TEMP_CLUSTER_NAME="$2"
      shift 2
      ;;
    -r|--region)
      TEMP_REGION="$2"
      shift 2
      ;;
    -t|--image-tag)
      TEMP_IMAGE_TAG="$2"
      shift 2
      ;;
    -e|--ecr-repo-name)
      TEMP_ECR_REPO_NAME="$2"
      shift 2
      ;;
    --delete-ecr-repo)
      TEMP_DELETE_ECR_REPO=true
      shift 1
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo "Unknown option: $1"
      usage
      ;;
  esac
done

# Apply parsed arguments, overriding config.sh values if arguments were provided
if [[ ! -z "$TEMP_ACTION" ]]; then
  if [[ "$TEMP_ACTION" == "delete-all" ]]; then
    ARG_ACTION="delete"
    ARG_DELETE_ECR_REPO=true # Explicitly set ECR repo deletion for delete-all
    echo "ℹ️ '--action delete-all' received. Will delete all resources including ECR repository."
  else
    ARG_ACTION="$TEMP_ACTION"
  fi
fi

# Apply other TEMP variables to ARG variables
if [[ ! -z "$TEMP_CLUSTER_NAME" ]]; then
  ARG_CLUSTER_NAME="$TEMP_CLUSTER_NAME"
fi
if [[ ! -z "$TEMP_REGION" ]]; then
  ARG_REGION="$TEMP_REGION"
fi
if [[ ! -z "$TEMP_IMAGE_TAG" ]]; then
  ARG_IMAGE_TAG="$TEMP_IMAGE_TAG"
fi
if [[ ! -z "$TEMP_ECR_REPO_NAME" ]]; then
  ARG_ECR_REPO_NAME="$TEMP_ECR_REPO_NAME"
fi

# This handles the --delete-ecr-repo flag if 'delete-all' wasn't used
# If 'delete-all' was used, ARG_DELETE_ECR_REPO is already true.
if [[ "$TEMP_DELETE_ECR_REPO" = true ]]; then
  ARG_DELETE_ECR_REPO=true
  if [[ "$TEMP_ACTION" != "delete-all" ]]; then # Avoid double message
      echo "ℹ️ '--delete-ecr-repo' flag received. ECR repository will be targeted for deletion if action is 'delete'."
  fi
fi

# Validate action (now only 'create' or 'delete' are valid for ARG_ACTION)
if [[ "$ARG_ACTION" != "create" && "$ARG_ACTION" != "delete" ]]; then
  echo "Error: Invalid action '$TEMP_ACTION' provided for --action. Must be 'create', 'delete', or 'delete-all'."
  usage
fi

# Update script variables (CLUSTER_NAME, REGION, etc.) to use ARG_ values
CLUSTER_NAME="$ARG_CLUSTER_NAME"
REGION="$ARG_REGION"
REPO_NAME="$ARG_ECR_REPO_NAME"
# POLICY_NAME, SERVICE_ACCOUNT_NAME, SERVICE_ACCOUNT_NAMESPACE remain from config.sh

# Set IMAGE_TAG based on ARG_IMAGE_TAG or GIT_COMMIT_SHORT
if [[ ! -z "$ARG_IMAGE_TAG" ]]; then
  IMAGE_TAG="$ARG_IMAGE_TAG"
  echo "ℹ️ Using provided image tag: $IMAGE_TAG"
else
  IMAGE_TAG="$GIT_COMMIT_SHORT"
  echo "ℹ️ Using Git commit hash as image tag: $IMAGE_TAG"
fi
export IMAGE_TAG # Ensure it's exported for envsubst later

# Re-calculate ECR_URL as REPO_NAME or REGION might have changed.
ECR_URL="$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/$REPO_NAME"

delete_cluster_resources() {
  echo "🔥 Starting resource deletion for cluster: $CLUSTER_NAME in region: $REGION..."

  # 1. Delete Kubernetes application resources (Ingress, Service, Deployment)
  #    These are defined in app_deployment.yaml. We need to template it and then delete.
  echo "🗑️ Deleting Kubernetes application resources (Deployment, Service, Ingress)..."
  if (export ECR_URL && export REGION && export ACCOUNT_ID && export IMAGE_TAG && envsubst < app_deployment.yaml | kubectl delete -f - --ignore-not-found=true); then
    echo "✅ Kubernetes application resources deleted or did not exist."
  else
    echo "⚠️  Could not delete all Kubernetes application resources. Manual check may be required."
  fi
  # Add a sleep to allow resources (like ALBs) to be de-registered by controller
  echo "⏳ Waiting for ALB resources to be potentially de-registered (60s)..."
  sleep 60

  # 2. Uninstall AWS Load Balancer Controller Helm chart
  echo "🗑️ Uninstalling AWS Load Balancer Controller Helm chart..."
  if (helm uninstall aws-load-balancer-controller -n kube-system --wait); then
    echo "✅ AWS Load Balancer Controller Helm chart uninstalled."
  else
    echo "⚠️  AWS Load Balancer Controller Helm chart uninstallation failed or chart not found. Manual check may be required."
  fi
  # Optionally delete the namespace if it was created by helm and is now empty
  # kubectl delete namespace kube-system --ignore-not-found=true (Risky if other things are there)
  # For now, let's skip deleting the kube-system namespace as it's standard.

  # 3. Delete IAM Service Account for ALB Controller
  #    We can use the processed iamserviceaccount_alb.yaml or direct eksctl command.
  #    Using the file is more consistent if eksctl supports `delete -f`.
  #    `eksctl delete iamserviceaccount --config-file <file>` is the way.
  echo "🗑️ Deleting IAM service account for ALB controller..."
  # Ensure variables are exported for envsubst
  export CLUSTER_NAME
  export REGION
  export SERVICE_ACCOUNT_NAME
  export SERVICE_ACCOUNT_NAMESPACE
  export ACCOUNT_ID
  export POLICY_NAME
  envsubst < iam_serviceaccount_alb.yaml > processed_iamserviceaccount_alb_for_delete.yaml
  if (eksctl delete iamserviceaccount -f processed_iamserviceaccount_alb_for_delete.yaml --wait); then
    echo "✅ IAM service account $SERVICE_ACCOUNT_NAME deleted."
    rm processed_iamserviceaccount_alb_for_delete.yaml # Clean up temp file
  else
    echo "⚠️  IAM service account $SERVICE_ACCOUNT_NAME deletion failed or not found. Manual check may be required."
    rm processed_iamserviceaccount_alb_for_delete.yaml # Still attempt cleanup
  fi

  # 4. Delete IAM Policy for ALB Controller
  echo "🗑️ Deleting IAM policy $POLICY_NAME..."
  # Detach policy from roles first (though eksctl *should* handle this for the SA role)
  # Listing roles attached to policy: aws iam list-entities-for-policy --policy-arn arn:aws:iam::$ACCOUNT_ID:policy/$POLICY_NAME
  # For simplicity, we assume eksctl/AWS handles detachment correctly when SA/roles are deleted.
  if (aws iam delete-policy --policy-arn arn:aws:iam::$ACCOUNT_ID:policy/$POLICY_NAME); then
    echo "✅ IAM policy $POLICY_NAME deleted."
  else
    # It's common for this to fail if it's attached to something eksctl didn't clean up, or if it doesn't exist.
    echo "⚠️  IAM policy $POLICY_NAME deletion failed. It might not exist or still be attached. Manual check may be required."
  fi

  # 5. Delete EKS Cluster
  #    eksctl delete cluster will use the cluster name and region.
  #    It can also take the original cluster.yaml via -f if preferred.
  echo "🗑️ Deleting EKS cluster $CLUSTER_NAME..."
  if (eksctl delete cluster --name "$CLUSTER_NAME" --region "$REGION" --wait); then # eksctl prompts for confirmation by default
    echo "✅ EKS cluster $CLUSTER_NAME deleted."
  else
    echo "❌ EKS cluster $CLUSTER_NAME deletion failed. Manual intervention required."
    # Exit here as further steps might depend on this. Or let it continue if ECR deletion is independent.
    # For now, let's inform and continue to ECR step.
  fi

  # 6. Delete ECR Repository (conditional)
  if [[ "$ARG_DELETE_ECR_REPO" = true ]]; then
    echo "🗑️ Deleting ECR repository $REPO_NAME..."
    # aws ecr delete-repository requires the repository to be empty or --force.
    # --force will delete images first.
    if (aws ecr delete-repository --repository-name "$REPO_NAME" --region "$REGION" --force); then
      echo "✅ ECR repository $REPO_NAME deleted."
    else
      echo "⚠️  ECR repository $REPO_NAME deletion failed. It might not exist or an error occurred."
    fi
  else
    echo "ℹ️ Skipping ECR repository $REPO_NAME deletion as --delete-ecr-repo was not specified."
  fi

  echo "✅ Resource deletion process complete."
}

if [[ "$ARG_ACTION" = "create" ]]; then
  echo "🚀 Starting 'create' action..."

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
  rm processed_iamserviceaccount_alb.yaml
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
  docker buildx build --platform linux/amd64 -t $ECR_URL:$IMAGE_TAG ./app --push

  if ! kubectl get secret my-app-secret >/dev/null 2>&1; then
    kubectl create secret generic my-app-secret --from-literal=apiKey=my-secret-key
  else
    echo "✅ Kubernetes secret already exists. Skipping."
  fi

  echo "📦 Deploying app to Kubernetes with image tag: $IMAGE_TAG..."
  # Ensure variables are exported for envsubst
  export ECR_URL # Already exported if using the new ECR_URL definition
  export REGION # Already exported if using the new REGION definition
  export ACCOUNT_ID # Already exported
  # IMAGE_TAG is already exported by the new logic

  envsubst < app_deployment.yaml | kubectl apply -f -

  echo "⏳ Waiting for ALB to be created..."
  sleep 60

  echo "🌍 Public URL:"
  kubectl get ingress my-app-ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
  echo -e "\n✅ 'create' action complete!"

elif [[ "$ARG_ACTION" = "delete" ]]; then
  echo "🚀 Starting 'delete' action..."
  delete_cluster_resources # Call the function defined in the previous step
  echo -e "\n✅ 'delete' action complete!"

else
  # This case should ideally be caught by argument validation earlier,
  # but as a fallback:
  echo "Error: Unknown action '$ARG_ACTION'."
  usage
fi