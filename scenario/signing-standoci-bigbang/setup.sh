source scenario/signing-ongoing/common_setup.sh

kubectl patch TektonConfig/config --type='merge' -p='{"spec":{"chain":{"disabled": true}}}'

info "Deploy standalone registry"
kubectl create namespace utils
kubectl -n utils create secret generic registry-certs --from-file=registry.crt=scenario/signing-standoci-bigbang/certs/registry.crt --from-file=registry.key=scenario/signing-standoci-bigbang/certs/registry.key
kubectl -n utils create secret generic registry-auth --from-file=scenario/signing-standoci-bigbang/certs/htpasswd
kubectl -n utils apply -f scenario/signing-standoci-bigbang/registry.yaml
oc -n utils get deployment --show-labels
wait_for_entity_by_selector 300 utils pod app=registry
kubectl -n utils wait --for=condition=ready --timeout=300s pod -l app=registry

kubectl -n benchmark create secret docker-registry test-dockerconfig --docker-server=registry.utils.svc.cluster.local:5000 --docker-username=test --docker-password=test --docker-email=test@example.com
sed -i 's|^\(\s\+\)value: "image-registry.openshift-image-registry.svc.cluster.local:5000/.*|\1value: "registry.utils.svc.cluster.local:5000/benchmark/test:$(context.pipelineRun.name)"|' scenario/signing-standoci-bigbang/run.yaml
sed -i 's|"perf-test-registry-sa-dockercfg-[^"]*"|"test-dockerconfig"|' scenario/signing-standoci-bigbang/run.yaml
