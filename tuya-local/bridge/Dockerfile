FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY controller.py service.py pairing.py local_network.py ./
COPY catalog ./catalog
USER 1000:1000
ENTRYPOINT ["python", "service.py"]
CMD ["serve", "--bind", "0.0.0.0"]
