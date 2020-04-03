#!/usr/bin/env bash

# Copyright 2020 Rasa Technologies GmbH
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Exit immediately if one of the commands ends with a non-zero exit code
set -e

boolean() {
  case $1 in
    true) echo true ;;
    false) echo false ;;
    *) echo "Err: Unknown boolean value \"$1\"" 1>&2; exit 1 ;;
   esac
}

# The script can either use `wget` or `curl` to pull other scripts
DOWNLOADER=

# Environment variables
DISABLE_TELEMETRY=${DISABLE_TELEMETRY}
ENABLE_DUCKLING=${ENABLE_DUCKLING}
INSTALLER_DEBUG_MODE=$(boolean "${INSTALLER_DEBUG_MODE:-false}")

# Passwords
INITIAL_USER_PASSWORD=${INITIAL_USER_PASSWORD}
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
RABBITMQ_PASSWORD=${RABBITMQ_PASSWORD}
REDIS_PASSWORD=${REDIS_PASSWORD}

# Versions
RASA_X_VERSION=${RASA_X_VERSION:-0.27.3}
RASA_VERSION=${RASA_VERSION:-1.9.2}

# Action server
ACTION_SERVER_IMAGE=${ACTION_SERVER_IMAGE}
ACTION_SERVER_TAG=${ACTION_SERVER_TAG}

# Deployment
DEBUG_MODE=${DEBUG_MODE}
DEPLOYMENT_NAME=${DEPLOYMENT_NAME:-rasa}
DEPLOYMENT_NAMESPACE=${DEPLOYMENT_NAMESPACE:-rasa}
NGINX_SERVICE_TYPE=${NGINX_SERVICE_TYPE:-LoadBalancer}

# Additional
ADDITIONAL_CHANNEL_CREDENTIALS=${ADDITIONAL_CHANNEL_CREDENTIALS}

if $INSTALLER_DEBUG_MODE
then
  set +x
  REDIRECT=/dev/stdout
else
  REDIRECT=/dev/null
fi

# Helper functions
echo_success() {
  echo -e "\e[32m${1}\e[0m"
}

echo_bold() {
  echo -e "\e[1m${1}\e[0m"
}

fatal() {
  echo "$@" >&2
  exit 1
}

run_loading_animation() {
  i=1
  sp="/-\|"
  while :
  do
    sleep 0.1
    # Don't show spinner when we are debugging
    if ! $INSTALLER_DEBUG_MODE
    then
      printf "\b%s" ${sp:i++%${#sp}:1}
    fi
  done
}

download() {
  [ $# -eq 1 ] || fatal 'download needs exactly 1 argument'

  case ${DOWNLOADER} in
    curl)
      curl -sfL "$1"
      ;;
    wget)
      wget -O - -o /dev/null "$1"
      ;;
    *)
      fatal "Incorrect executable '${DOWNLOADER}'"
      ;;
  esac

  # Abort if download command failed
  [[ $? ]] || fatal 'Download failed'
}

does_command_exist() {
  command -v "$1" > /dev/null
}

verify_downloader() {
    # Return failure if it doesn't exist or is no executable
    does_command_exist "$1" || return 1

    # Set verified executable as our downloader program and return success
    DOWNLOADER=$1
    return 0
}

check_if_can_be_installed() {
  OS=$(uname | tr '[:upper:]' '[:lower:]')
  if [[ $OS != "linux" ]]
  then
    fatal "Running this script is only supported on Linux systems."
  fi

  verify_downloader curl || verify_downloader wget || fatal 'Cannot find curl or wget for downloading files'
}

install_os_specific_requirements() {
  if [[ -f /etc/os-release ]]
  then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS=$NAME
  fi

  if [[ ${OS} == "CentOS Linux" ]] || [[  ${OS} == "Red Hat"* ]]
  then
    yum check-update -y -q || true
    # Don't fail in case it's already installed
    yum install -y -q policycoreutils-python-utils || true
    # Centos 8 does not include this in the `PATH`
    export PATH=$PATH:/usr/local/bin
  fi
}

is_kubectl_installed_and_configured() {
  # detect if kubectl command is available
  does_command_exist "kubectl" || return 1

  # detect if server is configured
  kubectl version --short | grep -q 'Server Version: .*' || return 1
}

export_k3s_kubeconfig() {
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
}

install_k3s() {
  echo "Installing embedded Kubernetes cluster ..."

  if does_command_exist "setenforce"
  then
    setenforce 0
  fi

  # Install an embedded Kubernetes cluster using K3s
  download https://get.k3s.io | sh - > ${REDIRECT}

  # Export the kubeconfig so that `kubectl` can access it later
  export_k3s_kubeconfig

  # Make it readable for no root users since they otherwise can't use `kubectl`
  chmod 744 ${KUBECONFIG}

  kubectl config set-context --current --namespace="${DEPLOYMENT_NAMESPACE}" > ${REDIRECT}
}

install_helm() {
  echo "Installing Helm command line interface  ..."

  # Install Helm
  download https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 | bash > ${REDIRECT}

  # Check if the `helm` command is available
  if ! does_command_exist "helm"
  then
    fatal "Something went wrong when trying to install the Helm command line interface.\
 This is required for Rasa X deployment. Please create a question for this in the Rasa\
 Forum (forum.rasa.com) so that we can help you."
  fi
}

no_root_helm() {
  # We don't run `helm` commands as `root` user because metadata, like added chart repos
  # are else stored in the cache for the `root` user.
  envs="PATH=$PATH:/usr/local/bin"
  if $IS_EMBEDDED_CLUSTER
  then
    sudo -u "$SUDO_USER" bash -c "$envs KUBECONFIG=/etc/rancher/k3s/k3s.yaml helm $*"
  else
    sudo -u "$SUDO_USER" bash -c "$envs helm $*"
  fi
}


get_latest_chart_from_repository() {
  # Get and install Rasa X chart
  if ! no_root_helm repo list &> /dev/null | grep -q "^rasa-x"
  then
    no_root_helm repo add rasa-x https://rasahq.github.io/rasa-x-helm > ${REDIRECT}
  fi
  no_root_helm repo update > ${REDIRECT}
}

generate_not_yet_specified_passwords() {
  INITIAL_USER_PASSWORD=$(get_specified_password_or_generate "${INITIAL_USER_PASSWORD}")
  POSTGRES_PASSWORD=$(get_specified_password_or_generate "${POSTGRES_PASSWORD}")
  RABBITMQ_PASSWORD=$(get_specified_password_or_generate "${RABBITMQ_PASSWORD}")
  REDIS_PASSWORD=$(get_specified_password_or_generate "${REDIS_PASSWORD}")
}

get_specified_password_or_generate() {
  if [[ -z $1 ]]
  then
    # shellcheck disable=SC2005
    echo "$(< /dev/urandom tr -dc _A-Z-a-z-0-9 | head -c20)"
  else
    echo "$1"
  fi
}

is_rasa_x_deployed() {
  no_root_helm ls --namespace "${DEPLOYMENT_NAMESPACE}" | grep "^${DEPLOYMENT_NAME}" | grep -q "rasa-x-[0-9.]*" || return 1
}

execute_helm_command() {
  if [[ $1 == "install" ]]
  then
    command=("install")
  else
    command=("upgrade" "--reuse-values")
  fi

  command=("${command[@]}"
    "--set rasax.tag=${RASA_X_VERSION}"
    "--set eventService.tag=${RASA_X_VERSION}"
    "--set nginx.tag=${RASA_X_VERSION}"
    "--set rasa.tag=${RASA_VERSION}-full"
  )

  if [[ $1 == "install" ]]
  then
    command=("${command[@]}"
      "--set rasax.initialUser.password=${INITIAL_USER_PASSWORD}"
      "--set global.postgresql.postgresqlPassword=${POSTGRES_PASSWORD}"
      "--set global.redis.password=${RABBITMQ_PASSWORD}"
      "--set rabbitmq.rabbitmq.password=${REDIS_PASSWORD}")
  fi

  if $IS_EMBEDDED_CLUSTER
  then
    command=("${command[@]}" "--set nginx.service.type=ClusterIP")
    command=("${command[@]}" "--set ingress.hosts[0].host=,ingress.hosts[0].paths={/}")
  else
    command=("${command[@]}" "--set nginx.service.type=${NGINX_SERVICE_TYPE}")
    # gcloud needs another path for the ingress than K3s
    command=("${command[@]}" "--set ingress.hosts[0].host=,ingress.hosts[0].paths={/*}")
  fi

  if  [[ $1 == "install" ]] || [[ -n "${DISABLE_TELEMETRY}" ]]
  then
    command=("${command[@]}" "--set rasax.disableTelemetry=${DISABLE_TELEMETRY:-false}")
  fi

  if  [[ $1 == "install" ]] || [[ -n "${ENABLE_DUCKLING}" ]]
  then
    command=("${command[@]}" "--set duckling.enabled=${ENABLE_DUCKLING:-False}")
  fi

  if  [[ $1 == "install" ]] || [[ -n "${ACTION_SERVER_IMAGE}" ]]
  then
    command=("${command[@]}" "--set app.name=${ACTION_SERVER_IMAGE:-rasa/rasa-x-demo}")
  fi

  if  [[ $1 == "install" ]] || [[ -n "${ACTION_SERVER_TAG}" ]]
  then
    command=("${command[@]}" "--set app.tag=${ACTION_SERVER_TAG:-${RASA_X_VERSION}}")
  fi

  if  [[ $1 == "install" ]] || [[ -n "${DEBUG_MODE}" ]]
  then
    command=("${command[@]}" "--set global.debugMode=${DEBUG_MODE:-False}")
  fi

  if [[ -n "${ADDITIONAL_CHANNEL_CREDENTIALS}" ]]
  then
    # additional credentials may be passed in comma separated, e.g.
    # facebook.verify="dasda",facebook.test="dasd"
    IFS=',' read -ra channels <<< "$ADDITIONAL_CHANNEL_CREDENTIALS"
    for channel_setting in "${channels[@]}"
    do
     command=("${command[@]}" "--set rasa.additionalChannelCredentials.$channel_setting")
    done
  fi

  command=("${command[@]}"
    "--set rasax.extraEnvs[0].name=QUICK_INSTALL"
    "--set-string rasax.extraEnvs[0].value=true"
    "--namespace ${DEPLOYMENT_NAMESPACE}" "${DEPLOYMENT_NAME}" "rasa-x/rasa-x"
  )

  no_root_helm "${command[@]}" > ${REDIRECT}
}

echo_rasa_is_deployed() {
  echo_success "\n\nWelcome to Rasa X ðŸŽ‰\n"

  echo "Rasa X is currently being deployed on your machine."

  if $IS_EMBEDDED_CLUSTER
  then
    echo "While you're waiting please add the following line to your terminal configuration\
 (depending on your operating system this is the '~/.bashrc' or '~/.zshrc' file).\
 This is needed so that you can access the embedded cluster using the 'kubectl' command\
 line interface."
    echo -e "\n\t$(echo_bold "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml")\n"
  fi
}

install_rasa_x_chart() {
  # Create namespace in case it does not exist
  kubectl create ns "${DEPLOYMENT_NAMESPACE}" &> /dev/null || true

  execute_helm_command install

  echo_rasa_is_deployed

    echo -e "Rasa X will be installed into the following Kubernetes namespace: \
$(echo_bold "${DEPLOYMENT_NAMESPACE}")\n"

  echo "Please save the following access credentials for later use:"

  echo -e "\nYour Rasa X password is $(echo_bold "${INITIAL_USER_PASSWORD}")"
  echo -e "\nThe passwords for the other services in the deployment are:

Database password (PostgreSQL): $(echo_bold "${POSTGRES_PASSWORD}")
Event Broker password (RabbitMQ): $(echo_bold "${RABBITMQ_PASSWORD}")
Lock Store password (Redis): $(echo_bold "${REDIS_PASSWORD}")
"

  echo "Deploying Rasa X ..."
}

wait_for_rasa_x_deployment() {
  # Use `/dev/null` for everything since the expected timeout will be logged to `stderr`
  kubectl wait \
    --namespace "${DEPLOYMENT_NAMESPACE}" \
    --for=condition=available \
    --timeout=10s \
    -l "app.kubernetes.io/component=rasa-x" deployment &> ${REDIRECT}
}

wait_till_deployment_finished() {
  # Run the loading animation in the background while are waiting for the deployment
  run_loading_animation &
  LOADING_ANIMATION_PID=$!
  # Kill loading animation when the install script is killed
  # Also mute error output in case the process was already killed before
  # shellcheck disable=SC2064
  trap "kill -9 ${LOADING_ANIMATION_PID} &> /dev/null || true" $(seq 1 15)

  # Wait until the Rasa deployment is up and running
  while ! wait_for_rasa_x_deployment
  do
    kubectl --namespace "${DEPLOYMENT_NAMESPACE}" get pod > ${REDIRECT}
  done

  # Stop the loading animation since the deployment is finished
  kill -9 ${LOADING_ANIMATION_PID}

  # Remove remnants of the spinner
  printf "\b"
}

provide_login_credentials() {
  # Explain how to access Rasa X
  PUBLIC_IP=$(curl -s http://whatismyip.akamai.com/)
  LOGIN_URL="http://${PUBLIC_IP}/login?username=me&password=${INITIAL_USER_PASSWORD}"

  echo -e "The deployment is ready ðŸŽ‰. "

  if $IS_EMBEDDED_CLUSTER
  then
    echo_success "You can now access Rasa X on this URL: ${LOGIN_URL}"
  fi
}

upgrade_rasa_x() {
  echo "Upgrading Rasa X ..."

  # Make sure we can access the embedded cluster
  if $IS_EMBEDDED_CLUSTER
  then
    export_k3s_kubeconfig
  fi

  execute_helm_command upgrade

  echo_rasa_is_deployed
}

uninstall() {
  K3S_UNINSTALL_SCRIPT="/usr/local/bin/k3s-uninstall.sh"
  if [[ -f ${K3S_UNINSTALL_SCRIPT} ]]
  then
    ${K3S_UNINSTALL_SCRIPT}
  else
    echo "K3s uninstall script not found."
  fi
}

if [[ $1 == "--uninstall" ]]
then
  echo "Uninstalling Rasa X... "
  uninstall
  exit 0
fi

check_if_can_be_installed
install_os_specific_requirements

if is_kubectl_installed_and_configured
then
  echo "Found existing cluster."
else
  install_k3s
fi

if does_command_exist "k3s"
then
  IS_EMBEDDED_CLUSTER=true
else
  IS_EMBEDDED_CLUSTER=false
fi

install_helm
get_latest_chart_from_repository

if is_rasa_x_deployed
then
  upgrade_rasa_x
  wait_till_deployment_finished
  echo -e "Upgrading was successful ðŸŽ‰. "
else
  generate_not_yet_specified_passwords
  install_rasa_x_chart
  wait_till_deployment_finished
  provide_login_credentials
fi
