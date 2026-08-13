FROM ghcr.io/ggml-org/llama.cpp:server-cuda

COPY healthcheck-slots.sh /healthcheck-slots.sh
COPY supervisor.sh /supervisor.sh

ENTRYPOINT ["/bin/sh", "/supervisor.sh"]
