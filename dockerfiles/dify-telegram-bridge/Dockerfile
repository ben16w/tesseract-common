FROM python:3.13-alpine

RUN apk add --no-cache ca-certificates

WORKDIR /app

COPY bridge.py /app/bridge.py

ENTRYPOINT ["python3", "/app/bridge.py"]
