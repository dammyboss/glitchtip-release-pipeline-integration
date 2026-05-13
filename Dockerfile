# syntax=docker/dockerfile:1
FROM us-central1-docker.pkg.dev/bespokelabs/nebula-devops-registry/nebula-devops:1.1.0

ENV ALLOWED_NAMESPACES="bleater,glitchtip,gitea,argocd"
