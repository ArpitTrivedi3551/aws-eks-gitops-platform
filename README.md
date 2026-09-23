This is a private-first, multi-AZ platform on AWS. It runs Spring PetClinic on EKS,
ships it with GitHub Actions + Argo CD (GitOps) and Argo Rollouts (canary), stores its
secrets in AWS Secrets Manager, encrypts with KMS, and is watched by Prometheus, Grafana
and Loki. Everything below is what I actually did to build it, in order, with the exact
commands. Where something broke, I've left the fix in — because it will break the same way
for the next person.

A note on how I run this: the EKS control plane, NAT gateway and Multi-AZ RDS cost real
money (~$6-7/day together), so I provision it, demonstrate it, take screenshots, and
destroy it. This repo is the source of truth for how it's built, not a claim that it's
running right now.

Account/region I used: 672937918844 / us-east-1. Cluster name: senior-devops-staging-eks.
Adjust these to your own.

## What's in the repo

- infra/ — Terraform. Reusable modules (network, database, eks) and a staging env that
  wires them together with remote state.
- gitops/ — the Kubernetes manifests Argo CD syncs: the PetClinic Rollout, Service,
  Ingress, the External Secret, the canary AnalysisTemplate, and the Argo CD Application.
- monitoring/ — the Grafana dashboard JSON and the Prometheus alert/error-budget rules.
- scripts/ — the S3 sync automation (Part 6.1).
- docs/ — architecture diagrams, the technical design, the Istio debug runbook (6.2), and
  the error-budget policy.

## Architecture 

One VPC, three tiers across two availability zones. Public subnets hold only the ALB, the
NAT gateway and a bastion. Private "app" subnets hold the EKS worker nodes. Private "data"
subnets hold RDS, with no internet route at all. Nothing reaches the nodes or the database
directly from the internet: traffic comes through the ALB, admin comes through the bastion
(or SSM), and the nodes reach out for image pulls via NAT. RDS runs Multi-AZ so it fails
over on its own. Diagrams are in docs/architecture.md.

## Prerequisites (tools I installed)

```bash
# kubectl
curl -LO "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

# helm
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# eksctl (used only for IRSA service accounts)
curl -sL "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_Linux_amd64.tar.gz" | tar xz
sudo mv eksctl /usr/local/bin/

# AWS Session Manager plugin (to reach the bastion without SSH keys)
curl "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_64bit/session-manager-plugin.deb" -o smp.deb
sudo dpkg -i smp.deb
```

You also need the AWS CLI configured (`aws configure`) and Terraform >= 1.5.

## Part 1 - Infrastructure with Terraform

### State backend (once, by hand)

Terraform can't manage the bucket that stores its own state, so I create that bucket and a
DynamoDB lock table manually before the first init.

```bash
export AWS_REGION=us-east-1
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export TF_BUCKET="terraform-backend-tfstate-${ACCOUNT_ID}"
export TF_LOCK_TABLE="backend-tf-locks"

aws s3api create-bucket --bucket "$TF_BUCKET" --region "$AWS_REGION"
aws s3api put-bucket-versioning --bucket "$TF_BUCKET" --versioning-configuration Status=Enabled
aws dynamodb create-table --table-name "$TF_LOCK_TABLE" \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST --region "$AWS_REGION"
```

The lock table's partition key must literally be called LockID - that's a requirement of
the Terraform S3 backend, not something you look up.

### Configure and apply

```bash
cd infrastaging          # my working copy was ~/TalkingLand/infra/staging
cp backend.tfbackend.example backend.tfbackend   # fill in the bucket + lock table
cp terraform.tfvars.example terraform.tfvars     # set admin_cidr to my IP: curl -s ifconfig.me

terraform init -backend-config=backend.tfbackend
terraform fmt -recursive
terraform validate
terraform plan
terraform apply
```

admin_cidr has no default and rejects 0.0.0.0/0 on purpose - the bastion and the EKS public
API endpoint are both locked to my own IP. If my home IP changes I update it and re-apply.

The apply builds the VPC, subnets, IGW, one NAT gateway (there's a flag to make it one per
AZ for real HA - I run one to save money and document that trade-off), the bastion, the KMS
key, RDS Multi-AZ, and the EKS cluster + node group.

### Prove the private path works

```bash
terraform output                                 
aws ssm start-session --target <bastion-instance-id>

# on the bastion (psql is pre-installed by user-data):
# the bastion isn't allowed to read the secret (least privilege), so I fetched the
# password on my laptop and pasted it, or read it locally:
aws secretsmanager get-secret-value --secret-id tgo-staging-db-credentials \
  --region us-east-1 --query SecretString --output text | jq -r '.host,.username,.password'

PGPASSWORD='<password>' psql -h <rds_endpoint> -U petclinic -d petclinic -c '\l'
```

Seeing the database list from the bastion proves the whole chain: bastion in a public
subnet -> RDS in a private subnet with no internet route -> credentials from Secrets
Manager -> KMS-encrypted storage.

### Connect kubectl

```bash
aws eks update-kubeconfig --name tgo-staging-eks --region us-east-1
kubectl get nodes            
```

## Part 2 (part 1) - cluster add-ons

These only exist on a live cluster, so they come after the apply. I ran them one at a time
and checked each before the next.

```bash
eksctl utils associate-iam-oidc-provider --cluster tgo-staging-eks --approve
```

### AWS Load Balancer Controller (turns an Ingress into a real ALB)

```bash
curl -sO https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json
aws iam create-policy --policy-name AWSLoadBalancerControllerIAMPolicy --policy-document file://iam_policy.json

eksctl create iamserviceaccount \
  --cluster tgo-staging-eks --namespace kube-system \
  --name aws-load-balancer-controller \
  --attach-policy-arn arn:aws:iam::672937918844:policy/AWSLoadBalancerControllerIAMPolicy \
  --approve --override-existing-serviceaccounts

helm repo add eks https://aws.github.io/eks-charts && helm repo update
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=tgo-staging-eks \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller
```

This crash-looped for me. The logs said "failed to fetch VPC ID from instance metadata:
context deadline exceeded" - the controller tries to auto-discover the VPC by calling the
node's metadata service, and my nodes enforce IMDSv2 with a restricted hop limit, so the
pod couldn't reach it. Fix: tell it the VPC and region explicitly instead of guessing.

```bash
helm upgrade aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=tgo-staging-eks \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set region=us-east-1 \
  --set vpcId=vpc-02282d4baf6fb2f2d
kubectl -n kube-system rollout status deploy/aws-load-balancer-controller
```

### External Secrets Operator (DB creds from Secrets Manager into the pods)

```bash
cat > eso-policy.json <<'JSON'
{ "Version":"2012-10-17","Statement":[
  {"Effect":"Allow","Action":["secretsmanager:GetSecretValue","secretsmanager:DescribeSecret"],
   "Resource":"arn:aws:secretsmanager:us-east-1:672937918844:secret:tgo-staging-db-credentials*"},
  {"Effect":"Allow","Action":["kms:Decrypt"],
   "Resource":"arn:aws:kms:us-east-1:672937918844:key/9ff96772-259f-4397-9cec-f86ac3f6c78d"}]}
JSON
aws iam create-policy --policy-name ESOReadDbSecret --policy-document file://eso-policy.json

kubectl create namespace petclinic
eksctl create iamserviceaccount \
  --cluster tgo-staging-eks --namespace petclinic \
  --name external-secrets-sa \
  --attach-policy-arn arn:aws:iam::672937918844:policy/ESOReadDbSecret \
  --approve --override-existing-serviceaccounts

helm repo add external-secrets https://charts.external-secrets.io && helm repo update
helm install external-secrets external-secrets/external-secrets \
  -n external-secrets --create-namespace --set installCRDs=true

kubectl apply -f gitops/petclinic/externalsecret.yaml
kubectl -n petclinic get externalsecret,secret
```

Two things bit me here. First, my manifest used external-secrets.io/v1beta1 but the newer
operator serves v1 - I changed the apiVersion to v1. Second, the k8s secret got created but
held the literal strings "{{ .password }}" instead of the real values, because ESO v1
defaults to template engine v2 and my template didn't say so. Fix was to set
engineVersion: v2 explicitly in the ExternalSecret. After that:

```bash
kubectl -n petclinic get secret petclinic-db -o jsonpath='{.data.url}' | base64 -d; echo
# -> jdbc:postgresql://tgo-staging-postgres...:5432/petclinic  (real value, not a template)
```

### Argo CD (GitOps)

```bash
helm repo add argo https://argoproj.github.io/argo-helm && helm repo update
helm install argocd argo/argo-cd -n argocd --create-namespace
kubectl -n argocd rollout status deploy/argocd-server

kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
kubectl -n argocd port-forward svc/argocd-server 8080:443   # UI at https://localhost:8080, user admin
```

Argo CD pulls from a Git repo, so the gitops/ folder has to be on GitHub and the
Application's repoURL has to point at it. I set repoURL in gitops/apps/petclinic-app.yaml to
my repo (a public repo, so no credentials needed), pushed, then:

```bash
kubectl apply -f gitops/apps/petclinic-app.yaml
kubectl -n argocd get applications        # OutOfSync at first is fine
```

### Argo Rollouts (canary)

```bash
helm install argo-rollouts argo/argo-rollouts -n argo-rollouts --create-namespace
kubectl -n argo-rollouts rollout status deploy/argo-rollouts

curl -sLO https://github.com/argoproj/argo-rollouts/releases/latest/download/kubectl-argo-rollouts-linux-amd64
chmod +x kubectl-argo-rollouts-linux-amd64
sudo mv kubectl-argo-rollouts-linux-amd64 /usr/local/bin/kubectl-argo-rollouts

kubectl -n argocd patch application petclinic --type merge -p '{"operation":{"sync":{}}}'
kubectl argo rollouts get rollout petclinic -n petclinic
kubectl -n petclinic get pods
```

The app runs as a Rollout, not a Deployment, so a new image tag triggers the canary
(20% -> analysis -> 50% -> 100%). Two real issues I hit: PetClinic crash-looped on the
second replica with a unique-constraint violation because both pods ran the seed script
against the same RDS at once (fix: SPRING_SQL_INIT_MODE=never after the first seed; for a
real setup I'd use Flyway or a one-shot Job). And the canary analysis errored with "no such
host" for the Prometheus service until Prometheus was actually installed - which is the
gate working correctly: it refuses to promote without a passing metric.

### Expose the app

```bash
kubectl apply -f gitops/petclinic/ingress.yaml
kubectl -n petclinic get ingress -w       
address=$(kubectl -n petclinic get ingress petclinic -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl -s -o /dev/null -w "%{http_code}\n" "http://$address/"   
```

That 200 (and the PetClinic page in a browser) is the whole path: internet -> ALB -> pod ->
RDS, secrets from Secrets Manager.

## Part 3 - monitoring, logging, alerting

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts && helm repo update
helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack -n monitoring --create-namespace
helm install loki grafana/loki-stack -n monitoring --set promtail.enabled=true --set loki.persistence.enabled=false
kubectl -n monitoring get pods
```

To get PetClinic's own metrics (request rate, error rate, latency) scraped, I added a
ServiceMonitor and named the Service port "http" (Prometheus matches by port name):

```bash
kubectl apply -f - <<'SM'
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: petclinic
  namespace: petclinic
  labels: { release: kube-prometheus-stack }
spec:
  selector: { matchLabels: { app: petclinic } }
  endpoints: [{ port: http, path: /actuator/prometheus, interval: 15s }]
SM
```

The release: kube-prometheus-stack label is what makes Prometheus adopt it. I confirmed the
target was UP at http://localhost:9090/targets (port-forward the prometheus service), and
that http_server_requests_seconds_count had data after hitting the app a few times.

Grafana and the dashboard:

```bash
kubectl -n monitoring get secret kube-prometheus-stack-grafana -o jsonpath='{.data.admin-password}' | base64 -d; echo
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80

```

That one dashboard has: application log volume (Loki), error rate, CPU/memory, response
time + request rate, and a note panel for RDS DB metrics (those come from CloudWatch /
Performance Insights, which I enabled on the DB in Terraform, since RDS isn't scraped by
Prometheus).

Alerting + error budget:

```bash
kubectl apply -f monitoring/alert-rules.yaml   
```

The SLO is 99.5% availability over 30 days (0.5% error budget). The policy - what you do as
the budget burns - and the multi-window burn-rate alerts are in docs/error-budget-and-alerting.md.
Alerts route to email via Alertmanager (SMTP config snippet is in that doc).

## Part 4 - security, compliance, cost

- Secrets: generated by Terraform, stored in Secrets Manager under a KMS customer-managed
  key, pulled into pods by External Secrets. Never in Git, never in an image.
- KMS: a customer-managed key encrypts RDS storage, the secret, and EKS secrets (envelope
  encryption on the cluster).
- IAM least privilege: controllers get scoped roles via IRSA (OIDC) instead of node-wide
  credentials; the ESO role can read exactly one secret and decrypt with one key.
- Encryption in transit: the ALB is the TLS termination point (I ran HTTP for the demo;
  production adds an ACM cert + HTTPS listener - documented, not done).
- Vulnerability scanning and the GitHub Actions CI pipeline (build/push image, scan
  Docker/IaC/deps, notify) are the remaining piece I'm wiring in .github/workflows.
- Cost: one NAT instead of one per AZ, small instances, and strict teardown between
  sessions. Estimates and Infracost usage are in docs/technical-design.md.

## Part 6 - scripts and the Istio scenario

The S3 sync script (no third-party tools, skips existing files, logs, emails a summary,
optional KMS):

```bash
python3 scripts/s3_sync.py --dir ./testdata --bucket artifacts-6729
python3 scripts/s3_sync.py --dir ./testdata --bucket artifacts-6729   
python3 scripts/s3_sync.py --dir ./testdata --bucket artifacts-6729 --kms-key-id 9ff96772-259f-4397-9cec-f86ac3f6c78d
```

The Istio "pod running but no traffic" troubleshooting runbook is in docs/istio-debug.md -
it's a written scenario (outside-in: Kubernetes checks first, then the mesh), with the
kubectl and istioctl commands for each check.




## Challenges faced and how I resolved them

These are the real problems I hit, in the order they happened. Each one cost time; each
taught something, so I'm keeping them here rather than pretending the build was clean.

1. SSM agent wouldn't register (assignment carried over to how I think about nodes).
   On the bastion/nodes, the SSM agent on Ubuntu ships as a snap and doesn't always start
   cleanly on boot. Symptom: the node never appeared in `aws ssm describe-instance-information`.
   Fix: explicitly start the agent in user-data, and verify registration before assuming a
   networking problem.

2. Bastion couldn't read the DB secret - and that was correct.
   `aws secretsmanager get-secret-value` from the bastion returned AccessDenied. That's
   least privilege working: I never gave the bastion role secret access. I fetched the
   password from my laptop for the psql test, and noted that granting the bastion a scoped
   read of that one secret is the clean follow-up.

3. AWS Load Balancer Controller crash-looped: "failed to fetch VPC ID from instance
   metadata: context deadline exceeded". Root cause: my nodes enforce IMDSv2 with a
   restricted hop limit, so the controller pod couldn't reach the metadata service to
   auto-discover the VPC. Fix: pass region and vpcId explicitly to the Helm chart instead
   of relying on auto-discovery. This pairs correctly with the IMDSv2 hardening rather than
   weakening it.

4. External Secrets CRD version mismatch. My manifest used external-secrets.io/v1beta1 but
   the installed operator serves v1 ("no matches for kind SecretStore in version v1beta1").
   Fix: bump the apiVersion to v1. Confirmed with `kubectl api-resources | grep external-secrets`.

5. External Secret synced but held literal template strings. The k8s secret contained
   "{{ .password }}" instead of the real value. Cause: ESO v1 defaults to template engine
   v2 and my template didn't declare it. Fix: set engineVersion: v2 explicitly. Verified by
   base64-decoding the secret and seeing a real JDBC URL.

6. PetClinic crash-looped on the second replica: duplicate key on unique_owner_pet_name.
   Both pods ran the seed script against the same RDS at once; the second lost the race. The
   script's WHERE NOT EXISTS guard checks a different column than the unique index. Fix for
   now: SPRING_SQL_INIT_MODE=never after the first seed. Proper fix I'd do next: run seeding
   as a one-shot Kubernetes Job, or use Flyway/Liquibase migrations instead of app-startup
   seeding.

7. Canary aborted: analysis couldn't resolve the Prometheus service ("no such host"). This
   was the analysis gate doing its job - it refuses to promote without a passing metric, and
   Prometheus wasn't installed yet. Correct sequencing: deploy the app with weight-based
   canary first, install Prometheus, then re-enable metric analysis so the canary gates on
   real data.

8. ServiceMonitor scraped nothing until the Service port was named. Prometheus matches a
   ServiceMonitor endpoint by port name; my Service port was unnamed. Fix: name it "http"
   and add the release: kube-prometheus-stack label so the stack's Prometheus adopts the
   ServiceMonitor.

9. Small operational papercuts worth noting: kubectl/eksctl/helm and the SSM plugin are all
   separate installs from the AWS CLI; Windows vs WSL path differences (backslash vs forward
   slash) broke a script run; and a stuck `terraform apply` on EKS is usually just the
   cluster taking its 15 minutes, not a failure.

## Tearing it down (do this in order, or you leak billable resources)

```bash
kubectl delete -f gitops/petclinic/ingress.yaml     
helm uninstall aws-load-balancer-controller -n kube-system
eksctl delete iamserviceaccount --cluster tgo-staging-eks --namespace kube-system --name aws-load-balancer-controller
eksctl delete iamserviceaccount --cluster tgo-staging-eks --namespace petclinic --name external-secrets-sa
cd infra/envs/staging && terraform destroy
```

Then check the console for anything left behind: load balancers, target groups, Elastic
IPs, NAT gateways. EKS and the load balancer controller are notorious for leaving orphans,
and each one keeps billing. The KMS key stays in a 7-day pending-deletion window after
destroy - that's expected and costs almost nothing.

## Git branching

main is protected and always deployable - changes go through a PR that runs CI, and merging
to main is what CD acts on. Work happens on short-lived feature/* branches. Because deploys
are GitOps, whatever the gitops/ folder on main says is what Argo CD makes true in the
cluster. Production changes additionally require a manual approval before the rollout
proceeds.

Kubernetes/Istio Debug Scenario
first I can Is the Pod actually alive and ready?
verify pod shows ready ``` kubectl get pods -n <namespace>```
 then check service is pointing to pod or not  ```kubectl get endpoints <service_name> -n <namespace>```
check port and targetport is correct ot not
if issue is not from above then check the sidecar status is it awake and updated `istioctl proxy-status`.
then if rules are valid `istioctl analyze - <namespace>`.

```kubectl logs <pod-name> -c istio-proxy -n <namespace>```
---

