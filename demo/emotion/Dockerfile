ARG EMOTION_BASE_IMAGE=stevef1uk/emotion-service:amd64
FROM ${EMOTION_BASE_IMAGE} AS emotion

FROM alpine:3.22 AS llama-library-links
RUN mkdir -p /links \
    && ln -s libggml-base.so /links/libggml-base.so.0 \
    && ln -s libggml-cpu.so /links/libggml-cpu.so.0 \
    && ln -s libggml.so /links/libggml.so.0 \
    && ln -s libllama-common.so /links/libllama-common.so.0 \
    && ln -s libllama.so /links/libllama.so.0 \
    && ln -s libmtmd.so /links/libmtmd.so.0

FROM emotion
COPY --from=llama-library-links /links/ /app/llama_libs/
