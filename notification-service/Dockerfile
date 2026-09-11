FROM python:3.13-slim
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /app
COPY --chmod=644 notifier.py healthcheck.py /app/
ENTRYPOINT ["python", "/app/notifier.py", "--home", "/data"]
