function cosign_generate_key_pair_secret() {
    export COSIGN_PASSWORD=reset
    before=$( date +%s )
    while ! cosign generate-key-pair -d k8s://openshift-pipelines/signing-secrets; do
        now=$( date +%s )
        [ $(( $now - $before )) -gt 300 ] && fatal "Was not able to create signing-secrets secret in time"
        debug "Waiting for next attempt for creation of signing-secrets secret"
        # Few steps to get us to simple state
        oc -n openshift-pipelines get secrets/signing-secrets || true
        oc -n openshift-pipelines delete secrets/signing-secrets || true
        sleep 10
    done
}

# Configure Chains as per https://tekton.dev/docs/chains/signed-provenance-tutorial/#configuring-tekton-chains
kubectl patch TektonConfig/config --type='merge' -p='{"spec":{"chain":{"disabled": false}}}'
kubectl patch TektonConfig/config --type='merge' -p='{"spec":{"chain":{"artifacts.taskrun.format": "slsa/v1"}}}'
kubectl patch TektonConfig/config --type='merge' -p='{"spec":{"chain":{"artifacts.taskrun.storage": "oci"}}}'
kubectl patch TektonConfig/config --type='merge' -p='{"spec":{"chain":{"artifacts.oci.storage": "oci"}}}'
kubectl patch TektonConfig/config --type='merge' -p='{"spec":{"chain":{"transparency.enabled": "false"}}}'   # this is the only difference from the docs

# Create signing-secrets secret
cosign_generate_key_pair_secret

# Wait for Chains controller to come up
wait_for_entity_by_selector 300 openshift-pipelines deployment app.kubernetes.io/name=controller,app.kubernetes.io/part-of=tekton-chains
oc -n openshift-pipelines rollout restart deployment/tekton-chains-controller
oc -n openshift-pipelines rollout status deployment/tekton-chains-controller
oc -n openshift-pipelines wait --for=condition=ready --timeout=300s pod -l app.kubernetes.io/part-of=tekton-chains

# Create ImageStreamTag we will be pushing to
oc -n benchmark create imagestream test

# SA to talk to internal registry
oc -n benchmark create serviceaccount perf-test-registry-sa
oc policy add-role-to-user registry-viewer system:serviceaccount:benchmark:perf-test-registry-sa   # pull
oc policy add-role-to-user registry-editor system:serviceaccount:benchmark:perf-test-registry-sa   # push

# Load SA to be added to PipelineRun
dockerconfig_secret_name=$( oc -n benchmark get serviceaccount perf-test-registry-sa -o json | jq --raw-output '.imagePullSecrets[0].name' )

info "Generating Pipeline and PipelineRun"
[[ "$TEST_SCENARIO" != "signing-ongoing" ]] && cp scenario/signing-ongoing/pipeline.yaml scenario/$TEST_SCENARIO/pipeline.yaml
sed "s/DOCKERCONFIG_SECRET_NAME/$dockerconfig_secret_name/g" scenario/signing-ongoing/run-source.yaml >scenario/$TEST_SCENARIO/run.yaml
