Push fake image
===============

This container, Tekton Task, Pipeline and PipelineRun are just pushing fake container image. They are meant for testing artifact signing performance by Tekton Chains.

To use it:

    $ oc -n benchmark apply -f scenario/signing-ongoing/pipeline.yaml
    task.tekton.dev/push-fake-image configured
    pipeline.tekton.dev/push-fake-image configured
    $ sed "s/DOCKERCONFIG_SECRET_NAME/<your_dockerconfig_secret>/g" scenario/signing-ongoing/run-source.yaml >run.yaml
    $ oc -n benchmark create -f run.yaml
    pipelinerun.tekton.dev/push-fake-image-44fk8 created
    $ oc -n benchmark logs pod/push-fake-image-44fk8-push-fake-image-pod
    [...]
    $ oc -n benchmark get TaskRun/push-fake-image-44fk8-push-fake-image -o json | jq --raw-output '.status.results[] | select(.name=="IMAGE_URL").value'
    image-registry.openshift-image-registry.svc.cluster.local:5000/benchmark/test:push-fake-image-44fk8
