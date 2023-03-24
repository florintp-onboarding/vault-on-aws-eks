#!/bin/bash
# https://docs.aws.amazon.com/eks/latest/userguide/managing-ebs-csi.html
# https://developer.hashicorp.com/vault/tutorials/kubernetes/kubernetes-amazon-eks
# https://kubernetes.io/docs/tasks/run-application/run-single-instance-stateful-application/

export DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
chmod +rx ${DIR}/clean.sh
${DIR}/clean.sh


#Set minimal variables
export NAMESPACE='vault'
export CLUSTEREKSNAME='k8s-eks'
export VAULT_LICENSE=$(cat ./vault_license.hclic)
export ROOT_PASSWORD="change_me_unsecure"
export AWSKEYSSH=mykeypair1

# getcreds
# kubectl config get-contexts
# kubectl config use-context 

if [ "Z${VAULT_LICENSE}" == "Z" ] ||
   [ "Z${AWS_ACCOUNT_ID}" == "Z" ] ; then
   echo "Environment is not correctly set!"
   exit 1
fi


function create_iam {

  eksctl create iamserviceaccount \
  --name ebs-csi-controller-sa \
  --namespace kube-system \
  --cluster $CLUSTEREKSNAME \
  --attach-policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy \
  --approve \
  --role-only \
  --role-name AmazonEKS_EBS_CSI_DriverRole
}


function create_eks_cluster {
  # Delete EKS cluster
  eksctl get cluster -n $CLUSTEREKSNAME  -o json 2>/dev/null|jq -r '.[].Status'|grep -i 'ACTIVE' || eksctl get cluster -n $CLUSTEREKSNAME -o json 2>/dev/null |jq -r '.[].Status'|grep -i 'DELETING' && echo 
  if [ $? -eq 0 ] ; then
    echo "Cluster: $CLUSTEREKSNAME is already ACTIVE!"
    echo "Destroy EKS?[Default n]" ; read ans
    # Destroy will involve creation
    if [ "Z$ans" == "Zy" ] ; then
      eksctl delete cluster --region=eu-central-1 --name=$CLUSTEREKSNAME 2>/dev/null
      while eksctl get cluster -n $CLUSTEREKSNAME  -o json |jq -r '.[].Status'|grep -i 'DELETING'  ; do
         echo . ; sleep 1
      done
      echo "EKS Cluster $CLUSTEREKSNAME has been destroyed!"
    else
      echo "SKIP destroying $CLUSTEREKSNAME... will reuse it!"
    fi
  else
    # Create EKS cluster if not already ACTIVE
    eksctl get cluster -n $CLUSTEREKSNAME  -o json |jq -r '.[].Status'|grep -i 'ACTIVE' 2>/dev/null
    [ $? -eq 0 ] || eksctl create cluster \
--name ${CLUSTEREKSNAME} \
--nodes 4 \
--with-oidc \
--ssh-access \
--ssh-public-key ${AWSKEYSSH} \
--managed
   [ $? -eq 0 ] && echo "EKS cluster created."
 fi

 #eksctl utils update-cluster-logging --enable-types=all --region=eu-central-1 --cluster=$CLUSTEREKSNAME
 eksctl upgrade cluster --name $CLUSTEREKSNAME --version 1.25 --approve

 # Add the EBS CSI driver
 eksctl create addon --name aws-ebs-csi-driver --cluster $CLUSTEREKSNAME  --service-account-role-arn arn:aws:iam::${AWS_ACCOUNT_ID}:role/AmazonEKS_EBS_CSI_DriverRole --force
 
 # The current version of the EBS  CSI driver
 # aws eks describe-addon-versions --addon-name aws-ebs-csi-driver
 
 # Optional update the driver
 eksctl get addon --name aws-ebs-csi-driver --cluster $CLUSTEREKSNAME
 
 # If only the role is found it means that there is no update
 #eksctl get addon --name aws-ebs-csi-driver --cluster $CLUSTEREKSNAME |tail -n1 | awk -F '/' '{print $NF}'|grep -v AmazonEKS_EBS_CSI_DriverRole
 _new_version=$(eksctl get addon --name aws-ebs-csi-driver --cluster $CLUSTEREKSNAME|tail -n1 | awk -F '/' '{print $NF}'|grep -v AmazonEKS_EBS_CSI_DriverRole)
 if [ "X${_new_version?}" == "X" ] ; then
   eksctl get addon --name aws-ebs-csi-driver --cluster $CLUSTEREKSNAME
   echo 'Nothing to update, the add-on is the latest...'
 else
   eksctl update addon --name aws-ebs-csi-driver --version $(eksctl get addon --name aws-ebs-csi-driver --cluster $CLUSTEREKSNAME |tail -n1|awk '{print $NF}')  --cluster $CLUSTEREKSNAME --force
 fi
 #
 kubectl get nodes
}

function create_mysql {
  #Install mysql helm chart
  #####helm repo add bitnami https://charts.bitnami.com/bitnami
  #####helm list -n default|grep mysql
  #####[ $? -eq 0 ] && echo "SKIP install MYSQL helm chart as it is already installed.... "|| helm install mysql bitnami/mysql
  #export ROOT_PASSWORD=$(kubectl get secret --namespace default mysql -o jsonpath="{.data.mysql-root-password}" | base64 --decode)
 # kubectl create namespace mysql
  kubectl apply -f mysql-secret.yaml
  kubectl apply -f mysql-pv.yaml 
  kubectl apply -f mysql-deployment.yaml
  kubectl get pods -l app=mysql
  echo "MYSQL deployment created."
}


function create_vault {
  helm repo add hashicorp https://helm.releases.hashicorp.com 1>/dev/null
  helm template  vault hashicorp/vault  --output-dir ./rendered_templates -f values.yaml 1>/dev/null
  helm repo update 1>/dev/null
  
  kubectl create namespace vault
  kubectl create secret generic \
  	vault-license \
  	--from-literal=VAULT_LICENSE=${VAULT_LICENSE} \
  	-n ${NAMESPACE} 
  
  helm install vault hashicorp/vault \
  	--namespace="${NAMESPACE?}" \
  	-f ${DIR?}/values.yaml 1>/dev/null
  
  sleep 5
  kubectl get pods -n $NAMESPACE
  kubectl get pvc
  
  kubectl wait pods -n ${NAMESPACE?} -l app.kubernetes.io/name=vault --for condition=Running --timeout=10s
  kubectl get pods -n ${NAMESPACE?}
  sleep 5
  kubectl exec -it vault-0 -n ${NAMESPACE?} -- vault operator init -format=json -t 1 -n 1 |tee -a init-keys.json
  
  VAULT_UNSEAL_KEY=$(jq -r ".unseal_keys_b64[]" init-keys.json)
  VAULT_ROOT_KEY=$(jq -r ".root_token" init-keys.json)
  sleep 10 
  kubectl exec -it vault-0 -n ${NAMESPACE?}  -- vault operator unseal ${VAULT_UNSEAL_KEY?}
  sleep 5
set -x
  for i in $(seq 4) ; do
    kubectl exec -it vault-${i?} -n ${NAMESPACE?}  -- vault operator raft join "http://vault-0.vault-internal:8200"
    sleep 3
    kubectl exec -it vault-${i?} -n ${NAMESPACE?}  -- vault operator unseal ${VAULT_UNSEAL_KEY?}
    sleep 3
    vstatus=$(kubectl exec vault-${i?} -n ${NAMESPACE?} -- vault status -format=json |jq -r '.sealed')
    [ "Z${vstatus}" == "Ztrue" ] && sleep 3
  done
  set +x
  kubectl get pods -n ${NAMESPACE?}
}

#MAIN body
create_eks_cluster

create_iam

create_mysql

create_vault

export VAULT_TOKEN=$VAULT_ROOT_KEY
# Get Vault addr
export EXTERNAL_VAULT_ADDR=$(kubectl get rc,services -n vault|grep 'vault-ui'|awk '{print $(NF-2)}')
export VAULT_ADDR="http://$EXTERNAL_VAULT_ADDR:8200"
export VAULT_TOKEN=$(jq -r ".root_token" init-keys.json)

vault login $VAULT_TOKEN
vault secrets enable database
vault auth enable kubernetes
vault write -f database/config/mysql \
    plugin_name=mysql-database-plugin \
    connection_url="{{username}}:{{password}}@tcp(mysql.default.svc.cluster.local:3306)/" \
    allowed_roles="readonly" \
    verify_connection=false \
    username="root" \
    password="$ROOT_PASSWORD"

cat >vault-auth-service-account.yaml<< EOF1
apiVersion: v1
kind: ServiceAccount
metadata:
  name: vault-auth
  namespace: default
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: role-tokenreview-binding
  namespace: default
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:auth-delegator
subjects:
- kind: ServiceAccount
  name: vault-auth
  namespace: default
EOF1

cat >vault-auth-secret.yaml<<EOF2
apiVersion: v1
kind: Secret
metadata:
  name: vault-auth-secret
  annotations:
    kubernetes.io/service-account.name: vault-auth
type: kubernetes.io/service-account-token
EOF2

kubectl apply --filename vault-auth-service-account.yaml
kubectl apply --filename vault-auth-secret.yaml

export SA_SECRET_NAME=$(kubectl get secrets --output=json \
    | jq -r '.items[].metadata | select(.name|startswith("vault-auth-")).name')

export SA_JWT_TOKEN=$(kubectl get secret $SA_SECRET_NAME \
    --output 'go-template={{ .data.token }}' | base64 --decode)

export SA_CA_CRT=$(kubectl config view --raw --minify --flatten \
    --output 'jsonpath={.clusters[].cluster.certificate-authority-data}' | base64 --decode)

export K8S_HOST=$(kubectl config view --raw --minify --flatten \
    --output 'jsonpath={.clusters[].cluster.server}')

#echo -e "export SA_SECRETNAME=$SA_SECRET_NAME\n export SA_JWT_TOKEN='"$SA_JWT_TOKEN"' \n export SA_CA_CRT='"$SA_CA_CRT"' \n export K8S_HOST=$K8S_HOST"

# Writting Kubernetes configuration
vault write auth/kubernetes/config \
     token_reviewer_jwt="$SA_JWT_TOKEN" \
     kubernetes_host="$K8S_HOST" \
     kubernetes_ca_cert="$SA_CA_CRT" \
     issuer="https://kubernetes.default.svc.cluster.local"

# Read the kubernetes auth configuration
vault read auth/kubernetes/config

vault write auth/kubernetes/role/example \
     bound_service_account_names=vault-auth \
     bound_service_account_namespaces=default \
     token_policies=myapp-kv-ro \
     ttl=24h

cat > devwebapp.yaml <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: devwebapp
  labels:
    app: devwebapp
spec:
  serviceAccountName: vault-auth
  containers:
    - name: devwebapp
      image: burtlo/devwebapp-ruby:k8s
      env:
        - name: VAULT_ADDR
          value: "http://$EXTERNAL_VAULT_ADDR:8200"
EOF

#Deploy the devwebapp
kubectl apply --filename devwebapp.yaml --namespace default
kubectl wait --for condition=Ready  pod/devwebapp  --timeout=20s -o jsonpath="{range .items[*].status.conditions[?(.type == 'Ready')]}{.type} is {.status}{end}"
kubectl get pods |grep devwebapp

export KUBE_TOKEN=$(kubectl exec --stdin=true --tty=true devwebapp -- cat /var/run/secrets/kubernetes.io/serviceaccount/token )
echo "TOKEN found on devwebapp: $KUBE_TOKEN"

export TEMP_TOKEN=$(curl -s --request POST \
       --data '{"jwt": "'"$KUBE_TOKEN"'", "role": "example"}' \
       $VAULT_ADDR/v1/auth/kubernetes/login|jq -r '.auth.client_token')
echo TEMP_TOKEN=$(echo $TEMP_TOKEN|sed 's/"//g')
unset VAULT_TOKEN 
[ "Z$TEMP_TOKEN" == "Znull" ] && set -x && echo RETRY
export TEMP_TOKEN=$(curl --request POST \
       --data '{"jwt": "'"$KUBE_TOKEN"'", "role": "example"}' \
       $VAULT_ADDR/v1/auth/kubernetes/login|jq -r '.auth.client_token')
echo TEMP_TOKEN=$(echo $TEMP_TOKEN|sed 's/"//g')
vault login "$TEMP_TOKEN"

echo -e "\nUse: \n./clean.sh $NAMESPACE \n to cleanup the Kubernetes\n"
