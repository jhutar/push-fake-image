info "Starting to monitor signatures"
./push-fake-image/measure-signed.py --server "$( oc whoami --show-server )" --namespace benchmark --token "$( oc whoami -t )" --insecure --save ./measure-signed.csv --verbose &
measure_signed_pid=$!

info "Enabling Chains"
cosign_generate_key_pair_secret   # it was removed when we disabled Chains
cat "benchmark-tekton.json" | jq '.results.started = "'"$( date -Iseconds --utc )"'"' >"$$.json" && mv -f "$$.json" "benchmark-tekton.json"
kubectl patch TektonConfig/config --type='merge' -p='{"spec":{"chain":{"disabled": false}}}'

source scenario/signing-ongoing/common_tierdown.sh
