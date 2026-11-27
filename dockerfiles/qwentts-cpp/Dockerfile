FROM ghcr.io/serveurpersocom/qwentts.cpp:vulkan

RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends \
        python3 ffmpeg \
    > /dev/null && rm -rf /var/lib/apt/lists/*

ARG BASE_URL="https://huggingface.co/Serveurperso/Qwen3-TTS-GGUF/resolve/main"
ARG MODEL_FILE
ARG CODEC_FILE

RUN mkdir -p /models && \
    curl -L --progress-bar -o "/models/$MODEL_FILE" "$BASE_URL/$MODEL_FILE" && \
    curl -L --progress-bar -o "/models/$CODEC_FILE" "$BASE_URL/$CODEC_FILE"

COPY proxy.py /app/

ENTRYPOINT ["python3", "/app/proxy.py"]
