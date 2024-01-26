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

info "Stopping measure-signed.py PID $measure_signed_pid"
kill "$measure_signed_pid" || true

if ${TEST_DO_CLEANUP:-true}; then
    oc -n benchmark delete serviceaccount/perf-test-registry-sa
    oc -n benchmark delete imagestreamtags/test
fi
