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

function chains_setup_oci_oci() {
    info "Setting up Chains with oci/oci"

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
}

function chains_start() {
    info "Enabling Chains"
    cosign_generate_key_pair_secret   # it was removed when we disabled Chains
    cat "benchmark-tekton.json" | jq '.results.started = "'"$( date -Iseconds --utc )"'"' >"$$.json" && mv -f "$$.json" "benchmark-tekton.json"
    kubectl patch TektonConfig/config --type='merge' -p='{"spec":{"chain":{"disabled": false}}}'
}

function chains_stop() {
    info "Disabling Chains"
    kubectl patch TektonConfig/config --type='merge' -p='{"spec":{"chain":{"disabled": true}}}'
}

function internal_registry_setup() {
    info "Setting up internal registry"

    # Create ImageStreamTag we will be pushing to
    oc -n benchmark create imagestream test

    # SA to talk to internal registry
    oc -n benchmark create serviceaccount perf-test-registry-sa
    oc policy add-role-to-user registry-viewer system:serviceaccount:benchmark:perf-test-registry-sa   # pull
    oc policy add-role-to-user registry-editor system:serviceaccount:benchmark:perf-test-registry-sa   # push

    # Load SA to be added to PipelineRun
    dockerconfig_secret_name=$( oc -n benchmark get serviceaccount perf-test-registry-sa -o json | jq --raw-output '.imagePullSecrets[0].name' )
}

function standalone_registry_setup() {
    info "Deploy standalone registry"

    # Create secrets
    kubectl -n utils create secret generic registry-certs --from-file=registry.crt=scenario/common/certs/registry.crt --from-file=registry.key=scenario/common/certs/registry.key
    kubectl -n utils create secret generic registry-auth --from-file=scenario/common/certs/htpasswd

    # Deployment
    kubectl -n utils apply -f scenario/common/registry.yaml
    oc -n utils get deployment --show-labels
    wait_for_entity_by_selector 300 utils pod app=registry
    kubectl -n utils wait --for=condition=ready --timeout=300s pod -l app=registry

    # Dockenconfig to access the registry
    kubectl -n benchmark create secret docker-registry test-dockerconfig --docker-server=registry.utils.svc.cluster.local:5000 --docker-username=test --docker-password=test --docker-email=test@example.com
}

function pipeline_and_pipelinerun_setup() {
    local image_name="$1"
    local dockerconfig_secret_name="$2"

    info "Generating Pipeline and PipelineRun"
    cp scenario/common/pipeline.yaml scenario/$TEST_SCENARIO/pipeline.yaml
    cp scenario/common/run.yaml scenario/$TEST_SCENARIO/run.yaml
    sed -i "s|IMAGE_NAME|$image_name|g" scenario/$TEST_SCENARIO/run.yaml
    sed -i "s|DOCKERCONFIG_SECRET_NAME|$dockerconfig_secret_name|g" scenario/$TEST_SCENARIO/run.yaml
}

function imagestreamtags_wait() {
    info "Collecting info about imagestreamtags"
    before=$( date +%s )
    while true; do
        oc -n benchmark get imagestreamtags.image.openshift.io -o json >imagestreamtags.json
        count_all=$( cat imagestreamtags.json | jq --raw-output '.items | length' )
        count_signatures=$( cat imagestreamtags.json | jq --raw-output '.items | map(select(.metadata.name | endswith(".sig"))) | length' )
        count_attestations=$( cat imagestreamtags.json | jq --raw-output '.items | map(select(.metadata.name | endswith(".att"))) | length' )
        count_plain=$( cat imagestreamtags.json | jq --raw-output '.items | map(select((.metadata.name | endswith(".sig") | not) and (.metadata.name | endswith(".att") | not))) | length' )
        if [[ $count_plain -eq $count_signatures ]] && [[ $count_plain -eq $count_attestations ]]; then
            debug "All artifacts present"
            break
        else
            now=$( date +%s )
            if [ $(( $now - $before )) -gt $(( $TEST_TOTAL * 3 + 100 )) ]; then
                warning "Not all artifacts present ($count_plain/$count_signatures/$count_attestations) but we have already waited for $(( $now - $before )) seconds, so giving up."
                break
            fi
            debug "Not all artifacts present yet ($count_plain/$count_signatures/$count_attestations), waiting bit more"
            sleep 10
        fi
    done

    cat "benchmark-tekton.json" | jq '.results.imagestreamtags.sig = '$count_signatures' | .results.imagestreamtags.att = '$count_attestations' | .results.imagestreamtags.plain = '$count_plain' | .results.imagestreamtags.all = '$count_all'' >"$$.json" && mv -f "$$.json" "benchmark-tekton.json"
    debug "Got these counts of imagestreamtags: all=${count_all}, plain=${count_plain}, signatures=${count_signatures}, attestations=${count_attestations}"

    # Only now, when all imagestreamtags are in, we can consider the test done
    last_pushed=$( cat imagestreamtags.json | jq --raw-output '.items | sort_by(.metadata.creationTimestamp) | last | .metadata.creationTimestamp' )
    cat "benchmark-tekton.json" | jq '.results.ended = "'"$last_pushed"'"' >"$$.json" && mv -f "$$.json" "benchmark-tekton.json"
    debug "Configured test end time to match when last imagestreamtag was created: $last_pushed"
}

function measure_signed_start() {
    info "Starting measure-signed.py to monitor signatures"
    ./push-fake-image/measure-signed.py --server "$( oc whoami --show-server )" --namespace benchmark --token "$( oc whoami -t )" --insecure --save ./measure-signed.csv &
    measure_signed_pid=$!
    echo "$measure_signed_pid" >./measure-signed.pid
    debug "Started with PID $measure_signed_pid"
}

function measure_signed_stop() {
    info "Stopping measure-signed.py PID $( cat ./measure-signed.pid )"
    kill "$( cat ./measure-signed.pid )" || true
    rm -f ./measure-signed.pid
}

function internal_registry_cleanup() {
    if ${TEST_DO_CLEANUP:-true}; then
        oc -n benchmark delete serviceaccount/perf-test-registry-sa
        oc -n benchmark delete imagestreamtags/test
    fi
}
