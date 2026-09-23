# kubectl comes from the upstream Kubernetes image, which is distroless and has no
# shell. Alpine supplies the shell the gate script needs, and nothing else.
ARG KUBECTL_VERSION=v1.35.8

FROM registry.k8s.io/kubectl:${KUBECTL_VERSION} AS kubectl

FROM alpine:3.24
RUN apk add --no-cache ca-certificates \
 && adduser -u 65532 -D -H -s /sbin/nologin nonroot
COPY --from=kubectl /bin/kubectl /usr/local/bin/kubectl
COPY gate/stack-gate.sh /usr/local/bin/stack-gate
RUN chmod 0755 /usr/local/bin/stack-gate /usr/local/bin/kubectl
USER 65532:65532
ENTRYPOINT ["/usr/local/bin/stack-gate"]
