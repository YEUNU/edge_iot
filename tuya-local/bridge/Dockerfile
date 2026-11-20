FROM python:3.13-slim
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /app
COPY --chmod=644 requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY --chmod=644 controller.py service.py pairing.py ./
COPY catalog ./catalog
USER 1000:1000
ENTRYPOINT ["python", "service.py"]
CMD ["serve", "--bind", "0.0.0.0"]
