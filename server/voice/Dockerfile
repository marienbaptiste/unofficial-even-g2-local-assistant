# Even G2 Voice Service — App layer (source code only, rebuilds in seconds)
# Requires base image: docker build -f voice/Dockerfile.base -t even-g2-voice-base ./voice

FROM even-g2-voice-base

ENV TORCH_FORCE_NO_WEIGHTS_ONLY_LOAD=1

WORKDIR /app

COPY *.py ./

EXPOSE 8081

CMD ["python3", "-m", "uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8081"]
