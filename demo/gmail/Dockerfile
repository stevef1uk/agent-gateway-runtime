FROM python:3.12-slim
ARG GMAIL_UID=1000
ARG GMAIL_GID=1000
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY connector.py ingress.py ./
# Docker initializes the named data volume from this owned directory.
RUN mkdir /data && chown ${GMAIL_UID}:${GMAIL_GID} /data
USER ${GMAIL_UID}:${GMAIL_GID}
EXPOSE 8092
HEALTHCHECK --interval=5s --timeout=3s --retries=10 CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8092/healthz', timeout=2)"
CMD ["python", "connector.py"]
