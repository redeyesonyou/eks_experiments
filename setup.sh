#!/bin/bash
set -e

CLUSTER_NAME="test-eks-auto"
REGION="eu-west-2"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REPO_NAME="my-app"
ECR_URL="$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/$REPO_NAME"
VPC_ID=""
POLICY_NAME="AWSLoadBalancerControllerIAMPolicy"
SERVICE_ACCOUNT_NAME="aws-load-balancer-controller"
SERVICE_ACCOUNT_NAMESPACE="kube-system"

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

echo "🔧 Creating service account for ALB controller..."
eksctl create iamserviceaccount \
  --cluster $CLUSTER_NAME \
  --region $REGION \
  --namespace $SERVICE_ACCOUNT_NAMESPACE \
  --name $SERVICE_ACCOUNT_NAME \
  --attach-policy-arn arn:aws:iam::$ACCOUNT_ID:policy/$POLICY_NAME \
  --approve \
  --override-existing-serviceaccounts

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
  --set clusterName=$CLUSTER_NAME \
  --set region=$REGION \
  --set vpcId=$VPC_ID \
  --set serviceAccount.create=false \
  --set serviceAccount.name=$SERVICE_ACCOUNT_NAME

echo "🐳 Creating ECR repository (if not exists)..."
aws ecr describe-repositories --repository-names $REPO_NAME --output text || \
  aws ecr create-repository --repository-name $REPO_NAME --output text

echo "🔐 Logging into ECR..."
aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin "$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com"

echo "🔨 Building and pushing Docker image..."
docker buildx create --use || true
docker buildx build --platform linux/amd64 -t $ECR_URL:latest ./app --push

if ! kubectl get secret my-app-secret >/dev/null 2>&1; then
  kubectl create secret generic my-app-secret --from-literal=apiKey=my-secret-key
else
  echo "✅ Kubernetes secret already exists. Skipping."
fi

echo "📦 Deploying app to Kubernetes..."
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-app
spec:
  replicas: 2
  selector:
    matchLabels:
      app: my-app
  template:
    metadata:
      labels:
        app: my-app
    spec:
      containers:
        - name: my-app
          image: $ECR_URL:latest
          ports:
            - containerPort: 80
          env:
            - name: ENVIRONMENT
              value: "production"
            - name: API_KEY
              valueFrom:
                secretKeyRef:
                  name: my-app-secret
                  key: apiKey
---
apiVersion: v1
kind: Service
metadata:
  name: my-app-service
spec:
  selector:
    app: my-app
  ports:
    - port: 80
      targetPort: 80
  type: NodePort
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-app-ingress
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    # Update the ACM certificate ARN and domain name as needed
    alb.ingress.kubernetes.io/certificate-arn: arn:aws:acm:$REGION:$ACCOUNT_ID:certificate/your-cert-id
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTPS": 443}]'
spec:
  ingressClassName: alb
  rules:
    - http:
        paths:
        - path: /
          pathType: Prefix
          backend:
            service:
              name: my-app-service
              port:
                number: 80
EOF

echo "⏳ Waiting for ALB to be created..."
sleep 60

echo "🌍 Public URL:"
kubectl get ingress my-app-ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
echo -e "\n✅ Done!"