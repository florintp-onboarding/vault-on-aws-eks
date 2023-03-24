#!/bin/bash

#Check the arguments
[ $# -eq 0 ] && export NAMESPACE=vault || export NAMESPACE=$1

#Delete the MYSQL namespace - by default is mysql
kubectl get deployments -n mysql 2>/dev/null |grep  mysql
[ $? -eq 0 ] && kubectl delete deployment mysql -n mysql

#Delete the pod devwebapp
kubectl get pods 2>/dev/null |grep devwebapp
[ $? -eq 0 ] && kubectl delete pod devwebapp

#Delete the license secret
kubectl get secrets -n ${NAMESPACE?} 2>/dev/null|tail -n1|grep vault-license  
[ $? -eq 0 ] && kubectl delete secrets vault-license -n ${NAMESPACE?}

#Delete the Vault namespace - by default is vault
kubectl get namespace ${NAMESPACE?} 2>/dev/null
[ $? -eq 0 ] && kubectl delete namespace ${NAMESPACE}

#Delete the MYSQL namespace - by default is mysql
kubectl get namespace mysql 2>/dev/null
[ $? -eq 0 ] && kubectl delete namespace mysql

#Delete the helm chart vault
helm list -n ${NAMESPACE?} 2>/dev/null|grep vault
[ $? -eq 0 ] && helm uninstall vault -n ${NAMESPACE?}

#Delete the mysql helchart
helm list 2>/dev/null|grep mysql
[ $? -eq 0 ] && helm uninstall mysql

#Delete the yaml files
rm -f vault-auth-service-account.yaml vault-auth-secret.yaml devwebapp.yaml init-keys.json

#kubectl delete deployment,svc mysql
#kubectl delete pvc mysql-pv-claim
#kubectl delete pv mysql-pv-volume


