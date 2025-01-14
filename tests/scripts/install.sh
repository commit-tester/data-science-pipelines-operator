#!/bin/bash

echo "Installing kfDef from test directory"

set -x

ODHREPO=${ODHREPO:-"data-science-pipelines-operator"}

## Install the opendatahub-operator
pushd ~/peak
retry=5
if ! [ -z "${SKIP_OPERATOR_INSTALL}" ]; then
    ## SKIP_OPERATOR_INSTALL is used in the opendatahub-operator repo
    ## because openshift-ci will install the operator for us
    echo "Relying on odh operator installed by openshift-ci"
    ./setup.sh -t ~/peak/operatorsetup 2>&1
else
  echo "Installing operator from community marketplace"
  while [[ $retry -gt 0 ]]; do
    ./setup.sh -o ~/peak/operatorsetup 2>&1
    if [ $? -eq 0 ]; then
      retry=-1
    else
      echo "Trying restart of marketplace community operator pod"
      oc delete pod -n openshift-marketplace $(oc get pod -n openshift-marketplace -l marketplace.operatorSource=community-operators -o jsonpath="{$.items[*].metadata.name}")
      sleep 3m
    fi
    retry=$(( retry - 1))
    sleep 1m
  done
fi
popd
## Grabbing and applying the patch in the PR we are testing
pushd ~/src/${ODHREPO}
if [ -z "$PULL_NUMBER" ]; then
  echo "No pull number, assuming nightly run"
else
  curl -O -L https://github.com/${REPO_OWNER}/${REPO_NAME}/pull/${PULL_NUMBER}.patch
  echo "Applying following patch:"
  cat ${PULL_NUMBER}.patch > ${ARTIFACT_DIR}/github-pr-${PULL_NUMBER}.patch
  git am ${PULL_NUMBER}.patch
fi
popd
## Point kfctl_openshift.yaml to the manifests in the PR
pushd ~/kfdef
if [ -z "$PULL_NUMBER" ]; then
  echo "No pull number, not modifying kfctl_openshift.yaml"
else
  IMAGE_TAG=${IMAGE_TAG:-"quay.io/opendatahub/data-science-pipelines-operator:pr-$PULL_NUMBER"}
  sed -i "s#value: quay.io/opendatahub/data-science-pipelines-operator:latest#value: $IMAGE_TAG#" ./kfctl_openshift.yaml
  if [ $REPO_NAME == $ODHREPO ]; then
    echo "Setting manifests in kfctl_openshift to use pull number: $PULL_NUMBER"
    sed -i "s#uri: https://github.com/opendatahub-io/${ODHREPO}/tarball/main#uri: https://api.github.com/repos/opendatahub-io/${ODHREPO}/tarball/pull/${PULL_NUMBER}/head#" ./kfctl_openshift.yaml
  fi
fi

if ! [ -z "${SKIP_KFDEF_INSTALL}" ]; then
  ## SKIP_KFDEF_INSTALL is useful in an instance where the
  ## operator install comes with an init container to handle
  ## the KfDef creation
  echo "Relying on existing KfDef because SKIP_KFDEF_INSTALL was set"
else
  echo "Creating the following KfDef"
  cat ./kfctl_openshift.yaml > ${ARTIFACT_DIR}/kfctl_openshift.yaml
  oc apply -f ./kfctl_openshift.yaml
  kfctl_result=$?
  if [ "$kfctl_result" -ne 0 ]; then
    echo "The installation failed"
    exit $kfctl_result
  fi
fi
set +x
popd
