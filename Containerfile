FROM registry.fedoraproject.org/fedora-minimal

USER 0
RUN microdnf -y install coreutils jq golang-oras
USER 1001

CMD oras --help
