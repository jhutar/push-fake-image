source scenario/signing-ongoing/common_setup.sh

kubectl patch TektonConfig/config --type='merge' -p='{"spec":{"chain":{"disabled": true}}}'
