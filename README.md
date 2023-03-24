# vault-on-aws-eks

[![license](http://img.shields.io/badge/license-apache_2.0-red.svg?style=flat)](https://github.com/florintp-onboarding/vault-on-aws-eks/blob/main/LICENSE)

# The scope of this repository is to deploy a Vault cluster with RAFT storage backend into an EKS cluster using the CloudFormation template.

The steps from this repository are closely following the Tutorial [Vault on Kubernetes in AWS EKS](https://developer.hashicorp.com/vault/tutorials/kubernetes/kubernetes-amazon-eks).

----

## Requirements
 - A Vault Vault Enterprise Edition [https://www.vaultproject.io]
 - An AWS account (https://aws.amazon.com/account/)  
 - AWS command-line interface (CLI) (https://docs.aws.amazon.com/eks/latest/userguide/getting-started-eksctl.html)
 - Amazon EKS CLI (https://aws.amazon.com/cli/)
 - Kubernetes CLI (https://kubernetes.io/docs/tasks/tools/install-kubectl/)
 - Helm CLI (https://helm.sh/docs/helm/)
 - A valid Vault Enterprise license.

----
## Steps to deploy an AWS EKS cluster and install a Vault cluster
1. First, create an AWS account, an AWS SSH KEY PAIR and ensure that all the requirements are met:
 - AWS CLI [`aws --version`]
 - Amazon EKS CLI [`eksctl info`]
 - Kubectl CLI [`kubectl version`]
 - Helm CLI [`helm version`]

2. Set the location of your working directory and clone this repo
````shell
gh repo clone florintp-onboarding/vault-on-aws-eks
````

3. Review and modify your desired cluster name and ssh kaypair in `deploy_vault_on_eks.sh`.
The variables CLUSTEREKSNAME and AWSKEYSS are having by default the values `k8s-eks` and respectively `mykeypar`.

4. Review the K8S configuration from the override `values.yaml` (default vault version is `tag: "1.13.0-ent"` and `replicas=3`)
```
server:
  image:
    repository: "hashicorp/vault-enterprise"
    tag: "1.13.0-ent"
    # Overrides the default Image Pull Policy
    pullPolicy: IfNotPresent
 ...
 ...
  # Configure the logging verbosity for the Vault server.
  # Supported log levels include: trace, debug, info, warn, error
  logLevel: "trace"
  logFormat: "standard"
  affinity: ""
  ha:
    enabled: true
    replicas: 3
 ...
 ```

5. Loading the necessary environment variables
```shell
#AWS
export AWS_ACCOUNT_ID=<your_aws_account_id>
# Vault license
cp <path_to_your_license>/your_vault_ent.license vault_license.hclic
```

6. Configure the AWS CLI details and AWS cli session
```shell
#As example you may need to export into environment the following variables
#export AWS_ACCESS_KEY_ID=<22222222>
#export AWS_ACCOUNT_ID=<1212121221>
#export AWS_SECRET_ACCESS_KEY=<rdlfkhdskhfkdshfkh_random>
#export AWS_SESSION_EXPIRATION=2023-03-25T00:09:14Z
#export AWS_SESSION_TOKEN=elkjrelwjrllekpiJLKJLLLLLLLLL

# Configure AWS cli
aws configure
```
```
# As example you may get something like:
# aws configure
# AWS Access Key ID [****************HEHO]:
# AWS Secret Access Key [****************e9k+]:
# Default region name [eu-central-1]:
# Default output format [None]:
```

7. Execute the creation script
```shell
chmod +rx deploy_vault_on_eks.sh
bash deploy_vault_on_eks.sh
```

8. Export the VAULT_ADDR, VAULT_TOKEN, login to Vault and check the status of Vault cluster
```shell
vault status
unset VAULT_TOKEN
export EXTERNAL_VAULT_ADDR=$(kubectl get rc,services -n vault|grep 'vault-ui'|awk '{print $(NF-2)}')
export VAULT_ADDR="http://$EXTERNAL_VAULT_ADDR:8200"
export VAULT_TOKEN=$(jq -r ".root_token" init-keys.json)
vault login $VAULT_TOKEN
vault secrets list
vault operator raft list-peers
```

9. Cleanup the infrastructure and local files
```shell
eksctl delete cluster --region=<eu-central-1> --name=<cluster_name>
bash clean.sh
```
