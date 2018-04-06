#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

[[ ${DEBUG:-} == 'true' ]] && set -x

private_registry=${1}
kube_conformance_home="${2}"
kube_version_full="${KUBE_VERSION_FULL:-${3}}"

blacklist_image() {
  grep -v gcr.io/google-containers/cassandra-e2e-test:0.1 | grep -v '{{' | grep -v mysql-e2e-test:0.1 | grep -v mysql:5.7.15
}

get_images() {
  if [[ "${file##*.}" == "yaml" ]]; then
    grep 'image:' ${file}| blacklist_image | cut -d':' -f2,3,4
  fi
  if [[ "${file##*.}" == "json" ]]; then
    grep '"image":' ${file}| blacklist_image | cut -d'"' -f4
  fi
}

gettag() {
  base_image=$(basename $image)
  tag="${private_registry}/${base_image}"
}

savetags() {
  echo "${image},${tag}">>${kube_conformance_home}/container.list
}

patchfile() {
  if grep ${image} ${file} >/dev/null; then
    if ! grep ${tag} ${file} >/dev/null; then
      echo "patching ${file} from ${image} to ${tag}"
      sed -i "s\\${image}\\${tag}\g" ${file}
    fi
  fi
}

fix_images() {
  echo "processing ${file}"
  for image in $(get_images); do
    [[ "${image}" =~ ".jpg" ]] && continue
    gettag
    [[ "${image}" == "${tag}" ]] && continue
    savetags
    patchfile
  done
}

is_clean_version() {
  local ver=${1}
  [[ "$(git describe)"    == "${ver}" ]] || return 1
  [[ "$(git ls-files -m)" == ""       ]] || return 1
  return 0
}

get_k8_src() {
  # For now...
  if [ ! -d ~/go/src/k8s.io/kubernetes ]; then
    mkdir -p ~/go/src/k8s.io
    cd ~/go/src/k8s.io
    git clone https://github.com/kubernetes/kubernetes
    cd kubernetes
    git checkout ${kube_version_full}
  fi
  cd ~/go/src/k8s.io/kubernetes
  if ! is_clean_version ${kube_version_full} ; then
    echo "Not proceeding with dirty Kubernetes - expecting ${kube_version_full} in ${PWD}"
    return 1
  fi
}

publish() {
    mv _output/release-stage/test/kubernetes/platforms/linux/amd64/e2e.test ${kube_conformance_home}/
    echo "Now run ${kube_conformance_home}/publish_containers.sh to pull, retag and push all the containers..."
}

build_e2e() {
  if go run hack/e2e.go -- --build ; then
    git checkout .
    return 0
  else
    git checkout .
    return 1
  fi
}

find_and_patch_images() {
  if [[ -f ${kube_conformance_home}/container.list ]]; then
    rm ${kube_conformance_home}/container.list
  fi
  for patch in ${kube_conformance_home}/patches/*.diff ; do
    if git apply --check ${patch} &>/dev/null; then
      git apply ${patch}
    fi
  done

  for file in $(find test/e2e/testing-manifests/ -name "*.yaml") ; do
    fix_images
  done

  for file in $(find test/images/ -name "*.json" -o -name "*.yaml") ; do
    fix_images
  done

  for image in "gcr.io/google_containers/pause:3.0" ; do
    gettag
    savetags
  done

  # pull and push the images defined from the manefests...
  declare -A registries
  registries=( ["e2eRegistry"]="gcr.io/kubernetes-e2e-test-images" \
               ["gcRegistry"]="gcr.io/google-containers" \
               ["PrivateRegistry"]="gcr.io/k8s-authenticated-test" \
               ["sampleRegistry"]="gcr.io/google-samples" )
  for public_registry in "${registries[@]}" ; do
    for imagebits in $(grep ImageConfig test/utils/image/manifest.go \
      | grep $public_registry \
      | cut -d'"' -f 2,3,4 | grep -v func | grep -v struct | tr '" ,"' "_" ); do
      image=${registries[$public_registry]}/${imagebits/____/-amd64:}
      gettag
      savetags
    done
  done
}

get_k8_src
find_and_patch_images
build_e2e || return 1
publish
