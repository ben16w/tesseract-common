FROM ghcr.io/serveurpersocom/qwentts.cpp:vulkan

RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends \
        python3 \
    > /dev/null && rm -rf /var/lib/apt/lists/*

ARG BASE_URL="https://huggingface.co/Serveurperso/Qwen3-TTS-GGUF/resolve/main"
ARG TALKER
ARG TOKENIZER

RUN mkdir -p /models && \
    curl -L --progress-bar -o "/models/$TALKER" "$BASE_URL/$TALKER" && \
    curl -L --progress-bar -o "/models/$TOKENIZER" "$BASE_URL/$TOKENIZER"

COPY proxy.py start.sh /app/
RUN chmod +x /app/start.sh

ENTRYPOINT ["/app/start.sh"]
