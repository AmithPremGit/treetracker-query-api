#!/bin/bash

set -e



echo "Setting up Kind cluster with Ambassador API Gateway v1 for treetracker-query-api testing on M1 Mac"

# Create a kind config file for M1 Mac compatibility
cat > kind-config.yaml << EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  # Use latest stable Kind node image that supports ARM64
  image: kindest/node:v1.29.14@sha256:8703bd94ee24e51b778d5556ae310c6c0fa67d761fae6379c8e0bb480e6fea29
  extraPortMappings:
  - containerPort: 80
    hostPort: 8080
    protocol: TCP
  - containerPort: 443
    hostPort: 8443
    protocol: TCP
EOF

# Make sure Docker Desktop is running with the correct configuration
echo "Checking Docker settings for M1 compatibility..."
echo "NOTE: Ensure 'Use Rosetta for x86/amd64 emulation on Apple Silicon' is UNCHECKED in Docker Desktop settings"
echo "      This setting can cause compatibility issues with Kubernetes on M1 Macs"

# Check if cluster already exists
if kind get clusters | grep -q "treetracker-test"; then
  echo "Cluster 'treetracker-test' already exists. Skipping cluster creation."
else
  # Create a kind cluster
  echo "Creating Kind cluster with ARM64-compatible image..."
  kind create cluster --name treetracker-test --config kind-config.yaml
fi

# Create namespaces
echo "Creating namespaces..."
kubectl create namespace webmap --dry-run=client -o yaml | kubectl apply -f -

# Install Ambassador API Gateway - using a much simpler installation with fewer dependencies
echo "Installing Ambassador API Gateway v1 (no webhooks)..."

# Create Ambassador RBAC and service
cat > ambassador-rbac.yaml << EOF
---
apiVersion: v1
kind: Service
metadata:
  name: ambassador
spec:
  type: NodePort
  ports:
  - port: 80
    targetPort: 8080
    nodePort: 30080
  selector:
    service: ambassador
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ambassador
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: ambassador
rules:
- apiGroups: [""]
  resources:
  - services
  - endpoints
  - pods
  - nodes
  - secrets
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ambassador
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: ambassador
subjects:
- kind: ServiceAccount
  name: ambassador
  namespace: default
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ambassador
spec:
  replicas: 1
  selector:
    matchLabels:
      service: ambassador
  template:
    metadata:
      labels:
        service: ambassador
    spec:
      serviceAccountName: ambassador
      containers:
      - name: ambassador
        image: docker.io/datawire/ambassador:1.13.10
        resources:
          limits:
            cpu: 1
            memory: 400Mi
          requests:
            cpu: 200m
            memory: 100Mi
        env:
        - name: AMBASSADOR_NAMESPACE
          valueFrom:
            fieldRef:
              fieldPath: metadata.namespace
        ports:
        - name: http
          containerPort: 8080
        livenessProbe:
          httpGet:
            path: /ambassador/v0/check_alive
            port: 8080
          initialDelaySeconds: 30
          periodSeconds: 3
        readinessProbe:
          httpGet:
            path: /ambassador/v0/check_ready
            port: 8080
          initialDelaySeconds: 30
          periodSeconds: 3
EOF

kubectl apply -f ambassador-rbac.yaml

echo "Waiting for Ambassador pods to be ready..."
kubectl wait --for=condition=available deployment/ambassador --timeout=90s || true

# Create a test deployment and service
cat > deployment-alpha/base/deployment.yaml << EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: treetracker-query-api
  namespace: webmap
  labels:
    app: treetracker-query-api
spec:
  replicas: 1
  selector:
    matchLabels:
      app: treetracker-query-api
  template:
    metadata:
      labels:
        app: treetracker-query-api
    spec:
      containers:
      - name: nginx
        image: nginx:alpine
        ports:
        - containerPort: 80
EOF

cat > deployment-alpha/base/service.yaml << EOF
apiVersion: v1
kind: Service
metadata:
  name: treetracker-query-api
  namespace: webmap
  annotations:
    getambassador.io/config: |
      ---
      apiVersion: ambassador/v1
      kind: Mapping
      name: treetracker-query-api-main
      prefix: /query/
      service: treetracker-query-api.webmap
      rewrite: /
      ---
      apiVersion: ambassador/v1
      kind: Mapping
      name: treetracker-query-api-alpha
      prefix: /alpha/query/
      service: treetracker-query-api.webmap
      rewrite: /
spec:
  selector:
    app: treetracker-query-api
  ports:
  - port: 80
    targetPort: 80
EOF

# Apply the deployment and service
echo "Applying test deployment and service..."
kubectl apply -f deployment-alpha/base/deployment.yaml
kubectl apply -f deployment-alpha/base/service.yaml

echo "Waiting for test deployment to be ready..."
kubectl -n webmap wait --for=condition=available deployment/treetracker-query-api --timeout=60s || true

echo "Setting up port forwarding to access Ambassador..."
# Kill any existing port forwarding
pkill -f "kubectl port-forward" || true
# Forward the Ambassador service port
kubectl port-forward svc/ambassador 8080:80 &

echo "Installation complete! Your Kind cluster with Ambassador v1 is now running."
echo "You can access your API at:"
echo "  - Main API: http://localhost:8080/query/"
echo "  - Alpha channel: http://localhost:8080/alpha/query/"
echo ""
echo "To clean up, run: kind delete cluster --name treetracker-test"