source scenario/signing-ongoing/common_setup.sh

info "Starting to monitor signatures"
./push-fake-image/measure-signed.py --server "$( oc whoami --show-server )" --namespace benchmark --token "$( oc whoami -t )" --insecure --save ./measure-signed.csv &
measure_signed_pid=$!
