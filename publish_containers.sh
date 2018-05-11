#!/bin/bash
for line in $(cat container.list); do
  tagsArr=(${line//,/ })
  src_image=${tagsArr[0]}
  target_image=${tagsArr[1]}
  docker pull ${src_image}
  docker tag ${src_image} ${target_image}
  docker push ${target_image}
done
